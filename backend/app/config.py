from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="YTCUTTER_", extra="ignore")

    cors_origins: list[str] = ["http://localhost:5173"]
    allowed_hosts: list[str] = ["localhost", "127.0.0.1"]
    clips_dir: str = "/tmp/yt-cutter"

    # JavaScript runtime yt-dlp uses to solve YouTube challenges (must be on PATH).
    # Node needs version 22+, Deno 2.3+.
    js_runtime: Literal["deno", "node", "bun", "quickjs"] = "node"

    # limits
    max_video_seconds: int = 3 * 3600
    max_clip_seconds: int = 600
    max_concurrent_jobs: int = 2
    max_pending_jobs: int = 10
    job_timeout_seconds: int = 900
    file_ttl_seconds: int = 1800
    cleanup_interval_seconds: int = 60

    # rate limits (slowapi syntax)
    rate_limit_info: str = "20/minute"
    rate_limit_cut: str = "5/minute"


settings = Settings()
