"""History is a bounded, owner-scoped projection, never a completion operation."""

import base64
import json
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from test_rehearsal_targets import rows
from test_rehearsal_targets import target_source as target_source
from test_saved_transcripts import event, reserve, seal
from test_saved_transcripts import scope as scope

from simontalk_api.models import PracticeSession, RealtimeConnection

PATH = "/v1/practice-history"


def add_records(factory, owner, count=21, *, timestamp=None):
    timestamp = timestamp or datetime(2026, 10, 20, 12, tzinfo=UTC)
    ids = []
    with factory.begin() as db:
        for _ in range(count):
            row = PracticeSession(
                user_id=UUID(owner),
                creation_key=uuid4(),
                request_digest="a" * 64,
                mode="free_chat",
                status="cancelled",
                configuration={"effective_difficulty": "advanced", "private": "MUST NOT LEAK"},
                created_at=timestamp,
                ended_at=timestamp + timedelta(seconds=1),
            )
            db.add(row)
            db.flush()
            ids.append(str(row.id))
    return sorted(ids, reverse=True)


def headers(identity):
    return {"Authorization": f"Bearer {identity['access_token']}"}


def test_empty_owner_list_and_anonymous(client, signup):
    a = signup()
    assert client.get(PATH).status_code == 401
    r = client.get(PATH, headers=headers(a))
    assert r.status_code == 200, r.text
    assert r.json() == {
        "schema_version": "practice_history_v1",
        "source": "server_recorded",
        "account_id": a["user"]["id"],
        "limit": 10,
        "items": [],
        "next_cursor": None,
    }
    assert r.headers["Cache-Control"] == "no-store"


def test_seek_equal_time_insert_and_deleted_boundary(client, signup, factory):
    a = signup()
    ids = add_records(factory, a["user"]["id"])
    h = headers(a)
    first = client.get(PATH, headers=h).json()
    assert [x["id"] for x in first["items"]] == ids[:10]
    # A new record must not shift the older page; a cursor survives its row's removal.
    add_records(factory, a["user"]["id"], 1, timestamp=datetime.now(UTC))
    with factory.begin() as db:
        db.delete(db.get(PracticeSession, UUID(ids[9])))
    second = client.get(PATH, headers=h, params={"cursor": first["next_cursor"]}).json()
    assert [x["id"] for x in second["items"]] == ids[10:20]
    last = client.get(PATH, headers=h, params={"cursor": second["next_cursor"]}).json()
    assert [x["id"] for x in last["items"]] == ids[20:]
    assert last["next_cursor"] is None


def test_detail_owner_snapshot_and_no_body(client, signup, factory):
    a = signup()
    sid = add_records(factory, a["user"]["id"], 1)[0]
    r = client.get(f"{PATH}/{sid}", headers=headers(a))
    assert r.status_code == 200, r.text
    item = r.json()["item"]
    assert item["difficulty"] == "advanced"
    assert item["completion_status"] == "unregistered" and item["coverage"] is None
    assert item["connection_pending"] is False
    assert set(item) == set(
        (
            "id kind source_session_id status created_at ended_at difficulty topic "
            "completion_status coverage connection_pending"
        ).split()
    )
    assert "MUST NOT LEAK" not in r.text
    b = signup("bob")
    assert client.get(f"{PATH}/{sid}", headers=headers(b)).status_code == 404
    assert client.get(f"{PATH}/{uuid4()}", headers=headers(a)).status_code == 404
    assert client.get(PATH, headers=headers(b)).json()["items"] == []
    assert (
        client.get(PATH, headers=headers(a) | {"X-Account-ID": b["user"]["id"]}).status_code == 409
    )


def test_cursor_bound_to_account(client, signup, factory):
    a = signup()
    add_records(factory, a["user"]["id"], 2)
    cursor = client.get(PATH, headers=headers(a), params={"limit": 1}).json()["next_cursor"]
    b = signup("bob")
    r = client.get(PATH, headers=headers(b), params={"cursor": cursor})
    assert r.status_code == 400 and r.json()["code"] == "history_cursor_invalid"


def test_extreme_timezone_cursor_is_bad_request_not_server_failure(client, signup):
    a = signup()
    value = (
        base64.urlsafe_b64encode(
            json.dumps([a["user"]["id"], "0001-01-01T00:00:00.000000+01:00", str(uuid4())]).encode()
        )
        .decode()
        .rstrip("=")
    )
    r = client.get(PATH, headers=headers(a), params={"cursor": value})
    assert r.status_code == 400


@pytest.mark.parametrize(
    "value",
    [
        "",
        "garbage",
        "=",
        "é",
        "x" * 257,
        base64.urlsafe_b64encode(json.dumps(["a", "b", "c"]).encode()).decode().rstrip("="),
    ],
)
def test_bad_cursor(client, signup, value):
    r = client.get(PATH, headers=headers(signup()), params={"cursor": value})
    assert r.status_code == 400


@pytest.mark.parametrize("value", [0, -1, 21, "1.0", "01", "true"])
def test_bad_limit(client, signup, value):
    assert client.get(PATH, headers=headers(signup()), params={"limit": value}).status_code == 422


def test_seal_and_pending_are_independent_and_reads_never_write(
    client, scope, factory, monkeypatch
):
    connection, _ = seal(client, scope, [event()])
    with factory.begin() as db:
        c = db.get(RealtimeConnection, UUID(connection["id"]))
        c.status = "unknown"
        c.termination_status = "unknown"
        c.ended_at = None
    before = rows(factory)
    from sqlalchemy.orm import Session

    monkeypatch.setattr(Session, "commit", lambda _: pytest.fail("read committed"))
    for path in (PATH, f"{PATH}/{scope.session['id']}"):
        r = client.get(path, headers=scope.headers)
        assert r.status_code == 200, r.text
        item = r.json().get("item") or r.json()["items"][0]
        assert item["completion_status"] == "sealed" and item["coverage"] == "complete"
        assert item["connection_pending"] is True
    assert rows(factory) == before


def test_pending_preparation_does_not_pretend_content_saved(client, scope):
    reserve(client, scope)
    item = client.get(f"{PATH}/{scope.session['id']}", headers=scope.headers).json()["item"]
    assert item["connection_pending"] is True and item["completion_status"] == "unregistered"


def test_owner_seek_index_exists(factory):
    with factory() as db:
        definition = db.scalar(
            text("SELECT indexdef FROM pg_indexes WHERE indexname='practice_history_owner_seek'")
        )
        assert definition and "(user_id, created_at, id)" in definition


def test_ending_is_not_sealed(client, scope):
    c = reserve(client, scope)
    response = client.post(
        f"/v1/practice-sessions/{scope.session['id']}/connections/{c['id']}/end",
        headers=scope.headers | {"Idempotency-Key": str(uuid4())},
        json={"client_instance_id": c["client_instance_id"], "epoch": c["epoch"]},
    )
    assert response.status_code == 200, response.text
    item = client.get(f"{PATH}/{scope.session['id']}", headers=scope.headers).json()["item"]
    assert item["completion_status"] == "ending" and item["coverage"] == "pending"


def test_rehearsal_source_and_ordinary_appear_independently(client, target_source, factory):
    from test_rehearsal_preparations import create, release, target

    s = target_source
    release(factory, s)
    child = create(client, s, target(client, s)).json()["practice"]
    listing = client.get(PATH, headers=s.scope.headers).json()["items"]
    assert {item["id"] for item in listing} == {s.scope.session["id"], child["id"]}
    detail = client.get(f"{PATH}/{child['id']}", headers=s.scope.headers).json()["item"]
    assert detail["kind"] == "rehearsal" and detail["source_session_id"] == s.scope.session["id"]
    assert detail["completion_status"] == "unregistered"
    assert "rehearsal_target" not in str(listing)


def test_page_uses_one_projection_query_with_no_content_load(client, signup, factory, database):
    from sqlalchemy import event

    a = signup()
    add_records(factory, a["user"]["id"], 30)
    statements = []

    def capture(connection, cursor, statement, parameters, context, many):
        statements.append(statement)

    engine = client.app.state.engine
    event.listen(engine, "before_cursor_execute", capture)
    try:
        r = client.get(PATH, headers=headers(a), params={"limit": 20})
        assert r.status_code == 200 and len(r.json()["items"]) == 20
        assert len(statements) == 2  # identity + one history projection
        projection = statements[-1]
        assert "configuration ->>" in projection and "rehearsal_target" not in projection
        assert "practice_completions" in projection and "EXISTS" in projection
    finally:
        event.remove(engine, "before_cursor_execute", capture)
