#!/usr/bin/env bash
# add_services.sh - writes the backend services layer into an existing yt-cutter scaffold.
# Usage (from the yt-cutter project root):  bash add_services.sh
set -euo pipefail

ROOT="${1:-.}"
B="$ROOT/backend"

[ -d "$B/app/services" ] || { echo "Run this from the yt-cutter project root (backend/app/services not found)." >&2; exit 1; }

echo "[*] Writing config, security and services"

# ------------------------------------------------------------------ pytest config
cat > "$B/pytest.ini" <<'EOF'
[pytest]
pythonpath = .
testpaths = tests
EOF

# ------------------------------------------------------------------ requirements
# yt-dlp[default] includes yt-dlp-ejs, which YouTube extraction now needs together with a JS runtime.
cat > "$B/requirements.txt" <<'EOF'
fastapi>=0.110
uvicorn[standard]>=0.29
yt-dlp[default]
sse-starlette>=2.0
slowapi>=0.1.9
pydantic-settings>=2.2
EOF

# ------------------------------------------------------------------ config
cat > "$B/app/config.py" <<'EOF'
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="YTCUTTER_", extra="ignore")

    cors_origins: list[str] = ["http://localhost:5173"]
    clips_dir: str = "/tmp/yt-cutter"

    # JavaScript runtime yt-dlp uses to solve YouTube challenges (must be on PATH).
    # Node needs version 22+, Deno 2.3+.
    js_runtime: Literal["deno", "node", "bun", "quickjs"] = "node"

    # limits
    max_video_seconds: int = 3 * 3600
    max_clip_seconds: int = 600
    max_concurrent_jobs: int = 2
    max_pending_jobs: int = 10
    job_timeout_seconds: int = 900
    file_ttl_seconds: int = 1800
    cleanup_interval_seconds: int = 60

    # rate limits (slowapi syntax)
    rate_limit_info: str = "20/minute"
    rate_limit_cut: str = "5/minute"


settings = Settings()
EOF

cat > "$B/.env.example" <<'EOF'
YTCUTTER_CORS_ORIGINS=["http://localhost:5173"]
YTCUTTER_CLIPS_DIR=/tmp/yt-cutter
YTCUTTER_JS_RUNTIME=node
YTCUTTER_MAX_VIDEO_SECONDS=10800
YTCUTTER_MAX_CLIP_SECONDS=600
YTCUTTER_MAX_CONCURRENT_JOBS=2
YTCUTTER_MAX_PENDING_JOBS=10
YTCUTTER_JOB_TIMEOUT_SECONDS=900
YTCUTTER_FILE_TTL_SECONDS=1800
YTCUTTER_CLEANUP_INTERVAL_SECONDS=60
YTCUTTER_RATE_LIMIT_INFO=20/minute
YTCUTTER_RATE_LIMIT_CUT=5/minute
EOF

# ------------------------------------------------------------------ core/security.py
cat > "$B/app/core/security.py" <<'EOF'
"""Input validation: URL allowlist, clip range checks, filename sanitising."""
import math
import re
from urllib.parse import parse_qs, urlparse

ALLOWED_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
}
_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
_PATH_PREFIXES = {"shorts", "embed", "live", "v"}
_MAX_URL_LENGTH = 2048


class ValidationError(ValueError):
    """Raised when user input is rejected. The message is safe to show to the user."""


def extract_video_id(url: str) -> str:
    """Return the 11-character video id of a YouTube URL, or raise ValidationError."""
    if not isinstance(url, str) or not url.strip() or len(url) > _MAX_URL_LENGTH:
        raise ValidationError("Invalid URL")

    try:
        parsed = urlparse(url.strip())
        port = parsed.port
    except ValueError:
        raise ValidationError("Invalid URL") from None

    if parsed.scheme not in ("http", "https"):
        raise ValidationError("Only http(s) URLs are allowed")
    if parsed.username or parsed.password:
        raise ValidationError("Invalid URL")
    if port not in (None, 80, 443):
        raise ValidationError("Invalid URL")

    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise ValidationError("Only YouTube URLs are allowed")

    if host == "youtu.be":
        candidate = parsed.path.lstrip("/").split("/")[0]
    elif parsed.path == "/watch":
        candidate = parse_qs(parsed.query).get("v", [""])[0]
    else:
        parts = [p for p in parsed.path.split("/") if p]
        if len(parts) == 2 and parts[0] in _PATH_PREFIXES:
            candidate = parts[1]
        else:
            raise ValidationError("Could not find a video in this URL")

    if not _VIDEO_ID_RE.match(candidate):
        raise ValidationError("Could not find a valid video id in this URL")
    return candidate


def canonical_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def normalize_url(url: str) -> str:
    """Validate a URL and rebuild it from the video id.

    Everything downstream (yt-dlp) only ever sees this canonical form, so
    playlist parameters, redirects and option-like strings cannot get through.
    """
    return canonical_url(extract_video_id(url))


def validate_range(
    start: float,
    end: float,
    *,
    video_duration: float | None,
    max_clip_seconds: int,
) -> None:
    """Check that start/end describe a sensible clip."""
    if not (math.isfinite(start) and math.isfinite(end)):
        raise ValidationError("Invalid time range")
    if start < 0:
        raise ValidationError("Start time cannot be negative")
    if end <= start:
        raise ValidationError("End time must be after start time")
    if end - start > max_clip_seconds:
        raise ValidationError(f"Clip is too long (maximum {max_clip_seconds} seconds)")
    if video_duration is not None and end > video_duration + 1:
        raise ValidationError("End time is past the end of the video")


def sanitize_filename(title: str, fallback: str = "clip", max_len: int = 80) -> str:
    """Make a title safe to use as (part of) a download filename."""
    cleaned = "".join(ch for ch in title if ch.isprintable())
    cleaned = re.sub(r"[^\w\- .]", "_", cleaned)
    cleaned = re.sub(r"[\s_]+", "_", cleaned).strip("._ -")
    return cleaned[:max_len].strip("._ -") or fallback
EOF

# ------------------------------------------------------------------ services/ffmpeg.py
cat > "$B/app/services/ffmpeg.py" <<'EOF'
"""ffmpeg / ffprobe helpers."""
import asyncio
import shutil
from pathlib import Path


def check_binaries() -> None:
    """Raise RuntimeError at startup if ffmpeg or ffprobe are missing."""
    missing = [name for name in ("ffmpeg", "ffprobe") if shutil.which(name) is None]
    if missing:
        raise RuntimeError(
            f"Missing required binaries on PATH: {', '.join(missing)}. "
            "Install ffmpeg (e.g. 'sudo apt install ffmpeg')."
        )


async def probe_duration(path: Path, timeout: float = 15.0) -> float | None:
    """Return the media duration in seconds, or None if it cannot be read."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "ffprobe",
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except FileNotFoundError:
        return None

    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return None

    try:
        return float(out.decode().strip())
    except ValueError:
        return None
EOF

# ------------------------------------------------------------------ services/ytdlp.py
cat > "$B/app/services/ytdlp.py" <<'EOF'
"""yt-dlp wrapper: metadata lookup and section download.

yt-dlp is started with an argument list (never through a shell). URLs must be
normalised with core.security.normalize_url before they reach this module.
"""
import asyncio
import json
import re
import shutil
import sys
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from app.config import settings

Format = Literal["mp4", "mp3"]

_YTDLP = [sys.executable, "-m", "yt_dlp"]
_RUNTIME_BINARIES = {"deno": "deno", "node": "node", "bun": "bun", "quickjs": "qjs"}
_PCT_RE = re.compile(r"PCT:\s*([\d.]+)%")
_FINAL_SUFFIXES = {".mp4", ".mp3"}
_MAX_LINE = 1024 * 1024


def _base_cmd() -> list[str]:
    """yt-dlp command with the configured JavaScript runtime enabled (only deno is on by default)."""
    return [*_YTDLP, "--js-runtimes", settings.js_runtime]


def check_js_runtime() -> None:
    """Raise RuntimeError at startup if the configured JavaScript runtime is not installed."""
    binary = _RUNTIME_BINARIES[settings.js_runtime]
    if shutil.which(binary) is None:
        raise RuntimeError(
            f"yt-dlp needs a JavaScript runtime for YouTube, but '{binary}' was not found on PATH. "
            "Install Node 22+ (or Deno 2.3+), or set YTCUTTER_JS_RUNTIME to the runtime you have."
        )


class YtDlpError(RuntimeError):
    """yt-dlp failed. The message is short and safe to show to the user."""


class VideoRejected(YtDlpError):
    """The video exists but cannot be cut (live stream, too long, ...)."""


@dataclass(frozen=True)
class VideoInfo:
    id: str
    title: str
    duration: float
    thumbnail: str | None


def _friendly_error(lines: list[str]) -> str:
    for line in reversed(lines):
        if "ERROR:" in line:
            return line.split("ERROR:", 1)[1].strip()[:200] or "yt-dlp failed"
    return "yt-dlp failed"


async def _kill(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is None:
        proc.kill()
        await proc.wait()


async def fetch_info(url: str, timeout: float = 30.0) -> VideoInfo:
    """Fetch video metadata without downloading anything."""
    args = [
        *_base_cmd(),
        "--dump-single-json",
        "--no-playlist",
        "--no-warnings",
        "--skip-download",
        "--socket-timeout", "15",
        "--", url,
    ]
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        await _kill(proc)
        raise YtDlpError("Timed out while fetching video info") from None
    except asyncio.CancelledError:
        await _kill(proc)
        raise

    if proc.returncode != 0:
        raise YtDlpError(_friendly_error(err.decode(errors="replace").splitlines()))

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        raise YtDlpError("Could not read video info") from None

    if data.get("is_live"):
        raise VideoRejected("Live streams are not supported")
    duration = data.get("duration")
    if not duration:
        raise VideoRejected("This video has no known duration")
    if duration > settings.max_video_seconds:
        raise VideoRejected(
            f"Video is too long (maximum {settings.max_video_seconds // 60} minutes)"
        )

    return VideoInfo(
        id=data["id"],
        title=data.get("title") or "video",
        duration=float(duration),
        thumbnail=data.get("thumbnail"),
    )


def build_download_args(
    *,
    url: str,
    start: float,
    end: float,
    fmt: Format,
    quality: int,
    accurate: bool,
    out_dir: Path,
) -> list[str]:
    """Build the yt-dlp argument list for a section download (pure, easy to test)."""
    args = [
        *_base_cmd(),
        "--no-playlist",
        "--no-warnings",
        "--newline",
        "--socket-timeout", "15",
        "--retries", "3",
        "--concurrent-fragments", "4",
        "--progress-template", "download:PCT:%(progress._percent_str)s",
        "--download-sections", f"*{start:.3f}-{end:.3f}",
        "-o", str(out_dir / "clip.%(ext)s"),
    ]
    if accurate:
        # re-encode around the cut points so the clip starts exactly where requested
        args.append("--force-keyframes-at-cuts")

    if fmt == "mp3":
        args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
    else:
        args += [
            "-f",
            f"bv*[height<={quality}][vcodec^=avc1]+ba[ext=m4a]"
            f"/b[height<={quality}][ext=mp4]"
            f"/bv*[height<={quality}]+ba"
            f"/b[height<={quality}]/b",
            "--merge-output-format", "mp4",
        ]

    args += ["--", url]
    return args


class ProgressMapper:
    """Turns yt-dlp's per-stream percentages into one monotonic 0..95 value.

    A video+audio download reports 0-100% twice; a drop in the percentage means
    the next stream started. Returns a value only when it increases by a whole point.
    """

    def __init__(self, streams: int) -> None:
        self.streams = max(1, streams)
        self.index = 0
        self._last_pct = 0.0
        self._last_emit = -1

    def update(self, pct: float) -> int | None:
        if pct + 30 < self._last_pct and self.index < self.streams - 1:
            self.index += 1
        self._last_pct = pct
        value = int((self.index + min(pct, 100.0) / 100) / self.streams * 95)
        if value > self._last_emit:
            self._last_emit = value
            return value
        return None


async def download_section(
    *,
    url: str,
    start: float,
    end: float,
    fmt: Format,
    quality: int,
    accurate: bool,
    out_dir: Path,
    on_progress: Callable[[int], None],
    timeout: float | None = None,
) -> Path:
    """Download only [start, end] of the video and return the finished file."""
    out_dir.mkdir(parents=True, exist_ok=True)
    args = build_download_args(
        url=url, start=start, end=end, fmt=fmt, quality=quality,
        accurate=accurate, out_dir=out_dir,
    )
    mapper = ProgressMapper(streams=2 if fmt == "mp4" else 1)
    tail: deque[str] = deque(maxlen=20)

    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        limit=_MAX_LINE,
    )

    async def pump() -> int:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").strip()
            match = _PCT_RE.search(line)
            if match:
                value = mapper.update(float(match.group(1)))
                if value is not None:
                    on_progress(value)
            elif line:
                tail.append(line)
        return await proc.wait()

    effective_timeout = timeout if timeout is not None else settings.job_timeout_seconds
    try:
        returncode = await asyncio.wait_for(pump(), effective_timeout)
    except asyncio.TimeoutError:
        await _kill(proc)
        raise YtDlpError("The download took too long and was cancelled") from None
    except asyncio.CancelledError:
        await _kill(proc)
        raise

    if returncode != 0:
        raise YtDlpError(_friendly_error(list(tail)))

    finished = sorted(p for p in out_dir.glob("clip.*") if p.suffix in _FINAL_SUFFIXES)
    if not finished:
        raise YtDlpError("The clip was not produced")
    return finished[0]
EOF

# ------------------------------------------------------------------ services/jobs.py
cat > "$B/app/services/jobs.py" <<'EOF'
"""In-memory job store with a concurrency limit and live progress events."""
import asyncio
import logging
import secrets
import shutil
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any

from app.config import settings
from app.core.security import sanitize_filename
from app.services import ffmpeg, ytdlp

log = logging.getLogger("yt-cutter.jobs")


class JobStatus(str, Enum):
    QUEUED = "queued"
    DOWNLOADING = "downloading"
    PROCESSING = "processing"
    DONE = "done"
    ERROR = "error"


TERMINAL = {JobStatus.DONE, JobStatus.ERROR}


class TooManyJobs(RuntimeError):
    """Too many jobs are already waiting or running."""


@dataclass(frozen=True)
class CutParams:
    url: str  # must already be normalised
    start: float
    end: float
    fmt: ytdlp.Format
    quality: int
    accurate: bool
    title: str


@dataclass
class Job:
    id: str
    params: CutParams
    status: JobStatus = JobStatus.QUEUED
    progress: int = 0
    message: str | None = None
    file_path: Path | None = None
    filename: str | None = None
    duration: float | None = None
    created_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    subscribers: set[asyncio.Queue] = field(default_factory=set, repr=False)

    @property
    def terminal(self) -> bool:
        return self.status in TERMINAL

    def snapshot(self) -> dict[str, Any]:
        """Public view of the job (this is what the API and SSE stream send)."""
        return {
            "id": self.id,
            "status": self.status.value,
            "progress": self.progress,
            "message": self.message,
            "filename": self.filename,
            "duration": self.duration,
        }


def _stamp(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}h{m:02d}m{sec:02d}s" if h else f"{m}m{sec:02d}s"


class JobManager:
    def __init__(
        self,
        *,
        base_dir: Path,
        max_concurrent: int,
        max_pending: int,
        ttl_seconds: int,
        timeout_seconds: int,
    ) -> None:
        self.base_dir = base_dir
        self.max_pending = max_pending
        self.ttl_seconds = ttl_seconds
        self.timeout_seconds = timeout_seconds
        self._sem = asyncio.Semaphore(max_concurrent)
        self._jobs: dict[str, Job] = {}
        self._tasks: dict[str, asyncio.Task] = {}
        self.base_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------ public API
    def get(self, job_id: str) -> Job | None:
        return self._jobs.get(job_id)

    def create(self, params: CutParams) -> Job:
        """Register a job and start it in the background."""
        pending = sum(1 for j in self._jobs.values() if not j.terminal)
        if pending >= self.max_pending:
            raise TooManyJobs("The server is busy, try again in a moment")
        job = Job(id=secrets.token_urlsafe(16), params=params)
        self._jobs[job.id] = job
        self._tasks[job.id] = asyncio.create_task(self._run(job))
        return job

    async def events(self, job: Job) -> AsyncIterator[dict[str, Any]]:
        """Yield the current state, then every update, until the job finishes."""
        queue: asyncio.Queue = asyncio.Queue()
        job.subscribers.add(queue)
        try:
            yield job.snapshot()
            if job.terminal:
                return
            while True:
                snap = await queue.get()
                yield snap
                if snap["status"] in {s.value for s in TERMINAL}:
                    return
        finally:
            job.subscribers.discard(queue)

    def remove(self, job_id: str) -> None:
        task = self._tasks.pop(job_id, None)
        if task and not task.done():
            task.cancel()
        self._jobs.pop(job_id, None)
        shutil.rmtree(self.base_dir / job_id, ignore_errors=True)

    def purge_expired(self) -> int:
        """Delete finished jobs (and their files) older than the TTL."""
        now = time.time()
        expired = [
            j.id for j in self._jobs.values()
            if j.finished_at is not None and now - j.finished_at > self.ttl_seconds
        ]
        for job_id in expired:
            self.remove(job_id)
        return len(expired)

    def purge_orphans(self, max_age: float = 0.0) -> int:
        """Delete job folders that no longer belong to a known job.

        Call once at startup (max_age=0) to clear leftovers from a previous run.
        """
        now = time.time()
        removed = 0
        for child in self.base_dir.iterdir():
            if child.name in self._jobs or not child.is_dir():
                continue
            if now - child.stat().st_mtime >= max_age:
                shutil.rmtree(child, ignore_errors=True)
                removed += 1
        return removed

    async def shutdown(self) -> None:
        """Cancel running jobs and delete all files."""
        for task in list(self._tasks.values()):
            task.cancel()
        await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        self._tasks.clear()
        self._jobs.clear()
        shutil.rmtree(self.base_dir, ignore_errors=True)

    # ------------------------------------------------------------ internals
    def _update(self, job: Job, **fields: Any) -> None:
        for key, value in fields.items():
            setattr(job, key, value)
        if job.terminal and job.finished_at is None:
            job.finished_at = time.time()
        snap = job.snapshot()
        for queue in job.subscribers:
            queue.put_nowait(snap)

    async def _run(self, job: Job) -> None:
        p = job.params
        job_dir = self.base_dir / job.id
        try:
            async with self._sem:
                self._update(job, status=JobStatus.DOWNLOADING, progress=0)
                path = await ytdlp.download_section(
                    url=p.url,
                    start=p.start,
                    end=p.end,
                    fmt=p.fmt,
                    quality=p.quality,
                    accurate=p.accurate,
                    out_dir=job_dir,
                    on_progress=lambda pct: self._update(job, progress=pct),
                    timeout=self.timeout_seconds,
                )
                self._update(job, status=JobStatus.PROCESSING, progress=97)
                duration = await ffmpeg.probe_duration(path)
                filename = (
                    f"{sanitize_filename(p.title)}_{_stamp(p.start)}-{_stamp(p.end)}.{p.fmt}"
                )
                self._update(
                    job,
                    status=JobStatus.DONE,
                    progress=100,
                    file_path=path,
                    filename=filename,
                    duration=duration,
                )
        except asyncio.CancelledError:
            self._update(job, status=JobStatus.ERROR, message="Cancelled")
            shutil.rmtree(job_dir, ignore_errors=True)
            raise
        except ytdlp.YtDlpError as exc:
            self._update(job, status=JobStatus.ERROR, message=str(exc))
            shutil.rmtree(job_dir, ignore_errors=True)
        except Exception:
            log.exception("Job %s failed unexpectedly", job.id)
            self._update(job, status=JobStatus.ERROR, message="Internal error")
            shutil.rmtree(job_dir, ignore_errors=True)


def build_manager() -> JobManager:
    """Create a JobManager from the application settings."""
    return JobManager(
        base_dir=Path(settings.clips_dir),
        max_concurrent=settings.max_concurrent_jobs,
        max_pending=settings.max_pending_jobs,
        ttl_seconds=settings.file_ttl_seconds,
        timeout_seconds=settings.job_timeout_seconds,
    )
EOF

# ------------------------------------------------------------------ services/cleanup.py
cat > "$B/app/services/cleanup.py" <<'EOF'
"""Background task that deletes expired clips."""
import asyncio
import logging

from app.services.jobs import JobManager

log = logging.getLogger("yt-cutter.cleanup")


async def cleanup_loop(manager: JobManager, interval: float) -> None:
    """Every `interval` seconds, delete finished jobs older than the TTL."""
    while True:
        await asyncio.sleep(interval)
        try:
            removed = manager.purge_expired()
            removed += manager.purge_orphans(max_age=manager.ttl_seconds)
            if removed:
                log.info("Removed %d expired job(s)", removed)
        except Exception:
            log.exception("Cleanup pass failed")
EOF

# ------------------------------------------------------------------ tests
cat > "$B/tests/test_security.py" <<'EOF'
import pytest

from app.core.security import (
    ValidationError,
    extract_video_id,
    normalize_url,
    sanitize_filename,
    validate_range,
)

VID = "dQw4w9WgXcQ"


@pytest.mark.parametrize(
    "url",
    [
        f"https://www.youtube.com/watch?v={VID}",
        f"https://youtube.com/watch?v={VID}&list=PL123&t=42",
        f"http://m.youtube.com/watch?v={VID}",
        f"https://youtu.be/{VID}",
        f"https://youtu.be/{VID}?si=abc",
        f"https://www.youtube.com/shorts/{VID}",
        f"https://www.youtube.com/embed/{VID}",
        f"  https://www.youtube.com/watch?v={VID}  ",
    ],
)
def test_valid_urls(url):
    assert extract_video_id(url) == VID
    assert normalize_url(url) == f"https://www.youtube.com/watch?v={VID}"


@pytest.mark.parametrize(
    "url",
    [
        "",
        "not a url",
        f"https://evil.com/watch?v={VID}",
        f"https://youtube.com.evil.com/watch?v={VID}",
        f"https://evil.com/?u=youtube.com/watch?v={VID}",
        f"ftp://www.youtube.com/watch?v={VID}",
        f"file:///etc/passwd",
        f"https://user:pw@www.youtube.com/watch?v={VID}",
        f"https://www.youtube.com:8080/watch?v={VID}",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=--exec-evil-x",
        "https://www.youtube.com/watch?v=abc$(id)defg",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/",
        "https://www.youtube.com/watch",
        "--exec rm -rf /",
        "https://www.youtube.com/watch?v=" + "a" * 3000,
    ],
)
def test_invalid_urls(url):
    with pytest.raises(ValidationError):
        extract_video_id(url)


def test_id_starting_with_dash_is_valid_but_url_is_canonical():
    # real ids can start with "-"; yt-dlp receives the URL after "--", so it is never an option
    assert normalize_url("https://youtu.be/-abcdefghij") == "https://www.youtube.com/watch?v=-abcdefghij"


def test_range_ok():
    validate_range(10, 70, video_duration=300, max_clip_seconds=600)


@pytest.mark.parametrize(
    "start,end,duration",
    [
        (-1, 10, 100),
        (10, 10, 100),
        (20, 10, 100),
        (0, 700, 1000),
        (0, 200, 100),
        (float("nan"), 10, 100),
        (0, float("inf"), 100),
    ],
)
def test_range_rejected(start, end, duration):
    with pytest.raises(ValidationError):
        validate_range(start, end, video_duration=duration, max_clip_seconds=600)


def test_sanitize_filename():
    assert sanitize_filename("My Video: part 1/2?") == "My_Video_part_1_2"
    assert sanitize_filename("../../etc/passwd") == "etc_passwd"
    assert sanitize_filename("") == "clip"
    assert sanitize_filename("???") == "clip"
    assert sanitize_filename("a\x00b\nc") == "abc"
    assert len(sanitize_filename("x" * 500)) <= 80
EOF

cat > "$B/tests/test_ytdlp.py" <<'EOF'
from pathlib import Path

import pytest

from app.config import settings
from app.services import ytdlp
from app.services.ytdlp import ProgressMapper, build_download_args

URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"


def _args(**kw):
    base = dict(url=URL, start=70, end=150, fmt="mp4", quality=720, accurate=False, out_dir=Path("/tmp/x"))
    base.update(kw)
    return build_download_args(**base)


def test_section_and_url_placement():
    args = _args()
    assert "--download-sections" in args
    assert args[args.index("--download-sections") + 1] == "*70.000-150.000"
    assert args[-2:] == ["--", URL]
    assert "--no-playlist" in args


def test_js_runtime_enabled(monkeypatch):
    monkeypatch.setattr(settings, "js_runtime", "node")
    args = _args()
    assert args[args.index("--js-runtimes") + 1] == "node"
    assert args.index("--js-runtimes") < args.index("--download-sections")


def test_check_js_runtime(monkeypatch):
    monkeypatch.setattr(settings, "js_runtime", "node")
    monkeypatch.setattr(ytdlp.shutil, "which", lambda name: "/usr/bin/node")
    ytdlp.check_js_runtime()
    monkeypatch.setattr(ytdlp.shutil, "which", lambda name: None)
    with pytest.raises(RuntimeError, match="JavaScript runtime"):
        ytdlp.check_js_runtime()


def test_accurate_flag():
    assert "--force-keyframes-at-cuts" not in _args(accurate=False)
    assert "--force-keyframes-at-cuts" in _args(accurate=True)


def test_mp3_args():
    args = _args(fmt="mp3")
    assert "-x" in args and args[args.index("--audio-format") + 1] == "mp3"
    assert "--merge-output-format" not in args


def test_mp4_quality_in_format():
    args = _args(quality=480)
    assert "height<=480" in args[args.index("-f") + 1]


def test_progress_mapper_two_streams():
    m = ProgressMapper(streams=2)
    seen = [m.update(p) for p in (10, 50, 100, 5, 50, 100)]
    values = [v for v in seen if v is not None]
    assert values == sorted(values)          # monotonic
    assert values[-1] == 95                  # capped below 100
    assert m.update(100) is None             # no duplicate emits


def test_progress_mapper_single_stream():
    m = ProgressMapper(streams=1)
    assert m.update(50) == 47
    assert m.update(100) == 95
EOF

cat > "$B/tests/test_ffmpeg.py" <<'EOF'
import asyncio
import shutil
import subprocess

import pytest

from app.services import ffmpeg

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")


def test_check_binaries_ok():
    ffmpeg.check_binaries()


def test_probe_duration(tmp_path):
    clip = tmp_path / "tone.mp3"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=duration=2", str(clip)],
        check=True,
    )
    duration = asyncio.run(ffmpeg.probe_duration(clip))
    assert duration is not None and 1.9 < duration < 2.2


def test_probe_duration_invalid_file(tmp_path):
    bad = tmp_path / "bad.mp3"
    bad.write_bytes(b"not media")
    assert asyncio.run(ffmpeg.probe_duration(bad)) is None
EOF

cat > "$B/tests/test_jobs.py" <<'EOF'
import asyncio
from pathlib import Path

import pytest

from app.services import jobs as jobs_mod
from app.services import ytdlp
from app.services.jobs import CutParams, JobManager, JobStatus, TooManyJobs

PARAMS = CutParams(
    url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    start=70, end=150, fmt="mp4", quality=720, accurate=False, title="My Video: test",
)


def make_manager(tmp_path, **kw):
    opts = dict(base_dir=tmp_path / "clips", max_concurrent=1, max_pending=10,
                ttl_seconds=60, timeout_seconds=30)
    opts.update(kw)
    return JobManager(**opts)


@pytest.fixture(autouse=True)
def fake_services(monkeypatch):
    state = {"running": 0, "max_running": 0, "fail": None}

    async def fake_download(*, out_dir: Path, on_progress, **kwargs):
        state["running"] += 1
        state["max_running"] = max(state["max_running"], state["running"])
        try:
            if state["fail"]:
                raise ytdlp.YtDlpError(state["fail"])
            out_dir.mkdir(parents=True, exist_ok=True)
            on_progress(10)
            await asyncio.sleep(0.05)
            on_progress(60)
            f = out_dir / "clip.mp4"
            f.write_bytes(b"data")
            return f
        finally:
            state["running"] -= 1

    async def fake_probe(path, timeout=15.0):
        return 80.0

    monkeypatch.setattr(jobs_mod.ytdlp, "download_section", fake_download)
    monkeypatch.setattr(jobs_mod.ffmpeg, "probe_duration", fake_probe)
    return state


def test_job_lifecycle_and_events(tmp_path):
    async def scenario():
        mgr = make_manager(tmp_path)
        job = mgr.create(PARAMS)
        events = [e async for e in mgr.events(job)]
        statuses = [e["status"] for e in events]
        assert statuses[0] in ("queued", "downloading")
        assert statuses[-1] == "done"
        assert [e["progress"] for e in events] == sorted(e["progress"] for e in events)
        assert job.filename == "My_Video_test_1m10s-2m30s.mp4"
        assert job.duration == 80.0
        assert job.file_path.exists()
        await mgr.shutdown()

    asyncio.run(scenario())


def test_error_is_reported_and_files_removed(tmp_path, fake_services):
    fake_services["fail"] = "Video unavailable"

    async def scenario():
        mgr = make_manager(tmp_path)
        job = mgr.create(PARAMS)
        events = [e async for e in mgr.events(job)]
        assert events[-1]["status"] == "error"
        assert events[-1]["message"] == "Video unavailable"
        assert not (mgr.base_dir / job.id).exists()
        await mgr.shutdown()

    asyncio.run(scenario())


def test_concurrency_limit(tmp_path, fake_services):
    async def scenario():
        mgr = make_manager(tmp_path, max_concurrent=2)
        created = [mgr.create(PARAMS) for _ in range(5)]
        for job in created:
            async for _ in mgr.events(job):
                pass
        assert fake_services["max_running"] == 2
        assert all(j.status == JobStatus.DONE for j in created)
        await mgr.shutdown()

    asyncio.run(scenario())


def test_too_many_pending(tmp_path):
    async def scenario():
        mgr = make_manager(tmp_path, max_pending=2)
        mgr.create(PARAMS)
        mgr.create(PARAMS)
        with pytest.raises(TooManyJobs):
            mgr.create(PARAMS)
        await mgr.shutdown()

    asyncio.run(scenario())


def test_purge_expired_and_orphans(tmp_path):
    async def scenario():
        mgr = make_manager(tmp_path, ttl_seconds=0)
        job = mgr.create(PARAMS)
        async for _ in mgr.events(job):
            pass
        (mgr.base_dir / "leftover").mkdir()
        await asyncio.sleep(0.01)
        assert mgr.purge_expired() == 1
        assert mgr.get(job.id) is None
        assert not (mgr.base_dir / job.id).exists()
        assert mgr.purge_orphans() == 1
        assert not (mgr.base_dir / "leftover").exists()
        await mgr.shutdown()

    asyncio.run(scenario())
EOF

if [ -x "$B/.venv/bin/pip" ]; then
  echo "[*] Updating Python dependencies (yt-dlp[default])"
  "$B/.venv/bin/pip" install --quiet -r "$B/requirements.txt"
fi

echo "[+] Done. Run the tests with:"
echo "    cd backend && source .venv/bin/activate && pytest -v"
