"""Background task that deletes expired clips."""
import asyncio
import logging

from app.services.jobs import JobManager

log = logging.getLogger("yt-cutter.cleanup")


async def cleanup_loop(manager: JobManager, interval: float) -> None:
    """Every `interval` seconds, delete finished jobs older than the TTL."""
    while True:
        await asyncio.sleep(interval)
        try:
            removed = manager.purge_expired()
            removed += manager.purge_orphans(max_age=manager.ttl_seconds)
            if removed:
                log.info("Removed %d expired job(s)", removed)
        except Exception:
            log.exception("Cleanup pass failed")
