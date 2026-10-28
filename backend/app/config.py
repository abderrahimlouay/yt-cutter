from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="YTCUTTER_", extra="ignore")

    cors_origins: list[str] = ["http://localhost:5173"]
    clips_dir: str = "/tmp/yt-cutter"
    max_video_seconds: int = 3 * 3600
    max_clip_seconds: int = 600
    max_concurrent_jobs: int = 2
    file_ttl_seconds: int = 1800
    rate_limit_info: str = "20/minute"
    rate_limit_cut: str = "5/minute"


settings = Settings()
