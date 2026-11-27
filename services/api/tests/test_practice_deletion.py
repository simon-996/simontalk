"""Deletion removes content, never unknown upstream occupancy or usage evidence."""

import asyncio
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select, text
from test_connection_reservations import prepared as prepared
from test_practice_history import add_records, headers
from test_practice_preparation import account as account
from test_practice_preparation import admission as admission
from test_rehearsal_preparations import create, release, target
from test_rehearsal_targets import rows
from test_rehearsal_targets import target_source as target_source
from test_review_worker import Gateway, batch, queued
from test_saved_transcripts import base, event, reserve, upload
from test_saved_transcripts import scope as scope

from simontalk_api.models import PracticeSession, RealtimeConnection

PATH = "/v1/practice-history"


def snapshot(client, sid, h):
    r = client.get(f"{PATH}/{sid}/deletion-scope", headers=h)
    assert r.status_code == 200, r.text
    return r.json()


def erase(client, sid, h, scope, key=None):
    return client.request(
        "DELETE",
        f"{PATH}/{sid}",
        headers=h | {"Idempotency-Key": str(key or uuid4())},
        json={"scope_version": scope["scope_version"]},
    )


@pytest.mark.parametrize("occupied", [False, True])
def test_deleting_topic_erases_the_snapshot_but_preserves_unknown_occupancy(
    client, factory, account, admission, occupied
):
    identity, h = account
    response = client.post(
        "/v1/practice-sessions",
        headers=h | {"Idempotency-Key": str(uuid4())},
        json={"mode": "daily_topic", "topic_id": "travel"},
    )
    assert response.status_code == 201
    practice = response.json()
    sid = practice["id"]
    if occupied:
        scope = SimpleNamespace(identity=identity, headers=h, session=practice)
        reserved = reserve(client, scope)
        with factory.begin() as db:
            connection = db.get(RealtimeConnection, UUID(reserved["id"]))
            connection.status = "ready"
            connection.termination_status = "unknown"
            connection.offer_digest = "a" * 64
            connection.signalling_started_at = connection.created_at
    deleted = erase(client, sid, h, snapshot(client, sid, h))
    assert deleted.status_code == 200
    assert deleted.json()["connection_pending"] is occupied
    assert client.get(f"{PATH}/{sid}", headers=h).status_code == 404
    with factory() as db:
        row = db.get(PracticeSession, UUID(sid))
        assert row.deleted_at is not None and "topic" not in row.configuration
    current = client.get("/v1/practice-sessions/current", headers=h).json()
    if occupied:
        assert current["connection"]["termination_status"] == "unknown"
        assert current["practice"]["state_reason"] == "content_deleted"
        assert "topic" not in current["practice"]["configuration"]
    else:
        assert current == {"practice": None, "connection": None}


def test_scope_is_owner_only_bounded_and_zero_write(client, signup, factory):
    a, b = signup(), signup("bob")
    sid = add_records(factory, a["user"]["id"], 1)[0]
    before = rows(factory)
    data = snapshot(client, sid, headers(a))
    assert set(data) == set(
        (
            "schema_version source account_id session_id kind record_count "
            "rehearsal_count scope_version connection_pending"
        ).split()
    )
    assert data["kind"] == "ordinary" and data["record_count"] == 1
    assert data["rehearsal_count"] == 0 and not data["connection_pending"]
    assert len(data["scope_version"]) == 64
    assert rows(factory) == before
    assert client.get(f"{PATH}/{sid}/deletion-scope").status_code == 401
    assert client.get(f"{PATH}/{sid}/deletion-scope", headers=headers(b)).status_code == 404
    assert erase(client, sid, headers(b), data).status_code == 404
    assert (
        erase(client, sid, headers(a) | {"X-Account-ID": b["user"]["id"]}, data).status_code == 409
    )


def test_parent_deletes_children_content_and_replays_original_receipt(
    client, target_source, factory
):
    s = target_source
    release(factory, s)
    children = []
    for _ in range(2):
        child = create(client, s, target(client, s)).json()["practice"]
        children.append(child)
        assert (
            client.post(
                f"/v1/practice-sessions/{child['id']}/cancel-preparation", headers=s.scope.headers
            ).status_code
            == 200
        )
    sid, h = s.scope.session["id"], s.scope.headers
    scope = snapshot(client, sid, h)
    assert scope["record_count"] == 3 and scope["rehearsal_count"] == 2
    key = uuid4()
    r = erase(client, sid, h, scope, key)
    assert r.status_code == 200, r.text
    receipt = r.json()
    assert receipt["schema_version"] == "practice_deletion_receipt_v1"
    assert receipt["record_count"] == 3 and receipt["request_key"] == str(key)
    assert erase(client, sid, h, scope, key).json() == receipt
    assert (
        client.get(f"{PATH}/{sid}/deletion", headers=h, params={"key": str(key)}).json() == receipt
    )
    assert erase(client, sid, h, {"scope_version": "b" * 64}, key).status_code == 409
    assert client.get(PATH, headers=h).json()["items"] == []
    for record in [s.scope.session, *children]:
        assert client.get(f"{PATH}/{record['id']}", headers=h).status_code == 404
        assert client.get(f"/v1/practice-sessions/{record['id']}", headers=h).status_code == 404
    for suffix in ["/completion", "/review-input", "/review", "/saved-transcript", "/rehearsals"]:
        params = (
            {"input_revision": 1, "input_hash": s.completion["input_hash"]}
            if suffix == "/saved-transcript"
            else {}
        )
        assert client.get(base(s.scope) + suffix, headers=h, params=params).status_code == 404
    assert client.get(s.path, headers=h).status_code == 404
    for suffix in ["/transcripts", "/playback-evidence"]:
        assert (
            client.get(
                base(s.scope) + f"/connections/{s.connection['id']}" + suffix, headers=h
            ).status_code
            == 404
        )
    with factory() as db:
        for table in [
            "final_transcripts",
            "playback_evidence",
            "practice_completions",
            "completion_connections",
            "review_inputs",
            "review_jobs",
            "review_results",
            "review_actions",
        ]:
            assert db.scalar(text(f"SELECT count(*) FROM {table}")) == 0, table
        tombstones = db.scalars(select(PracticeSession)).all()
        assert len(tombstones) == 3
        assert all(x.deleted_at is not None and x.configuration == {} for x in tombstones)
        assert all(x.rehearsal_target in (None, {}) for x in tombstones)
        assert db.scalar(text("SELECT count(*) FROM review_attempts WHERE job_id IS NULL")) == 1
        assert s.original["text"] not in str(rows(factory))


def test_single_child_preserves_parent_sibling_and_scope_changes_on_add_remove(
    client, target_source, factory
):
    s = target_source
    release(factory, s)
    sid, h = s.scope.session["id"], s.scope.headers
    old = snapshot(client, sid, h)
    first = create(client, s, target(client, s)).json()["practice"]
    assert (
        client.post(
            f"/v1/practice-sessions/{first['id']}/cancel-preparation", headers=h
        ).status_code
        == 200
    )
    second = create(client, s, target(client, s)).json()["practice"]
    assert (
        client.post(
            f"/v1/practice-sessions/{second['id']}/cancel-preparation", headers=h
        ).status_code
        == 200
    )
    assert erase(client, sid, h, old).json()["code"] == "deletion_scope_changed"
    full = snapshot(client, sid, h)
    one = snapshot(client, first["id"], h)
    assert one["record_count"] == 1 and one["rehearsal_count"] == 1
    assert erase(client, first["id"], h, one).status_code == 200
    assert erase(client, sid, h, full).status_code == 409
    assert client.get(s.path, headers=h).status_code == 200
    assert client.get(f"{PATH}/{second['id']}", headers=h).status_code == 200
    assert len(client.get(base(s.scope) + "/rehearsals", headers=h).json()["items"]) == 1


def test_unknown_retains_occupancy_and_blocks_all_late_writes(client, scope, factory):
    c = reserve(client, scope)
    original = event()
    upload(client, scope, c, [original])
    with factory.begin() as db:
        connection = db.get(RealtimeConnection, UUID(c["id"]))
        connection.status = "ready"
        connection.termination_status = "unknown"
        connection.offer_digest = "a" * 64
        connection.signalling_started_at = connection.created_at
    sid, h = scope.session["id"], scope.headers
    snap = snapshot(client, sid, h)
    assert snap["connection_pending"] is True
    r = erase(client, sid, h, snap)
    assert r.status_code == 200 and r.json()["connection_pending"] is True
    current = client.get("/v1/practice-sessions/current", headers=h).json()
    assert current["practice"]["state_reason"] == "content_deleted"
    assert current["connection"]["status"] == "unknown"
    blocked = client.post(
        "/v1/practice-sessions",
        headers=h | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    )
    assert blocked.status_code == 409 and blocked.json()["code"] == "practice_in_progress"
    path = base(scope) + f"/connections/{c['id']}"
    assert (
        client.post(
            path + "/transcripts",
            headers=h,
            json={
                "client_instance_id": c["client_instance_id"],
                "epoch": c["epoch"],
                "events": [event(2)],
            },
        ).status_code
        == 404
    )
    assert (
        client.post(
            path + "/renew-lease",
            headers=h,
            json={"client_instance_id": c["client_instance_id"], "epoch": c["epoch"]},
        ).status_code
        == 404
    )
    with factory() as db:
        assert (
            db.scalar(
                text(
                    "SELECT count(*) FROM termination_checks WHERE status='blocked' AND attempts=0"
                )
            )
            == 1
        )
        assert db.scalar(text("SELECT count(*) FROM final_transcripts")) == 0


def test_safe_unsignalled_preparation_can_close_without_occupancy(client, scope, factory):
    c = reserve(client, scope)
    sid, h = scope.session["id"], scope.headers
    r = erase(client, sid, h, snapshot(client, sid, h))
    assert r.status_code == 200 and r.json()["connection_pending"] is False
    assert client.get("/v1/practice-sessions/current", headers=h).json() == {
        "practice": None,
        "connection": None,
    }
    with factory() as db:
        connection = db.get(RealtimeConnection, UUID(c["id"]))
        assert connection.termination_status == "not_started" and connection.status == "closed"
    # Original preparation key cannot resurrect the removed configuration.
    with factory() as db:
        key = db.get(PracticeSession, UUID(sid)).creation_key
    assert (
        client.post(
            "/v1/practice-sessions",
            headers=h | {"Idempotency-Key": str(key)},
            json={"mode": "free_chat"},
        ).status_code
        == 404
    )


@pytest.mark.parametrize("running", [False, True])
def test_deleted_queued_or_running_review_never_restores_body(
    client, app, prepared, factory, running
):
    gateway = Gateway()
    queued(client, app, prepared, gateway)
    from simontalk_api.review_worker import claim_review_job, execute_review_job

    claim = claim_review_job(factory, gateway) if running else None
    sid, h = prepared.session["id"], prepared.headers
    assert erase(client, sid, h, snapshot(client, sid, h)).status_code == 200
    if claim:
        assert asyncio.run(execute_review_job(factory, gateway, claim)) is False
    else:
        assert batch(factory, gateway) == 0
    assert gateway.calls == []
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_jobs")) == 0
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0


def test_receipt_missing_and_other_owner_are_not_success(client, signup, factory):
    a, b = signup(), signup("bob")
    sid = add_records(factory, a["user"]["id"], 1)[0]
    h = headers(a)
    key = uuid4()
    snap = snapshot(client, sid, h)
    assert (
        client.get(f"{PATH}/{sid}/deletion", headers=h, params={"key": str(key)}).status_code == 404
    )
    assert erase(client, sid, h, snap, key).status_code == 200
    assert (
        client.get(
            f"{PATH}/{sid}/deletion", headers=headers(b), params={"key": str(key)}
        ).status_code
        == 404
    )
    assert erase(client, sid, h, snap).status_code == 404


@pytest.mark.parametrize(
    "body", [{}, {"scope_version": "x"}, {"scope_version": "a" * 64, "ids": []}]
)
def test_invalid_confirmation_rejected(client, scope, body):
    r = client.request(
        "DELETE",
        f"{PATH}/{scope.session['id']}",
        headers=scope.headers | {"Idempotency-Key": str(uuid4())},
        json=body,
    )
    assert r.status_code == 422


def test_gateway_already_dispatched_cannot_write_after_delete(client, app, prepared, factory):
    async def erase_during_generation(request):
        sid, h = prepared.session["id"], prepared.headers
        assert erase(client, sid, h, snapshot(client, sid, h)).status_code == 200

    gateway = Gateway(callback=erase_during_generation)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    assert len(gateway.calls) == 1
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0
        attempt = db.execute(
            text("SELECT job_id, outcome, input_tokens, output_tokens FROM review_attempts")
        ).one()
        assert attempt.job_id is None and attempt.outcome == "outcome_unknown"
        assert attempt.input_tokens is None and attempt.output_tokens is None


def test_owner_lock_serializes_scope_change_and_delete(client, target_source, factory, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    from simontalk_api import deletion_routes
    from simontalk_api.models import User

    s = target_source
    release(factory, s)
    sid, h = s.scope.session["id"], s.scope.headers
    scope = snapshot(client, sid, h)
    reached = Event()
    original = deletion_routes.locked_identity

    def waiting(request, db):
        reached.set()
        return original(request, db)

    monkeypatch.setattr(deletion_routes, "locked_identity", waiting)
    with ThreadPoolExecutor(1) as pool:
        with factory.begin() as db:
            db.scalar(
                select(User)
                .where(User.id == UUID(s.scope.identity["user"]["id"]))
                .with_for_update()
            )
            future = pool.submit(erase, client, sid, h, scope)
            assert reached.wait(2)
            assert not future.done()
            db.add(
                PracticeSession(
                    user_id=UUID(s.scope.identity["user"]["id"]),
                    creation_key=uuid4(),
                    request_digest="a" * 64,
                    mode="free_chat",
                    kind="rehearsal",
                    status="cancelled",
                    configuration={},
                    source_session_id=UUID(sid),
                    source_kind="ordinary",
                    source_review_item_id=UUID(s.item["id"]),
                    rehearsal_target={},
                    rehearsal_target_hash="a" * 64,
                )
            )
        result = future.result(timeout=3)
        assert result.status_code == 409 and result.json()["code"] == "deletion_scope_changed"
    assert client.get(f"{PATH}/{sid}", headers=h).status_code == 200


def test_browser_delete_requires_csrf_and_origin(client, signup, factory):
    csrf = client.get("/v1/auth/csrf").json()["csrf_token"]
    a = signup(platform="web", headers={"Origin": "http://localhost:7357", "X-CSRF-Token": csrf})
    sid = add_records(factory, a["user"]["id"], 1)[0]
    scope = snapshot(client, sid, {})
    key = uuid4()
    assert erase(client, sid, {"Origin": "http://localhost:7357"}, scope, key).status_code == 403
    csrf = client.get("/v1/auth/csrf", headers={"Origin": "http://localhost:7357"}).json()[
        "csrf_token"
    ]
    assert (
        erase(
            client, sid, {"Origin": "https://foreign.invalid", "X-CSRF-Token": csrf}, scope, key
        ).status_code
        == 403
    )
    headers = {
        "Origin": "http://localhost:7357",
        "X-CSRF-Token": csrf,
        "X-Account-ID": a["user"]["id"],
    }
    preflight = client.options(
        f"{PATH}/{sid}",
        headers={
            "Origin": headers["Origin"],
            "Access-Control-Request-Method": "DELETE",
            "Access-Control-Request-Headers": (
                "content-type,x-csrf-token,x-account-id,idempotency-key"
            ),
        },
    )
    assert preflight.status_code == 200
    response = erase(client, sid, headers, scope, key)
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == headers["Origin"]
    assert response.headers["access-control-allow-credentials"] == "true"
    assert erase(client, sid, headers, scope, key).json() == response.json()
    assert client.get(f"{PATH}/{sid}", headers=headers).status_code == 404


@pytest.mark.parametrize(
    ("field", "value", "status", "code"),
    [
        ("Origin", None, 403, "csrf_invalid"),
        ("Origin", "https://foreign.invalid", 403, "origin_forbidden"),
        ("X-CSRF-Token", None, 403, "csrf_invalid"),
        ("X-CSRF-Token", "wrong-token", 403, "csrf_invalid"),
        ("X-Account-ID", None, 409, "account_changed"),
        ("X-Account-ID", str(UUID(int=1)), 409, "account_changed"),
    ],
)
def test_web_delete_rejected_credentials_do_not_change_rows(
    client, signup, factory, field, value, status, code
):
    origin = {"Origin": "http://localhost:7357"}
    csrf = client.get("/v1/auth/csrf", headers=origin).json()["csrf_token"]
    account = signup(platform="web", headers=origin | {"X-CSRF-Token": csrf})
    sid = add_records(factory, account["user"]["id"], 1)[0]
    scope = snapshot(client, sid, origin)
    csrf = client.get("/v1/auth/csrf", headers=origin).json()["csrf_token"]
    headers = origin | {"X-CSRF-Token": csrf, "X-Account-ID": account["user"]["id"]}
    if value is None:
        headers.pop(field)
    else:
        headers[field] = value
    before = rows(factory)
    response = erase(client, sid, headers, scope)
    assert response.status_code == status
    assert response.json()["code"] == code
    assert response.json()["request_id"] == response.headers["x-request-id"]
    if headers.get("Origin") == origin["Origin"]:
        assert response.headers["access-control-allow-origin"] == origin["Origin"]
        assert response.headers["access-control-allow-credentials"] == "true"
    assert rows(factory) == before


def test_deletion_body_is_bounded_before_json_decode(client):
    response = client.request(
        "DELETE",
        f"{PATH}/{uuid4()}",
        content=b"x" * 8193,
        headers={"Content-Type": "application/json", "Idempotency-Key": str(uuid4())},
    )
    assert response.status_code == 413


def test_deletion_chunked_body_does_not_trust_content_length():
    from test_offer_body_limit import invoke

    status, result, consumed = invoke(
        [
            {"type": "http.request", "body": b"x" * 8192, "more_body": True},
            {"type": "http.request", "body": b"y", "more_body": False},
        ],
        method="DELETE",
        path=f"{PATH}/{uuid4()}",
        headers=[(b"content-length", b"1")],
    )
    assert status == 413 and result["code"] == "request_too_large" and consumed == []


def test_deletion_body_has_total_receipt_deadline(monkeypatch):
    from test_offer_body_limit import invoke

    from simontalk_api import offer_body_limit

    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.01)
    status, result, consumed = invoke(
        [{"type": "http.request", "body": b"x"}],
        method="DELETE",
        path=f"{PATH}/{uuid4()}",
        delay=0.1,
    )
    assert status == 408 and result["code"] == "request_timeout" and consumed == []
