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
