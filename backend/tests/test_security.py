import pytest

from app.core.security import (
    ValidationError,
    extract_video_id,
    normalize_url,
    sanitize_filename,
    validate_range,
)

VID = "dQw4w9WgXcQ"


@pytest.mark.parametrize(
    "url",
    [
        f"https://www.youtube.com/watch?v={VID}",
        f"https://youtube.com/watch?v={VID}&list=PL123&t=42",
        f"http://m.youtube.com/watch?v={VID}",
        f"https://youtu.be/{VID}",
        f"https://youtu.be/{VID}?si=abc",
        f"https://www.youtube.com/shorts/{VID}",
        f"https://www.youtube.com/embed/{VID}",
        f"  https://www.youtube.com/watch?v={VID}  ",
    ],
)
def test_valid_urls(url):
    assert extract_video_id(url) == VID
    assert normalize_url(url) == f"https://www.youtube.com/watch?v={VID}"


@pytest.mark.parametrize(
    "url",
    [
        "",
        "not a url",
        f"https://evil.com/watch?v={VID}",
        f"https://youtube.com.evil.com/watch?v={VID}",
        f"https://evil.com/?u=youtube.com/watch?v={VID}",
        f"ftp://www.youtube.com/watch?v={VID}",
        f"file:///etc/passwd",
        f"https://user:pw@www.youtube.com/watch?v={VID}",
        f"https://www.youtube.com:8080/watch?v={VID}",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=--exec-evil-x",
        "https://www.youtube.com/watch?v=abc$(id)defg",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/",
        "https://www.youtube.com/watch",
        "--exec rm -rf /",
        "https://www.youtube.com/watch?v=" + "a" * 3000,
    ],
)
def test_invalid_urls(url):
    with pytest.raises(ValidationError):
        extract_video_id(url)


def test_id_starting_with_dash_is_valid_but_url_is_canonical():
    # real ids can start with "-"; yt-dlp receives the URL after "--", so it is never an option
    assert normalize_url("https://youtu.be/-abcdefghij") == "https://www.youtube.com/watch?v=-abcdefghij"


def test_range_ok():
    validate_range(10, 70, video_duration=300, max_clip_seconds=600)


@pytest.mark.parametrize(
    "start,end,duration",
    [
        (-1, 10, 100),
        (10, 10, 100),
        (20, 10, 100),
        (0, 700, 1000),
        (0, 200, 100),
        (float("nan"), 10, 100),
        (0, float("inf"), 100),
    ],
)
def test_range_rejected(start, end, duration):
    with pytest.raises(ValidationError):
        validate_range(start, end, video_duration=duration, max_clip_seconds=600)


def test_sanitize_filename():
    assert sanitize_filename("My Video: part 1/2?") == "My_Video_part_1_2"
    assert sanitize_filename("../../etc/passwd") == "etc_passwd"
    assert sanitize_filename("") == "clip"
    assert sanitize_filename("???") == "clip"
    assert sanitize_filename("a\x00b\nc") == "abc"
    assert len(sanitize_filename("x" * 500)) <= 80
