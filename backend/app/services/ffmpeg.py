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
