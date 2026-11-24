"""Strict browser WebSocket precheck; it is not authentication or admission."""

import json
import re
import secrets
from dataclasses import dataclass, field
from urllib.parse import urlsplit
from uuid import UUID

from starlette.datastructures import Headers

from simontalk_api.security import CSRF_COOKIE, SESSION_COOKIE, digest

_TOKEN = re.compile(r"[A-Za-z0-9_-]{32,256}", re.ASCII)
_COOKIE_NAME = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", re.ASCII)


class HandshakeError(Exception):
    """Fixed error that never includes request data."""


@dataclass(frozen=True, slots=True)
class HandshakeIdentity:
    account_id: UUID
    session_digest: str = field(repr=False)


def _unique_pairs(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("duplicate key")
        result[name] = value
    return result


def _invalid_constant(_):
    raise ValueError("invalid constant")


def _header_cookies(headers, query, allowed_origins):
    if not isinstance(headers, Headers) or type(query) is not bytes or query:
        raise ValueError("invalid request")
    origins = headers.getlist("origin")
    cookies = headers.getlist("cookie")
    if (
        len(origins) != 1
        or len(cookies) != 1
        or headers.getlist("authorization")
        or headers.getlist("sec-websocket-protocol")
        or not origins[0].isascii()
        or len(origins[0]) > 512
        or not isinstance(allowed_origins, (list, tuple, set, frozenset))
        or origins[0] not in allowed_origins
    ):
        raise ValueError("invalid request")
    origin = urlsplit(origins[0])
    if (
        origin.scheme not in {"http", "https"}
        or not origin.hostname
        or origin.username is not None
        or origin.password is not None
        or origin.path
        or origin.query
        or origin.fragment
        or origins[0] != f"{origin.scheme}://{origin.netloc}"
    ):
        raise ValueError("invalid origin")
    _ = origin.port  # Reject malformed ports before accepting the origin.
    cookie = cookies[0]
    if not cookie.isascii() or len(cookie) > 4096:
        raise ValueError("invalid cookie")
    parts = cookie.split(";")
    if len(parts) > 64:
        raise ValueError("invalid cookie")
    found = {}
    for part in parts:
        name, separator, value = part.strip().partition("=")
        if not separator or not _COOKIE_NAME.fullmatch(name):
            raise ValueError("invalid cookie")
        if name in (SESSION_COOKIE, CSRF_COOKIE):
            if name in found or not _TOKEN.fullmatch(value):
                raise ValueError("invalid cookie")
            found[name] = value
    if set(found) != {SESSION_COOKIE, CSRF_COOKIE}:
        raise ValueError("invalid cookie")
    return found


def check_browser_headers(headers, query, allowed_origins):
    """Reject invalid upgrade requests before accepting the socket."""
    try:
        _header_cookies(headers, query, allowed_origins)
    except (UnicodeError, ValueError, TypeError):
        raise HandshakeError("handshake_rejected") from None


def _validate(headers, query, body, allowed_origins):
    found = _header_cookies(headers, query, allowed_origins)
    if type(body) is not str or len(body) > 1024 or len(body.encode("utf-8")) > 1024:
        raise ValueError("invalid message")
    message = json.loads(body, object_pairs_hook=_unique_pairs, parse_constant=_invalid_constant)
    if type(message) is not dict or set(message) != {"type", "account_id", "csrf"}:
        raise ValueError("invalid message")
    csrf = message["csrf"]
    account = message["account_id"]
    if (
        message["type"] != "authenticate"
        or type(csrf) is not str
        or not _TOKEN.fullmatch(csrf)
        or not secrets.compare_digest(csrf, found[CSRF_COOKIE])
        or type(account) is not str
        or len(account) != 36
    ):
        raise ValueError("invalid message")
    account_id = UUID(account)
    if str(account_id) != account:
        raise ValueError("invalid message")
    return HandshakeIdentity(account_id=account_id, session_digest=digest(found[SESSION_COOKIE]))


def validate_handshake(headers, query, body, allowed_origins):
    """Check browser proof shape only; the caller must authenticate using the DB."""
    try:
        return _validate(headers, query, body, allowed_origins)
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise HandshakeError("handshake_rejected") from None
