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
