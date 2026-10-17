from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event

import pytest
from sqlalchemy import text
from test_connection_reservations import control, reserve
from test_connection_reservations import prepared as prepared

from simontalk_api.security import now


def age(factory, prepared, stamp):
    with factory.begin() as db:
        db.execute(
            text("UPDATE practice_sessions SET created_at=:stamp WHERE id=:id"),
            {"stamp": stamp, "id": prepared.session["id"]},
        )


def sweep(factory, limit=100):
    from simontalk_api.preparation_cleanup import expire_idle_preparations

    with factory.begin() as db:
        return expire_idle_preparations(db, limit=limit)


def detail(client, prepared):
    return client.get(
        f"/v1/practice-sessions/{prepared.session['id']}", headers=prepared.headers
    ).json()


def test_idle_cutoff_is_inclusive_preserves_key_and_replays_terminal(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import preparation_cleanup

    stamp = now()
    monkeypatch.setattr(preparation_cleanup, "now", lambda: stamp)
    age(factory, prepared, stamp - timedelta(seconds=300) + timedelta(microseconds=1))
    assert sweep(factory) == 0
    age(factory, prepared, stamp - timedelta(seconds=300))
    assert sweep(factory) == 1
    result = detail(client, prepared)
    assert result["status"] == "cancelled"
    assert result["state_reason"] == "preparation_expired"
    assert result["ended_at"] is not None
    assert result["configuration"] == prepared.session["configuration"]
    assert sweep(factory) == 0
    with factory() as db:
        key = db.scalar(
            text("SELECT creation_key FROM practice_sessions WHERE id=:id"),
            {"id": prepared.session["id"]},
        )
    replay = client.post(
        "/v1/practice-sessions",
        headers={**prepared.headers, "Idempotency-Key": str(key)},
        json={"mode": "free_chat"},
    )
    assert replay.status_code == 201
    assert replay.json() == result


def test_recent_safe_connection_end_postpones_idle_cleanup(client, prepared, factory, monkeypatch):
    from simontalk_api import preparation_cleanup

    saved = reserve(client, prepared).json()
    assert control(client, prepared, saved, "cancel-preparation").status_code == 200
    stamp = now()
    monkeypatch.setattr(preparation_cleanup, "now", lambda: stamp)
    age(factory, prepared, stamp - timedelta(minutes=30))
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET ended_at=:stamp WHERE id=:id"),
            {"stamp": stamp - timedelta(seconds=299), "id": saved["id"]},
        )
    assert sweep(factory) == 0
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET ended_at=:stamp WHERE id=:id"),
            {"stamp": stamp - timedelta(seconds=300), "id": saved["id"]},
        )
    assert sweep(factory) == 1


@pytest.mark.parametrize(
    "status,termination",
    [
        ("preparing", "not_started"),
        ("negotiating", "unknown"),
        ("unknown", "unknown"),
        ("closed", "confirmed"),
    ],
)
def test_connection_occupancy_and_upstream_history_block_cleanup_even_with_wrong_parent(
    client, prepared, factory, status, termination
):
    saved = reserve(client, prepared).json()
    stamp = now() - timedelta(hours=1)
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status=:status,"
                "termination_status=:termination,ended_at=:ended WHERE id=:id"
            ),
            {
                "status": status,
                "termination": termination,
                "ended": stamp if status == "closed" else None,
                "id": saved["id"],
            },
        )
        db.execute(
            text("UPDATE practice_sessions SET status='created',created_at=:stamp WHERE id=:id"),
            {"stamp": stamp, "id": prepared.session["id"]},
        )
    assert sweep(factory) == 0
    assert detail(client, prepared)["status"] == "created"


@pytest.mark.parametrize(
    "status", ["connecting", "interrupted", "active", "ending", "cancelled", "failed"]
)
def test_only_created_preparations_are_candidates(client, prepared, factory, status):
    with factory.begin() as db:
        db.execute(
            text("UPDATE practice_sessions SET status=:status,created_at=:past WHERE id=:id"),
            {"status": status, "past": now() - timedelta(hours=1), "id": prepared.session["id"]},
        )
    assert sweep(factory) == 0
    assert detail(client, prepared)["status"] == status


@pytest.mark.parametrize("table", ["users", "practice_sessions"])
def test_idle_cleanup_skips_locked_rows_without_waiting(client, prepared, factory, table):
    age(factory, prepared, now() - timedelta(hours=1))
    row_id = prepared.identity["user"]["id"] if table == "users" else prepared.session["id"]
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        holder.execute(text(f"SELECT id FROM {table} WHERE id=:id FOR UPDATE"), {"id": row_id})
        assert pool.submit(sweep, factory).result(timeout=3) == 0
    assert sweep(factory) == 1


@pytest.mark.parametrize("operation", ["connect", "cancel"])
def test_idle_cleanup_rechecks_new_activity_after_old_candidate_selection(
    client, prepared, factory, monkeypatch, operation
):
    from simontalk_api import preparation_cleanup

    age(factory, prepared, now() - timedelta(hours=1))
    selected, proceed = Event(), Event()
    original = preparation_cleanup._idle_candidates

    def observe(db, cutoff, limit):
        rows = original(db, cutoff, limit)
        selected.set()
        assert proceed.wait(5)
        return rows

    monkeypatch.setattr(preparation_cleanup, "_idle_candidates", observe)
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(sweep, factory)
        try:
            assert selected.wait(5)
            saved = reserve(client, prepared).json()
            if operation == "cancel":
                assert control(client, prepared, saved, "cancel-preparation").status_code == 200
        finally:
            proceed.set()
        assert pending.result(timeout=5) == 0
    assert detail(client, prepared)["status"] == (
        "connecting" if operation == "connect" else "created"
    )


def test_two_idle_sweepers_only_finalize_once(client, prepared, factory):
    age(factory, prepared, now() - timedelta(hours=1))
    with ThreadPoolExecutor(max_workers=2) as pool:
        counts = list(pool.map(lambda _: sweep(factory), range(2)))
    assert sum(counts) == 1
    assert detail(client, prepared)["status"] == "cancelled"


@pytest.mark.parametrize("limit", [True, 0, -1, 1001])
def test_idle_batch_limit_is_strictly_bounded(factory, limit):
    with pytest.raises(ValueError):
        sweep(factory, limit=limit)


def test_manual_preparation_cancel_records_reason(client, prepared):
    response = client.post(
        f"/v1/practice-sessions/{prepared.session['id']}/cancel-preparation",
        headers=prepared.headers,
    )
    assert response.status_code == 200
    assert response.json()["state_reason"] == "cancelled_before_signalling"
