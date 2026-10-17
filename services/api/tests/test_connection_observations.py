from concurrent.futures import ThreadPoolExecutor
from threading import Event
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from test_connection_reservations import TestAdmission, control, path, reserve
from test_connection_reservations import prepared as prepared
from test_practice_preparation import wait_for_row_lock

from simontalk_api.practice import UnavailableAdmission


def event(sequence=1, **changes):
    return {
        "event_id": str(uuid4()),
        "sequence": sequence,
        "code": "transport_connected",
        "elapsed_ms": sequence * 100,
        **changes,
    }


def post(client, prepared, saved, events=None, **changes):
    return client.post(
        path(prepared, saved, "/observations"),
        headers=prepared.headers,
        json={
            "client_instance_id": saved["client_instance_id"],
            "epoch": saved["epoch"],
            "events": events if events is not None else [event()],
            **changes,
        },
    )


def rows(factory):
    with factory() as db:
        return (
            db.execute(text("SELECT * FROM connection_observations ORDER BY sequence"))
            .mappings()
            .all()
        )


def connection(factory, saved):
    with factory() as db:
        return dict(
            db.execute(text("SELECT * FROM realtime_connections WHERE id=:id"), {"id": saved["id"]})
            .mappings()
            .one()
        )


def test_append_and_exact_replay_only_write_untrusted_facts(client, app, prepared, factory):
    saved = reserve(client, prepared).json()
    before = connection(factory, saved)
    events = [event(), event(2, code="local_closed", reason="user_stop")]
    app.state.practice_admission = UnavailableAdmission()
    first = post(client, prepared, saved, events)
    assert first.status_code == 200, first.text
    assert first.json() == {
        "source": "client_observed",
        "connection_id": saved["id"],
        "client_instance_id": saved["client_instance_id"],
        "epoch": 1,
        "acknowledged_event_ids": [e["event_id"] for e in events],
        "last_sequence": 2,
        "total_events": 2,
    }
    assert post(client, prepared, saved, events).json() == first.json()
    assert len(rows(factory)) == 2
    assert connection(factory, saved) == before
    assert all(row["received_at"] is not None for row in rows(factory))
    assert first.headers["Cache-Control"] == "no-store"


def test_conflict_or_stale_sequence_rejects_the_entire_batch(client, prepared, factory):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first]).status_code == 200
    for events in [
        [{**first, "elapsed_ms": 99}],
        [event(2), {**first, "sequence": 3}],
        [event(1)],
    ]:
        response = post(client, prepared, saved, events)
        assert response.status_code == 409
        assert response.json()["code"] == "observation_conflict"
        assert len(rows(factory)) == 1
    assert post(client, prepared, saved, [event(4)]).status_code == 200
    stale = post(client, prepared, saved, [event(3)])
    assert stale.status_code == 409
    assert stale.json()["code"] == "observation_sequence_stale"
    assert len(rows(factory)) == 2


@pytest.mark.parametrize("same", [True, False])
def test_concurrent_batches_never_duplicate_or_overwrite(client, prepared, factory, same):
    saved = reserve(client, prepared).json()
    first = event()
    payloads = [[first], [first if same else event()]]
    with ThreadPoolExecutor(max_workers=2) as pool:
        result = list(pool.map(lambda items: post(client, prepared, saved, items), payloads))
    assert sorted(r.status_code for r in result) == ([200, 200] if same else [200, 409])
    assert len(rows(factory)) == 1


def test_per_connection_limit_does_not_reject_replay_or_partially_append(client, prepared, factory):
    saved = reserve(client, prepared).json()
    for start in range(1, 257, 16):
        batch = [event(sequence) for sequence in range(start, start + 16)]
        assert post(client, prepared, saved, batch).status_code == 200
    assert post(client, prepared, saved, batch).status_code == 200
    over = post(client, prepared, saved, [batch[-1], event(257)])
    assert over.status_code == 429
    assert over.json()["code"] == "observation_limit_reached"
    assert len(rows(factory)) == 256


@pytest.mark.parametrize(
    "changes",
    [
        {"sequence": True},
        {"sequence": 0},
        {"sequence": "1"},
        {"elapsed_ms": True},
        {"elapsed_ms": -1},
        {"elapsed_ms": 86400001},
        {"code": "confirmed"},
        {"code": "arbitrary-private-text"},
        {"reason": "user_stop"},
        {"code": "local_closed", "reason": "raw-private-reason"},
        {"transcript": "private-user-speech"},
    ],
)
def test_event_fields_are_strict_and_never_echo_input(client, prepared, factory, changes):
    saved = reserve(client, prepared).json()
    result = post(client, prepared, saved, [event(**changes)])
    assert result.status_code == 422
    assert "private" not in result.text
    assert rows(factory) == []


def test_batch_shape_and_connection_identity_are_strict(client, prepared, factory):
    saved = reserve(client, prepared).json()
    one = event()
    for batch in [[], [event(i) for i in range(1, 18)], [one, one], [event(2), event(1)]]:
        assert post(client, prepared, saved, batch).status_code == 422
    for changes, status in [
        ({"epoch": True}, 422),
        ({"epoch": 2}, 409),
        ({"client_instance_id": str(uuid4())}, 409),
        ({"termination_status": "confirmed"}, 422),
    ]:
        assert post(client, prepared, saved, **changes).status_code == status
    assert rows(factory) == []


def test_authentication_ownership_and_read_queries(client, prepared, signup):
    saved = reserve(client, prepared).json()
    anonymous = SimpleNamespace(session=prepared.session, headers={})
    assert post(client, anonymous, saved).status_code == 401
    other = signup("bob")
    foreign = SimpleNamespace(
        session=prepared.session, headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert post(client, foreign, saved).status_code == 404
    url = path(prepared, saved, "/observations")
    assert client.get(url, headers=foreign.headers).status_code == 404
    assert client.get(url).status_code == 401
    for query in ["limit=0", "limit=33", "after_sequence=-1"]:
        assert client.get(f"{url}?{query}", headers=prepared.headers).status_code == 422


def test_read_pages_use_a_bounded_record_snapshot(client, app, prepared):
    saved = reserve(client, prepared).json()
    events = [event(i) for i in [1, 3, 5, 7]]
    assert post(client, prepared, saved, events).status_code == 200
    app.state.practice_admission = UnavailableAdmission()
    url = path(prepared, saved, "/observations")
    first = client.get(url + "?after_sequence=1&limit=2", headers=prepared.headers).json()
    assert first["source"] == "client_observed"
    assert [e["sequence"] for e in first["events"]] == [3, 5]
    assert first["next_after_sequence"] == 5 and first["has_more"]
    assert first["last_sequence"] == 7 and first["total_events"] == 4
    last = client.get(url + "?after_sequence=5&limit=2", headers=prepared.headers).json()
    assert [e["sequence"] for e in last["events"]] == [7]
    assert last["next_after_sequence"] == 7 and not last["has_more"]


def test_historical_close_never_changes_the_new_connection(client, prepared, factory):
    old = reserve(client, prepared).json()
    assert control(client, prepared, old, "cancel-preparation").status_code == 200
    new = reserve(client, prepared, expected_epoch=1).json()
    before = connection(factory, new)
    response = post(client, prepared, old, [event(code="local_closed", reason="background")])
    assert response.status_code == 200
    assert connection(factory, new) == before
    assert connection(factory, old)["status"] == "closed"


def test_unknown_close_never_releases_or_confirms_upstream(client, prepared, factory):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='unknown', "
                "termination_status='unknown' WHERE id=:id"
            ),
            {"id": saved["id"]},
        )
    before = connection(factory, saved)
    assert (
        post(client, prepared, saved, [event(code="local_closed", reason="user_stop")]).status_code
        == 200
    )
    assert connection(factory, saved) == before
    assert reserve(client, prepared, expected_epoch=1).status_code == 409


def test_database_binds_observations_to_original_identity_and_cascades(client, prepared, factory):
    saved = reserve(client, prepared).json()
    assert post(client, prepared, saved).status_code == 200
    for field, value in [("client_instance_id", uuid4()), ("epoch", 2)]:
        with pytest.raises(IntegrityError), factory.begin() as db:
            db.execute(text(f"UPDATE connection_observations SET {field}=:value"), {"value": value})
    with factory.begin() as db:
        db.execute(
            text("DELETE FROM practice_sessions WHERE id=:id"), {"id": prepared.session["id"]}
        )
    assert rows(factory) == []


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_authentication_is_rechecked_after_owner_lock_wait(
    client, prepared, factory, monkeypatch, action
):
    from simontalk_api import practice_routes

    saved = reserve(client, prepared).json()
    checked = Event()
    original = practice_routes.session_identity

    def observed(request, db):
        result = original(request, db)
        checked.set()
        return result

    monkeypatch.setattr(practice_routes, "session_identity", observed)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        owner = UUID(prepared.identity["user"]["id"])
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": owner})
        pending = pool.submit(post, client, prepared, saved)
        assert checked.wait(5)
        wait_for_row_lock(factory, "users")
        sql = (
            "UPDATE users SET disabled_at=now() WHERE id=:id"
            if action == "disable"
            else "UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"
        )
        holder.execute(text(sql), {"id": owner})
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    assert rows(factory) == []


def test_web_observations_keep_csrf_origin_and_account_binding(client, app, signup):
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
    for missing, status in [("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)]:
        prepared.headers = {k: v for k, v in headers.items() if k != missing}
        assert post(client, prepared, saved).status_code == status
    prepared.headers = headers
    assert post(client, prepared, saved).status_code == 200
