import hashlib
import secrets
from datetime import UTC, datetime, timedelta

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import Request, Response
from sqlalchemy import select

from simontalk_api.errors import APIError, unauthorized
from simontalk_api.models import AuthSession, User

SESSION_COOKIE = "simontalk_session"
CSRF_COOKIE = "simontalk_csrf"
SESSION_SECONDS = 7 * 24 * 60 * 60
PASSWORD_HASHER = PasswordHasher()
DUMMY_HASH = PASSWORD_HASHER.hash(secrets.token_urlsafe(32))


def now():
    return datetime.now(UTC)


def digest(token: str):
    return hashlib.sha256(token.encode()).hexdigest()


def new_token():
    return secrets.token_urlsafe(32)


def verify_password(encoded: str, password: str):
    try:
        return PASSWORD_HASHER.verify(encoded, password)
    except (VerificationError, InvalidHashError):
        return False


def is_browser(request: Request):
    return bool(
        request.headers.get("origin")
        or request.headers.get("sec-fetch-site")
        or request.cookies.get(SESSION_COOKIE)
    )


def protect_mutation(request: Request, platform: str | None = None):
    browser = is_browser(request)
    if platform == "mobile" and browser:
        raise APIError(403, "origin_forbidden", "浏览器请使用 Web 登录。")
    if not browser and platform != "web":
        return
    origin = request.headers.get("origin")
    if origin and origin not in request.app.state.settings.allowed_origins:
        raise APIError(403, "origin_forbidden", "此来源不受允许。")
    cookie = request.cookies.get(CSRF_COOKIE, "")
    header = request.headers.get("x-csrf-token", "")
    if (
        not origin
        or not cookie
        or len(cookie) > 256
        or len(header) > 256
        or not secrets.compare_digest(cookie.encode(), header.encode())
    ):
        raise APIError(403, "csrf_invalid", "页面验证已失效，请刷新后重试。")


def cookie_options(settings):
    return {"httponly": True, "secure": settings.cookie_secure, "samesite": "lax", "path": "/"}


def create_session(db, user, platform: str):
    token = new_token()
    db.add(
        AuthSession(
            user_id=user.id,
            token_digest=digest(token),
            platform=platform,
            expires_at=now() + timedelta(seconds=SESSION_SECONDS),
        )
    )
    return token


def set_session_cookie(response: Response, token: str, settings):
    response.set_cookie(
        SESSION_COOKIE,
        token,
        max_age=SESSION_SECONDS,
        **cookie_options(settings),
    )


def session_identity(request: Request, db, *, optional=False):
    authorization = request.headers.get("authorization", "")
    cookie = request.cookies.get(SESSION_COOKIE)
    if authorization:
        parts = authorization.split(" ")
        if len(parts) != 2 or parts[0].lower() != "bearer" or cookie:
            if optional:
                return None
            raise unauthorized()
        token, platform = parts[1], "mobile"
    else:
        token, platform = cookie, "web"
    if not token or len(token) > 256:
        if optional:
            return None
        raise unauthorized()
    identity = db.execute(
        select(AuthSession, User)
        .join(User, User.id == AuthSession.user_id)
        .where(
            AuthSession.token_digest == digest(token),
            AuthSession.platform == platform,
            AuthSession.revoked_at.is_(None),
            AuthSession.expires_at > now(),
            User.disabled_at.is_(None),
        )
    ).first()
    if not identity and not optional:
        raise unauthorized()
    if identity:
        expected = request.headers.get("x-account-id")
        requires_binding = platform == "web" and request.method in {"PATCH", "POST", "DELETE"}
        if (requires_binding and not expected) or (
            expected is not None and expected != str(identity[1].id)
        ):
            raise APIError(409, "account_changed", "浏览器登录账号已更改，请重新确认身份。")
    return identity
