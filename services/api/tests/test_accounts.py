import hashlib
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import func, select, update

from simontalk_api.models import AuthSession, Invite, PasswordResetGrant, User, UserPreferences

PASSWORD = "a long test password"
ORIGIN = {"Origin": "http://localhost:7357"}


def bearer(account):
    return {"Authorization": f"Bearer {account['access_token']}"}


def registration(invite, username="alice", platform="mobile"):
    return {
        "invite_code": invite,
        "username": username,
        "password": PASSWORD,
        "display_name": "Alice",
        "platform": platform,
    }


def test_web_stale_tab_cannot_update_or_logout_different_account(client, invitation):
    csrf = client.get("/v1/auth/csrf", headers=ORIGIN).json()["csrf_token"]
    headers = {**ORIGIN, "X-CSRF-Token": csrf}
    alice = client.post(
        "/v1/auth/register", headers=headers, json=registration(invitation(), platform="web")
    ).json()["user"]
    bob = client.post(
        "/v1/auth/register", headers=headers, json=registration(invitation(), "bob", "web")
    ).json()["user"]
    stale = {**headers, "X-Account-ID": alice["id"]}
    for method, path, body in [
        ("PATCH", "/v1/me/preferences", {"version": 1, "difficulty": "advanced"}),
        ("POST", "/v1/auth/logout", None),
        ("GET", "/v1/me/preferences", None),
    ]:
        response = client.request(method, path, headers=stale, json=body)
        assert response.status_code == 409
        assert response.json()["code"] == "account_changed"
    assert client.get("/v1/me", headers=ORIGIN).json()["id"] == bob["id"]
    assert client.get("/v1/me/preferences", headers=ORIGIN).json()["version"] == 1
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "advanced"}
        ).status_code
        == 409
    )
    assert (
        client.patch(
            "/v1/me/preferences",
            headers={**headers, "X-Account-ID": bob["id"]},
            json={"version": 1, "difficulty": "beginner"},
        ).status_code
        == 200
    )


def test_invitation_once_and_credentials_are_only_stored_as_hashes(client, invitation, factory):
    invite = invitation()
    response = client.post("/v1/auth/register", json=registration(invite, "Alice"))
    assert response.status_code == 201
    account = response.json()
    assert account["user"]["username"] == "alice"
    assert client.get("/v1/me", headers=bearer(account)).json() == account["user"]
    repeat = client.post("/v1/auth/register", json=registration(invite, "bobby"))
    assert repeat.status_code == 400
    assert repeat.json()["code"] == "invite_invalid"
    with factory() as db:
        assert db.scalar(select(User)).password_hash.startswith("$argon2id$")
        assert db.scalar(select(Invite)).token_digest != invite
        assert (
            db.scalar(select(AuthSession)).token_digest
            == hashlib.sha256(account["access_token"].encode()).hexdigest()
        )
        assert db.scalar(select(func.count()).select_from(UserPreferences)) == 1


def test_invitation_cannot_be_consumed_concurrently(app, invitation, factory):
    invite = invitation()

    def register(username):
        with TestClient(app) as client:
            return client.post("/v1/auth/register", json=registration(invite, username)).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(register, ["alice", "bobby"]))
    assert sorted(results) == [201, 400]
    with factory() as db:
        assert db.scalar(select(func.count()).select_from(User)) == 1


def test_expired_invite_and_duplicate_account_leave_invite_intact(client, invitation, signup):
    signup()
    expired = client.post("/v1/auth/register", json=registration(invitation(expired=True), "bobby"))
    assert expired.json()["code"] == "invite_invalid"
    invite = invitation()
    duplicate = client.post("/v1/auth/register", json=registration(invite))
    assert duplicate.json()["code"] == "registration_failed"
    assert client.post("/v1/auth/register", json=registration(invite, "bobby")).status_code == 201


def test_wrong_password_expiry_logout_and_disable(client, signup, factory):
    account = signup()
    for username in ["alice", "unknown"]:
        response = client.post(
            "/v1/auth/login",
            json={"username": username, "password": "incorrect password", "platform": "mobile"},
        )
        assert response.status_code == 401
        assert response.json()["code"] == "invalid_credentials"
    headers = bearer(account)
    assert client.post("/v1/auth/logout", headers=headers).status_code == 204
    assert client.post("/v1/auth/logout", headers=headers).status_code == 204
    assert client.get("/v1/me", headers=headers).status_code == 401
    login = client.post(
        "/v1/auth/login", json={"username": "ALICE", "password": PASSWORD, "platform": "mobile"}
    ).json()
    with factory.begin() as db:
        db.execute(update(AuthSession).values(expires_at=datetime.now(UTC) - timedelta(seconds=1)))
    assert client.get("/v1/me", headers=bearer(login)).status_code == 401
    login = client.post(
        "/v1/auth/login", json={"username": "alice", "password": PASSWORD, "platform": "mobile"}
    ).json()
    with factory.begin() as db:
        db.execute(update(User).values(disabled_at=datetime.now(UTC)))
    assert client.get("/v1/me", headers=bearer(login)).status_code == 401
    assert (
        client.post(
            "/v1/auth/login", json={"username": "alice", "password": PASSWORD, "platform": "mobile"}
        ).status_code
        == 401
    )


def test_preferences_defaults_isolation_and_version_conflict(client, signup):
    alice, bobby = signup(), signup("bobby")
    alice_headers, bob_headers = bearer(alice), bearer(bobby)
    expected = {
        "difficulty": None,
        "speech_pace": "normal",
        "subtitle_default": True,
        "chinese_hints_enabled": True,
        "translation_mode": "on_demand",
        "version": 1,
    }
    assert client.get("/v1/me/preferences", headers=alice_headers).json() == expected
    response = client.patch(
        "/v1/me/preferences",
        headers=alice_headers,
        json={
            "version": 1,
            "difficulty": "intermediate",
            "speech_pace": "slow",
            "subtitle_default": False,
            "chinese_hints_enabled": False,
        },
    )
    assert response.status_code == 200
    assert response.json()["version"] == 2
    assert response.json()["difficulty"] == "intermediate"
    stale = client.patch(
        "/v1/me/preferences", headers=alice_headers, json={"version": 1, "difficulty": "advanced"}
    )
    assert stale.status_code == 409
    assert stale.json()["code"] == "preferences_conflict"
    assert client.get("/v1/me/preferences", headers=bob_headers).json() == expected
    assert (
        client.patch(
            "/v1/me/preferences",
            headers=alice_headers,
            json={
                "version": 2,
                "user_id": bobby["user"]["id"],
                "difficulty": "advanced",
            },
        ).status_code
        == 422
    )


def test_concurrent_preference_writers_one_version_wins(app, signup):
    account = signup()

    def change(difficulty):
        with TestClient(app) as client:
            return client.patch(
                "/v1/me/preferences",
                headers=bearer(account),
                json={"version": 1, "difficulty": difficulty},
            ).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(change, ["beginner", "advanced"]))
    assert sorted(results) == [200, 409]


def test_password_reset_is_single_use_and_revokes_all_sessions(client, signup, factory):
    from simontalk_api.maintenance import issue_reset

    account = signup()
    second = client.post(
        "/v1/auth/login", json={"username": "alice", "password": PASSWORD, "platform": "mobile"}
    ).json()
    with factory.begin() as db:
        token = issue_reset(db, "alice")
        other = issue_reset(db, "alice")
    payload = {"reset_token": token, "new_password": "a different long password"}
    assert client.post("/v1/auth/password-reset/confirm", json=payload).status_code == 204
    for session in [account, second]:
        assert client.get("/v1/me", headers=bearer(session)).status_code == 401
    for grant in [token, other]:
        response = client.post(
            "/v1/auth/password-reset/confirm", json={**payload, "reset_token": grant}
        )
        assert response.status_code == 400
        assert response.json()["code"] == "reset_invalid"
    assert (
        client.post(
            "/v1/auth/login", json={"username": "alice", "password": PASSWORD, "platform": "mobile"}
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/v1/auth/login",
            json={"username": "alice", "password": payload["new_password"], "platform": "mobile"},
        ).status_code
        == 200
    )
    with factory() as db:
        assert all(grant.consumed_at for grant in db.scalars(select(PasswordResetGrant)))
        assert token not in db.scalar(select(PasswordResetGrant)).token_digest


def test_web_cookie_csrf_origin_and_no_bearer_in_response(client, invitation):
    csrf = client.get("/v1/auth/csrf", headers=ORIGIN)
    assert csrf.status_code == 200
    headers = {**ORIGIN, "X-CSRF-Token": csrf.json()["csrf_token"]}
    response = client.post(
        "/v1/auth/register", headers=headers, json=registration(invitation(), platform="web")
    )
    assert response.status_code == 201
    assert set(response.json()) == {"user"}
    cookie = response.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=lax" in cookie
    assert client.get("/v1/me", headers=ORIGIN).status_code == 200
    headers["X-Account-ID"] = response.json()["user"]["id"]
    missing = client.patch("/v1/me/preferences", headers=ORIGIN, json={"version": 1})
    assert missing.status_code == 403
    assert missing.json()["code"] == "csrf_invalid"
    forged = client.patch(
        "/v1/me/preferences",
        json={"version": 1},
        headers={
            "Origin": "https://evil.example",
            "X-CSRF-Token": csrf.json()["csrf_token"],
        },
    )
    assert forged.status_code == 403
    assert forged.json()["code"] == "origin_forbidden"
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
        ).status_code
        == 200
    )
    assert client.post("/v1/auth/logout", headers=headers).status_code == 204
    assert client.get("/v1/me", headers=ORIGIN).status_code == 401


def test_cookie_without_origin_is_not_allowed_to_mutate(client, invitation):
    csrf = client.get("/v1/auth/csrf", headers=ORIGIN).json()["csrf_token"]
    headers = {**ORIGIN, "X-CSRF-Token": csrf}
    client.post(
        "/v1/auth/register", json=registration(invitation(), platform="web"), headers=headers
    )
    response = client.patch(
        "/v1/me/preferences", json={"version": 1}, headers={"X-CSRF-Token": csrf}
    )
    assert response.status_code == 403


def test_platform_cannot_expose_mobile_token_to_browser(client, invitation):
    csrf = client.get("/v1/auth/csrf", headers=ORIGIN).json()["csrf_token"]
    response = client.post(
        "/v1/auth/register",
        json=registration(invitation()),
        headers={**ORIGIN, "X-CSRF-Token": csrf},
    )
    assert response.status_code == 403
    assert "access_token" not in response.text


def test_strict_fields_and_secret_safe_errors(client, invitation):
    secret = "SUPER_SECRET_RAW_TOKEN"
    payload = registration(invitation())
    payload.update(password=secret, username="bad username", unknown=secret)
    response = client.post("/v1/auth/register", json=payload)
    assert response.status_code == 422
    assert set(response.json()) == {"code", "message", "request_id"}
    assert response.json()["request_id"] == response.headers["x-request-id"]
    assert secret not in response.text and "bad username" not in response.text
    assert client.get("/v1/me", headers={"Authorization": f"Bearer {secret}"}).status_code == 401


def test_expired_reset_rejected(client, signup, factory):
    from simontalk_api.maintenance import issue_reset

    account = signup()
    with factory.begin() as db:
        token = issue_reset(db, "alice")
        db.flush()
        db.execute(
            update(PasswordResetGrant)
            .where(PasswordResetGrant.user_id == UUID(account["user"]["id"]))
            .values(expires_at=datetime.now(UTC) - timedelta(seconds=1))
        )
    assert (
        client.post(
            "/v1/auth/password-reset/confirm",
            json={"reset_token": token, "new_password": "a new long password"},
        ).status_code
        == 400
    )
