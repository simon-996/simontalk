import os
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path
from threading import Event
from types import SimpleNamespace

import pytest
from conftest import TEST_URL
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from test_practice_preparation import wait_for_row_lock

from simontalk_api.config import Settings
from simontalk_api.main import create_app
from simontalk_api.practice import UnavailableAdmission
from simontalk_api.security import now


class TestAdmission:
    __test__ = False

    def admit(self, user_id):
        return SimpleNamespace(
            provider="test-only", region="test", model="test-model", config_id="test-v1"
        )


@pytest.fixture
def prepared(client, app, signup):
    identity = signup()
    headers = {"Authorization": f"Bearer {identity['access_token']}"}
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
        ).status_code
        == 200
    )
    app.state.practice_admission = TestAdmission()
    response = client.post(
        "/v1/practice-sessions",
        headers={**headers, "Idempotency-Key": str(uuid.uuid4())},
        json={"mode": "free_chat"},
    )
    assert response.status_code == 201
    return SimpleNamespace(identity=identity, headers=headers, session=response.json())


def reserve(client, prepared, *, key=None, **changes):
    return client.post(
        f"/v1/practice-sessions/{prepared.session['id']}/connections",
        headers={**prepared.headers, "Idempotency-Key": str(key or uuid.uuid4())},
        json={"client_instance_id": str(uuid.UUID(int=1)), "expected_epoch": 0, **changes},
    )


def path(prepared, connection, suffix=""):
    return f"/v1/practice-sessions/{prepared.session['id']}/connections/{connection['id']}{suffix}"


def control(client, prepared, connection, action, **changes):
    return client.post(
        path(prepared, connection, f"/{action}"),
        headers=prepared.headers,
        json={
            "client_instance_id": connection["client_instance_id"],
            "epoch": connection["epoch"],
            **changes,
        },
    )


def count(factory):
    with factory() as db:
        return db.scalar(text("SELECT count(*) FROM realtime_connections"))


def test_default_admission_blocks_connection_without_allocating_epoch(
    client, app, prepared, factory
):
    app.state.practice_admission = UnavailableAdmission()
    response = reserve(client, prepared)
    assert response.status_code == 503
    assert response.json()["code"] == "realtime_unavailable"
    assert count(factory) == 0
    detail = client.get(f"/v1/practice-sessions/{prepared.session['id']}", headers=prepared.headers)
    assert detail.json()["status"] == "created"
    assert detail.json()["connection_epoch"] == 0


def test_reservation_is_durable_and_replay_does_not_renew_or_readmit(
    client, app, prepared, factory
):
    key = uuid.uuid4()
    response = reserve(client, prepared, key=key)
    assert response.status_code == 201, response.text
    saved = response.json()
    assert saved["status"] == "preparing"
    assert saved["epoch"] == 1
    assert saved["termination_status"] == "not_started"
    assert saved["ended_at"] is None
    assert saved["configuration"] == prepared.session["configuration"]["provider"]
    app.state.practice_admission = UnavailableAdmission()
    assert reserve(client, prepared, key=key).json() == saved
    assert client.get(path(prepared, saved), headers=prepared.headers).json() == saved
    other = create_app(Settings(database_url=TEST_URL, environment="test"))
    try:
        with TestClient(other) as second:
            assert reserve(second, prepared, key=key).json() == saved
    finally:
        other.state.engine.dispose()
    assert count(factory) == 1


def test_request_key_and_fields_are_strict_and_no_upstream_input_is_accepted(
    client, prepared, factory
):
    for changes in [
        {"user_id": prepared.identity["user"]["id"]},
        {"provider": "test-only"},
        {"expected_epoch": True},
        {"expected_epoch": -1},
        {"client_instance_id": "not-a-uuid"},
        {"lease_expires_at": "2099-01-01T00:00:00Z"},
    ]:
        assert reserve(client, prepared, **changes).status_code == 422
    assert reserve(client, prepared, key="invalid").status_code == 422
    assert count(factory) == 0


def test_changed_input_or_reused_key_in_another_practice_conflicts(client, prepared, factory):
    key = uuid.uuid4()
    first = reserve(client, prepared, key=key).json()
    assert (
        reserve(client, prepared, key=key, client_instance_id=str(uuid.uuid4())).status_code == 409
    )
    assert control(client, prepared, first, "cancel-preparation").status_code == 200
    assert (
        client.post(
            f"/v1/practice-sessions/{prepared.session['id']}/cancel-preparation",
            headers=prepared.headers,
        ).status_code
        == 200
    )
    new = client.post(
        "/v1/practice-sessions",
        headers={**prepared.headers, "Idempotency-Key": str(uuid.uuid4())},
        json={"mode": "free_chat"},
    )
    assert new.status_code == 201
    prepared.session = new.json()
    response = reserve(client, prepared, key=key)
    assert response.status_code == 409
    assert response.json()["code"] == "idempotency_conflict"
    assert count(factory) == 1


@pytest.mark.parametrize("same_key", [False, True])
def test_concurrent_reservations_allocate_only_one_attempt(client, prepared, factory, same_key):
    key = uuid.uuid4() if same_key else None
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: reserve(client, prepared, key=key), range(2)))
    assert sorted(result.status_code for result in responses) == (
        [201, 201] if same_key else [201, 409]
    )
    if same_key:
        assert responses[0].json() == responses[1].json()
    assert count(factory) == 1


def test_configuration_change_and_stale_epoch_cannot_silently_start(client, app, prepared, factory):
    class ChangedAdmission(TestAdmission):
        def admit(self, user_id):
            permit = super().admit(user_id)
            permit.config_id = "changed-v2"
            return permit

    app.state.practice_admission = ChangedAdmission()
    changed = reserve(client, prepared)
    assert changed.status_code == 409
    assert changed.json()["code"] == "practice_configuration_changed"
    app.state.practice_admission = TestAdmission()
    assert reserve(client, prepared, expected_epoch=1).status_code == 409
    assert count(factory) == 0


def test_other_user_and_other_practice_paths_cannot_control_a_connection(
    client, prepared, signup, factory
):
    saved = reserve(client, prepared).json()
    other = signup("bobby")
    for method, suffix, body in [
        ("GET", "", None),
        ("POST", "/renew-lease", {"epoch": 1, "client_instance_id": saved["client_instance_id"]}),
        (
            "POST",
            "/cancel-preparation",
            {"epoch": 1, "client_instance_id": saved["client_instance_id"]},
        ),
    ]:
        response = client.request(
            method,
            path(prepared, saved, suffix),
            headers={"Authorization": f"Bearer {other['access_token']}"},
            json=body,
        )
        assert response.status_code == 404
    wrong = client.get(
        f"/v1/practice-sessions/{uuid.uuid4()}/connections/{saved['id']}", headers=prepared.headers
    )
    assert wrong.status_code == 404
    assert count(factory) == 1


def test_safe_cancellation_is_idempotent_and_a_new_attempt_increments_epoch(client, prepared):
    first = reserve(client, prepared).json()
    cancelled = control(client, prepared, first, "cancel-preparation")
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "closed"
    assert cancelled.json()["termination_status"] == "not_started"
    assert cancelled.json()["ended_at"] is not None
    second = reserve(client, prepared, expected_epoch=1)
    assert second.status_code == 201
    assert second.json()["epoch"] == 2
    assert control(client, prepared, first, "cancel-preparation").json() == cancelled.json()
    assert control(client, prepared, first, "renew-lease").status_code == 409
    detail = client.get(f"/v1/practice-sessions/{prepared.session['id']}", headers=prepared.headers)
    assert detail.json()["connection_epoch"] == 2
    assert detail.json()["status"] == "connecting"


def test_lease_renewal_uses_server_time_and_cannot_change_identity(client, prepared, monkeypatch):
    from simontalk_api import connections

    stamp = now()
    monkeypatch.setattr(connections, "now", lambda: stamp)
    first = reserve(client, prepared).json()
    assert control(client, prepared, first, "renew-lease", epoch=2).status_code == 409
    assert (
        control(
            client, prepared, first, "renew-lease", client_instance_id=str(uuid.uuid4())
        ).status_code
        == 409
    )
    monkeypatch.setattr(connections, "now", lambda: stamp + timedelta(seconds=10))
    renewed = control(client, prepared, first, "renew-lease")
    assert renewed.status_code == 200
    assert renewed.json()["lease_expires_at"] > first["lease_expires_at"]
    assert renewed.json()["last_seen_at"] != first["last_seen_at"]


def test_expiry_before_signalling_is_safe_but_never_revives_the_old_attempt(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import connections

    stamp = now()
    monkeypatch.setattr(connections, "now", lambda: stamp)
    first = reserve(client, prepared).json()
    monkeypatch.setattr(connections, "now", lambda: stamp + timedelta(seconds=45))
    expired = control(client, prepared, first, "renew-lease")
    assert expired.status_code == 409
    assert expired.json()["code"] == "connection_lease_expired"
    detail = client.get(path(prepared, first), headers=prepared.headers).json()
    assert detail["status"] == "failed"
    assert detail["termination_status"] == "not_started"
    assert detail["ended_at"] is not None
    assert reserve(client, prepared, expected_epoch=1).status_code == 201
    assert count(factory) == 2


def test_unknown_upstream_cannot_be_cancelled_renewed_or_replaced(client, prepared, factory):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='unknown', "
                "termination_status='unknown' WHERE id=:id"
            ),
            {"id": saved["id"]},
        )
    assert control(client, prepared, saved, "cancel-preparation").status_code == 409
    assert control(client, prepared, saved, "renew-lease").status_code == 409
    assert reserve(client, prepared, expected_epoch=1).status_code == 409
    assert (
        client.post(
            f"/v1/practice-sessions/{prepared.session['id']}/cancel-preparation",
            headers=prepared.headers,
        ).status_code
        == 409
    )


def test_sweep_only_releases_attempts_proven_not_started_and_is_repeatable(
    client, prepared, factory
):
    from simontalk_api.connections import expire_connection_leases

    first = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": first["id"]},
        )
        assert expire_connection_leases(db) == 1
    safe = client.get(path(prepared, first), headers=prepared.headers).json()
    assert safe["status"] == "failed" and safe["termination_status"] == "not_started"
    second = reserve(client, prepared, expected_epoch=1).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='ready', termination_status='unknown', "
                "lease_expires_at=:past WHERE id=:id"
            ),
            {"past": now() - timedelta(seconds=1), "id": second["id"]},
        )
        assert expire_connection_leases(db) == 1
    uncertain = client.get(path(prepared, second), headers=prepared.headers).json()
    assert uncertain["status"] == "unknown" and uncertain["termination_status"] == "unknown"
    assert uncertain["ended_at"] is None
    with factory.begin() as db:
        assert expire_connection_leases(db) == 0
    assert reserve(client, prepared, expected_epoch=2).status_code == 409


def test_unknown_connection_still_blocks_when_parent_status_is_incorrectly_terminal(
    client, prepared, factory
):
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
            text("UPDATE practice_sessions SET status='completed' WHERE id=:id"),
            {"id": prepared.session["id"]},
        )
    response = client.post(
        "/v1/practice-sessions",
        headers={**prepared.headers, "Idempotency-Key": str(uuid.uuid4())},
        json={"mode": "free_chat"},
    )
    assert response.status_code == 409


def test_database_rejects_cross_owner_connections_and_duplicate_live_attempts(
    client, prepared, signup, factory
):
    saved = reserve(client, prepared).json()
    other = signup("bobby")
    insert = text(
        "INSERT INTO realtime_connections "
        "(id,session_id,user_id,creation_key,request_digest,client_instance_id,epoch,configuration,"
        "last_seen_at,lease_expires_at,status,ended_at) "
        "SELECT :id,session_id,:owner,:key,request_digest,"
        "client_instance_id,2,configuration,last_seen_at,lease_expires_at,:status,:ended "
        "FROM realtime_connections "
        "WHERE id=:source"
    )
    for owner, status, ended, constraint in [
        (other["user"]["id"], "closed", now(), "connection_practice_owner"),
        (prepared.identity["user"]["id"], "preparing", None, "one_open_connection_per_user"),
    ]:
        with pytest.raises(IntegrityError) as caught, factory.begin() as db:
            db.execute(
                insert,
                {
                    "id": uuid.uuid4(),
                    "owner": uuid.UUID(owner),
                    "key": uuid.uuid4(),
                    "source": saved["id"],
                    "status": status,
                    "ended": ended,
                },
            )
        assert caught.value.orig.diag.constraint_name == constraint


def test_real_maintenance_cli_expires_only_not_started_connections(client, prepared, factory):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": saved["id"]},
        )
    executable = str(Path(sys.executable).parent / "simontalk-admin")
    result = subprocess.run(
        [executable, "expire-connections", "--limit", "10"],
        env={**os.environ, "SIMONTALK_DATABASE_URL": TEST_URL, "SIMONTALK_ENVIRONMENT": "test"},
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout.strip() == "Expired connection leases: 1."
    assert client.get(path(prepared, saved), headers=prepared.headers).json()["status"] == "failed"


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_reservation_rechecks_authentication_after_owner_lock_wait(
    client, prepared, factory, monkeypatch, action
):
    from simontalk_api import practice_routes

    checked = Event()
    original = practice_routes.session_identity

    def observed(request, db):
        result = original(request, db)
        checked.set()
        return result

    monkeypatch.setattr(practice_routes, "session_identity", observed)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        owner = uuid.UUID(prepared.identity["user"]["id"])
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": owner})
        pending = pool.submit(reserve, client, prepared)
        assert checked.wait(5)
        wait_for_row_lock(factory, "users")
        if action == "disable":
            holder.execute(text("UPDATE users SET disabled_at=now() WHERE id=:id"), {"id": owner})
        else:
            holder.execute(
                text("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"), {"id": owner}
            )
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    assert count(factory) == 0


def test_web_connection_writes_keep_csrf_and_account_binding(client, app, signup):
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
        headers={**headers, "Idempotency-Key": str(uuid.uuid4())},
        json={"mode": "free_chat"},
    ).json()
    prepared = SimpleNamespace(session=session, headers=headers)
    body = {"client_instance_id": str(uuid.uuid4()), "expected_epoch": 0}
    url = f"/v1/practice-sessions/{session['id']}/connections"
    for missing, expected in [("X-CSRF-Token", 403), ("X-Account-ID", 409)]:
        altered = {k: v for k, v in headers.items() if k != missing}
        response = client.post(
            url, headers={**altered, "Idempotency-Key": str(uuid.uuid4())}, json=body
        )
        assert response.status_code == expected
    saved = client.post(
        url, headers={**headers, "Idempotency-Key": str(uuid.uuid4())}, json=body
    ).json()
    for action in ["renew-lease", "cancel-preparation"]:
        for missing, expected in [("X-CSRF-Token", 403), ("X-Account-ID", 409)]:
            prepared.headers = {k: v for k, v in headers.items() if k != missing}
            assert control(client, prepared, saved, action).status_code == expected
        prepared.headers = headers
        assert control(client, prepared, saved, action).status_code == 200


@pytest.mark.parametrize("table", ["users", "practice_sessions", "realtime_connections"])
def test_sweep_skips_busy_rows_without_blocking(client, prepared, factory, table):
    from simontalk_api.connections import expire_connection_leases

    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": saved["id"]},
        )
    row_id = {
        "users": prepared.identity["user"]["id"],
        "practice_sessions": prepared.session["id"],
        "realtime_connections": saved["id"],
    }[table]

    def sweep():
        with factory.begin() as db:
            return expire_connection_leases(db)

    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        holder.execute(text(f"SELECT id FROM {table} WHERE id=:id FOR UPDATE"), {"id": row_id})
        assert pool.submit(sweep).result(timeout=3) == 0
    with factory.begin() as db:
        assert expire_connection_leases(db) == 1


@pytest.mark.parametrize("operation", ["renew", "replace"])
def test_sweep_rechecks_fresh_rows_after_candidate_selection(
    client, prepared, factory, monkeypatch, operation
):
    from sqlalchemy.orm import Session

    from simontalk_api import connections
    from simontalk_api.models import RealtimeConnection

    stamp = now()
    monkeypatch.setattr(connections, "now", lambda: stamp)
    saved = reserve(client, prepared).json()
    selected = Event()
    proceed = Event()
    committing = Event()
    may_commit = Event()
    original = connections._expired_candidates
    original_commit = Session.commit

    def observed(db, stamp, limit):
        rows = original(db, stamp, limit)
        selected.set()
        assert proceed.wait(5)
        return rows

    monkeypatch.setattr(connections, "_expired_candidates", observed)
    clock = [stamp + timedelta(seconds=10)]
    monkeypatch.setattr(connections, "now", lambda: clock[0])

    def delayed_commit(db):
        changed = any(
            isinstance(value, RealtimeConnection)
            and str(value.id) == saved["id"]
            and (
                value.status == "closed"
                if operation == "replace"
                else value.last_seen_at == stamp + timedelta(seconds=10)
            )
            for value in db.identity_map.values()
        )
        if changed and not committing.is_set():
            committing.set()
            assert may_commit.wait(5)
        return original_commit(db)

    monkeypatch.setattr(Session, "commit", delayed_commit)

    def sweep():
        with factory.begin() as db:
            return connections.expire_connection_leases(db)

    with ThreadPoolExecutor(max_workers=2) as pool:
        action = "renew-lease" if operation == "renew" else "cancel-preparation"
        mutation = pool.submit(control, client, prepared, saved, action)
        try:
            assert committing.wait(5)
            # The request was valid at t+10 but its commit is delayed past t+45.
            # A separate PostgreSQL transaction must see the old committed lease.
            clock[0] = stamp + timedelta(seconds=50)
            pending = pool.submit(sweep)
            assert selected.wait(5)
            may_commit.set()
            result = mutation.result(timeout=5)
            assert result.status_code == 200
            if operation == "renew":
                latest = result
            else:
                latest = reserve(client, prepared, expected_epoch=1)
            assert latest.status_code in {200, 201}
        finally:
            may_commit.set()
            proceed.set()
        assert pending.result(timeout=5) == 0
    detail = client.get(path(prepared, latest.json()), headers=prepared.headers).json()
    assert detail == latest.json()
    assert detail["status"] == "preparing"


def test_cancel_waiting_on_connection_lock_cannot_overwrite_signalling(client, prepared, factory):
    saved = reserve(client, prepared).json()
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        holder.execute(
            text("SELECT id FROM realtime_connections WHERE id=:id FOR UPDATE"), {"id": saved["id"]}
        )
        pending = pool.submit(control, client, prepared, saved, "cancel-preparation")
        wait_for_row_lock(factory, "realtime_connections")
        holder.execute(
            text(
                "UPDATE realtime_connections SET status='negotiating', "
                "termination_status='unknown' WHERE id=:id"
            ),
            {"id": saved["id"]},
        )
        holder.commit()
        assert pending.result(timeout=5).status_code == 409
    result = client.get(path(prepared, saved), headers=prepared.headers).json()
    assert result["status"] == "negotiating"
    assert result["termination_status"] == "unknown"


@pytest.mark.parametrize(
    "status,termination,ended,constraint",
    [
        ("closed", "unknown", True, "connection_termination_evidence"),
        ("closed", "not_started", False, "connection_ended_at"),
        ("ready", "not_started", False, "connection_termination_evidence"),
    ],
)
def test_database_cannot_free_a_connection_without_termination_evidence(
    client, prepared, factory, status, termination, ended, constraint
):
    saved = reserve(client, prepared).json()
    with pytest.raises(IntegrityError) as caught, factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status=:status, termination_status=:termination, "
                "ended_at=:ended WHERE id=:id"
            ),
            {
                "id": saved["id"],
                "status": status,
                "termination": termination,
                "ended": now() if ended else None,
            },
        )
    assert caught.value.orig.diag.constraint_name == constraint


def test_attempt_reads_and_writes_require_authentication(client, prepared):
    saved = reserve(client, prepared).json()
    assert client.get(path(prepared, saved)).status_code == 401
    anonymous = SimpleNamespace(session=prepared.session, headers={})
    assert reserve(client, anonymous).status_code == 401
    for action in ["renew-lease", "cancel-preparation"]:
        assert control(client, anonymous, saved, action).status_code == 401
