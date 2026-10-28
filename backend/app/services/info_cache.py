"""Small TTL cache so /info followed by /cut does not run yt-dlp twice."""
import time

from app.services.ytdlp import VideoInfo


class InfoCache:
    def __init__(self, ttl_seconds: float = 300.0, max_entries: int = 256) -> None:
        self.ttl = ttl_seconds
        self.max_entries = max_entries
        self._data: dict[str, tuple[float, VideoInfo]] = {}

    def get(self, video_id: str) -> VideoInfo | None:
        entry = self._data.get(video_id)
        if entry is None:
            return None
        stored_at, info = entry
        if time.monotonic() - stored_at > self.ttl:
            self._data.pop(video_id, None)
            return None
        return info

    def set(self, video_id: str, info: VideoInfo) -> None:
        if len(self._data) >= self.max_entries:
            oldest = min(self._data, key=lambda k: self._data[k][0])
            self._data.pop(oldest, None)
        self._data[video_id] = (time.monotonic(), info)
