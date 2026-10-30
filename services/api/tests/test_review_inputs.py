from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from test_connection_reservations import TestAdmission, control, reserve
from test_connection_reservations import prepared as prepared
from test_final_transcripts import event
from test_final_transcripts import post as post_transcripts
from test_playback_evidence import event as playback_event
from test_playback_evidence import freeze, revoke
from test_playback_evidence import post as post_playback
from test_practice_completion import begin, manifest, submit, summary


def review_path(prepared):
    return f"/v1/practice-sessions/{prepared.session['id']}/review-input"


def create(client, prepared, completion=None, **changes):
    return client.post(
        review_path(prepared),
        headers=prepared.headers,
        json={
            "input_revision": 1,
            "input_hash": (completion or {}).get("input_hash", "a" * 64),
            **changes,
        },
    )


def seal(client, prepared, transcripts=(), playback=(), **changes):
    saved = reserve(client, prepared).json()
    upload(client, prepared, saved, transcripts, playback)
    assert begin(client, prepared, saved).status_code == 200
    result = submit(client, prepared, saved, manifest(saved, transcripts, playback, **changes))
    assert result.status_code == 200, result.text
    assert result.json()["status"] == "sealed"
    return saved, result.json()


def upload(client, prepared, saved, transcripts=(), playback=()):
    for events, post in ((playback, post_playback), (transcripts, post_transcripts)):
        for offset in range(0, len(events), 4):
            result = post(client, prepared, saved, events[offset : offset + 4])
            assert result.status_code == 200, result.text


def decisions(result):
    assert result.status_code == 200, result.text
    return result.json()["scopes"][0]["decisions"]


def test_review_input_requires_a_sealed_completion(client, prepared):
    result = create(client, prepared)
    assert result.status_code == 409, result.text
    assert result.json()["code"] == "completion_not_sealed"
    assert begin(client, prepared, reserve(client, prepared).json()).status_code == 200
    assert create(client, prepared).json()["code"] == "completion_not_sealed"


def test_create_replay_read_are_durable_and_body_free_snapshot(client, prepared, factory):
    first = event(7, turn_index=9)
    saved, completion = seal(client, prepared, [first], tail_status="unconfirmed")
    before = summary(client, prepared).json()
    assert (
        client.get(review_path(prepared), headers=prepared.headers).json()["code"]
        == "review_input_not_found"
    )
    result = create(client, prepared, completion)
    entries = decisions(result)
    data = result.json()
    assert data["source"] == "server_derived" and data["evidence_source"] == "client_reported"
    assert data["policy_version"] == "review_input_v1"
    assert data["practice_input_hash"] == completion["input_hash"]
    assert data["account_id"] == prepared.identity["user"]["id"]
    assert data["session_id"] == prepared.session["id"]
    assert data["input_revision"] == 1 and len(data["review_input_hash"]) == 64
    assert data["counts"] == {"eligible": 1, "uncertain": 0, "excluded": 0}
    assert data["status"] == "ready" and data["created_at"]
    assert entries[0]["eligibility"] == "eligible"
    assert entries[0]["reason_codes"] == ["user_final_text"]
    assert entries[0]["text"] == first["text"]
    assert entries[0]["confidence"] is None and entries[0]["quality_source"] == "unavailable"
    assert entries[0]["allowed_bases"] == ["text_only", "conversation_context"]
    assert entries[0]["context_before"] == []
    assert result.headers["Cache-Control"] == "no-store"
    assert create(client, prepared, completion).json() == data
    assert client.get(review_path(prepared), headers=prepared.headers).json() == data
    assert summary(client, prepared).json() == before
    with factory() as db:
        row = db.execute(text("SELECT * FROM review_inputs")).mappings().one()
        assert row["review_input_hash"] == data["review_input_hash"]
        assert first["text"] not in str(row["snapshot"])
        assert str(saved["id"]) in str(row["snapshot"])


def test_versions_empty_cover_ai_and_missing_final_decisions(client, prepared):
    original = event()
    empty = {**original, "event_id": str(uuid4()), "sequence": 2, "revision": 2, "text": " \t"}
    assistant = event(3, role="assistant", response_id=str(uuid4()))
    final = event(6)
    missing = str(uuid4())
    _, completion = seal(
        client,
        prepared,
        [original, empty, assistant, final],
        unfinalized_turn_ids=[final["turn_id"], missing],
    )
    data = create(client, prepared, completion)
    entries = decisions(data)
    assert data.json()["counts"] == {"eligible": 0, "uncertain": 1, "excluded": 4}
    assert [e["reason_codes"][0] for e in entries] == [
        "superseded_revision",
        "empty_text",
        "assistant_text",
        "unfinalized_turn",
        "missing_final_text",
    ]
    absent = entries[-1]
    assert absent["role"] == "unknown" and absent["revision"] is None
    assert absent["transcript_event_id"] is None and "text" not in absent
    assert all("text" not in e for e in entries if e["eligibility"] == "excluded")
    assert entries[-2]["allowed_bases"] == ["text_only"]


def test_old_freeze_is_exact_context_and_future_turn_never_leaks(client, prepared):
    played = playback_event(turn_index=2)
    frozen = freeze(played)
    assistant = event(
        2,
        turn_id=played["turn_id"],
        turn_index=2,
        role="assistant",
        response_id=played["response_id"],
        revision=2,
        text="New final suffix.",
    )
    earlier, later = event(1), event(3)
    _, completion = seal(client, prepared, [earlier, assistant, later], [played, frozen])
    entries = decisions(create(client, prepared, completion))
    assert entries[0]["context_before"] == []
    context = entries[2]["context_before"]
    assert [c["text"] for c in context] == [earlier["text"], played["played_text"]]
    assert context[1]["event_id"] == frozen["event_id"] and context[1]["revision"] == 1
    assert context[1]["role"] == "assistant"
    assert "New final" not in str(context)
    assert entries[2]["allowed_bases"] == ["text_only", "conversation_context"]


@pytest.mark.parametrize("mode", ["unknown", "revoked", "not_played", "unconfirmed"])
def test_playback_context_gap_is_local_to_later_turns(client, prepared, mode):
    played = playback_event(turn_index=2, transcript_final=True)
    if mode == "unknown":
        played.update(
            delivery_status="unknown",
            played_text="",
            played_until_ms=None,
            evidence_source="unknown",
        )
    if mode == "not_played":
        played.update(delivery_status="not_played", played_text="", played_until_ms=0)
    playback = [played] + ([revoke(2, played["response_id"])] if mode == "revoked" else [])
    assistant = event(
        2,
        role="assistant",
        response_id=played["response_id"],
        turn_id=played["turn_id"],
        turn_index=2,
        text=played["generated_text"],
    )
    before, after = event(1), event(3)
    _, completion = seal(
        client,
        prepared,
        [before, assistant, after],
        playback,
        unconfirmed_response_ids=[played["response_id"]] if mode == "unconfirmed" else [],
    )
    entries = decisions(create(client, prepared, completion))
    assert entries[0]["eligibility"] == "eligible"
    last = entries[-1]
    if mode == "not_played":
        assert last["eligibility"] == "eligible"
        assert [c["role"] for c in last["context_before"]] == ["user"]
    else:
        assert last["eligibility"] == "uncertain" and "context_incomplete" in last["reason_codes"]
        assert last["allowed_bases"] == ["text_only"]


@pytest.mark.parametrize("kind", ["empty", "unfinalized"])
def test_unusable_user_history_limits_following_context(client, prepared, kind):
    before, middle, after = (
        event(1),
        event(2, text="" if kind == "empty" else "Original."),
        event(3),
    )
    _, completion = seal(
        client,
        prepared,
        [before, middle, after],
        unfinalized_turn_ids=[middle["turn_id"]] if kind == "unfinalized" else [],
    )
    entries = decisions(create(client, prepared, completion))
    assert entries[0]["eligibility"] == "eligible"
    assert entries[-1]["allowed_bases"] == ["text_only"]
    assert entries[-1]["eligibility"] == "uncertain"


@pytest.mark.parametrize(
    "changes",
    [
        {"transcript_rejected_count": 1},
        {"playback_rejected_count": 1},
        {"journal_unavailable": True},
    ],
)
def test_unlocated_gaps_limit_scope_context_without_excluding_text(client, prepared, changes):
    _, completion = seal(client, prepared, [event(7, turn_index=9)], **changes)
    entry = decisions(create(client, prepared, completion))[0]
    assert entry["eligibility"] == "uncertain" and entry["text"]
    assert entry["reason_codes"] == ["user_final_text", "context_incomplete"]
    assert entry["allowed_bases"] == ["text_only"]


def test_empty_content_is_stable_business_result(client, prepared):
    _, completion = seal(client, prepared)
    response = create(client, prepared, completion)
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "no_evaluable_content"
    assert response.json()["counts"] == {"eligible": 0, "uncertain": 0, "excluded": 0}


def test_epoch_context_does_not_carry_and_delete_cascades(client, prepared, factory):
    old = reserve(client, prepared).json()
    first, second = event(), event()
    upload(client, prepared, old, [first])
    assert control(client, prepared, old, "cancel-preparation").status_code == 200
    current = reserve(client, prepared, expected_epoch=1).json()
    upload(client, prepared, current, [second])
    assert begin(client, prepared, current).status_code == 200
    assert submit(client, prepared, old, manifest(old, [first])).status_code == 200
    completion = submit(client, prepared, current, manifest(current, [second])).json()
    response = create(client, prepared, completion)
    assert response.status_code == 200, response.text
    assert len(response.json()["scopes"]) == 2
    assert all(s["decisions"][0]["context_before"] == [] for s in response.json()["scopes"])
    with factory.begin() as db:
        db.execute(
            text("DELETE FROM practice_sessions WHERE id=:id"), {"id": prepared.session["id"]}
        )
        assert db.scalar(text("SELECT count(*) FROM review_inputs")) == 0
    assert client.get(review_path(prepared), headers=prepared.headers).status_code == 404


def test_changed_hash_version_and_client_policy_are_rejected(client, prepared):
    _, completion = seal(client, prepared, [event()])
    for changes in ({"input_hash": "b" * 64}, {"input_revision": 2}):
        result = create(client, prepared, completion, **changes)
        assert result.status_code == 409 and result.json()["code"] == "review_input_changed"
    for changes in (
        {"policy_version": "review_input_v1"},
        {"text": "forged"},
        {"input_revision": True},
    ):
        assert create(client, prepared, completion, **changes).status_code == 422


def test_concurrent_creation_has_one_immutable_record(client, prepared, factory):
    _, completion = seal(client, prepared, [event()])
    with ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(lambda _: create(client, prepared, completion), range(2)))
    assert all(r.status_code == 200 for r in replies)
    assert replies[0].json() == replies[1].json()
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_inputs")) == 1


@pytest.mark.parametrize(
    "table,mutation",
    [
        ("final_transcripts", "text='tampered'"),
        ("final_transcripts", "event_digest=repeat('b',64)"),
        ("completion_connections", "snapshot=jsonb_set(snapshot,'{turns,0,revision}','99')"),
        ("practice_completions", "input_hash=repeat('b',64)"),
        ("review_inputs", "snapshot=jsonb_set(snapshot,'{status}','\"no_evaluable_content\"')"),
        ("review_inputs", "review_input_hash=repeat('b',64)"),
    ],
)
def test_read_fails_closed_on_tampered_source_seal_or_projection(
    client, prepared, factory, table, mutation
):
    _, completion = seal(client, prepared, [event()])
    assert create(client, prepared, completion).status_code == 200
    with factory.begin() as db:
        db.execute(text(f"UPDATE {table} SET {mutation}"))
    response = client.get(review_path(prepared), headers=prepared.headers)
    assert response.status_code == 409 and response.json()["code"] == "review_input_changed"


@pytest.mark.parametrize(
    "budget", ["MAX_MEMBERS", "MAX_SOURCE_EVENTS", "MAX_SOURCE_BYTES", "MAX_EXPANDED_BYTES"]
)
def test_limits_fail_atomically_without_affecting_completion(
    client, prepared, factory, monkeypatch, budget
):
    from simontalk_api import review_inputs

    _, completion = seal(client, prepared, [event()])
    monkeypatch.setattr(review_inputs, budget, 0)
    result = create(client, prepared, completion)
    assert result.status_code == 409 and result.json()["code"] == "review_input_limit_exceeded"
    assert summary(client, prepared).json() == completion
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_inputs")) == 0


def test_ownership_account_header_and_authentication(client, prepared, signup):
    _, completion = seal(client, prepared, [event()])
    other = signup("bob")
    foreign = SimpleNamespace(
        session=prepared.session, headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert create(client, foreign, completion).json()["code"] == "practice_not_found"
    assert (
        client.get(review_path(prepared), headers=foreign.headers).json()["code"]
        == "practice_not_found"
    )
    assert client.get(review_path(prepared)).status_code == 401
    prepared.headers["X-Account-ID"] = other["user"]["id"]
    assert create(client, prepared, completion).status_code == 409


def test_web_writes_require_origin_csrf_account(client, app, signup):
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
        headers={**headers, "Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    ).json()
    scope = SimpleNamespace(session=created, headers=headers)
    _, completion = seal(client, scope, [event()])
    for missing, expected in (("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)):
        scope.headers = {k: v for k, v in headers.items() if k != missing}
        assert create(client, scope, completion).status_code == expected
    scope.headers = headers
    assert create(client, scope, completion).status_code == 200


def suggestion(saved, original, **changes):
    return {
        "source_connection_id": saved["id"],
        "source_turn_id": original["turn_id"],
        "revision": original["revision"],
        "exact_quote": original["text"],
        "kind": "polish",
        "basis": "text_only",
        "explanation": "可选表达",
        "suggestion": "Alternative.",
        **changes,
    }


def validate(factory, prepared, data, suggestions, **changes):
    from simontalk_api.review_inputs import validate_review_suggestions

    with factory() as db:
        return validate_review_suggestions(
            db,
            UUID(prepared.identity["user"]["id"]),
            UUID(prepared.session["id"]),
            input_revision=data["input_revision"],
            practice_input_hash=data["practice_input_hash"],
            review_input_hash=data["review_input_hash"],
            policy_version=data["policy_version"],
            suggestions=suggestions,
            **changes,
        )


def test_quote_gate_accepts_exact_unicode_and_zero_to_three_items(client, prepared, factory):
    original = event(text="I like cafe\u0301. 我😀 speak.")
    saved, completion = seal(client, prepared, [original])
    data = create(client, prepared, completion).json()
    exact = suggestion(saved, original, exact_quote="cafe\u0301. 我😀")
    assert validate(factory, prepared, data, []) == []
    assert len(validate(factory, prepared, data, [exact] * 3)) == 3


@pytest.mark.parametrize(
    "changes",
    [
        {"exact_quote": "café"},
        {"exact_quote": ""},
        {"exact_quote": "I like speak."},
        {"revision": 0},
        {"revision": 2},
        {"revision": True},
        {"source_connection_id": str(uuid4())},
        {"source_turn_id": str(uuid4())},
        {"kind": "pronunciation"},
        {"basis": "audio"},
        {"explanation": ""},
        {"suggestion": ""},
        {"extra": "forged"},
    ],
)
def test_quote_gate_rejects_entire_list_on_invalid_item(client, prepared, factory, changes):
    from simontalk_api.errors import APIError

    original = event(text="I like cafe\u0301. 我😀 speak.")
    saved, completion = seal(client, prepared, [original])
    data = create(client, prepared, completion).json()
    good = suggestion(saved, original)
    with pytest.raises(APIError) as error:
        validate(factory, prepared, data, [good, {**good, **changes}])
    assert error.value.code == "review_suggestions_invalid"


def test_quote_gate_rejects_old_ai_empty_context_and_binding(client, prepared, factory):
    from simontalk_api.errors import APIError

    old = event()
    latest = {**old, "event_id": str(uuid4()), "sequence": 2, "revision": 2, "text": "Latest."}
    ai = event(3, role="assistant", response_id=str(uuid4()))
    empty = event(4, text="")
    target = event(5)
    saved, completion = seal(client, prepared, [old, latest, ai, empty, target])
    data = create(client, prepared, completion).json()
    for invalid in (
        [suggestion(saved, old)],
        [suggestion(saved, ai)],
        [suggestion(saved, empty)],
        [suggestion(saved, target, basis="conversation_context")],
        [suggestion(saved, latest)] * 4,
    ):
        with pytest.raises(APIError):
            validate(factory, prepared, data, invalid)
    for field in ("practice_input_hash", "review_input_hash", "policy_version", "input_revision"):
        changed = deepcopy(data)
        changed[field] = 2 if field == "input_revision" else "b" * 64
        with pytest.raises(APIError):
            validate(factory, prepared, changed, [])


def test_missing_final_manifest_turn_keeps_unknown_role_even_with_playback(client, prepared):
    played = playback_event()
    _, completion = seal(client, prepared, [], [played], unfinalized_turn_ids=[played["turn_id"]])
    entries = decisions(create(client, prepared, completion))
    assert len(entries) == 1
    assert entries[0]["role"] == "unknown" and entries[0]["revision"] is None
    assert entries[0]["reason_codes"] == ["missing_final_text"]


@pytest.mark.parametrize("mode", ["missing_manifest", "missing_events"])
def test_expired_seal_with_unlocated_gap_still_allows_text_only(
    client, prepared, factory, monkeypatch, mode
):
    from datetime import datetime

    from simontalk_api import practice_completion
    from simontalk_api.practice_maintenance import run_maintenance_batch

    saved = reserve(client, prepared).json()
    first = event()
    upload(client, prepared, saved, [first])
    begun = begin(client, prepared, saved).json()
    if mode == "missing_events":
        assert submit(client, prepared, saved, manifest(saved, [event(2)])).status_code == 200
    monkeypatch.setattr(
        practice_completion, "now", lambda: datetime.fromisoformat(begun["final_upload_deadline"])
    )
    assert run_maintenance_batch(factory).completions_finalized == 1
    completion = summary(client, prepared).json()
    entry = decisions(create(client, prepared, completion))[0]
    assert entry["eligibility"] == "uncertain"
    assert entry["allowed_bases"] == ["text_only"] and entry["text"] == first["text"]


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_identity_is_rechecked_after_user_lock_wait(client, prepared, factory, monkeypatch, action):
    from threading import Event

    from test_practice_preparation import wait_for_row_lock

    from simontalk_api import practice_routes

    _, completion = seal(client, prepared, [event()])
    checked = Event()
    original = practice_routes.session_identity

    def observed(request, db):
        value = original(request, db)
        checked.set()
        return value

    monkeypatch.setattr(practice_routes, "session_identity", observed)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        owner = prepared.identity["user"]["id"]
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": owner})
        pending = pool.submit(create, client, prepared, completion)
        assert checked.wait(3)
        wait_for_row_lock(factory, "users")
        sql = (
            "UPDATE users SET disabled_at=now() WHERE id=:id"
            if action == "disable"
            else "UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"
        )
        holder.execute(text(sql), {"id": owner})
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_inputs")) == 0


@pytest.mark.parametrize("update_digest", [False, True])
def test_playback_payload_tampering_is_detected_by_read_and_internal_gate(
    client, prepared, factory, update_digest
):
    from simontalk_api.errors import APIError
    from simontalk_api.playback_evidence import PlaybackEvent
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    played = playback_event(transcript_final=True)
    assistant = event(
        1,
        role="assistant",
        turn_id=played["turn_id"],
        response_id=played["response_id"],
        text=played["generated_text"],
    )
    target = event(2)
    saved, completion = seal(client, prepared, [assistant, target], [played])
    data = create(client, prepared, completion).json()
    changed = {**played, "played_text": "Hell"}
    with factory.begin() as db:
        db.execute(text("UPDATE playback_evidence SET played_text='Hell'"))
        if update_digest:
            db.execute(
                text("UPDATE playback_evidence SET event_digest=:digest"),
                {
                    "digest": digest(
                        canonical(PlaybackEvent.model_validate(changed).model_dump(mode="json"))
                    )
                },
            )
    assert (
        client.get(review_path(prepared), headers=prepared.headers).json()["code"]
        == "review_input_changed"
    )
    with pytest.raises(APIError):
        validate(factory, prepared, data, [suggestion(saved, target)])


def test_source_text_and_digest_tamper_before_creation_cannot_be_resigned(
    client, prepared, factory
):
    from simontalk_api.final_transcripts import TranscriptEvent
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    first = event()
    _, completion = seal(client, prepared, [first])
    fingerprint = digest(
        canonical(
            TranscriptEvent.model_validate({**first, "text": "Changed."}).model_dump(mode="json")
        )
    )
    with factory.begin() as db:
        db.execute(
            text("UPDATE final_transcripts SET text='Changed.', event_digest=:digest"),
            {"digest": fingerprint},
        )
    assert create(client, prepared, completion).json()["code"] == "review_input_changed"


def test_get_and_internal_gate_issue_only_selects(client, prepared, app, factory):
    from sqlalchemy import event as sql_event

    target = event()
    saved, completion = seal(client, prepared, [target])
    data = create(client, prepared, completion).json()
    queries = []

    def record(conn, cursor, statement, parameters, context, executemany):
        queries.append(statement)

    sql_event.listen(app.state.engine, "after_cursor_execute", record)
    try:
        assert client.get(review_path(prepared), headers=prepared.headers).json() == data
    finally:
        sql_event.remove(app.state.engine, "after_cursor_execute", record)
    assert queries and all(q.lstrip().startswith("SELECT") for q in queries)
    sql_event.listen(factory.kw["bind"], "after_cursor_execute", record)
    try:
        validate(factory, prepared, data, [suggestion(saved, target)])
    finally:
        sql_event.remove(factory.kw["bind"], "after_cursor_execute", record)
    assert all(q.lstrip().startswith("SELECT") for q in queries)


def test_member_and_event_budgets_reject_before_source_text_query(
    client, prepared, app, monkeypatch
):
    from sqlalchemy import event as sql_event

    from simontalk_api import review_inputs

    _, completion = seal(client, prepared, [event()])
    monkeypatch.setattr(review_inputs, "MAX_SOURCE_EVENTS", 0)
    queries = []

    def record(conn, cursor, statement, parameters, context, executemany):
        queries.append(statement)

    sql_event.listen(app.state.engine, "after_cursor_execute", record)
    try:
        assert create(client, prepared, completion).json()["code"] == "review_input_limit_exceeded"
    finally:
        sql_event.remove(app.state.engine, "after_cursor_execute", record)
    assert not any("SELECT final_transcripts.connection_id" in q for q in queries)
    assert not any("SELECT playback_evidence.connection_id" in q for q in queries)


def test_source_budget_inclusive_boundaries():
    from simontalk_api.errors import APIError
    from simontalk_api.review_inputs import check_source_budget

    check_source_budget(32, 8192, 4 * 1024 * 1024)
    for values in (
        (33, 8192, 4 * 1024 * 1024),
        (32, 8193, 4 * 1024 * 1024),
        (32, 8192, 4 * 1024 * 1024 + 1),
    ):
        with pytest.raises(APIError):
            check_source_budget(*values)


def test_expanded_context_budget_is_checked_before_persisting(client, prepared, factory):
    transcripts = [event(index, text="x" * 8192) for index in range(1, 13)]
    _, completion = seal(client, prepared, transcripts)
    result = create(client, prepared, completion)
    assert result.status_code == 409 and result.json()["code"] == "review_input_limit_exceeded"
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_inputs")) == 0


@pytest.mark.parametrize(
    "mutation",
    [
        "input_revision=2",
        "policy_version='new_policy'",
        "practice_input_hash='invalid'",
        "review_input_hash='invalid'",
        "user_id=gen_random_uuid()",
    ],
)
def test_database_enforces_review_input_binding(client, prepared, factory, mutation):
    from sqlalchemy.exc import IntegrityError

    _, completion = seal(client, prepared, [event()])
    assert create(client, prepared, completion).status_code == 200
    with pytest.raises(IntegrityError), factory.begin() as db:
        db.execute(text(f"UPDATE review_inputs SET {mutation}"))


def test_unconfirmed_assistant_without_playback_only_limits_later_context(client, prepared):
    before = event(1)
    assistant = event(2, role="assistant", response_id=str(uuid4()))
    after = event(3)
    _, completion = seal(
        client,
        prepared,
        [before, assistant, after],
        unconfirmed_response_ids=[assistant["response_id"]],
    )
    entries = decisions(create(client, prepared, completion))
    assert entries[0]["eligibility"] == "eligible"
    assert entries[-1]["eligibility"] == "uncertain"
    assert entries[-1]["context_before"] == []


def test_unfinalized_target_does_not_receive_context_without_context_basis(client, prepared):
    before, after = event(1), event(2)
    _, completion = seal(client, prepared, [before, after], unfinalized_turn_ids=[after["turn_id"]])
    entry = decisions(create(client, prepared, completion))[-1]
    assert entry["allowed_bases"] == ["text_only"]
    assert entry["context_before"] == []


def test_review_post_body_limit_precedes_json_decode(client, prepared):
    response = client.post(review_path(prepared), headers=prepared.headers, content=b" " * 8193)
    assert response.status_code == 413 and response.json()["code"] == "request_too_large"


def test_review_post_chunked_body_and_timeout_are_bounded():
    import asyncio
    import json

    from simontalk_api.offer_body_limit import ConnectionBodyLimitMiddleware

    async def run(messages):
        output = []

        async def forbidden(scope, receive, send):
            raise AssertionError("Oversize request reached JSON handler")

        async def receive():
            return messages.pop(0)

        async def send(message):
            output.append(message)

        await ConnectionBodyLimitMiddleware(forbidden)(
            {
                "type": "http",
                "method": "POST",
                "path": f"/v1/practice-sessions/{uuid4()}/review-input",
                "headers": [],
            },
            receive,
            send,
        )
        return output

    output = asyncio.run(
        run(
            [
                {"type": "http.request", "body": b"x" * 8192, "more_body": True},
                {"type": "http.request", "body": b"x", "more_body": False},
            ]
        )
    )
    assert output[0]["status"] == 413
    assert json.loads(output[1]["body"])["code"] == "request_too_large"


@pytest.mark.parametrize("declare_unconfirmed", [True, False])
def test_unlocated_revoke_limits_scope_even_without_unconfirmed_manifest(
    client, prepared, declare_unconfirmed
):
    tombstone = revoke(1, str(uuid4()))
    _, completion = seal(
        client,
        prepared,
        [event()],
        [tombstone],
        unconfirmed_response_ids=[tombstone["response_id"]] if declare_unconfirmed else [],
    )
    target = decisions(create(client, prepared, completion))[0]
    assert target["eligibility"] == "uncertain"
    assert target["allowed_bases"] == ["text_only"] and target["context_before"] == []


def test_review_post_slow_receiving_has_a_fixed_timeout(monkeypatch):
    import asyncio

    from simontalk_api import offer_body_limit

    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.001)

    async def run():
        output = []

        async def forbidden(scope, receive, send):
            raise AssertionError("Unbounded body reached JSON handler")

        async def receive():
            await asyncio.sleep(0.1)
            return {"type": "http.request", "body": b"{}", "more_body": False}

        async def send(message):
            output.append(message)

        await offer_body_limit.ConnectionBodyLimitMiddleware(forbidden)(
            {
                "type": "http",
                "method": "POST",
                "path": f"/v1/practice-sessions/{uuid4()}/review-input",
                "headers": [],
            },
            receive,
            send,
        )
        return output

    assert asyncio.run(run())[0]["status"] == 408
