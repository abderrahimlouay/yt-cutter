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
