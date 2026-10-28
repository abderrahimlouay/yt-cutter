"""yt-dlp wrapper: metadata lookup and section download.

yt-dlp is started with an argument list (never through a shell). URLs must be
normalised with core.security.normalize_url before they reach this module.
"""
import asyncio
import json
import re
import sys
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from app.config import settings

Format = Literal["mp4", "mp3"]

_YTDLP = [sys.executable, "-m", "yt_dlp"]
_PCT_RE = re.compile(r"PCT:\s*([\d.]+)%")
_FINAL_SUFFIXES = {".mp4", ".mp3"}
_MAX_LINE = 1024 * 1024


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
        *_YTDLP,
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
        *_YTDLP,
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
