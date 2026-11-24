"""Pure handshake checks; these do not authenticate an account or start a route."""

import json
from uuid import UUID

import pytest
from starlette.datastructures import Headers

from simontalk_api.security import digest
from simontalk_api.websocket_handshake import HandshakeError, validate_handshake

SESSION = "S" * 43
CSRF = "C" * 43
ACCOUNT = "12345678-1234-4234-8234-123456789abc"
ORIGIN = "https://talk.example"


def headers(*, origin=ORIGIN, cookie=None, extra=()):
    return Headers(
        raw=[
            (b"origin", origin.encode()),
            (b"cookie", (cookie or f"simontalk_session={SESSION}; simontalk_csrf={CSRF}").encode()),
            *extra,
        ]
    )


def message(**changes):
    return json.dumps({"type": "authenticate", "account_id": ACCOUNT, "csrf": CSRF, **changes})


def validate(h=None, body=None, query=b""):
    return validate_handshake(h or headers(), query, message() if body is None else body, [ORIGIN])


def test_valid_precheck_returns_only_digest_and_bound_account():
    result = validate()
    assert result.account_id == UUID(ACCOUNT)
    assert result.session_digest == digest(SESSION)
    assert SESSION not in repr(result) and CSRF not in repr(result)


@pytest.mark.parametrize(
    "h,body,query",
    [
        (headers(origin="https://evil.example"), message(), b""),
        (headers(extra=((b"origin", ORIGIN.encode()),)), message(), b""),
        (headers(extra=((b"authorization", b"Bearer secret"),)), message(), b""),
        (headers(extra=((b"sec-websocket-protocol", b"secret"),)), message(), b""),
        (headers(extra=((b"cookie", b"extra=x"),)), message(), b""),
        (
            headers(
                cookie=(
                    f"simontalk_session={SESSION}; simontalk_session={SESSION}; "
                    f"simontalk_csrf={CSRF}"
                )
            ),
            message(),
            b"",
        ),
        (headers(cookie=f"simontalk_session={SESSION}; simontalk_csrf=other"), message(), b""),
        (headers(), message(csrf="X" * 43), b""),
        (headers(), message(account_id=ACCOUNT.upper()), b""),
        (headers(), message(type="other"), b""),
        (headers(), message(extra="secret"), b""),
        (
            headers(),
            '{"type":"authenticate","type":"authenticate","account_id":"'
            + ACCOUNT
            + '","csrf":"'
            + CSRF
            + '"}',
            b"",
        ),
        (headers(), "x" * 1025, b""),
        (headers(), message(), b"token=secret"),
    ],
)
def test_precheck_rejects_invalid_without_leaking(h, body, query):
    with pytest.raises(HandshakeError) as caught:
        validate(h, body, query)
    assert SESSION not in str(caught.value)
    assert CSRF not in str(caught.value)
    assert "secret" not in str(caught.value)


def test_invalid_unicode_and_nonstring_payload_rejected():
    for body in ("\ud800", b"abc", None, [], 42):
        with pytest.raises(HandshakeError):
            validate_handshake(headers(), b"", body, [ORIGIN])


def test_missing_origin_or_cookie_rejected():
    for h in (Headers(raw=[]), Headers(raw=[(b"origin", ORIGIN.encode())])):
        with pytest.raises(HandshakeError):
            validate_handshake(h, b"", message(), [ORIGIN])


@pytest.mark.parametrize(
    "origin", ["null", "*", "", "https://user@example.com", "https://example.com/path"]
)
def test_invalid_origin_is_rejected_even_if_misconfigured(origin):
    with pytest.raises(HandshakeError):
        validate_handshake(headers(origin=origin), b"", message(), [origin])
