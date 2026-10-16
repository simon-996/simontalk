import hashlib
import os
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from conftest import TEST_URL
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy import func, select
from test_accounts import ORIGIN, bearer, registration

from simontalk_api.config import Settings
from simontalk_api.main import create_app
from simontalk_api.models import AuthSession, Invite, PasswordResetGrant, RateLimitBucket


def login(client, username="alice"):
    return client.post(
        "/v1/auth/login",
        json={
            "username": username,
            "password": "incorrect long password",
            "platform": "mobile",
        },
    )


def test_rate_limits_persist_between_application_instances(client, app):
    app.state.settings.login_ip_limit = 2
    assert login(client).status_code == 401
    assert login(client).status_code == 401
    other = create_app(app.state.settings)
    try:
        with TestClient(other) as second:
            blocked = login(second)
        assert blocked.status_code == 429
        assert blocked.json()["code"] == "rate_limited"
        assert int(blocked.headers["retry-after"]) > 0
    finally:
        other.state.engine.dispose()


def test_account_rate_limit_spans_ips(app):
    app.state.settings.login_account_limit = 1
    with TestClient(app, client=("198.51.100.1", 1234)) as first:
        assert login(first).status_code == 401
    with TestClient(app, client=("198.51.100.2", 1234)) as second:
        assert login(second).status_code == 429


def test_rate_limit_storage_is_bounded_and_cleans_expired_rows(client, app, factory):
    app.state.settings.rate_limit_max_buckets = 3
    with factory.begin() as db:
        db.add(
            RateLimitBucket(
                key=hashlib.sha256(b"old").hexdigest(),
                attempts=1,
                window_start=datetime.now(UTC) - timedelta(hours=2),
                expires_at=datetime.now(UTC) - timedelta(hours=1),
            )
        )
    statuses = [login(client, f"account_{index}").status_code for index in range(8)]
    assert statuses[:2] == [401, 401]
    assert all(status == 429 for status in statuses[2:])
    with factory() as db:
        assert db.scalar(select(func.count()).select_from(RateLimitBucket)) == 3
        assert db.get(RateLimitBucket, hashlib.sha256(b"old").hexdigest()) is None


def test_readiness_database_unavailable_is_safe_and_live_still_works():
    application = create_app(
        Settings(
            database_url="postgresql+psycopg://hidden_user:hidden_password@127.0.0.1:1/missing",
            environment="test",
        )
    )
    try:
        with TestClient(application) as client:
            assert client.get("/health/live").status_code == 200
            response = client.get("/health/ready")
            assert response.status_code == 503
            assert response.json()["code"] == "service_unavailable"
            for secret in ["hidden_password", "hidden_user", "127.0.0.1", "psycopg"]:
                assert secret not in response.text
            assert response.json()["request_id"] == response.headers["x-request-id"]
    finally:
        application.state.engine.dispose()


def test_readiness_uses_real_database(client):
    assert client.get("/health/ready").status_code == 200


def test_production_forces_secure_cookies(database, invitation):
    settings = Settings(
        database_url=TEST_URL,
        environment="production",
        cookie_secure=False,
        allowed_origins=["https://talk.example.com"],
    )
    application = create_app(settings)
    try:
        with TestClient(application, base_url="https://api.example.com") as client:
            response = client.get("/v1/auth/csrf", headers={"Origin": "https://talk.example.com"})
            cookie = response.headers["set-cookie"].lower()
            assert "secure" in cookie and "httponly" in cookie and "samesite=lax" in cookie
            registration_response = client.post(
                "/v1/auth/register",
                json=registration(invitation(), platform="web"),
                headers={
                    "Origin": "https://talk.example.com",
                    "X-CSRF-Token": response.json()["csrf_token"],
                },
            )
            assert registration_response.status_code == 201
            cookie = registration_response.headers["set-cookie"].lower()
            assert "secure" in cookie and "httponly" in cookie and "samesite=lax" in cookie
            assert set(registration_response.json()) == {"user"}
    finally:
        application.state.engine.dispose()


def test_production_disallows_wildcard_and_http_origins():
    for origins in [["*"], ["http://talk.example.com"], ["https://talk.example.com/path"]]:
        with pytest.raises(ValidationError):
            Settings(environment="production", allowed_origins=origins)


def test_browser_cors_preflight_is_exact(client):
    allowed = client.options(
        "/v1/me/preferences",
        headers={
            **ORIGIN,
            "Access-Control-Request-Method": "PATCH",
            "Access-Control-Request-Headers": "content-type,x-csrf-token",
        },
    )
    assert allowed.status_code == 200
    assert allowed.headers["access-control-allow-origin"] == ORIGIN["Origin"]
    assert allowed.headers["access-control-allow-credentials"] == "true"
    denied = client.options(
        "/v1/me/preferences",
        headers={
            "Origin": "http://localhost:7357.evil.example",
            "Access-Control-Request-Method": "PATCH",
        },
    )
    assert denied.status_code == 403


def test_maintenance_tokens_expire_as_specified_and_disable_revokes(client, signup, factory):
    from simontalk_api.maintenance import disable_user, issue_invite, issue_reset

    account = signup()
    timestamp = datetime.now(UTC)
    with factory.begin() as db:
        invite = issue_invite(db)
        reset = issue_reset(db, "alice")
    with factory() as db:
        invitation = db.scalar(
            select(Invite).where(Invite.token_digest == hashlib.sha256(invite.encode()).hexdigest())
        )
        grant = db.scalar(select(PasswordResetGrant))
        session = db.scalar(select(AuthSession))
        assert timedelta(hours=71) < invitation.expires_at - timestamp <= timedelta(hours=73)
        assert timedelta(minutes=14) < grant.expires_at - timestamp <= timedelta(minutes=16)
        assert timedelta(days=6) < session.expires_at - timestamp <= timedelta(days=7)
        assert grant.token_digest == hashlib.sha256(reset.encode()).hexdigest()
    with factory.begin() as db:
        disable_user(db, "alice")
    assert client.get("/v1/me", headers=bearer(account)).status_code == 401
    with factory() as db:
        assert db.scalar(select(AuthSession)).revoked_at is not None


def test_web_token_cannot_be_used_as_bearer_and_mobile_token_cannot_be_cookie(
    client, invitation, signup
):
    mobile = signup()
    client.cookies.set("simontalk_session", mobile["access_token"])
    assert client.get("/v1/me").status_code == 401
    client.cookies.clear()
    csrf = client.get("/v1/auth/csrf", headers=ORIGIN).json()["csrf_token"]
    response = client.post(
        "/v1/auth/register",
        json=registration(invitation(), "bobby", "web"),
        headers={**ORIGIN, "X-CSRF-Token": csrf},
    )
    assert response.status_code == 201
    web_token = client.cookies.get("simontalk_session")
    client.cookies.clear()
    assert client.get("/v1/me", headers={"Authorization": f"Bearer {web_token}"}).status_code == 401


@pytest.mark.parametrize(
    "field,value",
    [
        ("speech_pace", None),
        ("subtitle_default", None),
        ("subtitle_default", 1),
        ("chinese_hints_enabled", "false"),
        ("translation_mode", "automatic"),
        ("version", True),
        ("difficulty", "expert"),
    ],
)
def test_preference_invalid_fields_never_reach_database(client, signup, field, value):
    account = signup()
    response = client.patch(
        "/v1/me/preferences",
        headers=bearer(account),
        json={
            "version": 1,
            field: value,
        },
    )
    assert response.status_code == 422
    assert client.get("/v1/me/preferences", headers=bearer(account)).json()["version"] == 1


def test_concurrent_reset_grants_only_one_can_change_password(app, client, signup, factory):
    from concurrent.futures import ThreadPoolExecutor

    from simontalk_api.maintenance import issue_reset

    signup()
    with factory.begin() as db:
        grants = [issue_reset(db, "alice"), issue_reset(db, "alice")]

    def reset(token):
        with TestClient(app) as connection:
            return connection.post(
                "/v1/auth/password-reset/confirm",
                json={
                    "reset_token": token,
                    "new_password": "a replaced test password",
                },
            ).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(reset, grants)) == [204, 400]


def test_reset_account_limit_covers_distinct_grants_and_ips(app, signup, factory):
    from simontalk_api.maintenance import issue_reset

    signup()
    app.state.settings.login_account_limit = 1
    with factory.begin() as db:
        first, second = issue_reset(db, "alice"), issue_reset(db, "alice")
    with TestClient(app, client=("198.51.100.11", 1234)) as client:
        assert (
            client.post(
                "/v1/auth/password-reset/confirm",
                json={
                    "reset_token": first,
                    "new_password": "a replaced test password",
                },
            ).status_code
            == 204
        )
    with TestClient(app, client=("198.51.100.12", 1234)) as client:
        response = client.post(
            "/v1/auth/password-reset/confirm",
            json={
                "reset_token": second,
                "new_password": "a replaced test password",
            },
        )
        assert response.status_code == 429


def test_request_id_is_generated_and_not_reflected(client):
    response = client.get("/v1/me", headers={"X-Request-ID": "sensitive attacker-controlled input"})
    assert response.status_code == 401
    assert "sensitive attacker-controlled input" not in response.text
    assert response.headers["x-request-id"] != "sensitive attacker-controlled input"


def test_installed_maintenance_cli_commits_before_printing_credentials(client, signup, factory):
    account = signup()
    environment = {
        **os.environ,
        "SIMONTALK_DATABASE_URL": TEST_URL,
        "SIMONTALK_ENVIRONMENT": "test",
    }
    executable = str(Path(sys.executable).parent / "simontalk-admin")
    invitation = subprocess.run(
        [executable, "invite"],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert len(invitation) >= 40
    with factory() as db:
        assert (
            db.scalar(
                select(Invite).where(
                    Invite.token_digest == hashlib.sha256(invitation.encode()).hexdigest(),
                )
            )
            is not None
        )
    reset = subprocess.run(
        [executable, "reset", "alice"],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert len(reset) >= 40
    with factory() as db:
        assert (
            db.scalar(
                select(PasswordResetGrant).where(
                    PasswordResetGrant.token_digest == hashlib.sha256(reset.encode()).hexdigest(),
                )
            )
            is not None
        )
    subprocess.run(
        [executable, "disable", "alice"],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )
    assert client.get("/v1/me", headers=bearer(account)).status_code == 401
