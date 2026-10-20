import json
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


def test_orm_metadata_matches_migrated_database(database):
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext

    from simontalk_api.db import Base

    with database[0].connect() as connection:
        assert compare_metadata(MigrationContext.configure(connection), Base.metadata) == []


def event(sequence=1, **changes):
    return {
        "event_id": str(uuid4()),
        "sequence": sequence,
        "turn_id": str(uuid4()),
        "turn_index": sequence,
        "role": "user",
        "revision": 1,
        "text": "I enjoy learning English. 我喜欢英语。",
        "response_id": None,
        "provider_item_id": None,
        **changes,
    }


def post(client, prepared, saved, events=None, **changes):
    return client.post(
        path(prepared, saved, "/transcripts"),
        headers={**prepared.headers, "Content-Type": "application/json"},
        content=json.dumps(
            {
                "client_instance_id": saved["client_instance_id"],
                "epoch": saved["epoch"],
                "events": [event()] if events is None else events,
                **changes,
            },
            ensure_ascii=True,
        ),
    )


def rows(factory):
    with factory() as db:
        return (
            db.execute(text("SELECT * FROM final_transcripts ORDER BY sequence")).mappings().all()
        )


def state(factory):
    with factory() as db:
        return (
            db.execute(text("SELECT * FROM practice_sessions ORDER BY id")).mappings().all(),
            db.execute(text("SELECT * FROM realtime_connections ORDER BY id")).mappings().all(),
        )


def test_append_replay_ack_and_read_are_explicit_client_reports(client, app, prepared, factory):
    saved = reserve(client, prepared).json()
    before = state(factory)
    events = [event(), event(3, role="assistant", response_id=str(uuid4()))]
    app.state.practice_admission = UnavailableAdmission()
    first = post(client, prepared, saved, events)
    assert first.status_code == 200, first.text
    assert first.json() == {
        "source": "client_reported",
        "account_id": prepared.identity["user"]["id"],
        "session_id": prepared.session["id"],
        "connection_id": saved["id"],
        "client_instance_id": saved["client_instance_id"],
        "epoch": 1,
        "acknowledged_event_ids": [e["event_id"] for e in events],
        "last_sequence": 3,
        "total_events": 2,
        "total_text_bytes": sum(len(e["text"].encode()) for e in events),
    }
    assert post(client, prepared, saved, events).json() == first.json()
    assert state(factory) == before
    assert len(rows(factory)) == 2
    result = client.get(path(prepared, saved, "/transcripts"), headers=prepared.headers)
    assert result.status_code == 200
    assert result.headers["Cache-Control"] == "no-store"
    page = result.json()
    assert page["source"] == "client_reported"
    assert [e["delivery_status"] for e in page["events"]] == [None, "unknown"]
    for original, received in zip(events, page["events"], strict=True):
        assert {k: received[k] for k in original} == original
        assert received["received_at"]
    assert not page["has_more"] and page["next_after_sequence"] == 3


def test_final_revisions_append_without_overwriting_and_preserve_order_gaps(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    first = event(2, turn_index=4, revision=3, provider_item_id="provider-original")
    revised = {**first, "event_id": str(uuid4()), "sequence": 6, "revision": 7, "text": ""}
    earlier_turn = event(8, turn_index=1)
    assert post(client, prepared, saved, [first, revised, earlier_turn]).status_code == 200
    assert [r["revision"] for r in rows(factory)] == [3, 7, 1]
    assert [r["text"] for r in rows(factory)] == [first["text"], "", earlier_turn["text"]]
    url = path(prepared, saved, "/transcripts?after_sequence=2&limit=1")
    page = client.get(url, headers=prepared.headers).json()
    assert page["last_sequence"] == 8 and page["total_events"] == 3
    assert page["has_more"] and page["next_after_sequence"] == 6
    assert page["events"][0]["text"] == ""


def test_later_revision_remains_readable_after_its_turn_was_already_paged(client, prepared):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first, event(2)]).status_code == 200
    url = path(prepared, saved, "/transcripts")
    page = client.get(url + "?limit=2", headers=prepared.headers).json()
    assert not page["has_more"] and page["next_after_sequence"] == 2
    revised = {
        **first,
        "event_id": str(uuid4()),
        "sequence": 3,
        "revision": 2,
        "text": "I enjoy speaking English.",
    }
    assert post(client, prepared, saved, [revised]).status_code == 200
    next_page = client.get(url + "?after_sequence=2", headers=prepared.headers).json()
    assert next_page["events"][0]["turn_id"] == first["turn_id"]
    assert next_page["events"][0]["revision"] == 2
    assert next_page["events"][0]["text"] == revised["text"]


def test_four_maximum_escaped_texts_fit_bounded_wire_body(client, prepared):
    saved = reserve(client, prepared).json()
    events = [event(i, text="\u0001" * 8192, provider_item_id="😀" * 256) for i in range(1, 5)]
    response = post(client, prepared, saved, events)
    assert response.status_code == 200, response.text
    assert response.json()["total_text_bytes"] == 4 * 8192


def test_database_rejects_invalid_final_text_rows(client, prepared, factory):
    saved = reserve(client, prepared).json()
    assert post(client, prepared, saved).status_code == 200
    for field, value in [
        ("sequence", 0),
        ("turn_index", 0),
        ("revision", 0),
        ("role", "assistant"),
        ("text", "x" * 8193),
        ("provider_item_id", ""),
        ("event_digest", "invalid"),
    ]:
        with pytest.raises(IntegrityError), factory.begin() as db:
            db.execute(text(f"UPDATE final_transcripts SET {field}=:value"), {"value": value})


@pytest.mark.parametrize(
    "changes",
    [
        {"text": "private-conflicting-text"},
        {"event_id": str(uuid4())},
        {"event_id": str(uuid4()), "sequence": 2},
        {"event_id": str(uuid4()), "sequence": 2, "revision": 2, "turn_index": 2},
        {"event_id": str(uuid4()), "sequence": 2, "revision": 2, "provider_item_id": "new"},
        {
            "event_id": str(uuid4()),
            "sequence": 2,
            "revision": 2,
            "role": "assistant",
            "response_id": str(uuid4()),
        },
    ],
)
def test_conflicts_reject_entire_batch_without_echo(client, prepared, factory, changes):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first]).status_code == 200
    invalid = {**first, **changes}
    batch = [invalid, event(3)]
    result = post(client, prepared, saved, batch)
    assert result.status_code == 409
    assert "private-conflicting-text" not in result.text
    assert len(rows(factory)) == 1


def test_later_conflict_rolls_back_an_otherwise_valid_earlier_addition(client, prepared, factory):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first]).status_code == 200
    invalid = {**first, "event_id": str(uuid4()), "sequence": 3}
    result = post(client, prepared, saved, [event(2), invalid])
    assert result.status_code == 409
    assert [str(row["event_id"]) for row in rows(factory)] == [first["event_id"]]


def test_new_event_cannot_reuse_index_regress_revision_or_sequence(client, prepared, factory):
    saved = reserve(client, prepared).json()
    first = event(5, revision=4)
    assert post(client, prepared, saved, [first]).status_code == 200
    for bad in [
        event(7, turn_index=5),
        {**first, "event_id": str(uuid4()), "sequence": 7, "revision": 3},
        event(4),
    ]:
        result = post(client, prepared, saved, [bad])
        assert result.status_code == 409
    assert len(rows(factory)) == 1


@pytest.mark.parametrize("same", [True, False])
def test_concurrent_append_is_serialized_and_idempotent(client, prepared, factory, same):
    saved = reserve(client, prepared).json()
    first = event()
    batches = [[first], [first if same else event()]]
    with ThreadPoolExecutor(max_workers=2) as pool:
        result = list(pool.map(lambda es: post(client, prepared, saved, es), batches))
    assert sorted(r.status_code for r in result) == ([200, 200] if same else [200, 409])
    assert len(rows(factory)) == 1


@pytest.mark.parametrize(
    "changes",
    [
        {"sequence": True},
        {"sequence": 0},
        {"sequence": "1"},
        {"sequence": 2147483648},
        {"turn_index": False},
        {"turn_index": 0},
        {"revision": True},
        {"revision": 0},
        {"turn_id": "private-invalid"},
        {"role": "system"},
        {"role": "assistant"},
        {"response_id": str(uuid4())},
        {"text": 123},
        {"text": "好" * 2731},
        {"text": "private\u0000content"},
        {"text": "private\ud800content"},
        {"provider_item_id": ""},
        {"provider_item_id": "x" * 257},
        {"provider_item_id": "private\u0000value"},
        {"provider_item_id": "private\ud800value"},
        {"is_final": False},
        {"source": "verified"},
        {"played_text": "private"},
    ],
)
def test_strict_fields_reject_private_input_without_echo(client, prepared, factory, changes):
    saved = reserve(client, prepared).json()
    result = post(client, prepared, saved, [event(**changes)])
    assert result.status_code == 422, result.text
    assert "private" not in result.text
    assert rows(factory) == []


def test_batch_identity_shape_and_read_queries_are_bounded(client, prepared, factory):
    saved = reserve(client, prepared).json()
    one = event()
    for batch in [[], [event(i) for i in range(1, 6)], [one, one], [event(2), event(1)]]:
        assert post(client, prepared, saved, batch).status_code == 422
    for changes, status in [
        ({"epoch": True}, 422),
        ({"epoch": 2}, 409),
        ({"client_instance_id": str(uuid4())}, 409),
        ({"source": "client_reported"}, 422),
    ]:
        assert post(client, prepared, saved, **changes).status_code == status
    for query in ["limit=0", "limit=33", "after_sequence=-1", "after_sequence=2147483648"]:
        assert (
            client.get(
                path(prepared, saved, "/transcripts?" + query), headers=prepared.headers
            ).status_code
            == 422
        )
    assert rows(factory) == []


@pytest.mark.parametrize("limit", ["events", "turns", "text"])
def test_lifetime_limits_allow_replay_and_reject_atomically(client, prepared, factory, limit):
    saved = reserve(client, prepared).json()
    common = event()
    maximum = {"events": 512, "turns": 256, "text": 128}[limit]
    last_batch = []
    for start in range(1, maximum + 1, 4):
        batch = [
            (
                {**common, "event_id": str(uuid4()), "sequence": i, "revision": i, "text": ""}
                if limit == "events"
                else event(i, text="x" * 8192 if limit == "text" else "")
            )
            for i in range(start, start + 4)
        ]
        result = post(client, prepared, saved, batch)
        assert result.status_code == 200, result.text
        last_batch = batch
    replay = post(client, prepared, saved, last_batch)
    assert replay.status_code == 200
    assert replay.json()["total_events"] == maximum
    over = (
        {
            **common,
            "event_id": str(uuid4()),
            "sequence": maximum + 1,
            "revision": maximum + 1,
            "text": "",
        }
        if limit == "events"
        else event(maximum + 1, text="x")
    )
    result = post(client, prepared, saved, [last_batch[-1], over])
    assert result.status_code == 429 and result.json()["code"] == "transcript_limit_reached"
    assert len(rows(factory)) == maximum


def test_history_unknown_and_deletion_never_move_facts_to_new_connection(client, prepared, factory):
    old = reserve(client, prepared).json()
    assert control(client, prepared, old, "cancel-preparation").status_code == 200
    new = reserve(client, prepared, expected_epoch=1).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='unknown', "
                "termination_status='unknown' WHERE id=:id"
            ),
            {"id": new["id"]},
        )
    before = state(factory)
    assert post(client, prepared, old).status_code == 200
    assert post(client, prepared, new).status_code == 200
    assert state(factory) == before
    assert reserve(client, prepared, expected_epoch=2).status_code == 409
    for field, value in [("client_instance_id", uuid4()), ("epoch", 99), ("source", "verified")]:
        with pytest.raises(IntegrityError), factory.begin() as db:
            db.execute(text(f"UPDATE final_transcripts SET {field}=:value"), {"value": value})
    with factory.begin() as db:
        db.execute(
            text("DELETE FROM practice_sessions WHERE id=:id"), {"id": prepared.session["id"]}
        )
    assert rows(factory) == []
    assert post(client, prepared, old).status_code == 404


def test_authentication_ownership_and_path_binding(client, prepared, signup, factory):
    saved = reserve(client, prepared).json()
    anonymous = SimpleNamespace(session=prepared.session, headers={})
    assert post(client, anonymous, saved).status_code == 401
    other = signup("bob")
    foreign = SimpleNamespace(
        session=prepared.session, headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert post(client, foreign, saved).status_code == 404
    url = path(prepared, saved, "/transcripts")
    assert client.get(url, headers=foreign.headers).status_code == 404
    assert client.get(url).status_code == 401
    absent = {**saved, "id": str(uuid4())}
    assert post(client, prepared, absent).status_code == 404
    assert rows(factory) == []


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_owner_authentication_is_rechecked_after_lock_wait(
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


def test_web_writes_keep_csrf_origin_and_expected_account(client, app, signup):
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
