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
