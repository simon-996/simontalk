from datetime import UTC, datetime, timedelta

from fastapi import Request
from sqlalchemy import delete, func, select, text

from simontalk_api.errors import APIError
from simontalk_api.models import RateLimitBucket
from simontalk_api.security import digest, now


def rate_limit(request: Request, scope: str, account: str | None = None, *, include_ip=True):
    settings = request.app.state.settings
    if not settings.rate_limit_enabled:
        return
    limits = {
        "login": settings.login_ip_limit,
        "register": settings.register_ip_limit,
        "reset": settings.reset_ip_limit,
        "csrf": 60,
    }
    # Deliberately ignore forwarded headers until a trusted reverse proxy is configured.
    ip = request.client.host if request.client else "unknown"
    dimensions = [(f"{scope}:ip:{ip}", limits[scope])] if include_ip else []
    if account:
        dimensions.append((f"{scope}:account:{account}", settings.login_account_limit))
    current = now()
    seconds = settings.rate_limit_window_seconds
    start = datetime.fromtimestamp(int(current.timestamp()) // seconds * seconds, UTC)
    expiry = start + timedelta(seconds=seconds)
    blocked = False
    with request.app.state.session_factory.begin() as db:
        # Bound all stored buckets, including attacker-selected account names.
        # A single short database lock makes capacity checks and upserts atomic across workers.
        db.execute(text("SELECT pg_advisory_xact_lock(581739201)"))
        db.execute(delete(RateLimitBucket).where(RateLimitBucket.expires_at <= current))
        count = db.scalar(select(func.count()).select_from(RateLimitBucket))
        for identifier, limit in dimensions:
            key = digest(identifier)
            bucket = db.get(RateLimitBucket, key)
            if bucket is None:
                if count >= settings.rate_limit_max_buckets:
                    blocked = True
                    continue
                bucket = RateLimitBucket(key=key, window_start=start, expires_at=expiry, attempts=1)
                db.add(bucket)
                count += 1
            else:
                bucket.attempts = min(bucket.attempts + 1, limit + 1)
            if bucket.attempts > limit:
                blocked = True
    if blocked:
        raise APIError(429, "rate_limited", "尝试过于频繁，请稍后重试。")
