from datetime import datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import event, text
from test_connection_reservations import path, reserve
from test_connection_reservations import prepared as prepared
from test_practice_completion import upstream

from simontalk_api.models import RealtimeConnection
from simontalk_api.security import now
from simontalk_api.termination_checks import ensure_termination_check


def read(client, prepared, saved, *, headers=None):
    return client.get(
        path(prepared, saved, "/termination-check"),
        headers=prepared.headers if headers is None else headers,
    )


def stored(factory):
    with factory() as db:
        return {
            table: db.execute(text(f"SELECT * FROM {table} ORDER BY 1")).mappings().all()
            for table in ("practice_sessions", "realtime_connections", "termination_checks")
        }


def block(factory, saved):
    upstream(factory, saved, status="unknown")
    with factory.begin() as db:
        connection = db.get(RealtimeConnection, UUID(saved["id"]))
        assert ensure_termination_check(db, connection)


def test_not_requested_is_read_only_even_with_expired_unknown_connection(client, prepared, factory):
    saved = reserve(client, prepared).json()
    upstream(factory, saved, status="unknown")
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:expired WHERE id=:id"),
            {"id": saved["id"], "expired": now() - timedelta(seconds=5)},
        )
    before = stored(factory)
    response = read(client, prepared, saved)
    assert response.status_code == 200, response.text
    assert response.headers["Cache-Control"] == "no-store"
    assert response.json() == {
        "source": "server_recorded",
        "account_id": prepared.identity["user"]["id"],
        "session_id": prepared.session["id"],
        "connection_id": saved["id"],
        "client_instance_id": saved["client_instance_id"],
        "epoch": saved["epoch"],
        "status": "not_requested",
        "reason": None,
        "attempts": 0,
        "created_at": None,
    }
    assert read(client, prepared, saved).json() == response.json()
    assert stored(factory) == before


def test_blocked_is_exact_snapshot_without_attempt_digest_or_writes(client, prepared, factory):
    saved = reserve(client, prepared).json()
    block(factory, saved)
    before = stored(factory)
    response = read(client, prepared, saved)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["status"] == "blocked" and data["reason"] == "capability_unavailable"
    assert data["attempts"] == 0
    assert datetime.fromisoformat(data["created_at"]).tzinfo is not None
    assert set(data) == {
        "source",
        "account_id",
        "session_id",
        "connection_id",
        "client_instance_id",
        "epoch",
        "status",
        "reason",
        "attempts",
        "created_at",
    }
    assert "a" * 64 not in response.text
    assert read(client, prepared, saved).json() == data
    assert stored(factory) == before


def test_connection_and_check_are_read_with_one_left_join(client, prepared, factory, app):
    saved = reserve(client, prepared).json()
    block(factory, saved)
    statements = []

    def capture(conn, cursor, statement, parameters, context, executemany):
        if "realtime_connections" in statement:
            statements.append(statement)

    event.listen(app.state.engine, "before_cursor_execute", capture)
    try:
        assert read(client, prepared, saved).status_code == 200
    finally:
        event.remove(app.state.engine, "before_cursor_execute", capture)
    assert len(statements) == 1
    assert "LEFT OUTER JOIN termination_checks" in statements[0]
    assert "attempt_digest" not in statements[0]


def test_other_account_missing_scope_and_deleted_connection_are_404(
    client, prepared, factory, signup
):
    saved = reserve(client, prepared).json()
    block(factory, saved)
    other = signup("other")
    other_headers = {"Authorization": f"Bearer {other['access_token']}"}
    before = stored(factory)
    for requested, headers in [
        (saved, other_headers),
        ({**saved, "id": str(uuid4())}, prepared.headers),
    ]:
        response = read(client, prepared, requested, headers=headers)
        assert response.status_code == 404
        assert response.json()["code"] == "connection_not_found"
        assert response.headers["Cache-Control"] == "no-store"
        assert "attempt_digest" not in response.text
    wrong_session = client.get(
        f"/v1/practice-sessions/{uuid4()}/connections/{saved['id']}/termination-check",
        headers=prepared.headers,
    )
    assert wrong_session.status_code == 404
    assert stored(factory) == before
    with factory.begin() as db:
        db.execute(text("DELETE FROM realtime_connections WHERE id=:id"), {"id": saved["id"]})
    assert read(client, prepared, saved).status_code == 404


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_revoked_or_disabled_identity_cannot_read(client, prepared, factory, action):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"
                if action == "revoke"
                else "UPDATE users SET disabled_at=now() WHERE id=:id"
            ),
            {"id": prepared.identity["user"]["id"]},
        )
    response = read(client, prepared, saved)
    assert response.status_code == 401
    assert response.headers["Cache-Control"] == "no-store"


def test_account_header_binding_and_unauthenticated_reads_are_rejected(client, prepared):
    saved = reserve(client, prepared).json()
    response = read(
        client,
        prepared,
        saved,
        headers={**prepared.headers, "X-Account-ID": str(uuid4())},
    )
    assert response.status_code == 409 and response.json()["code"] == "account_changed"
    assert read(client, prepared, saved, headers={}).status_code == 401
    response = read(
        client,
        prepared,
        saved,
        headers={**prepared.headers, "X-Account-ID": prepared.identity["user"]["id"]},
    )
    assert response.status_code == 200
