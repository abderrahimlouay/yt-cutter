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
