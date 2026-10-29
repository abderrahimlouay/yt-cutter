#!/usr/bin/env bash
# add_api.sh - writes the backend HTTP layer (schemas, routes, rate limiting, app wiring).
# Run it AFTER add_services.sh, from the yt-cutter project root:  bash add_api.sh
set -euo pipefail

ROOT="${1:-.}"
B="$ROOT/backend"

[ -f "$B/app/services/jobs.py" ] || { echo "Run add_services.sh first (backend/app/services/jobs.py not found)." >&2; exit 1; }

echo "[*] Writing API layer"

# ------------------------------------------------------------------ config: allowed_hosts
python3 - "$B" <<'PY'
import sys, pathlib
b = pathlib.Path(sys.argv[1])

cfg = b / "app/config.py"
text = cfg.read_text()
if "allowed_hosts" not in text:
    marker = '    cors_origins: list[str] = ["http://localhost:5173"]\n'
    assert marker in text, "config.py was modified; add allowed_hosts manually"
    text = text.replace(marker, marker + '    allowed_hosts: list[str] = ["localhost", "127.0.0.1"]\n')
    cfg.write_text(text)

env = b / ".env.example"
envtext = env.read_text() if env.exists() else ""
if "ALLOWED_HOSTS" not in envtext:
    with env.open("a") as f:
        if envtext and not envtext.endswith("\n"):
            f.write("\n")
        f.write('YTCUTTER_ALLOWED_HOSTS=["localhost","127.0.0.1"]\n')
PY

# ------------------------------------------------------------------ core/rate_limit.py
cat > "$B/app/core/rate_limit.py" <<'EOF'
"""Per-IP rate limiting (slowapi, in-memory storage)."""
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)
EOF

# ------------------------------------------------------------------ services/info_cache.py
cat > "$B/app/services/info_cache.py" <<'EOF'
"""Small TTL cache so /info followed by /cut does not run yt-dlp twice."""
import time

from app.services.ytdlp import VideoInfo


class InfoCache:
    def __init__(self, ttl_seconds: float = 300.0, max_entries: int = 256) -> None:
        self.ttl = ttl_seconds
        self.max_entries = max_entries
        self._data: dict[str, tuple[float, VideoInfo]] = {}

    def get(self, video_id: str) -> VideoInfo | None:
        entry = self._data.get(video_id)
        if entry is None:
            return None
        stored_at, info = entry
        if time.monotonic() - stored_at > self.ttl:
            self._data.pop(video_id, None)
            return None
        return info

    def set(self, video_id: str, info: VideoInfo) -> None:
        if len(self._data) >= self.max_entries:
            oldest = min(self._data, key=lambda k: self._data[k][0])
            self._data.pop(oldest, None)
        self._data[video_id] = (time.monotonic(), info)
EOF

# ------------------------------------------------------------------ api/schemas.py
cat > "$B/app/api/schemas.py" <<'EOF'
"""Request and response models."""
from typing import Literal

from pydantic import BaseModel, Field


class InfoRequest(BaseModel):
    url: str = Field(max_length=2048)


class InfoResponse(BaseModel):
    id: str
    title: str
    duration: float
    thumbnail: str | None = None


class CutRequest(BaseModel):
    url: str = Field(max_length=2048)
    start: float = Field(ge=0, le=86_400, allow_inf_nan=False, description="Start time in seconds")
    end: float = Field(gt=0, le=86_400, allow_inf_nan=False, description="End time in seconds")
    format: Literal["mp4", "mp3"] = "mp4"
    quality: Literal[360, 480, 720, 1080] = 720
    accurate: bool = Field(
        default=True,
        description="Re-encode at the cut points for a frame-accurate start (slower). "
        "False = fast mode, may start a few seconds early.",
    )


class JobCreated(BaseModel):
    job_id: str


class JobStatusResponse(BaseModel):
    id: str
    status: Literal["queued", "downloading", "processing", "done", "error"]
    progress: int
    message: str | None = None
    filename: str | None = None
    duration: float | None = None
EOF

# ------------------------------------------------------------------ api/routes.py
cat > "$B/app/api/routes.py" <<'EOF'
"""HTTP endpoints."""
import json
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Request
from fastapi.responses import FileResponse
from sse_starlette.sse import EventSourceResponse

from app.api.schemas import (
    CutRequest,
    InfoRequest,
    InfoResponse,
    JobCreated,
    JobStatusResponse,
)
from app.config import settings
from app.core.rate_limit import limiter
from app.core.security import ValidationError as InputError
from app.core.security import extract_video_id, normalize_url, validate_range
from app.services import ytdlp
from app.services.info_cache import InfoCache
from app.services.jobs import CutParams, Job, JobManager, JobStatus, TooManyJobs

router = APIRouter(prefix="/api")

JobId = Annotated[str, Path(pattern=r"^[A-Za-z0-9_-]{16,64}$")]

_MEDIA_TYPES = {"mp4": "video/mp4", "mp3": "audio/mpeg"}


def get_manager(request: Request) -> JobManager:
    return request.app.state.jobs


def get_cache(request: Request) -> InfoCache:
    return request.app.state.info_cache


def get_job(job_id: JobId, manager: Annotated[JobManager, Depends(get_manager)]) -> Job:
    job = manager.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


async def _lookup(url: str, cache: InfoCache) -> tuple[str, ytdlp.VideoInfo]:
    """Validate the URL and return (canonical_url, video info), using the cache."""
    try:
        video_id = extract_video_id(url)
        canonical = normalize_url(url)
    except InputError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from None

    info = cache.get(video_id)
    if info is None:
        try:
            info = await ytdlp.fetch_info(canonical)
        except ytdlp.VideoRejected as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        except ytdlp.YtDlpError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from None
        cache.set(video_id, info)
    return canonical, info


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.post("/info", response_model=InfoResponse)
@limiter.limit(settings.rate_limit_info)
async def video_info(
    request: Request,
    body: InfoRequest,
    cache: Annotated[InfoCache, Depends(get_cache)],
) -> InfoResponse:
    _, info = await _lookup(body.url, cache)
    return InfoResponse(
        id=info.id, title=info.title, duration=info.duration, thumbnail=info.thumbnail
    )


@router.post("/cut", response_model=JobCreated, status_code=202)
@limiter.limit(settings.rate_limit_cut)
async def start_cut(
    request: Request,
    body: CutRequest,
    cache: Annotated[InfoCache, Depends(get_cache)],
    manager: Annotated[JobManager, Depends(get_manager)],
) -> JobCreated:
    canonical, info = await _lookup(body.url, cache)

    # duration and title come from yt-dlp, never from the client
    try:
        validate_range(
            body.start,
            body.end,
            video_duration=info.duration,
            max_clip_seconds=settings.max_clip_seconds,
        )
    except InputError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from None

    params = CutParams(
        url=canonical,
        start=body.start,
        end=min(body.end, info.duration),
        fmt=body.format,
        quality=body.quality,
        accurate=body.accurate,
        title=info.title,
    )
    try:
        job = manager.create(params)
    except TooManyJobs as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from None
    return JobCreated(job_id=job.id)


@router.get("/jobs/{job_id}", response_model=JobStatusResponse)
def job_status(job: Annotated[Job, Depends(get_job)]) -> dict:
    return job.snapshot()


@router.get("/jobs/{job_id}/events")
async def job_events(
    job: Annotated[Job, Depends(get_job)],
    manager: Annotated[JobManager, Depends(get_manager)],
) -> EventSourceResponse:
    """Server-Sent Events: one JSON message per update, closes when the job ends."""

    async def stream():
        async for snap in manager.events(job):
            yield {"data": json.dumps(snap)}

    return EventSourceResponse(stream(), ping=15)


@router.get("/jobs/{job_id}/download")
def job_download(job: Annotated[Job, Depends(get_job)]) -> FileResponse:
    if job.status != JobStatus.DONE:
        raise HTTPException(status_code=409, detail="The clip is not ready yet")
    if job.file_path is None or not job.file_path.exists():
        raise HTTPException(status_code=410, detail="The clip has expired")
    return FileResponse(
        job.file_path,
        media_type=_MEDIA_TYPES[job.params.fmt],
        filename=job.filename,
        headers={"Cache-Control": "no-store"},
    )
EOF

# ------------------------------------------------------------------ main.py
cat > "$B/app/main.py" <<'EOF'
import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from starlette.datastructures import MutableHeaders
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app.api.routes import router
from app.config import settings
from app.core.rate_limit import limiter
from app.services import ffmpeg, ytdlp
from app.services.cleanup import cleanup_loop
from app.services.info_cache import InfoCache
from app.services.jobs import build_manager

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    ffmpeg.check_binaries()
    ytdlp.check_js_runtime()
    manager = build_manager()
    manager.purge_orphans()  # clear leftovers from a previous run
    app.state.jobs = manager
    app.state.info_cache = InfoCache()
    cleanup = asyncio.create_task(cleanup_loop(manager, settings.cleanup_interval_seconds))
    try:
        yield
    finally:
        cleanup.cancel()
        await asyncio.gather(cleanup, return_exceptions=True)
        await manager.shutdown()


class SecurityHeadersMiddleware:
    """Adds basic security headers (pure ASGI so streaming/SSE is not buffered)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers["X-Content-Type-Options"] = "nosniff"
                headers["X-Frame-Options"] = "DENY"
                headers["Referrer-Policy"] = "no-referrer"
            await send(message)

        await self.app(scope, receive, send_with_headers)


app = FastAPI(title="yt-cutter", version="0.1.0", lifespan=lifespan)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# the last middleware added is the outermost: reject bad Host headers first
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)
app.add_middleware(SecurityHeadersMiddleware)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)

app.include_router(router)
EOF

# ------------------------------------------------------------------ tests
cat > "$B/tests/test_health.py" <<'EOF'
from fastapi.testclient import TestClient

from app.main import app


def test_health() -> None:
    client = TestClient(app, base_url="http://localhost")
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
EOF

cat > "$B/tests/test_api.py" <<'EOF'
import asyncio
import json
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.core.rate_limit import limiter
from app.main import app
from app.services import ffmpeg, ytdlp
from app.services import jobs as jobs_mod

VID = "dQw4w9WgXcQ"
URL = f"https://www.youtube.com/watch?v={VID}"
INFO = ytdlp.VideoInfo(id=VID, title="Never Gonna: Give You Up", duration=212.0, thumbnail="https://i.ytimg.com/x.jpg")


@pytest.fixture
def state():
    return {"info_calls": 0, "delay": 0.05, "fail": None}


@pytest.fixture
def client(tmp_path, monkeypatch, state):
    monkeypatch.setattr(settings, "clips_dir", str(tmp_path / "clips"))
    monkeypatch.setattr(ffmpeg, "check_binaries", lambda: None)
    monkeypatch.setattr(ytdlp, "check_js_runtime", lambda: None)

    async def fake_fetch(url, timeout=30.0):
        state["info_calls"] += 1
        assert url == URL
        return INFO

    async def fake_download(*, out_dir: Path, on_progress, fmt, **kwargs):
        await asyncio.sleep(state["delay"])
        if state["fail"]:
            raise ytdlp.YtDlpError(state["fail"])
        out_dir.mkdir(parents=True, exist_ok=True)
        on_progress(40)
        f = out_dir / f"clip.{fmt}"
        f.write_bytes(b"fake-media")
        return f

    async def fake_probe(path, timeout=15.0):
        return 60.0

    monkeypatch.setattr(ytdlp, "fetch_info", fake_fetch)
    monkeypatch.setattr(jobs_mod.ytdlp, "download_section", fake_download)
    monkeypatch.setattr(jobs_mod.ffmpeg, "probe_duration", fake_probe)
    limiter.reset()
    with TestClient(app, base_url="http://localhost") as c:
        yield c


def cut(client, **overrides):
    body = {"url": URL, "start": 10, "end": 70}
    body.update(overrides)
    return client.post("/api/cut", json=body)


def wait_done(client, job_id, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        data = client.get(f"/api/jobs/{job_id}").json()
        if data["status"] in ("done", "error"):
            return data
        time.sleep(0.02)
    raise AssertionError("job did not finish")


def test_info(client, state):
    r = client.post("/api/info", json={"url": URL})
    assert r.status_code == 200
    assert r.json()["title"] == INFO.title
    assert r.json()["duration"] == 212.0


def test_info_rejects_foreign_urls(client):
    for bad in ["https://evil.com/watch?v=" + VID, "not a url", "file:///etc/passwd"]:
        assert client.post("/api/info", json={"url": bad}).status_code == 422


def test_info_cache_avoids_second_lookup(client, state):
    client.post("/api/info", json={"url": URL})
    cut(client)
    assert state["info_calls"] == 1


def test_full_flow_and_download(client):
    r = cut(client)
    assert r.status_code == 202
    job_id = r.json()["job_id"]
    data = wait_done(client, job_id)
    assert data["status"] == "done" and data["progress"] == 100
    assert data["filename"] == "Never_Gonna_Give_You_Up_0m10s-1m10s.mp4"

    d = client.get(f"/api/jobs/{job_id}/download")
    assert d.status_code == 200
    assert d.content == b"fake-media"
    assert d.headers["content-type"] == "video/mp4"
    assert "attachment" in d.headers["content-disposition"]
    assert d.headers["cache-control"] == "no-store"


def test_mp3_media_type(client):
    job_id = cut(client, format="mp3").json()["job_id"]
    wait_done(client, job_id)
    assert client.get(f"/api/jobs/{job_id}/download").headers["content-type"] == "audio/mpeg"


def test_sse_stream_ends_with_done(client):
    job_id = cut(client).json()["job_id"]
    events = []
    with client.stream("GET", f"/api/jobs/{job_id}/events") as r:
        assert r.headers["content-type"].startswith("text/event-stream")
        for line in r.iter_lines():
            if line.startswith("data:"):
                events.append(json.loads(line[5:].strip()))
                if events[-1]["status"] in ("done", "error"):
                    break
    assert events[-1]["status"] == "done"
    assert [e["progress"] for e in events] == sorted(e["progress"] for e in events)


def test_job_error_is_reported(client, state):
    state["fail"] = "Video unavailable"
    job_id = cut(client).json()["job_id"]
    data = wait_done(client, job_id)
    assert data["status"] == "error" and data["message"] == "Video unavailable"
    assert client.get(f"/api/jobs/{job_id}/download").status_code == 409


def test_download_before_ready_is_409(client, state):
    state["delay"] = 0.5
    job_id = cut(client).json()["job_id"]
    assert client.get(f"/api/jobs/{job_id}/download").status_code == 409


@pytest.mark.parametrize(
    "overrides",
    [
        {"start": -5},
        {"start": 50, "end": 40},
        {"start": 0, "end": 900},        # longer than max clip length
        {"start": 200, "end": 260},      # past the end of the 212 s video
        {"format": "avi"},
        {"quality": 999},
        {"url": "https://evil.com/x"},
    ],
)
def test_cut_validation(client, overrides):
    assert cut(client, **overrides).status_code == 422


def test_unknown_and_malformed_job_ids(client):
    assert client.get("/api/jobs/" + "a" * 20).status_code == 404
    assert client.get("/api/jobs/short").status_code == 422
    assert client.get("/api/jobs/" + "a" * 20 + "/download").status_code == 404


def test_cut_rate_limit(client):
    codes = [cut(client).status_code for _ in range(7)]
    assert codes[:5] == [202] * 5
    assert codes[5:] == [429, 429]


def test_bad_host_header_rejected(client):
    r = client.get("/api/health", headers={"host": "evil.example"})
    assert r.status_code == 400


def test_security_headers(client):
    r = client.get("/api/health")
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["x-frame-options"] == "DENY"


def test_cors_only_for_configured_origin(client):
    ok = client.get("/api/health", headers={"origin": "http://localhost:5173"})
    assert ok.headers.get("access-control-allow-origin") == "http://localhost:5173"
    bad = client.get("/api/health", headers={"origin": "http://evil.example"})
    assert "access-control-allow-origin" not in bad.headers
EOF

echo "[+] Done. Run the tests with:"
echo "    cd backend && source .venv/bin/activate && pytest -v"
echo "    uvicorn app.main:app --reload --port 8000   # then open http://localhost:8000/docs"
