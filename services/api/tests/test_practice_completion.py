from datetime import datetime, timedelta
from uuid import uuid4

import pytest
from sqlalchemy import text
from test_connection_reservations import control, path, reserve
from test_connection_reservations import prepared as prepared
from test_final_transcripts import event as transcript_event
from test_final_transcripts import post as post_transcripts
from test_playback_evidence import event as playback_event
from test_playback_evidence import freeze, revoke
from test_playback_evidence import post as post_playback


def begin(client, prepared, saved, *, key=None, **changes):
    return client.post(
        path(prepared, saved, "/end"),
        headers={**prepared.headers, "Idempotency-Key": str(key or uuid4())},
        json={
            "client_instance_id": saved["client_instance_id"],
            "epoch": saved["epoch"],
            **changes,
        },
    )


def ledger(events=(), *, playback=False, **changes):
    return {
        "events": [{"sequence": e["sequence"], "event_id": e["event_id"]} for e in events],
        "last_sequence": max((e["sequence"] for e in events), default=0),
        "total_events": len(events),
        "total_text_bytes": sum(
            len(((e.get("generated_text") or "") + (e.get("played_text") or "")).encode())
            if playback
            else len(e["text"].encode())
            for e in events
        ),
        "pending_count_at_close": 0,
        **changes,
    }


def manifest(saved, transcripts=(), playback=(), **changes):
    return {
        "client_instance_id": saved["client_instance_id"],
        "epoch": saved["epoch"],
        "transcripts": ledger(transcripts),
        "playback": ledger(playback, playback=True),
        "tail_status": "unconfirmed",
        "unfinalized_turn_ids": [],
        "unconfirmed_response_ids": [],
        "transcript_rejected_count": 0,
        "playback_rejected_count": 0,
        "journal_unavailable": False,
        **changes,
    }


def submit(client, prepared, saved, payload):
    return client.post(
        path(prepared, saved, "/completion-manifest"), headers=prepared.headers, json=payload
    )


def summary(client, prepared):
    return client.get(
        f"/v1/practice-sessions/{prepared.session['id']}/completion", headers=prepared.headers
    )


def snapshot(client, prepared, saved):
    return client.get(path(prepared, saved, "/completion"), headers=prepared.headers)


def upstream(factory, saved, *, status="configuring"):
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status=:status, "
                "termination_status='unknown', offer_digest=:digest, "
                "signalling_started_at=now() WHERE id=:id"
            ),
            {"id": saved["id"], "digest": "a" * 64, "status": status},
        )


def test_end_registers_fixed_deadline_and_precise_key_then_seals_safe_empty(client, prepared):
    saved = reserve(client, prepared).json()
    key = uuid4()
    response = begin(client, prepared, saved, key=key)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["source"] == "server_recorded"
    assert data["status"] == "ending" and data["coverage"] == "pending"
    assert data["input_revision"] == 0 and data["input_hash"] is None
    assert datetime.fromisoformat(data["final_upload_deadline"]) - datetime.fromisoformat(
        data["accepted_at"]
    ) == timedelta(seconds=30)
    assert begin(client, prepared, saved, key=key).json() == data
    assert summary(client, prepared).json() == data
    assert begin(client, prepared, saved).status_code == 409
    assert begin(client, prepared, saved, key=key, epoch=2).status_code == 409
    data = submit(client, prepared, saved, manifest(saved, tail_status="complete")).json()
    assert data["status"] == "sealed" and data["coverage"] == "complete"
    connection = client.get(path(prepared, saved), headers=prepared.headers).json()
    assert connection["status"] == "closed" and connection["termination_status"] == "not_started"
    assert snapshot(client, prepared, saved).json()["coverage"] == "complete"


def test_manifest_before_upload_holds_only_declared_events_and_seals_on_receipt(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    original = transcript_event(7, revision=4, turn_index=9)
    started = begin(client, prepared, saved).json()
    assert started["status"] == "ending"
    payload = manifest(saved, [original])
    assert submit(client, prepared, saved, payload).json()["status"] == "ending"
    rejected = post_transcripts(client, prepared, saved, [transcript_event(8)])
    assert rejected.status_code == 409 and rejected.json()["code"] == "completion_manifest_conflict"
    assert post_transcripts(client, prepared, saved, [original]).status_code == 200
    sealed = summary(client, prepared).json()
    assert sealed["status"] == "sealed" and sealed["coverage"] == "incomplete"
    assert sealed["gap_codes"] == ["tail_unconfirmed"]
    assert submit(client, prepared, saved, payload).json() == sealed
    assert post_transcripts(client, prepared, saved, [original]).status_code == 200
    assert summary(client, prepared).json() == sealed
    assert (
        post_transcripts(client, prepared, saved, [transcript_event(9)]).json()["code"]
        == "practice_input_sealed"
    )
    snap = snapshot(client, prepared, saved).json()
    assert snap["transcripts"]["received"]["last_sequence"] == 7
    assert snap["turns"][0]["candidate_eligibility"] == "eligible"
    assert snap["turns"][0]["reason_codes"] == ["user_final_text"]
    assert not snap["recoverable"] and snap["sealed"]
    assert client.get(path(prepared, saved, "/playback-evidence"), headers=prepared.headers).json()[
        "sealed"
    ]


def test_deadline_rejects_mixed_batches_without_waiting_for_scanner_and_scans_after_restart(
    client, prepared, factory, monkeypatch
):
    from simontalk_api.security import now

    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    original = transcript_event()
    assert post_transcripts(client, prepared, saved, [original]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    from simontalk_api import practice_completion

    future = now() + timedelta(seconds=31)
    monkeypatch.setattr(practice_completion, "now", lambda: future)
    extra = transcript_event(2)
    result = post_transcripts(client, prepared, saved, [original, extra])
    assert result.status_code == 409 and result.json()["code"] == "practice_input_sealed"
    assert summary(client, prepared).json()["status"] == "ending"
    from simontalk_api.practice_maintenance import run_maintenance_batch

    assert run_maintenance_batch(factory).completions_finalized == 1
    sealed = summary(client, prepared).json()
    assert sealed["status"] == "sealed" and "manifest_missing" in sealed["gap_codes"]
    assert run_maintenance_batch(factory).completions_finalized == 0
    assert post_transcripts(client, prepared, saved, [original]).status_code == 200
    assert summary(client, prepared).json() == sealed


def test_final_text_qualification_old_freeze_and_revocation_survive_seal(client, prepared, factory):
    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    played = playback_event()
    frozen = freeze(played)
    final = transcript_event(
        role="assistant",
        turn_id=played["turn_id"],
        turn_index=played["turn_index"],
        response_id=played["response_id"],
        revision=2,
        text="Another final text.",
    )
    user = transcript_event(2, turn_index=2)
    empty = {**user, "event_id": str(uuid4()), "sequence": 3, "revision": 2, "text": ""}
    assert post_playback(client, prepared, saved, [played, frozen]).status_code == 200
    assert post_transcripts(client, prepared, saved, [final, user, empty]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    payload = manifest(saved, [final, user, empty], [played, frozen])
    assert submit(client, prepared, saved, payload).json()["status"] == "sealed"
    turns = snapshot(client, prepared, saved).json()["turns"]
    assert turns[0]["interrupted_prefix"]["playback_event_id"] == frozen["event_id"]
    assert turns[0]["final_prefix"] is None
    assert turns[1]["candidate_eligibility"] == "excluded" and turns[1]["revision"] == 2


def test_end_does_not_clear_unknown_occupancy_and_registers_one_blocked_check(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    key = uuid4()
    assert begin(client, prepared, saved, key=key).status_code == 200
    assert begin(client, prepared, saved, key=key).status_code == 200
    with factory() as db:
        task = db.execute(text("SELECT * FROM termination_checks")).mappings().one()
        assert task["status"] == "blocked" and task["reason"] == "capability_unavailable"
        assert task["attempts"] == 0
    assert submit(client, prepared, saved, manifest(saved)).json()["status"] == "sealed"
    result = client.get("/v1/practice-sessions/current", headers=prepared.headers).json()
    assert result["practice"]["status"] == "completed"
    assert result["connection"]["termination_status"] == "unknown"
    assert result["connection"]["status"] == "unknown"
    assert control(client, prepared, saved, "renew-lease").status_code == 409
    assert reserve(client, prepared, expected_epoch=1).status_code == 409


@pytest.mark.parametrize("changes", [{"epoch": True}, {"extra": "text"}, {"epoch": 0}])
def test_end_strict_fields(client, prepared, changes):
    saved = reserve(client, prepared).json()
    assert begin(client, prepared, saved, **changes).status_code == 422


def test_known_not_played_is_not_a_playback_gap_and_receipt_has_actual_refs(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    played = playback_event(
        transcript_final=True, delivery_status="not_played", played_text="", played_until_ms=0
    )
    final = transcript_event(
        role="assistant",
        turn_id=played["turn_id"],
        turn_index=played["turn_index"],
        response_id=played["response_id"],
        text=played["generated_text"],
    )
    assert post_playback(client, prepared, saved, [played]).status_code == 200
    assert post_transcripts(client, prepared, saved, [final]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    receipt_url = path(prepared, saved, "/completion-receipt")
    assert client.get(receipt_url, headers=prepared.headers).status_code == 409
    sealed = submit(
        client, prepared, saved, manifest(saved, [final], [played], tail_status="complete")
    )
    assert sealed.json()["gap_codes"] == []
    receipt = client.get(receipt_url, headers=prepared.headers).json()
    assert receipt["transcript_events"] == ledger([final])["events"]
    assert receipt["playback_events"] == ledger([played], playback=True)["events"]
    assert receipt["practice_input_hash"] == sealed.json()["input_hash"]
    assert receipt["input_hash"] == snapshot(client, prepared, saved).json()["input_hash"]


def test_playback_page_seal_and_events_share_one_read_snapshot(client, prepared, factory, app):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event, Lock

    from sqlalchemy import event as sql_event

    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    first = playback_event()
    second = freeze(first)
    assert post_playback(client, prepared, saved, [first]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    assert (
        submit(client, prepared, saved, manifest(saved, playback=[first, second])).status_code
        == 200
    )
    paused, proceed = Event(), Event()
    guard = Lock()
    armed = [True]

    def pause_read(conn, cursor, statement, parameters, context, executemany):
        if (
            not statement.lstrip().startswith("SELECT")
            or "playback_evidence" not in statement
            or "ORDER BY" not in statement
        ):
            return
        with guard:
            if not armed[0]:
                return
            armed[0] = False
        paused.set()
        assert proceed.wait(5)

    sql_event.listen(app.state.engine, "after_cursor_execute", pause_read)
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(
                client.get, path(prepared, saved, "/playback-evidence"), headers=prepared.headers
            )
            try:
                assert paused.wait(3)
                assert post_playback(client, prepared, saved, [second]).status_code == 200
            finally:
                proceed.set()
            page = future.result(timeout=5).json()
            assert not page["sealed"] or page["total_events"] == 2
    finally:
        proceed.set()
        sql_event.remove(app.state.engine, "after_cursor_execute", pause_read)


@pytest.mark.parametrize(
    "change",
    [
        {"journal_unavailable": 1},
        {"transcript_rejected_count": True},
        {"unfinalized_turn_ids": [str(uuid4())] * 2},
        {"unknown": "ignored"},
        {"tail_status": "provider_confirmed"},
        {"transcripts": ledger([], total_text_bytes=1)},
        {"transcripts": ledger([], pending_count_at_close=1)},
        {"transcripts": ledger([], last_sequence=True)},
    ],
)
def test_manifest_strict_shape(client, prepared, change):
    saved = reserve(client, prepared).json()
    assert begin(client, prepared, saved).status_code == 200
    assert submit(client, prepared, saved, {**manifest(saved), **change}).status_code == 422
    assert summary(client, prepared).json()["status"] == "ending"


def test_all_historical_scopes_are_frozen_and_empty_old_safe_scope_can_be_proven(client, prepared):
    old = reserve(client, prepared).json()
    assert control(client, prepared, old, "cancel-preparation").status_code == 200
    current = reserve(client, prepared, expected_epoch=1).json()
    assert begin(client, prepared, old).json()["code"] == "connection_epoch_changed"
    assert begin(client, prepared, current).json()["connection_count"] == 2
    assert snapshot(client, prepared, old).json()["coverage"] == "empty_not_started"
    assert summary(client, prepared).json()["status"] == "ending"
    result = submit(client, prepared, current, manifest(current, tail_status="complete")).json()
    assert result["status"] == "sealed" and result["coverage"] == "complete"


def test_historical_client_reported_text_is_not_an_empty_safe_scope(client, prepared):
    old = reserve(client, prepared).json()
    sentence = transcript_event()
    assert post_transcripts(client, prepared, old, [sentence]).status_code == 200
    assert control(client, prepared, old, "cancel-preparation").status_code == 200
    current = reserve(client, prepared, expected_epoch=1).json()
    assert begin(client, prepared, current).status_code == 200
    assert (
        submit(client, prepared, current, manifest(current, tail_status="complete")).json()[
            "status"
        ]
        == "ending"
    )
    result = submit(client, prepared, old, manifest(old, [sentence], tail_status="complete")).json()
    assert result["status"] == "sealed" and result["coverage"] == "complete"


def test_deadline_manifest_freezes_actual_missing_unexpected_and_hash_without_trusting_totals(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import practice_completion
    from simontalk_api.practice_maintenance import run_maintenance_batch
    from simontalk_api.security import now

    saved = reserve(client, prepared).json()
    original = transcript_event(3)
    missing = transcript_event(7)
    assert post_transcripts(client, prepared, saved, [original]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    payload = manifest(saved, [missing], transcript_rejected_count=1, journal_unavailable=True)
    assert submit(client, prepared, saved, payload).json()["status"] == "ending"
    assert (
        submit(client, prepared, saved, {**payload, "tail_status": "complete"}).json()["code"]
        == "completion_manifest_conflict"
    )
    future = now() + timedelta(seconds=30)
    monkeypatch.setattr(practice_completion, "now", lambda: future)
    assert run_maintenance_batch(factory).completions_finalized == 1
    snap = snapshot(client, prepared, saved).json()
    assert snap["transcripts"]["missing_event_ids"] == [missing["event_id"]]
    assert snap["transcripts"]["unexpected_event_ids"] == [original["event_id"]]
    assert set(snap["gap_codes"]) >= {
        "transcript_missing",
        "transcript_unexpected",
        "manifest_totals_mismatch",
        "transcript_rejected",
        "journal_unavailable",
    }
    before = summary(client, prepared).json()
    assert submit(client, prepared, saved, payload).json() == before
    receipt = client.get(
        path(prepared, saved, "/completion-receipt"), headers=prepared.headers
    ).json()
    assert receipt["transcript_events"] == ledger([original])["events"]
    assert missing["event_id"] not in str(receipt)


def test_new_manifest_at_exact_deadline_is_rejected_and_get_is_read_only(
    client, prepared, monkeypatch
):
    from simontalk_api import practice_completion

    saved = reserve(client, prepared).json()
    accepted = begin(client, prepared, saved).json()
    deadline = datetime.fromisoformat(accepted["final_upload_deadline"])
    monkeypatch.setattr(practice_completion, "now", lambda: deadline)
    result = submit(client, prepared, saved, manifest(saved))
    assert result.status_code == 409 and result.json()["code"] == "practice_input_sealed"
    assert summary(client, prepared).json() == accepted
    assert snapshot(client, prepared, saved).json()["manifest_received"] is False


def test_playback_mixed_batch_at_deadline_is_atomic_and_old_revoke_replays(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import practice_completion

    saved = reserve(client, prepared).json()
    first = playback_event()
    tombstone = revoke(3, first["response_id"])
    assert (
        post_playback(client, prepared, saved, [first, freeze(first), tombstone]).status_code == 200
    )
    begun = begin(client, prepared, saved).json()
    monkeypatch.setattr(
        practice_completion, "now", lambda: datetime.fromisoformat(begun["final_upload_deadline"])
    )
    extra = playback_event(4, turn_index=2)
    rejected = post_playback(client, prepared, saved, [tombstone, extra])
    assert rejected.status_code == 409 and rejected.json()["code"] == "practice_input_sealed"
    assert post_playback(client, prepared, saved, [first, tombstone]).status_code == 200
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM playback_evidence")) == 3


def test_revoke_removes_both_prefix_kinds_and_specific_unfinalized_turn_is_uncertain(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    first = playback_event(transcript_final=True)
    frozen = freeze(first)
    tombstone = revoke(3, first["response_id"])
    assistant = transcript_event(
        role="assistant",
        response_id=first["response_id"],
        turn_id=first["turn_id"],
        turn_index=first["turn_index"],
        text=first["generated_text"],
    )
    user = transcript_event(2, turn_index=2)
    assert post_playback(client, prepared, saved, [first, frozen, tombstone]).status_code == 200
    assert post_transcripts(client, prepared, saved, [assistant, user]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    payload = manifest(
        saved, [assistant, user], [first, frozen, tombstone], unfinalized_turn_ids=[user["turn_id"]]
    )
    assert submit(client, prepared, saved, payload).json()["status"] == "sealed"
    snap = snapshot(client, prepared, saved).json()
    assert (
        snap["turns"][0]["final_prefix"] is None and snap["turns"][0]["interrupted_prefix"] is None
    )
    assert snap["turns"][1]["candidate_eligibility"] == "uncertain"
    assert snap["turns"][1]["reason_codes"] == ["unfinalized_turn"]
    assert "playback_revoked" in snap["gap_codes"]


def test_unknown_backfill_and_lease_failure_register_checks_without_parent_state_reversion(
    client, prepared, factory
):
    from simontalk_api.practice_maintenance import run_maintenance_batch

    saved = reserve(client, prepared).json()
    upstream(factory, saved, status="unknown")
    assert run_maintenance_batch(factory).termination_checks_registered == 1
    assert run_maintenance_batch(factory).termination_checks_registered == 0
    assert begin(client, prepared, saved).status_code == 200
    assert submit(client, prepared, saved, manifest(saved)).json()["status"] == "sealed"
    with factory.begin() as db:
        # Exercise lease cleanup independently of end's conservative unknown state.
        db.execute(
            text(
                "UPDATE realtime_connections SET status='closing', "
                "lease_expires_at=now()-interval '1 second'"
            )
        )
    assert run_maintenance_batch(factory).connections_expired == 1
    assert summary(client, prepared).json()["status"] == "sealed"
    result = client.get("/v1/practice-sessions/current", headers=prepared.headers).json()
    assert (
        result["practice"]["status"] == "completed" and result["connection"]["status"] == "unknown"
    )
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM termination_checks")) == 1


def test_normally_negotiating_unknown_termination_does_not_schedule_early_check(
    client, prepared, factory
):
    from simontalk_api.practice_maintenance import run_maintenance_batch

    saved = reserve(client, prepared).json()
    upstream(factory, saved, status="negotiating")
    assert run_maintenance_batch(factory).termination_checks_registered == 0
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM termination_checks")) == 0


def test_other_account_cannot_read_write_or_replay_completion(client, prepared, signup):
    saved = reserve(client, prepared).json()
    key = uuid4()
    assert begin(client, prepared, saved, key=key).status_code == 200
    other = signup("bob")
    headers = {"Authorization": f"Bearer {other['access_token']}"}
    for suffix in ("/completion", "/completion-receipt"):
        assert client.get(path(prepared, saved, suffix), headers=headers).status_code == 404
    assert (
        client.get(
            f"/v1/practice-sessions/{prepared.session['id']}/completion", headers=headers
        ).status_code
        == 404
    )
    original_headers = prepared.headers
    try:
        prepared.headers = headers
        assert begin(client, prepared, saved, key=key).status_code == 404
        assert submit(client, prepared, saved, manifest(saved)).status_code == 404
    finally:
        prepared.headers = original_headers


def test_completion_identity_is_rechecked_after_owner_lock_wait(
    client, prepared, factory, monkeypatch
):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    from test_practice_preparation import wait_for_row_lock

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
        user_id = prepared.identity["user"]["id"]
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": user_id})
        future = pool.submit(begin, client, prepared, saved)
        assert checked.wait(3)
        wait_for_row_lock(factory, "users")
        holder.execute(
            text("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"), {"id": user_id}
        )
        holder.commit()
        assert future.result(timeout=5).status_code == 401
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM practice_completions")) == 0


def test_due_scan_skips_owner_lock_then_safely_recovers_and_delete_cascades(
    client, prepared, factory, monkeypatch
):
    from concurrent.futures import ThreadPoolExecutor

    from simontalk_api import practice_completion
    from simontalk_api.practice_maintenance import run_maintenance_batch

    saved = reserve(client, prepared).json()
    upstream(factory, saved)
    accepted = begin(client, prepared, saved).json()
    monkeypatch.setattr(
        practice_completion,
        "now",
        lambda: datetime.fromisoformat(accepted["final_upload_deadline"]),
    )
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        holder.execute(
            text("SELECT id FROM users WHERE id=:id FOR UPDATE"),
            {"id": prepared.identity["user"]["id"]},
        )
        assert (
            pool.submit(run_maintenance_batch, factory).result(timeout=3).completions_finalized == 0
        )
        holder.rollback()
    assert run_maintenance_batch(factory).completions_finalized == 1
    with factory.begin() as db:
        db.execute(
            text("DELETE FROM practice_sessions WHERE id=:id"), {"id": prepared.session["id"]}
        )
        for table in ("practice_completions", "completion_connections", "termination_checks"):
            assert db.scalar(text(f"SELECT count(*) FROM {table}")) == 0
    assert begin(client, prepared, saved).status_code == 404


def test_whitespace_final_is_excluded_candidate(client, prepared):
    saved = reserve(client, prepared).json()
    sentence = transcript_event(text=" \n\t ")
    assert post_transcripts(client, prepared, saved, [sentence]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    assert (
        submit(
            client, prepared, saved, manifest(saved, [sentence], tail_status="complete")
        ).status_code
        == 200
    )
    turn = snapshot(client, prepared, saved).json()["turns"][0]
    assert turn["candidate_eligibility"] == "excluded" and turn["reason_codes"] == ["empty_text"]


def test_playback_only_unknown_interim_has_server_derived_gaps_even_if_manifest_claims_complete(
    client, prepared
):
    saved = reserve(client, prepared).json()
    unknown = playback_event(
        delivery_status="unknown", played_text="", played_until_ms=None, evidence_source="unknown"
    )
    assert post_playback(client, prepared, saved, [unknown]).status_code == 200
    assert begin(client, prepared, saved).status_code == 200
    assert (
        submit(
            client, prepared, saved, manifest(saved, playback=[unknown], tail_status="complete")
        ).status_code
        == 200
    )
    snap = snapshot(client, prepared, saved).json()
    assert set(snap["gap_codes"]) >= {"unfinalized_turn", "playback_unconfirmed"}
    assert snap["turns"][0]["transcript_event_id"] is None
    assert snap["turns"][0]["candidate_eligibility"] == "excluded"


@pytest.mark.parametrize(
    "mutation",
    [
        "UPDATE practice_completions SET status='sealed', "
        "sealed_at=now(), input_revision=1, coverage='complete', "
        "input_hash=NULL",
        "UPDATE completion_connections SET manifest='{}'::jsonb, "
        "manifest_received_at=now(), manifest_digest=NULL",
        "UPDATE completion_connections SET snapshot='{}'::jsonb, snapshot_hash=NULL",
    ],
)
def test_database_rejects_incomplete_seal_and_digest_pairs(client, prepared, factory, mutation):
    from sqlalchemy.exc import IntegrityError

    saved = reserve(client, prepared).json()
    assert begin(client, prepared, saved).status_code == 200
    with pytest.raises(IntegrityError), factory.begin() as db:
        db.execute(text(mutation))


def test_concurrent_end_replay_and_manifest_append_have_one_immutable_input(
    client, prepared, factory
):
    from concurrent.futures import ThreadPoolExecutor

    saved = reserve(client, prepared).json()
    key = uuid4()
    with ThreadPoolExecutor(max_workers=2) as pool:
        ends = [pool.submit(begin, client, prepared, saved, key=key) for _ in range(2)]
        first, second = [f.result(timeout=5) for f in ends]
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    sentence = transcript_event()
    with ThreadPoolExecutor(max_workers=2) as pool:
        posted = pool.submit(post_transcripts, client, prepared, saved, [sentence])
        manifested = pool.submit(submit, client, prepared, saved, manifest(saved, [sentence]))
        assert posted.result(timeout=5).status_code == 200
        assert manifested.result(timeout=5).status_code == 200
    sealed = summary(client, prepared).json()
    assert sealed["status"] == "sealed" and sealed["connection_count"] == 1
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM practice_completions")) == 1
        assert db.scalar(text("SELECT count(*) FROM completion_connections")) == 1


def test_web_end_and_manifest_preserve_origin_csrf_and_account_binding(client, app, signup):
    from types import SimpleNamespace

    from test_connection_reservations import TestAdmission

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
    prepared = SimpleNamespace(session=created, headers=headers)
    saved = reserve(client, prepared).json()
    for missing, expected in (("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)):
        prepared.headers = {k: v for k, v in headers.items() if k != missing}
        assert begin(client, prepared, saved).status_code == expected
    prepared.headers = headers
    assert begin(client, prepared, saved).status_code == 200
    for missing, expected in (("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)):
        prepared.headers = {k: v for k, v in headers.items() if k != missing}
        assert submit(client, prepared, saved, manifest(saved)).status_code == expected
    prepared.headers = headers
    assert submit(client, prepared, saved, manifest(saved)).status_code == 200


def test_end_during_offer_prevents_late_answer_and_persists_blocked_check(
    client, app, prepared, factory
):
    import asyncio
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    from test_signalling import ANSWER, TestGateway, offer

    saved = reserve(client, prepared).json()
    gateway = TestGateway()
    app.state.signalling_gateway = gateway
    entered, proceed = Event(), Event()

    async def wait(configuration, raw):
        entered.set()
        assert await asyncio.to_thread(proceed.wait, 5)
        return ANSWER

    gateway.handler = wait
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(offer, client, prepared, saved)
        try:
            assert entered.wait(3)
            assert begin(client, prepared, saved).status_code == 200
        finally:
            proceed.set()
        response = pending.result(timeout=5)
        assert response.status_code == 409 and response.json()["code"] == "signalling_state_changed"
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM termination_checks")) == 1
    assert summary(client, prepared).json()["status"] == "ending"


def test_signalling_failure_persists_blocked_check_in_its_state_transaction(
    client, app, prepared, factory
):
    from test_signalling import TestGateway, offer

    saved = reserve(client, prepared).json()
    gateway = TestGateway()
    app.state.signalling_gateway = gateway

    async def fail(configuration, raw):
        raise RuntimeError("private-provider-detail")

    gateway.handler = fail
    result = offer(client, prepared, saved)
    assert result.status_code == 502
    with factory() as db:
        task = db.execute(text("SELECT * FROM termination_checks")).mappings().one()
        assert task["attempts"] == 0 and task["status"] == "blocked"
    assert client.get(path(prepared, saved), headers=prepared.headers).json()["status"] == "unknown"


def test_end_locks_all_connection_members_in_epoch_order(client, prepared, app):
    from sqlalchemy import event as sql_event

    old = reserve(client, prepared).json()
    assert control(client, prepared, old, "cancel-preparation").status_code == 200
    saved = reserve(client, prepared, expected_epoch=1).json()
    locked = []

    def record(conn, cursor, statement, parameters, context, executemany):
        if "FROM realtime_connections" in statement and "FOR UPDATE" in statement:
            locked.append(statement)

    sql_event.listen(app.state.engine, "after_cursor_execute", record)
    try:
        assert begin(client, prepared, saved).status_code == 200
    finally:
        sql_event.remove(app.state.engine, "after_cursor_execute", record)
    assert len(locked) == 1 and "ORDER BY realtime_connections.epoch" in locked[0]
