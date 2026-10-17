import asyncio
import hashlib
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from test_connection_reservations import TestAdmission, control, path, reserve
from test_connection_reservations import prepared as prepared
from test_practice_preparation import wait_for_row_lock

from simontalk_api.main import create_app
from simontalk_api.practice import UnavailableAdmission
from simontalk_api.security import now

OFFER = (
    "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
    "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-pwd:private-sdp-marker\r\n"
)
ANSWER = "v=0\r\no=- 2 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"


class TestGateway:
    __test__ = False

    def __init__(self):
        self.calls = []
        self.handler = self.answer

    def check_configuration(self, configuration):
        assert configuration["provider"] == "test-only"

    async def answer(self, configuration, offer):
        return ANSWER

    async def exchange_offer(self, configuration, offer):
        self.calls.append((configuration, offer))
        return await self.handler(configuration, offer)


@pytest.fixture
def gateway(app):
    result = TestGateway()
    app.state.signalling_gateway = result
    return result


def offer(client, prepared, saved, **changes):
    return client.post(
        path(prepared, saved, "/offer"),
        headers=prepared.headers,
        json={
            "client_instance_id": saved["client_instance_id"],
            "epoch": saved["epoch"],
            "offer": OFFER,
            **changes,
        },
    )


def connection_row(factory, saved):
    with factory() as db:
        return (
            db.execute(text("SELECT * FROM realtime_connections WHERE id=:id"), {"id": saved["id"]})
            .mappings()
            .one()
        )


def test_default_gateway_and_admission_never_start_an_offer(client, app, prepared, factory):
    saved = reserve(client, prepared).json()
    response = offer(client, prepared, saved)
    assert response.status_code == 503
    assert response.json()["code"] == "realtime_unavailable"
    assert connection_row(factory, saved)["status"] == "preparing"
    assert connection_row(factory, saved)["offer_digest"] is None
    app.state.practice_admission = UnavailableAdmission()
    app.state.signalling_gateway = TestGateway()
    assert offer(client, prepared, saved).status_code == 503
    assert app.state.signalling_gateway.calls == []


def test_success_commits_intent_and_releases_locks_before_gateway_then_configures(
    client, prepared, factory, gateway
):
    saved = reserve(client, prepared).json()

    async def inspect(configuration, raw):
        assert raw == OFFER
        with factory.begin() as db:
            db.execute(text("SET LOCAL lock_timeout = '100ms'"))
            for table, row_id in [
                ("users", prepared.identity["user"]["id"]),
                ("practice_sessions", prepared.session["id"]),
                ("realtime_connections", saved["id"]),
            ]:
                db.execute(text(f"SELECT id FROM {table} WHERE id=:id FOR UPDATE"), {"id": row_id})
            row = (
                db.execute(
                    text("SELECT * FROM realtime_connections WHERE id=:id"), {"id": saved["id"]}
                )
                .mappings()
                .one()
            )
            assert row["status"] == "negotiating"
            assert row["termination_status"] == "unknown"
            assert row["offer_digest"] == hashlib.sha256(OFFER.encode()).hexdigest()
            assert row["signalling_started_at"] is not None
            assert "private-sdp-marker" not in str(dict(row))
        return ANSWER

    gateway.handler = inspect
    response = offer(client, prepared, saved)
    assert response.status_code == 200, response.text
    assert response.json() == {
        "session_id": prepared.session["id"],
        "connection_id": saved["id"],
        "client_instance_id": saved["client_instance_id"],
        "epoch": 1,
        "answer": ANSWER,
    }
    assert response.headers["Cache-Control"] == "no-store"
    row = connection_row(factory, saved)
    assert row["status"] == "configuring"
    assert row["termination_status"] == "unknown"
    assert row["signalling_finished_at"] is not None
    assert "private-sdp-marker" not in str(dict(row)) and ANSWER not in str(dict(row))


def test_duplicate_and_changed_offer_never_repeat_gateway_even_after_restart(
    client, app, prepared, gateway
):
    saved = reserve(client, prepared).json()
    assert offer(client, prepared, saved).status_code == 200
    assert offer(client, prepared, saved).status_code == 409
    assert offer(client, prepared, saved, offer=OFFER.replace("1 1", "3 3")).status_code == 409
    other = create_app(app.state.settings)
    new_gateway = TestGateway()
    other.state.signalling_gateway = new_gateway
    try:
        with TestClient(other) as restored:
            assert offer(restored, prepared, saved).status_code == 409
    finally:
        other.state.engine.dispose()
    assert len(gateway.calls) == 1
    assert new_gateway.calls == []


def test_exchange_uses_the_exact_gateway_that_passed_local_validation(
    client, app, prepared, gateway
):
    saved = reserve(client, prepared).json()
    replacement = TestGateway()

    def replace_after_check(configuration):
        app.state.signalling_gateway = replacement

    gateway.check_configuration = replace_after_check
    response = offer(client, prepared, saved)
    assert response.status_code == 200, response.text
    assert len(gateway.calls) == 1
    assert replacement.calls == []


def test_web_offer_preserves_csrf_origin_and_account_binding(client, app, signup, gateway):
    origin = {"Origin": "http://localhost:7357"}
    csrf = client.get("/v1/auth/csrf", headers=origin).json()["csrf_token"]
    headers = {**origin, "X-CSRF-Token": csrf}
    identity = signup(platform="web", headers=headers)
    headers["X-Account-ID"] = identity["user"]["id"]
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
        ).status_code
        == 200
    )
    app.state.practice_admission = TestAdmission()
    session = client.post(
        "/v1/practice-sessions",
        headers={**headers, "Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    ).json()
    prepared = SimpleNamespace(session=session, headers=headers)
    saved = reserve(client, prepared).json()
    for missing, expected in [("X-CSRF-Token", 403), ("Origin", 403), ("X-Account-ID", 409)]:
        prepared.headers = {key: value for key, value in headers.items() if key != missing}
        assert offer(client, prepared, saved).status_code == expected
        assert gateway.calls == []
    prepared.headers = headers
    assert offer(client, prepared, saved).status_code == 200
    assert len(gateway.calls) == 1


def test_concurrent_offer_is_single_use_and_preparation_cancel_cannot_free_it(
    client, prepared, gateway
):
    saved = reserve(client, prepared).json()
    entered, proceed = Event(), Event()

    async def wait(configuration, raw):
        entered.set()
        assert await asyncio.to_thread(proceed.wait, 5)
        return ANSWER

    gateway.handler = wait
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(offer, client, prepared, saved)
        try:
            assert entered.wait(5)
            assert offer(client, prepared, saved).status_code == 409
            assert control(client, prepared, saved, "cancel-preparation").status_code == 409
        finally:
            proceed.set()
        assert pending.result(timeout=5).status_code == 200
    assert len(gateway.calls) == 1


@pytest.mark.parametrize("outcome", ["exception", "invalid", "oversize", "timeout"])
def test_failed_exchange_is_unknown_and_never_retried(
    client, prepared, factory, gateway, monkeypatch, caplog, outcome
):
    from simontalk_api import signalling

    saved = reserve(client, prepared).json()

    async def fail(configuration, raw):
        if outcome == "exception":
            raise RuntimeError("private-sdp-marker-and-credential")
        if outcome == "timeout":
            await asyncio.sleep(100)
        return "v=0\r\n" + "x" * 65536 if outcome == "oversize" else "private-invalid-answer"

    gateway.handler = fail
    monkeypatch.setattr(signalling, "EXCHANGE_TIMEOUT_SECONDS", 0.01)
    response = offer(client, prepared, saved)
    assert response.status_code in {502, 504}
    assert "private" not in response.text and "private" not in caplog.text
    row = connection_row(factory, saved)
    assert row["status"] == "unknown" and row["termination_status"] == "unknown"
    assert row["ended_at"] is None
    assert offer(client, prepared, saved).status_code == 409
    assert control(client, prepared, saved, "cancel-preparation").status_code == 409
    assert len(gateway.calls) == 1


@pytest.mark.parametrize("change", ["revoke", "disable", "expire", "scan", "policy"])
def test_late_answer_cannot_revive_or_escape_changed_authorization(
    client, app, prepared, factory, gateway, change
):
    saved = reserve(client, prepared).json()

    async def mutate(configuration, raw):
        with factory.begin() as db:
            if change == "revoke":
                db.execute(
                    text("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"),
                    {"id": prepared.identity["user"]["id"]},
                )
            elif change == "disable":
                db.execute(
                    text("UPDATE users SET disabled_at=now() WHERE id=:id"),
                    {"id": prepared.identity["user"]["id"]},
                )
            elif change in {"expire", "scan"}:
                db.execute(
                    text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
                    {"past": now() - timedelta(seconds=1), "id": saved["id"]},
                )
        if change == "scan":
            from simontalk_api.connections import expire_connection_leases

            with factory.begin() as db:
                assert expire_connection_leases(db) == 1
        elif change == "policy":
            app.state.practice_admission = UnavailableAdmission()
        return ANSWER

    gateway.handler = mutate
    response = offer(client, prepared, saved)
    assert response.status_code in {401, 409, 503}
    assert ANSWER not in response.text
    row = connection_row(factory, saved)
    assert row["status"] == "unknown" and row["ended_at"] is None
    assert row["termination_status"] == "unknown"


def test_identity_owner_epoch_lease_and_configuration_gate_before_gateway(
    client, app, prepared, factory, gateway, signup
):
    saved = reserve(client, prepared).json()
    anonymous = SimpleNamespace(session=prepared.session, headers={})
    assert offer(client, anonymous, saved).status_code == 401
    other = signup("bob")
    foreign = SimpleNamespace(
        session=prepared.session, headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert offer(client, foreign, saved).status_code == 404
    assert offer(client, prepared, saved, client_instance_id=str(uuid4())).status_code == 409
    assert offer(client, prepared, saved, epoch=2).status_code == 409
    app.state.practice_admission = SimpleNamespace(
        admit=lambda _: SimpleNamespace(
            provider="test-only", region="test", model="test-model", config_id="changed"
        )
    )
    assert offer(client, prepared, saved).status_code == 409
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": saved["id"]},
        )
    assert offer(client, prepared, saved).status_code == 409
    assert gateway.calls == []
    assert connection_row(factory, saved)["offer_digest"] is None


@pytest.mark.parametrize(
    "invalid",
    [
        {"offer": ""},
        {"offer": "not-sdp"},
        {"offer": "v=0\r\n\x00"},
        {"offer": "v=0\r\n" + "é" * 40000},
        {"epoch": True},
        {"target_url": "https://example.invalid"},
    ],
)
def test_offer_payload_is_strict_and_errors_do_not_echo_input(client, prepared, gateway, invalid):
    saved = reserve(client, prepared).json()
    response = offer(client, prepared, saved, **invalid)
    assert response.status_code == 422
    assert "example.invalid" not in response.text
    assert gateway.calls == []


def test_revoke_during_owner_lock_wait_blocks_initial_attempt(client, prepared, factory, gateway):
    saved = reserve(client, prepared).json()
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        owner = prepared.identity["user"]["id"]
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": owner})
        pending = pool.submit(offer, client, prepared, saved)
        wait_for_row_lock(factory, "users")
        holder.execute(
            text("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"), {"id": owner}
        )
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    assert gateway.calls == []
    assert connection_row(factory, saved)["offer_digest"] is None


def test_signalled_connection_cannot_be_downgraded_to_not_started_in_database(
    client, prepared, factory, gateway
):
    saved = reserve(client, prepared).json()
    assert offer(client, prepared, saved).status_code == 200
    with pytest.raises(IntegrityError) as caught, factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='closed',"
                "termination_status='not_started',ended_at=now() WHERE id=:id"
            ),
            {"id": saved["id"]},
        )
    assert caught.value.orig.diag.constraint_name == "signalling_termination_evidence"
