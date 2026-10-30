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
from test_final_transcripts import event as transcript_event
from test_final_transcripts import post as post_transcripts
from test_practice_preparation import wait_for_row_lock

from simontalk_api.practice import UnavailableAdmission


def event(sequence=1, **changes):
    return {
        "event_id": str(uuid4()),
        "sequence": sequence,
        "kind": "alignment",
        "turn_id": str(uuid4()),
        "turn_index": sequence,
        "response_id": str(uuid4()),
        "transcript_revision": 1,
        "generated_text": "Hello, how are you?",
        "transcript_final": False,
        "playback_revision": 1,
        "delivery_status": "partial",
        "played_text": "Hello,",
        "played_until_ms": 250,
        "evidence_source": "device_output_aligned",
        **changes,
    }


def revoke(sequence, response_id):
    return {
        "event_id": str(uuid4()),
        "sequence": sequence,
        "kind": "revoke",
        "response_id": response_id,
    }


def freeze(original=None, sequence=2, **changes):
    return {
        **(original or event()),
        "event_id": str(uuid4()),
        "sequence": sequence,
        "kind": "freeze",
        "stop_boundary_ms": 300,
        "reason": "interrupted",
        **changes,
    }


def post(client, prepared, saved, events=None, **changes):
    return client.post(
        path(prepared, saved, "/playback-evidence"),
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
            db.execute(text("SELECT * FROM playback_evidence ORDER BY sequence")).mappings().all()
        )


def state(factory):
    with factory() as db:
        return (
            db.execute(text("SELECT * FROM practice_sessions ORDER BY id")).mappings().all(),
            db.execute(text("SELECT * FROM realtime_connections ORDER BY id")).mappings().all(),
        )


def test_append_replay_and_read_preserve_untrusted_nonfinal_prefix(client, app, prepared, factory):
    saved = reserve(client, prepared).json()
    before = state(factory)
    first = event()
    events = [first, freeze(first), revoke(4, first["response_id"])]
    app.state.practice_admission = UnavailableAdmission()
    response = post(client, prepared, saved, events)
    assert response.status_code == 200, response.text
    assert response.json() == {
        "source": "client_reported",
        "account_id": prepared.identity["user"]["id"],
        "session_id": prepared.session["id"],
        "connection_id": saved["id"],
        "client_instance_id": saved["client_instance_id"],
        "epoch": saved["epoch"],
        "last_sequence": 4,
        "total_events": 3,
        "total_text_bytes": 2 * len((first["generated_text"] + first["played_text"]).encode()),
        "acknowledged_event_ids": [e["event_id"] for e in events],
    }
    assert post(client, prepared, saved, events).json() == response.json()
    assert state(factory) == before
    page = client.get(path(prepared, saved, "/playback-evidence"), headers=prepared.headers)
    assert page.status_code == 200
    assert page.headers["Cache-Control"] == "no-store"
    assert page.json()["sealed"] is False and page.json()["recoverable"] is False
    assert page.json()["last_sequence"] == 4 and page.json()["next_after_sequence"] == 4
    assert not page.json()["has_more"]
    assert [e["kind"] for e in page.json()["events"]] == ["alignment", "freeze", "revoke"]
    for original, output in zip(events, page.json()["events"], strict=True):
        assert {key: output[key] for key in original} == original
        assert output["received_at"]
    assert page.json()["events"][-1]["generated_text"] is None


def test_frozen_original_version_survives_later_final_without_inherited_playback(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first, freeze(first)]).status_code == 200
    final = transcript_event(
        role="assistant",
        response_id=first["response_id"],
        turn_id=first["turn_id"],
        turn_index=first["turn_index"],
        revision=2,
        text="Hello there, how are you?",
    )
    assert post_transcripts(client, prepared, saved, [final]).status_code == 200
    latest = event(
        3,
        turn_id=first["turn_id"],
        turn_index=first["turn_index"],
        response_id=first["response_id"],
        transcript_revision=2,
        generated_text=final["text"],
        transcript_final=True,
        delivery_status="unknown",
        played_text="",
        played_until_ms=None,
        evidence_source="unknown",
    )
    assert post(client, prepared, saved, [latest]).status_code == 200
    assert rows(factory)[1]["transcript_revision"] == 1
    assert rows(factory)[1]["played_text"] == first["played_text"]
    page = client.get(path(prepared, saved, "/transcripts"), headers=prepared.headers).json()
    assert page["events"][0]["delivery_status"] == "unknown"


def test_empty_freeze_accepts_late_alignment_within_fixed_response_boundary(client, prepared):
    saved = reserve(client, prepared).json()
    first = event()
    empty = freeze(
        first,
        sequence=1,
        transcript_revision=0,
        generated_text="",
        transcript_final=False,
        playback_revision=0,
        delivery_status="unknown",
        played_text="",
        played_until_ms=None,
        evidence_source="unknown",
    )
    assert post(client, prepared, saved, [empty]).status_code == 200
    assert post(client, prepared, saved, [{**first, "sequence": 2}]).status_code == 200
    bad = {
        **first,
        "event_id": str(uuid4()),
        "sequence": 3,
        "playback_revision": 2,
        "played_until_ms": 301,
    }
    assert post(client, prepared, saved, [bad]).status_code == 409
    assert post(client, prepared, saved, [freeze(first, sequence=3)]).status_code == 409


def test_revocation_is_permanent_and_can_arrive_before_body(client, prepared, factory):
    saved = reserve(client, prepared).json()
    first = event()
    revoked = revoke(1, first["response_id"])
    assert post(client, prepared, saved, [revoked]).status_code == 200
    assert post(client, prepared, saved, [revoked]).status_code == 200
    for invalid in [
        {**first, "sequence": 2},
        freeze(first, sequence=2),
        revoke(2, first["response_id"]),
    ]:
        result = post(client, prepared, saved, [invalid])
        assert result.status_code == 409
    assert len(rows(factory)) == 1


@pytest.mark.parametrize("same", [True, False])
def test_concurrent_exact_replay_and_sequence_conflict_are_atomic(client, prepared, factory, same):
    saved = reserve(client, prepared).json()
    first = event()
    batches = [[first], [first if same else event()]]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda batch: post(client, prepared, saved, batch), batches))
    assert sorted(r.status_code for r in results) == ([200, 200] if same else [200, 409])
    assert len(rows(factory)) == 1


def test_conflicts_reject_whole_batch_and_never_echo_text(client, prepared, factory):
    saved = reserve(client, prepared).json()
    first = event(sequence=3)
    assert post(client, prepared, saved, [first]).status_code == 200
    for invalid in [
        {**first, "played_text": "Hello"},
        {**first, "event_id": str(uuid4())},
        event(sequence=2),
        {**first, "event_id": str(uuid4()), "sequence": 5, "generated_text": "Hello, private-new"},
        {**first, "event_id": str(uuid4()), "sequence": 5, "turn_index": 8},
        {**first, "event_id": str(uuid4()), "sequence": 5, "response_id": str(uuid4())},
        {**first, "event_id": str(uuid4()), "sequence": 5, "playback_revision": 1},
        {
            **first,
            "event_id": str(uuid4()),
            "sequence": 5,
            "playback_revision": 2,
            "played_text": "H",
            "played_until_ms": 100,
        },
    ]:
        result = post(client, prepared, saved, [invalid, event(8)])
        assert result.status_code == 409, result.text
        assert "private" not in result.text
    assert len(rows(factory)) == 1


@pytest.mark.parametrize("direction", ["ledger_first", "final_first"])
@pytest.mark.parametrize("conflict", ["role", "index", "response", "text", "nonfinal"])
def test_final_text_and_ledger_validate_identity_and_same_version_both_directions(
    client, prepared, direction, conflict
):
    saved = reserve(client, prepared).json()
    first = event(transcript_final=True)
    final = transcript_event(
        role="assistant",
        response_id=first["response_id"],
        turn_id=first["turn_id"],
        turn_index=first["turn_index"],
        text=first["generated_text"],
    )
    if direction == "ledger_first":
        if conflict == "nonfinal":
            first["transcript_final"] = False
        assert post(client, prepared, saved, [first]).status_code == 200
        final.update(
            {
                "role": {"role": "user", "response_id": None},
                "index": {"turn_index": 2},
                "response": {"response_id": str(uuid4())},
                "text": {"text": "different final"},
                "nonfinal": {},
            }[conflict]
        )
        result = post_transcripts(client, prepared, saved, [final])
    else:
        assert post_transcripts(client, prepared, saved, [final]).status_code == 200
        first.update(
            {
                "role": {"turn_id": str(uuid4())},
                "index": {"turn_index": 2},
                "response": {"response_id": str(uuid4())},
                "text": {"generated_text": "Hello, different suffix"},
                "nonfinal": {"transcript_final": False},
            }[conflict]
        )
        result = post(client, prepared, saved, [first])
    assert result.status_code == 409, result.text


@pytest.mark.parametrize(
    "changes",
    [
        {"sequence": True},
        {"sequence": 0},
        {"sequence": "1"},
        {"sequence": 2147483648},
        {"turn_index": False},
        {"transcript_revision": -1},
        {"transcript_revision": 0},
        {"transcript_final": 1},
        {"generated_text": 5},
        {"generated_text": "x" * 8193},
        {"generated_text": "private\x00body"},
        {"generated_text": "private\ud800body"},
        {"played_text": "好" * 2731},
        {"playback_revision": 0},
        {"playback_revision": True},
        {"played_until_ms": True},
        {"played_until_ms": 86400001},
        {"kind": "confirmed"},
        {"delivery_status": "played"},
        {"delivery_status": "not_played"},
        {"delivery_status": "unknown"},
        {"played_text": "not a prefix"},
        {"evidence_source": "provider_verified"},
        {"source": "verified"},
        {"stop_boundary_ms": 300},
        {"reason": "interrupted"},
        {"role": "assistant"},
        {"kind": "revoke"},
        {"turn_id": None},
        {"response_id": None},
    ],
)
def test_strict_shapes_and_alignment_fail_without_private_echo(client, prepared, factory, changes):
    saved = reserve(client, prepared).json()
    result = post(client, prepared, saved, [event(**changes)])
    assert result.status_code == 422, result.text
    assert "private" not in result.text
    assert rows(factory) == []


def test_batch_scope_read_and_ownership_are_strict(client, prepared, signup, factory):
    saved = reserve(client, prepared).json()
    first = event()
    for invalid in [[], [event(i) for i in range(1, 6)], [first, first], [event(2), event(1)]]:
        assert post(client, prepared, saved, invalid).status_code == 422
    for change, status in [
        ({"epoch": True}, 422),
        ({"epoch": 2}, 409),
        ({"client_instance_id": str(uuid4())}, 409),
        ({"source": "x"}, 422),
    ]:
        assert post(client, prepared, saved, **change).status_code == status
    assert (
        post(client, SimpleNamespace(session=prepared.session, headers={}), saved).status_code
        == 401
    )
    other = signup("bob")
    foreign = SimpleNamespace(
        session=prepared.session, headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert post(client, foreign, saved).status_code == 404
    url = path(prepared, saved, "/playback-evidence")
    assert client.get(url, headers=foreign.headers).status_code == 404
    for query in ["limit=0", "limit=17", "after_sequence=-1", "after_sequence=2147483648"]:
        assert client.get(url + "?" + query, headers=prepared.headers).status_code == 422
    assert rows(factory) == []


def test_historical_and_unknown_evidence_never_changes_occupancy_or_survives_delete(
    client, prepared, factory
):
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
    for field, value in [
        ("epoch", 99),
        ("client_instance_id", uuid4()),
        ("source", "verified"),
        ("generated_text", "x" * 8193),
        ("event_digest", "invalid"),
        ("kind", "revoke"),
        ("sequence", 0),
    ]:
        with pytest.raises(IntegrityError), factory.begin() as db:
            db.execute(text(f"UPDATE playback_evidence SET {field}=:value"), {"value": value})
    with factory.begin() as db:
        db.execute(
            text("DELETE FROM practice_sessions WHERE id=:id"), {"id": prepared.session["id"]}
        )
    assert rows(factory) == []
    assert post(client, prepared, old).status_code == 404


def test_client_evidence_does_not_override_complete_not_started_discard_history(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    assert post(client, prepared, saved).status_code == 200
    result = client.post(
        f"/v1/practice-sessions/{prepared.session['id']}/discard-preparation",
        headers=prepared.headers,
        json={"expected_epoch": 1},
    )
    assert result.status_code == 200, result.text
    assert state(factory)[1][0]["termination_status"] == "not_started"
    assert len(rows(factory)) == 1


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_identity_is_rechecked_after_owner_lock_wait(
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
        holder.execute(
            text(
                "UPDATE users SET disabled_at=now() WHERE id=:id"
                if action == "disable"
                else "UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"
            ),
            {"id": owner},
        )
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    assert rows(factory) == []


def test_web_write_requires_origin_csrf_and_expected_account(client, app, signup):
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
        prepared.headers = {key: value for key, value in headers.items() if key != missing}
        assert post(client, prepared, saved).status_code == status
    prepared.headers = headers
    assert post(client, prepared, saved).status_code == 200


def test_reserved_revocations_still_fit_after_512_normal_events_and_replays_fit_after_all_limits(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    common = event(
        generated_text="",
        transcript_final=True,
        delivery_status="unknown",
        played_text="",
        played_until_ms=None,
        evidence_source="unknown",
    )
    for start in range(1, 513, 4):
        batch = [
            {**common, "event_id": str(uuid4()), "sequence": index, "playback_revision": index}
            for index in range(start, start + 4)
        ]
        result = post(client, prepared, saved, batch)
        assert result.status_code == 200, result.text
    assert post(client, prepared, saved, batch).status_code == 200
    overflow = {**common, "event_id": str(uuid4()), "sequence": 513, "playback_revision": 513}
    assert post(client, prepared, saved, [overflow]).status_code == 429
    revoked = revoke(513, common["response_id"])
    assert post(client, prepared, saved, [revoked]).status_code == 200
    for start in range(514, 769, 4):
        tombstones = [revoke(index, str(uuid4())) for index in range(start, min(start + 4, 769))]
        result = post(client, prepared, saved, tombstones)
        assert result.status_code == 200, result.text
    assert len(rows(factory)) == 768
    assert post(client, prepared, saved, [revoke(769, str(uuid4()))]).status_code == 429
    assert post(client, prepared, saved, [revoked]).status_code == 200
    assert post(client, prepared, saved, batch).status_code == 200
    repeated = post(client, prepared, saved, [revoke(769, common["response_id"])])
    assert repeated.status_code == 409 and repeated.json()["code"] == "playback_revoked"


def test_total_generated_and_played_text_budget_is_cumulative_and_does_not_block_revocation(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    for start in range(1, 129, 4):
        batch = [
            event(
                index,
                generated_text="x" * 8192,
                transcript_final=True,
                delivery_status="played",
                played_text="x" * 8192,
            )
            for index in range(start, start + 4)
        ]
        result = post(client, prepared, saved, batch)
        assert result.status_code == 200, result.text
    assert result.json()["total_text_bytes"] == 2 * 1024 * 1024
    assert post(client, prepared, saved, [event(129)]).status_code == 429
    assert post(client, prepared, saved, [revoke(129, batch[-1]["response_id"])]).status_code == 200
    assert post(client, prepared, saved, batch).status_code == 200
    assert len(rows(factory)) == 129


def test_turn_budget_and_response_budget_are_independent_of_normal_events(client, prepared):
    saved = reserve(client, prepared).json()
    response = str(uuid4())
    for start in range(1, 257, 4):
        batch = [event(index, response_id=response) for index in range(start, start + 4)]
        assert post(client, prepared, saved, batch).status_code == 200
    assert post(client, prepared, saved, [event(257, response_id=response)]).status_code == 429
    assert post(client, prepared, saved, [revoke(257, response)]).status_code == 200


def test_late_revocation_is_readable_after_prior_pages_and_never_claims_sealed_recovery(
    client, prepared
):
    saved = reserve(client, prepared).json()
    events = [event(index) for index in [1, 3, 6]]
    assert post(client, prepared, saved, events).status_code == 200
    url = path(prepared, saved, "/playback-evidence")
    first = client.get(url + "?limit=2", headers=prepared.headers).json()
    assert first["last_sequence"] == 6 and first["has_more"]
    assert [item["sequence"] for item in first["events"]] == [1, 3]
    assert post(client, prepared, saved, [revoke(7, events[0]["response_id"])]).status_code == 200
    next_page = client.get(url + "?after_sequence=3&limit=2", headers=prepared.headers).json()
    assert [item["sequence"] for item in next_page["events"]] == [6, 7]
    assert next_page["next_after_sequence"] == 7 and not next_page["has_more"]
    assert next_page["sealed"] is False and next_page["recoverable"] is False


def test_freeze_cannot_claim_a_boundary_before_already_reported_output(client, prepared):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first]).status_code == 200
    later = freeze(
        first,
        sequence=2,
        transcript_revision=2,
        generated_text="Revised final",
        transcript_final=True,
        playback_revision=0,
        delivery_status="unknown",
        played_text="",
        played_until_ms=None,
        evidence_source="unknown",
        stop_boundary_ms=200,
    )
    assert post(client, prepared, saved, [later]).status_code == 409


def test_new_ledger_events_cannot_regress_source_versions_but_exact_replay_can(client, prepared):
    saved = reserve(client, prepared).json()
    first = event(transcript_revision=2)
    assert post(client, prepared, saved, [first]).status_code == 200
    older = {**first, "event_id": str(uuid4()), "sequence": 2, "transcript_revision": 1}
    for invalid in [older, freeze(older, sequence=2)]:
        assert post(client, prepared, saved, [invalid]).status_code == 409
    assert post(client, prepared, saved, [first]).status_code == 200


@pytest.mark.parametrize("direction", ["final_first", "ledger_first"])
def test_finality_does_not_regress_across_final_and_playback_ledgers(client, prepared, direction):
    saved = reserve(client, prepared).json()
    source = event(transcript_revision=2)
    final = transcript_event(
        role="assistant",
        response_id=source["response_id"],
        turn_id=source["turn_id"],
        turn_index=source["turn_index"],
        revision=1,
        text="Earlier final",
    )
    if direction == "final_first":
        assert post_transcripts(client, prepared, saved, [final]).status_code == 200
        result = post(client, prepared, saved, [source])
    else:
        assert post(client, prepared, saved, [source]).status_code == 200
        result = post_transcripts(client, prepared, saved, [final])
    assert result.status_code == 409


def test_old_interim_evidence_can_arrive_after_newer_final_only_from_independent_journal(
    client, prepared
):
    saved = reserve(client, prepared).json()
    interim = event(transcript_revision=1)
    final = transcript_event(
        role="assistant",
        response_id=interim["response_id"],
        turn_id=interim["turn_id"],
        turn_index=interim["turn_index"],
        revision=2,
        text="Newer final",
    )
    assert post_transcripts(client, prepared, saved, [final]).status_code == 200
    assert post(client, prepared, saved, [interim]).status_code == 200


def test_later_conflict_rolls_back_preceding_valid_addition(client, prepared, factory):
    saved = reserve(client, prepared).json()
    first = event()
    assert post(client, prepared, saved, [first]).status_code == 200
    invalid = {**first, "event_id": str(uuid4()), "sequence": 3, "playback_revision": 1}
    result = post(client, prepared, saved, [event(2), invalid])
    assert result.status_code == 409
    assert len(rows(factory)) == 1


def test_concurrent_cross_ledger_conflict_cannot_commit_inconsistent_versions(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    source = event()
    final = transcript_event(
        role="assistant",
        response_id=source["response_id"],
        turn_id=source["turn_id"],
        turn_index=source["turn_index"],
        text=source["generated_text"],
    )
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [
            pool.submit(post, client, prepared, saved, [source]),
            pool.submit(post_transcripts, client, prepared, saved, [final]),
        ]
        result = [future.result(timeout=5) for future in futures]
    assert sorted(item.status_code for item in result) == [200, 409]
    with factory() as db:
        assert (
            db.scalar(
                text(
                    "SELECT (SELECT count(*) FROM final_transcripts) + "
                    "(SELECT count(*) FROM playback_evidence)"
                )
            )
            == 1
        )


def test_maximum_escaped_generated_and_played_texts_fit_bounded_batch(client, prepared):
    saved = reserve(client, prepared).json()
    events = [
        event(
            index,
            generated_text="\u0001" * 8192,
            transcript_final=True,
            delivery_status="played",
            played_text="\u0001" * 8192,
        )
        for index in range(1, 5)
    ]
    result = post(client, prepared, saved, events)
    assert result.status_code == 200, result.text
    assert result.json()["total_text_bytes"] == 4 * 2 * 8192


def test_freeze_identity_and_membership_hold_for_all_turns_of_one_response(client, prepared):
    saved = reserve(client, prepared).json()
    first = event()
    other = event(2, response_id=first["response_id"])
    assert (
        post(client, prepared, saved, [first, other, freeze(first, sequence=3)]).status_code == 200
    )
    late = {**other, "event_id": str(uuid4()), "sequence": 4, "playback_revision": 2}
    assert post(client, prepared, saved, [late]).status_code == 409
    assert (
        post(client, prepared, saved, [freeze(other, sequence=4, reason="normal_end")]).status_code
        == 409
    )
    assert (
        post(client, prepared, saved, [freeze(other, sequence=4, stop_boundary_ms=350)]).status_code
        == 409
    )
    assert post(client, prepared, saved, [freeze(other, sequence=4)]).status_code == 200
    assert post(client, prepared, saved, [{**late, "sequence": 5}]).status_code == 200
