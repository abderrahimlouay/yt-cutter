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
