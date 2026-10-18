import asyncio
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event
from types import SimpleNamespace

import pytest
from sqlalchemy import text
from test_connection_reservations import TestAdmission, control, path, reserve
from test_connection_reservations import prepared as prepared
from test_practice_preparation import wait_for_row_lock
from test_signalling import ANSWER, TestGateway, offer

from simontalk_api.practice import UnavailableAdmission
from simontalk_api.security import now


def endpoint(prepared):
    return f"/v1/practice-sessions/{prepared.session['id']}/discard-preparation"


def discard(client, prepared, epoch=0, **changes):
    return client.post(
        endpoint(prepared), headers=prepared.headers, json={"expected_epoch": epoch, **changes}
    )


def snapshot(factory, prepared):
    with factory() as db:
        return [
            db.scalar(
                text("SELECT row_to_json(p) FROM practice_sessions p WHERE id=:id"),
                {"id": prepared.session["id"]},
            ),
            list(
                db.scalars(
                    text(
                        "SELECT row_to_json(c) FROM realtime_connections c "
                        "WHERE session_id=:id ORDER BY epoch"
                    ),
                    {"id": prepared.session["id"]},
                )
            ),
        ]


def test_empty_preparation_discard_works_with_voice_admission_closed(client, app, prepared):
    app.state.practice_admission = UnavailableAdmission()
    first = discard(client, prepared)
    assert first.status_code == 200, first.text
    saved = first.json()
    assert saved["status"] == "cancelled" and saved["ended_at"] is not None
    assert saved["state_reason"] == "cancelled_before_signalling"
    assert saved["configuration"] == prepared.session["configuration"]
    assert discard(client, prepared).json() == saved
    assert client.get("/v1/practice-sessions/current", headers=prepared.headers).json() == {
        "practice": None,
        "connection": None,
    }


def test_current_other_client_preparation_is_closed_atomically_without_lease_adoption(
    client, prepared, factory
):
    saved = reserve(client, prepared, client_instance_id=str(uuid.uuid4())).json()
    before = snapshot(factory, prepared)
    result = discard(client, prepared, 1)
    assert result.status_code == 200, result.text
    after = snapshot(factory, prepared)
    assert after[0]["status"] == "cancelled"
    assert after[0]["connection_epoch"] == 1
    assert after[1][0]["status"] == "closed"
    assert after[1][0]["termination_status"] == "not_started"
    assert after[1][0]["ended_at"] == after[0]["ended_at"]
    for key in ("client_instance_id", "last_seen_at", "lease_expires_at", "creation_key"):
        assert after[1][0][key] == before[1][0][key]
    assert discard(client, prepared, 1).json() == result.json()
    assert snapshot(factory, prepared) == after
    assert control(client, prepared, saved, "renew-lease").status_code == 409


def test_complete_safe_history_and_expired_preparing_can_be_discarded(client, prepared, factory):
    first = reserve(client, prepared).json()
    assert control(client, prepared, first, "cancel-preparation").status_code == 200
    second = reserve(client, prepared, expected_epoch=1).json()
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": second["id"]},
        )
    assert discard(client, prepared, 2).status_code == 200
    assert client.get(path(prepared, second), headers=prepared.headers).json()["status"] == "closed"


def test_already_expired_parent_keeps_original_end_reason_and_time(client, prepared, factory):
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE practice_sessions SET status='cancelled', ended_at=now(), "
                "state_reason='preparation_expired' WHERE id=:id"
            ),
            {"id": prepared.session["id"]},
        )
    before = snapshot(factory, prepared)
    assert discard(client, prepared).status_code == 200
    assert snapshot(factory, prepared) == before


def test_stale_epoch_cannot_discard_new_attempt(client, prepared, factory):
    reserve(client, prepared)
    before = snapshot(factory, prepared)
    result = discard(client, prepared)
    assert result.status_code == 409 and result.json()["code"] == "preparation_changed"
    assert snapshot(factory, prepared) == before


@pytest.mark.parametrize("state", ["negotiating", "configuring", "ready", "closing", "unknown"])
def test_unknown_upstream_always_retains_full_state(client, prepared, factory, state):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status=:state, termination_status='unknown' "
                "WHERE id=:id"
            ),
            {"state": state, "id": saved["id"]},
        )
    before = snapshot(factory, prepared)
    result = discard(client, prepared, 1)
    assert result.status_code == 409 and result.json()["code"] == "preparation_not_discardable"
    assert snapshot(factory, prepared) == before


def test_historical_upstream_cannot_be_hidden_by_new_not_started_attempt(client, prepared, factory):
    first = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='closed', termination_status='confirmed', "
                "ended_at=now(), offer_digest=:digest, signalling_started_at=now() WHERE id=:id"
            ),
            {"id": first["id"], "digest": "a" * 64},
        )
        db.execute(
            text("UPDATE practice_sessions SET status='interrupted' WHERE id=:id"),
            {"id": prepared.session["id"]},
        )
    assert reserve(client, prepared, expected_epoch=1).status_code == 201
    before = snapshot(factory, prepared)
    assert discard(client, prepared, 2).status_code == 409
    assert snapshot(factory, prepared) == before


def test_missing_connection_history_is_not_proof_of_no_upstream(client, prepared, factory):
    first = reserve(client, prepared).json()
    assert control(client, prepared, first, "cancel-preparation").status_code == 200
    assert reserve(client, prepared, expected_epoch=1).status_code == 201
    with factory.begin() as db:
        db.execute(text("DELETE FROM realtime_connections WHERE id=:id"), {"id": first["id"]})
    before = snapshot(factory, prepared)
    assert discard(client, prepared, 2).status_code == 409
    assert snapshot(factory, prepared) == before


@pytest.mark.parametrize("status", ["active", "interrupted", "ending", "completed", "failed"])
def test_other_parent_states_are_never_preparation_cleanup(client, prepared, factory, status):
    with factory.begin() as db:
        db.execute(
            text("UPDATE practice_sessions SET status=:status WHERE id=:id"),
            {"id": prepared.session["id"], "status": status},
        )
    before = snapshot(factory, prepared)
    assert discard(client, prepared).status_code == 409
    assert snapshot(factory, prepared) == before


@pytest.mark.parametrize("value", [True, -1, 2147483648, 0.0, "0", None])
def test_expected_epoch_is_strict(client, prepared, factory, value):
    before = snapshot(factory, prepared)
    assert discard(client, prepared, value).status_code == 422
    assert snapshot(factory, prepared) == before


def test_ownership_and_extra_input_cannot_change_anything(client, prepared, signup, factory):
    before = snapshot(factory, prepared)
    assert client.post(endpoint(prepared), json={"expected_epoch": 0}).status_code == 401
    other = signup("bobby")
    assert (
        client.post(
            endpoint(prepared),
            headers={"Authorization": f"Bearer {other['access_token']}"},
            json={"expected_epoch": 0},
        ).status_code
        == 404
    )
    assert discard(client, prepared, client_instance_id=str(uuid.uuid4())).status_code == 422
    assert snapshot(factory, prepared) == before


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_authentication_is_rechecked_after_owner_lock_wait(client, prepared, factory, action):
    before = snapshot(factory, prepared)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        owner = prepared.identity["user"]["id"]
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": owner})
        pending = pool.submit(discard, client, prepared)
        wait_for_row_lock(factory, "users")
        if action == "disable":
            holder.execute(text("UPDATE users SET disabled_at=now() WHERE id=:id"), {"id": owner})
        else:
            holder.execute(
                text("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"), {"id": owner}
            )
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    assert snapshot(factory, prepared) == before


def test_concurrent_discard_replays_one_terminal_result(client, prepared):
    reserve(client, prepared)
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: discard(client, prepared, 1), range(2)))
    assert [r.status_code for r in responses] == [200, 200]
    assert responses[0].json() == responses[1].json()


def test_discard_and_new_attempt_never_clear_a_new_epoch(client, prepared):
    first = reserve(client, prepared).json()
    assert control(client, prepared, first, "cancel-preparation").status_code == 200
    with ThreadPoolExecutor(max_workers=2) as pool:
        cleanup = pool.submit(discard, client, prepared, 1)
        create = pool.submit(reserve, client, prepared, expected_epoch=1)
        results = (cleanup.result(), create.result())
    assert tuple(r.status_code for r in results) in {(200, 409), (409, 201)}
    current = client.get("/v1/practice-sessions/current", headers=prepared.headers).json()
    if results[1].status_code == 201:
        assert current["connection"]["epoch"] == 2
        assert current["connection"]["status"] == "preparing"
    else:
        assert current["practice"] is None


def test_discard_and_offer_preserve_gateway_evidence(client, app, prepared):
    saved = reserve(client, prepared).json()
    gateway = TestGateway()
    app.state.signalling_gateway = gateway
    with ThreadPoolExecutor(max_workers=2) as pool:
        cleanup = pool.submit(discard, client, prepared, 1)
        signalling = pool.submit(offer, client, prepared, saved)
        result, signal = cleanup.result(), signalling.result()
    current = client.get("/v1/practice-sessions/current", headers=prepared.headers).json()
    if result.status_code == 200:
        assert signal.status_code == 409 and gateway.calls == []
        assert current["practice"] is None
    else:
        assert result.status_code == 409 and signal.status_code == 200
        assert len(gateway.calls) == 1
        assert current["connection"]["termination_status"] == "unknown"


def test_discard_committed_first_prevents_any_gateway_call(client, app, prepared):
    saved = reserve(client, prepared).json()
    gateway = TestGateway()
    app.state.signalling_gateway = gateway
    assert discard(client, prepared, 1).status_code == 200
    assert offer(client, prepared, saved).status_code == 409
    assert gateway.calls == []


def test_persisted_signalling_intent_blocks_discard_while_gateway_waits(
    client, app, prepared, factory
):
    saved = reserve(client, prepared).json()
    entered, release = Event(), Event()
    gateway = TestGateway()

    async def waiting(configuration, raw):
        entered.set()
        while not release.is_set():
            await asyncio.sleep(0.005)
        return ANSWER

    gateway.handler = waiting
    app.state.signalling_gateway = gateway
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(offer, client, prepared, saved)
        try:
            assert entered.wait(5)
            before = snapshot(factory, prepared)
            assert discard(client, prepared, 1).status_code == 409
            assert snapshot(factory, prepared) == before
        finally:
            release.set()
        assert pending.result(timeout=5).status_code == 200


def test_web_discard_preserves_csrf_origin_and_account_binding(client, app, signup, factory):
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
    created = client.post(
        "/v1/practice-sessions",
        headers={**headers, "Idempotency-Key": str(uuid.uuid4())},
        json={"mode": "free_chat"},
    )
    original = SimpleNamespace(session=created.json(), headers=headers)
    before = snapshot(factory, original)
    for missing, expected in [("X-CSRF-Token", 403), ("Origin", 403), ("X-Account-ID", 409)]:
        original.headers = {k: v for k, v in headers.items() if k != missing}
        assert discard(client, original).status_code == expected
        assert snapshot(factory, original) == before
    original.headers = {**headers, "X-Account-ID": str(uuid.uuid4())}
    assert discard(client, original).status_code == 409
    original.headers = headers
    assert discard(client, original).status_code == 200


def test_cancelled_parent_cannot_hide_occupied_unknown(client, prepared, factory):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='unknown', "
                "termination_status='unknown' WHERE id=:id"
            ),
            {"id": saved["id"]},
        )
        db.execute(
            text("UPDATE practice_sessions SET status='cancelled', ended_at=now() WHERE id=:id"),
            {"id": prepared.session["id"]},
        )
    before = snapshot(factory, prepared)
    assert discard(client, prepared, 1).status_code == 409
    assert snapshot(factory, prepared) == before
