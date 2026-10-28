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
