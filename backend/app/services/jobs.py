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
