from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select, text
from test_rehearsal_targets import rows
from test_rehearsal_targets import target_source as target_source
from test_saved_transcripts import base
from test_saved_transcripts import scope as scope

from simontalk_api.models import PracticeSession, RealtimeConnection
from simontalk_api.practice import UnavailableAdmission


def release(factory, source):
    with factory.begin() as db:
        parent = db.get(PracticeSession, UUID(source.scope.session["id"]))
        parent.status = "completed"
        for connection in db.scalars(select(RealtimeConnection)):
            connection.status = "closed"
            connection.termination_status = "confirmed"


def create(client, source, target_hash, key=None, **body):
    return client.post(
        source.path.replace("/rehearsal-target", "/rehearsals"),
        headers=source.scope.headers | {"Idempotency-Key": str(key or uuid4())},
        json={"target_hash": target_hash, **body},
    )


def test_create_replay_and_multiple_independent_siblings(client, target_source, factory):
    source = target_source
    release(factory, source)
    target = client.get(source.path, headers=source.scope.headers).json()
    key = uuid4()
    result = create(client, source, target["target_hash"], key)
    assert result.status_code == 201, result.text
    first = result.json()
    assert first["schema_version"] == "rehearsal_preparation_v1"
    practice = first["practice"]
    assert practice["kind"] == "rehearsal"
    assert practice["source_session_id"] == source.scope.session["id"]
    assert practice["source_review_item_id"] == source.item["id"]
    assert first["target"] == target
    assert create(client, source, target["target_hash"], key).json() == first
    assert (
        client.get(
            f"/v1/practice-sessions/{practice['id']}/rehearsal-target", headers=source.scope.headers
        ).json()
        == target
    )
    assert create(client, source, target["target_hash"]).json()["code"] == "practice_in_progress"
    assert create(client, source, "b" * 64, key).json()["code"] == "idempotency_conflict"
    assert (
        client.post(
            f"/v1/practice-sessions/{practice['id']}/cancel-preparation",
            headers=source.scope.headers,
        ).status_code
        == 200
    )
    second = create(client, source, target["target_hash"]).json()["practice"]
    assert second["id"] != practice["id"]
    listing = client.get(
        base(source.scope) + "/rehearsals", params={"limit": 1}, headers=source.scope.headers
    ).json()
    assert listing["items"][0]["id"] == second["id"]
    assert listing["next_before_id"] == second["id"]
    last = client.get(
        base(source.scope) + "/rehearsals",
        params={"before_id": second["id"]},
        headers=source.scope.headers,
    ).json()
    assert last["items"][0]["id"] == practice["id"]
    assert last["items"][0]["status"] == "cancelled"
    assert last["next_before_id"] is None


def target(client, source):
    response = client.get(source.path, headers=source.scope.headers)
    assert response.status_code == 200, response.text
    return response.json()["target_hash"]


@pytest.mark.parametrize("failure", ["default", "unknown", "active", "preferences", "hash"])
def test_creation_failure_is_atomic(client, app, target_source, factory, failure):
    source = target_source
    confirmed = target(client, source)
    release(factory, source)
    if failure == "default":
        app.state.practice_admission = UnavailableAdmission()
        expected = "realtime_unavailable"
    elif failure == "unknown":
        with factory.begin() as db:
            db.execute(
                text(
                    "UPDATE realtime_connections SET status='unknown', "
                    "termination_status='unknown', ended_at=NULL"
                )
            )
        expected = "practice_in_progress"
    elif failure == "active":
        with factory.begin() as db:
            db.execute(text("UPDATE practice_sessions SET status='active'"))
        expected = "practice_in_progress"
    elif failure == "preferences":
        with factory.begin() as db:
            db.execute(text("UPDATE user_preferences SET difficulty=NULL"))
        expected = "preferences_required"
    else:
        confirmed = "b" * 64
        expected = "rehearsal_source_changed"
    before = rows(factory)
    response = create(client, source, confirmed)
    assert response.status_code == (503 if failure == "default" else 409)
    assert response.json()["code"] == expected
    assert rows(factory) == before


def test_override_snapshots_current_preferences_and_replay_does_not_admit(
    client, app, target_source, factory, monkeypatch
):
    from sqlalchemy.orm import Session

    source = target_source
    confirmed = target(client, source)
    release(factory, source)
    key = uuid4()
    first = create(client, source, confirmed, key, difficulty_override="advanced")
    assert first.status_code == 201, first.text
    practice = first.json()["practice"]
    assert practice["configuration"]["effective_difficulty"] == "advanced"
    assert practice["configuration"]["preferences"]["difficulty"] == "beginner"
    with factory.begin() as db:
        db.execute(text("UPDATE user_preferences SET difficulty='intermediate'"))
        db.execute(
            text(
                "UPDATE practice_sessions SET status='cancelled', ended_at=now() "
                "WHERE kind='rehearsal'"
            )
        )
    app.state.practice_admission = UnavailableAdmission()
    before = rows(factory)
    monkeypatch.setattr(Session, "commit", lambda _: pytest.fail("replay committed"))
    response = create(client, source, confirmed, key, difficulty_override="advanced")
    assert response.status_code == 201 and response.json()["practice"]["status"] == "cancelled"
    assert response.json()["practice"]["configuration"] == practice["configuration"]
    assert rows(factory) == before


@pytest.mark.parametrize("change", ["hash", "override", "item", "parent", "ordinary"])
def test_key_is_bound_to_operation_path_and_complete_body(client, target_source, factory, change):
    source = target_source
    confirmed = target(client, source)
    release(factory, source)
    key = uuid4()
    assert create(client, source, confirmed, key).status_code == 201
    if change == "ordinary":
        response = client.post(
            "/v1/practice-sessions",
            headers=source.scope.headers | {"Idempotency-Key": str(key)},
            json={"mode": "free_chat"},
        )
    else:
        path = source.path.replace("/rehearsal-target", "/rehearsals")
        body = {"target_hash": confirmed}
        if change == "hash":
            body["target_hash"] = "a" * 64
        elif change == "override":
            body["difficulty_override"] = "advanced"
        elif change == "item":
            path = path.replace(source.item["id"], str(uuid4()))
        else:
            path = path.replace(source.scope.session["id"], str(uuid4()))
        response = client.post(
            path, headers=source.scope.headers | {"Idempotency-Key": str(key)}, json=body
        )
    assert response.status_code == 409 and response.json()["code"] == "idempotency_conflict"


def test_ordinary_key_cannot_be_reused_for_rehearsal(client, target_source, factory):
    source = target_source
    with factory() as db:
        key = db.get(PracticeSession, UUID(source.scope.session["id"])).creation_key
    response = create(client, source, target(client, source), key)
    assert response.status_code == 409 and response.json()["code"] == "idempotency_conflict"


@pytest.mark.parametrize(
    "mutation",
    [
        "UPDATE review_results SET result_hash=repeat('b',64)",
        "DELETE FROM final_transcripts",
        "UPDATE practice_sessions SET rehearsal_target='{}' WHERE kind='rehearsal'",
        "UPDATE practice_sessions SET rehearsal_target_hash=repeat('b',64) WHERE kind='rehearsal'",
    ],
)
def test_child_and_replay_revalidate_all_frozen_and_current_sources(
    client, target_source, factory, mutation
):
    source = target_source
    confirmed = target(client, source)
    release(factory, source)
    key = uuid4()
    first = create(client, source, confirmed, key).json()["practice"]
    with factory.begin() as db:
        db.execute(text(mutation))
    for response in [
        client.get(
            f"/v1/practice-sessions/{first['id']}/rehearsal-target", headers=source.scope.headers
        ),
        create(client, source, confirmed, key),
    ]:
        assert response.status_code == 409 and response.json()["code"] == "rehearsal_source_changed"
        assert source.original["text"] not in response.text
    assert (
        client.get(f"/v1/practice-sessions/{first['id']}", headers=source.scope.headers).status_code
        == 200
    )
    # Listing remains valid when the source feedback has failed.
    assert (
        client.get(base(source.scope) + "/rehearsals", headers=source.scope.headers).status_code
        == 200
    )


def test_frozen_source_valid_hash_with_modified_snapshot_still_rejected(
    client, target_source, factory
):
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    with factory.begin() as db:
        row = db.get(PracticeSession, UUID(child["id"]))
        row.rehearsal_target = {**row.rehearsal_target, "suggestion": "Changed suggestion"}
        row.rehearsal_target_hash = digest(canonical(row.rehearsal_target))
    response = client.get(
        f"/v1/practice-sessions/{child['id']}/rehearsal-target", headers=source.scope.headers
    )
    assert response.status_code == 409


def test_gets_and_list_are_pure_and_summary_only(client, target_source, factory, monkeypatch):
    from sqlalchemy.orm import Session

    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    before = rows(factory)
    monkeypatch.setattr(Session, "commit", lambda _: pytest.fail("GET commit"))
    result = client.get(base(source.scope) + "/rehearsals", headers=source.scope.headers)
    assert result.status_code == 200, result.text
    listing = result.json()
    assert set(listing) == set(
        "schema_version source account_id source_session_id limit items next_before_id".split()
    )
    assert set(listing["items"][0]) == set(
        "id kind source_session_id source_review_item_id status created_at ended_at".split()
    )
    assert source.original["text"] not in result.text
    assert (
        client.get(
            f"/v1/practice-sessions/{child['id']}/rehearsal-target", headers=source.scope.headers
        ).status_code
        == 200
    )
    assert rows(factory) == before


@pytest.mark.parametrize(
    "params",
    [
        {"limit": "0"},
        {"limit": "21"},
        {"limit": "01"},
        {"limit": "1.0"},
        {"limit": "true"},
        {"before_id": "bad"},
    ],
)
def test_list_strict_queries(client, target_source, params):
    response = client.get(
        base(target_source.scope) + "/rehearsals",
        headers=target_source.scope.headers,
        params=params,
    )
    assert response.status_code == 422


def test_cursors_and_targets_are_owner_and_parent_scoped(client, target_source, factory, signup):
    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    bob = signup("bob")
    headers = {"Authorization": f"Bearer {bob['access_token']}"}
    child_path = f"/v1/practice-sessions/{child['id']}/rehearsal-target"
    for path in (child_path, base(source.scope) + "/rehearsals"):
        assert client.get(path).status_code == 401
        assert client.get(path, headers=headers).status_code == 404
        assert (
            client.get(
                path, headers=source.scope.headers | {"X-Account-ID": bob["user"]["id"]}
            ).status_code
            == 409
        )
    for cursor in (source.scope.session["id"], str(uuid4())):
        assert (
            client.get(
                base(source.scope) + "/rehearsals",
                headers=source.scope.headers,
                params={"before_id": cursor},
            ).status_code
            == 404
        )
    assert (
        client.get(
            f"/v1/practice-sessions/{child['id']}/rehearsals", headers=source.scope.headers
        ).json()["code"]
        == "rehearsal_source_changed"
    )
    assert (
        client.get(
            child_path.replace(
                "/rehearsal-target", f"/review-items/{source.item['id']}/rehearsal-target"
            ),
            headers=source.scope.headers,
        ).status_code
        == 409
    )


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"target_hash": "A" * 64},
        {"target_hash": "a" * 64, "kind": "rehearsal"},
        {"target_hash": "a" * 64, "source_text": "untrusted"},
        {"target_hash": "a" * 64, "difficulty_override": "bad"},
    ],
)
def test_create_strict_body(client, target_source, body):
    response = client.post(
        target_source.path.replace("/rehearsal-target", "/rehearsals"),
        headers=target_source.scope.headers | {"Idempotency-Key": str(uuid4())},
        json=body,
    )
    assert response.status_code == 422


def test_ordinary_create_rejects_source_fields(client, target_source):
    for field, value in (
        ("kind", "rehearsal"),
        ("source_session_id", str(uuid4())),
        ("target", {}),
    ):
        response = client.post(
            "/v1/practice-sessions",
            headers=target_source.scope.headers | {"Idempotency-Key": str(uuid4())},
            json={"mode": "free_chat", field: value},
        )
        assert response.status_code == 422


def wait_for_lock(factory):
    import time

    for _ in range(100):
        with factory() as db:
            count = db.scalar(
                text(
                    "SELECT count(*) FROM pg_stat_activity "
                    "WHERE datname=current_database() AND wait_event_type='Lock'"
                )
            )
        if count:
            return
        time.sleep(0.01)
    pytest.fail("request did not reach row lock")


@pytest.mark.parametrize("action", ["revoke", "disable", "delete_parent"])
def test_owner_lock_revalidates_authentication_and_parent(client, target_source, factory, action):
    from concurrent.futures import ThreadPoolExecutor

    source = target_source
    release(factory, source)
    confirmed = target(client, source)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        holder.execute(text("SELECT id FROM users FOR UPDATE"))
        pending = pool.submit(create, client, source, confirmed)
        wait_for_lock(factory)
        if action == "disable":
            holder.execute(text("UPDATE users SET disabled_at=now()"))
        elif action == "revoke":
            holder.execute(text("UPDATE auth_sessions SET revoked_at=now()"))
        else:
            holder.execute(text("DELETE FROM practice_sessions"))
        holder.commit()
        result = pending.result(timeout=5)
    assert result.status_code == (404 if action == "delete_parent" else 401)
    with factory() as db:
        assert (
            db.scalar(
                select(func.count())
                .select_from(PracticeSession)
                .where(PracticeSession.kind == "rehearsal")
            )
            == 0
        )


def test_creation_holds_user_then_parent_until_atomic_commit(client, app, target_source, factory):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    source = target_source
    release(factory, source)
    confirmed = target(client, source)
    entered, proceed = Event(), Event()
    delegate = app.state.practice_admission

    class BlockingAdmission:
        def admit(self, user_id):
            entered.set()
            assert proceed.wait(5)
            return delegate.admit(user_id)

    app.state.practice_admission = BlockingAdmission()

    def delete_parent():
        with factory.begin() as db:
            db.execute(text("SELECT id FROM users FOR UPDATE"))
            db.execute(
                text("DELETE FROM practice_sessions WHERE id=:id"),
                {"id": source.scope.session["id"]},
            )

    with ThreadPoolExecutor(max_workers=2) as pool:
        creation = pool.submit(create, client, source, confirmed)
        assert entered.wait(3)
        deletion = pool.submit(delete_parent)
        wait_for_lock(factory)
        with factory() as db:
            assert db.scalar(select(func.count()).select_from(PracticeSession)) == 1
        proceed.set()
        assert creation.result(timeout=5).status_code == 201
        deletion.result(timeout=5)
    with factory() as db:
        assert db.scalar(select(func.count()).select_from(PracticeSession)) == 0


@pytest.mark.parametrize(
    "fault",
    [
        "cross_owner",
        "rehearsal_parent",
        "self",
        "ordinary_source_fields",
        "missing",
        "hash",
        "array",
    ],
)
def test_database_enforces_parent_owner_level_and_target_shape(
    client, target_source, factory, signup, fault
):
    from sqlalchemy.exc import IntegrityError

    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    bob = signup("bob")
    with pytest.raises(IntegrityError), factory.begin() as db:
        row = db.get(PracticeSession, UUID(child["id"]))
        if fault == "cross_owner":
            row.user_id = UUID(bob["user"]["id"])
        elif fault == "rehearsal_parent":
            sibling = PracticeSession(
                user_id=row.user_id,
                creation_key=uuid4(),
                request_digest="a" * 64,
                mode="free_chat",
                kind="rehearsal",
                status="cancelled",
                configuration={},
                source_session_id=row.id,
                source_kind="ordinary",
                source_review_item_id=uuid4(),
                rehearsal_target={},
                rehearsal_target_hash="a" * 64,
            )
            db.add(sibling)
        elif fault == "self":
            row.source_session_id = row.id
        elif fault == "ordinary_source_fields":
            row.kind = "ordinary"
        elif fault == "missing":
            row.rehearsal_target = None
        elif fault == "array":
            row.rehearsal_target = []
        else:
            row.rehearsal_target_hash = "A" * 64
        db.flush()


def test_parent_cascades_real_child_records_and_child_deletion_is_independent(
    client, target_source, factory
):
    source = target_source
    release(factory, source)
    confirmed = target(client, source)
    first = create(client, source, confirmed).json()["practice"]
    client.post(
        f"/v1/practice-sessions/{first['id']}/cancel-preparation", headers=source.scope.headers
    )
    second = create(client, source, confirmed).json()["practice"]
    with factory.begin() as db:
        db.delete(db.get(PracticeSession, UUID(first["id"])))
    assert client.get(base(source.scope), headers=source.scope.headers).status_code == 200
    assert (
        client.get(
            f"/v1/practice-sessions/{second['id']}/rehearsal-target", headers=source.scope.headers
        ).status_code
        == 200
    )
    with factory.begin() as db:
        db.delete(db.get(PracticeSession, UUID(source.scope.session["id"])))
    assert (
        client.get(
            f"/v1/practice-sessions/{second['id']}/rehearsal-target", headers=source.scope.headers
        ).status_code
        == 404
    )
    with factory() as db:
        assert db.scalar(select(func.count()).select_from(PracticeSession)) == 0


def test_source_and_target_never_enter_transcript_ledger(client, target_source, factory):
    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    with factory() as db:
        assert (
            db.scalar(
                text(
                    "SELECT count(*) FROM final_transcripts t JOIN realtime_connections c "
                    "ON c.id=t.connection_id WHERE c.session_id=:id"
                ),
                {"id": child["id"]},
            )
            == 0
        )
        assert (
            db.scalar(
                text(
                    "SELECT count(*) FROM playback_evidence t JOIN realtime_connections c "
                    "ON c.id=t.connection_id WHERE c.session_id=:id"
                ),
                {"id": child["id"]},
            )
            == 0
        )


def test_create_requires_key_and_identity(client, target_source):
    source = target_source
    path = source.path.replace("/rehearsal-target", "/rehearsals")
    assert (
        client.post(path, headers=source.scope.headers, json={"target_hash": "a" * 64}).status_code
        == 422
    )
    assert (
        client.post(
            path, headers={"Idempotency-Key": str(uuid4())}, json={"target_hash": "a" * 64}
        ).status_code
        == 401
    )


def test_new_post_has_eight_kib_and_five_second_receiving_gate(monkeypatch):
    from test_offer_body_limit import invoke

    from simontalk_api import offer_body_limit

    path = "/v1/practice-sessions/p/review-items/i/rehearsals"
    assert offer_body_limit.BODY_TIMEOUT_SECONDS == 5
    status, _, consumed = invoke([{"type": "http.request", "body": b"a" * 8192}], path=path)
    assert status == 200 and len(consumed[0]) == 8192
    status, body, consumed = invoke([{"type": "http.request", "body": b"a" * 8193}], path=path)
    assert status == 413 and body["code"] == "request_too_large" and consumed == []
    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.01)
    status, body, consumed = invoke([{"type": "http.request", "body": b"a"}], path=path, delay=0.1)
    assert status == 408 and body["code"] == "request_timeout" and consumed == []


def test_http_oversize_rehearsal_post_rejected_before_json(client, target_source):
    response = client.post(
        target_source.path.replace("/rehearsal-target", "/rehearsals"), content=b"a" * 8193
    )
    assert response.status_code == 413


def test_malformed_frozen_shape_is_rejected_before_reading_parent(
    client, target_source, factory, monkeypatch
):
    from simontalk_api import rehearsal_targets
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    with factory.begin() as db:
        row = db.get(PracticeSession, UUID(child["id"]))
        row.rehearsal_target = {}
        row.rehearsal_target_hash = digest(canonical({}))
    monkeypatch.setattr(
        rehearsal_targets,
        "read_source_target",
        lambda *_: pytest.fail("invalid shape reached parent"),
    )
    response = client.get(
        f"/v1/practice-sessions/{child['id']}/rehearsal-target", headers=source.scope.headers
    )
    assert response.status_code == 409


def test_source_invalidity_preserves_child_own_sealed_text(client, target_source, factory):
    from types import SimpleNamespace

    from test_saved_transcripts import event, read, seal

    source = target_source
    release(factory, source)
    child = create(client, source, target(client, source)).json()["practice"]
    scope = SimpleNamespace(session=child, headers=source.scope.headers)
    _, completion = seal(client, scope, [event(text="Independent child words.")])
    with factory.begin() as db:
        db.execute(text("UPDATE review_results SET result_hash=repeat('b',64)"))
    assert (
        client.get(
            f"/v1/practice-sessions/{child['id']}/rehearsal-target", headers=scope.headers
        ).status_code
        == 409
    )
    assert client.get(base(scope), headers=scope.headers).status_code == 200
    result = read(client, scope, completion)
    assert (
        result.status_code == 200
        and result.json()["items"][0]["final_text"] == "Independent child words."
    )


def test_failed_record_is_preserved_and_equal_timestamp_seek_is_stable(
    client, target_source, factory
):
    source = target_source
    release(factory, source)
    confirmed = target(client, source)
    ids = []
    for _ in range(3):
        child = create(client, source, confirmed).json()["practice"]
        ids.append(child["id"])
        client.post(
            f"/v1/practice-sessions/{child['id']}/cancel-preparation", headers=source.scope.headers
        )
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE practice_sessions SET created_at='2026-10-01T00:00:00Z', "
                "status='failed', ended_at=now() WHERE kind='rehearsal'"
            )
        )
    visited, before_id = [], None
    for _ in range(3):
        params = {"limit": 1, **({"before_id": before_id} if before_id else {})}
        result = client.get(
            base(source.scope) + "/rehearsals", headers=source.scope.headers, params=params
        ).json()
        visited.append(result["items"][0]["id"])
        assert result["items"][0]["status"] == "failed"
        before_id = result["next_before_id"]
    assert visited == sorted(ids, reverse=True) and before_id is None


def test_web_create_preserves_origin_csrf_and_account_gates(client, app, signup, factory):
    from types import SimpleNamespace

    from test_saved_transcripts import Admission, event, seal, successful_review

    headers = {"Origin": "http://localhost:7357"}
    headers["X-CSRF-Token"] = client.get("/v1/auth/csrf", headers=headers).json()["csrf_token"]
    identity = signup(platform="web", headers=headers)
    headers["X-Account-ID"] = identity["user"]["id"]
    client.patch(
        "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
    )
    app.state.practice_admission = Admission()
    practice = client.post(
        "/v1/practice-sessions",
        headers=headers | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    ).json()
    scope = SimpleNamespace(session=practice, headers=headers, identity=identity)
    _, completion = seal(client, scope, [event()])
    job = successful_review(client, scope, completion, factory)
    source = SimpleNamespace(
        scope=scope,
        path=base(scope) + f"/review-items/{job['result']['items'][0]['id']}/rehearsal-target",
    )
    confirmed = target(client, source)
    release(factory, source)
    before = rows(factory)
    for missing, expected in [("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)]:
        scope.headers = {key: value for key, value in headers.items() if key != missing}
        assert create(client, source, confirmed).status_code == expected
    assert rows(factory) == before
    scope.headers = headers
    assert create(client, source, confirmed).status_code == 201


def test_parent_seek_has_matching_partial_database_and_metadata_index(factory):
    from sqlalchemy import inspect

    expected_columns = ["source_session_id", "user_id", "created_at", "id"]
    with factory() as db:
        indexes = {
            item["name"]: item for item in inspect(db.get_bind()).get_indexes("practice_sessions")
        }
    assert "rehearsal_parent_seek" in indexes, "same-parent seek lacks its bounded scan index"
    actual = indexes["rehearsal_parent_seek"]
    assert actual["column_names"] == expected_columns
    predicate = actual["dialect_options"]["postgresql_where"]
    assert "kind" in predicate and "'rehearsal'" in predicate
    assert "status" not in predicate
    declared = next(
        index
        for index in PracticeSession.__table__.indexes
        if index.name == "rehearsal_parent_seek"
    )
    assert [column.name for column in declared.columns] == expected_columns
    assert str(declared.dialect_options["postgresql"]["where"]) == "kind = 'rehearsal'"
