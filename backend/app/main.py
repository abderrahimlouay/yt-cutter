import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from starlette.datastructures import MutableHeaders
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app.api.routes import router
from app.config import settings
from app.core.rate_limit import limiter
from app.services import ffmpeg, ytdlp
from app.services.cleanup import cleanup_loop
from app.services.info_cache import InfoCache
from app.services.jobs import build_manager

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    ffmpeg.check_binaries()
    ytdlp.check_js_runtime()
    manager = build_manager()
    manager.purge_orphans()  # clear leftovers from a previous run
    app.state.jobs = manager
    app.state.info_cache = InfoCache()
    cleanup = asyncio.create_task(cleanup_loop(manager, settings.cleanup_interval_seconds))
    try:
        yield
    finally:
        cleanup.cancel()
        await asyncio.gather(cleanup, return_exceptions=True)
        await manager.shutdown()


class SecurityHeadersMiddleware:
    """Adds basic security headers (pure ASGI so streaming/SSE is not buffered)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers["X-Content-Type-Options"] = "nosniff"
                headers["X-Frame-Options"] = "DENY"
                headers["Referrer-Policy"] = "no-referrer"
            await send(message)

        await self.app(scope, receive, send_with_headers)


app = FastAPI(title="yt-cutter", version="0.1.0", lifespan=lifespan)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# the last middleware added is the outermost: reject bad Host headers first
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)
app.add_middleware(SecurityHeadersMiddleware)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)

app.include_router(router)
