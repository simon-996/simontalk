"""Saved text uses real HTTP seals; fixtures stay local to this API contract."""

from types import SimpleNamespace
from uuid import uuid4

import pytest


class Admission:
    def admit(self, user_id):
        return SimpleNamespace(
            provider="test-only", region="test", model="test", config_id="test-v1"
        )


@pytest.fixture
def scope(client, app, signup):
    identity = signup()
    headers = {"Authorization": f"Bearer {identity['access_token']}"}
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
        ).status_code
        == 200
    )
    app.state.practice_admission = Admission()
    result = client.post(
        "/v1/practice-sessions",
        headers=headers | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    )
    assert result.status_code == 201, result.text
    return SimpleNamespace(headers=headers, identity=identity, session=result.json())


def base(scope):
    return f"/v1/practice-sessions/{scope.session['id']}"


def event(sequence=1, **changes):
    return {
        "event_id": str(uuid4()),
        "sequence": sequence,
        "turn_id": str(uuid4()),
        "turn_index": sequence,
        "role": "user",
        "revision": 1,
        "text": "I enjoy English. 我喜欢英语。",
        "response_id": None,
        "provider_item_id": None,
        **changes,
    }


def reserve(client, scope, **changes):
    result = client.post(
        base(scope) + "/connections",
        headers=scope.headers | {"Idempotency-Key": str(uuid4())},
        json={"client_instance_id": str(uuid4()), "expected_epoch": 0, **changes},
    )
    assert result.status_code == 201, result.text
    return result.json()


def upload(client, scope, connection, transcripts=(), playback=()):
    for events, suffix in [(playback, "/playback-evidence"), (transcripts, "/transcripts")]:
        for offset in range(0, len(events), 4):
            result = client.post(
                base(scope) + f"/connections/{connection['id']}" + suffix,
                headers=scope.headers,
                json={
                    "client_instance_id": connection["client_instance_id"],
                    "epoch": connection["epoch"],
                    "events": events[offset : offset + 4],
                },
            )
            assert result.status_code == 200, result.text


def ledger(events, *, playback=False):
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
    }


def seal(client, scope, transcripts=(), playback=(), *, connection=None, **changes):
    connection = connection or reserve(client, scope)
    upload(client, scope, connection, transcripts, playback)
    connection_path = base(scope) + f"/connections/{connection['id']}"
    result = client.post(
        connection_path + "/end",
        headers=scope.headers | {"Idempotency-Key": str(uuid4())},
        json={"client_instance_id": connection["client_instance_id"], "epoch": connection["epoch"]},
    )
    assert result.status_code == 200, result.text
    result = client.post(
        connection_path + "/completion-manifest",
        headers=scope.headers,
        json={
            "client_instance_id": connection["client_instance_id"],
            "epoch": connection["epoch"],
            "transcripts": ledger(transcripts),
            "playback": ledger(playback, playback=True),
            "tail_status": "complete",
            "unfinalized_turn_ids": [],
            "unconfirmed_response_ids": [],
            "transcript_rejected_count": 0,
            "playback_rejected_count": 0,
            "journal_unavailable": False,
            **changes,
        },
    )
    assert result.status_code == 200, result.text
    assert result.json()["status"] == "sealed"
    return connection, result.json()


def read(client, scope, completion, **params):
    return client.get(
        base(scope) + "/saved-transcript",
        headers=scope.headers,
        params={"input_revision": 1, "input_hash": completion["input_hash"], **params},
    )


def test_sealed_saved_text_is_read_without_a_review_job(client, scope):
    original = event()
    connection, completion = seal(client, scope, [original])
    response = read(client, scope, completion)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["schema_version"] == "saved_transcript_v1"
    assert data["total_turns"] == 1
    assert data["focus"] is None
    assert data["items"][0] == {
        "ordinal": 1,
        "connection_id": connection["id"],
        "client_instance_id": connection["client_instance_id"],
        "epoch": 1,
        "turn_id": original["turn_id"],
        "turn_index": 1,
        "revision": 1,
        "role": "user",
        "final_text": original["text"],
        "final_source": "final_transcript",
        "playback_status": None,
        "played_text": None,
        "played_revision": None,
    }


def playback(sequence=1, **changes):
    return {
        "event_id": str(uuid4()),
        "sequence": sequence,
        "kind": "alignment",
        "response_id": str(uuid4()),
        "turn_id": str(uuid4()),
        "turn_index": sequence,
        "transcript_revision": 1,
        "generated_text": "Hello, how are you?",
        "transcript_final": True,
        "playback_revision": 1,
        "delivery_status": "partial",
        "played_text": "Hello,",
        "played_until_ms": 250,
        "evidence_source": "device_output_aligned",
        **changes,
    }


def frozen(original, sequence=2, **changes):
    return {
        **original,
        "event_id": str(uuid4()),
        "sequence": sequence,
        "kind": "freeze",
        "reason": "interrupted",
        "stop_boundary_ms": 300,
        **changes,
    }


def test_read_has_fixed_fields_cursors_and_zero_writes(client, scope, factory, monkeypatch):
    from sqlalchemy import text
    from sqlalchemy.orm import Session

    _, completion = seal(client, scope, [event()])
    tables = [
        "practice_sessions",
        "practice_completions",
        "completion_connections",
        "realtime_connections",
        "review_inputs",
        "review_jobs",
        "review_actions",
        "review_attempts",
        "review_results",
    ]

    def state():
        with factory() as db:
            return [
                db.execute(
                    text(f"SELECT row_to_json(t) FROM {table} t ORDER BY row_to_json(t)::text")
                )
                .scalars()
                .all()
                for table in tables
            ]

    before = state()
    monkeypatch.setattr(Session, "commit", lambda _: pytest.fail("GET committed business data"))
    result = read(client, scope, completion)
    assert result.status_code == 200, result.text
    data = result.json()
    assert set(data) == {
        "schema_version",
        "source",
        "evidence_source",
        "account_id",
        "session_id",
        "input_revision",
        "practice_input_hash",
        "sealed_at",
        "coverage",
        "gap_codes",
        "total_turns",
        "offset",
        "limit",
        "previous_offset",
        "next_offset",
        "focus",
        "items",
    }
    assert data["source"] == "server_derived" and data["evidence_source"] == "client_reported"
    assert data["practice_input_hash"] == completion["input_hash"]
    assert data["sealed_at"] == completion["sealed_at"]
    assert data["coverage"] == "complete" and data["gap_codes"] == []
    assert data["offset"] == 0 and data["limit"] == 16
    assert data["previous_offset"] is None and data["next_offset"] is None
    assert result.headers["Cache-Control"] == "no-store"
    assert state() == before


def test_identity_and_seal_binding_fail_closed(client, scope, signup):
    params = {"input_revision": 1, "input_hash": "a" * 64}
    target = base(scope) + "/saved-transcript"
    assert client.get(target, params=params).status_code == 401
    assert read(client, scope, {"input_hash": "a" * 64}).json()["code"] == "completion_not_sealed"
    other = signup("bob")
    assert (
        client.get(
            target, params=params, headers={"Authorization": f"Bearer {other['access_token']}"}
        ).status_code
        == 404
    )
    _, completion = seal(client, scope, [event()])
    result = read(client, scope, completion, input_hash="b" * 64)
    assert result.status_code == 409 and result.json()["code"] == "saved_transcript_changed"
    result = client.get(
        target,
        params={**params, "input_hash": completion["input_hash"]},
        headers=scope.headers | {"X-Account-ID": other["user"]["id"]},
    )
    assert result.status_code == 409


@pytest.mark.parametrize(
    "params",
    [
        {"input_revision": "2"},
        {"input_revision": "true"},
        {"input_revision": "1.0"},
        {"input_revision": "01"},
        {"input_hash": "A" * 64},
        {"input_hash": "a" * 63},
        {"offset": "-1"},
        {"offset": "8193"},
        {"offset": "1.0"},
        {"offset": "01"},
        {"limit": "0"},
        {"limit": "17"},
        {"limit": "true"},
        {"review_item_id": "bad"},
    ],
)
def test_bad_query_is_rejected_without_text(client, scope, params):
    _, completion = seal(client, scope, [event(text="private source")])
    result = read(client, scope, completion, **params)
    assert result.status_code == 422, result.text
    assert "private source" not in result.text


def test_missing_required_query_is_rejected(client, scope):
    for params in [{}, {"input_revision": 1}, {"input_hash": "a" * 64}]:
        assert (
            client.get(
                base(scope) + "/saved-transcript", headers=scope.headers, params=params
            ).status_code
            == 422
        )


def test_pagination_and_empty_latest_revision(client, scope):
    first = event()
    latest = {**first, "event_id": str(uuid4()), "sequence": 2, "revision": 2, "text": ""}
    events = [first, latest, *[event(i, turn_index=i - 1) for i in range(3, 20)]]
    _, completion = seal(client, scope, events)
    result = read(client, scope, completion).json()
    assert result["total_turns"] == 18 and len(result["items"]) == 16
    assert result["items"][0]["final_text"] == "" and result["items"][0]["revision"] == 2
    assert result["next_offset"] == 16
    last = read(client, scope, completion, offset=16).json()
    assert [item["ordinal"] for item in last["items"]] == [17, 18]
    assert last["previous_offset"] == 0 and last["next_offset"] is None
    empty = read(client, scope, completion, offset=18).json()
    assert empty["items"] == [] and empty["previous_offset"] == 2 and empty["next_offset"] is None
    assert read(client, scope, completion, offset=19).status_code == 422


def test_empty_seal_has_only_zero_offset(client, scope):
    _, completion = seal(client, scope)
    data = read(client, scope, completion).json()
    assert data["items"] == [] and data["total_turns"] == 0
    assert data["previous_offset"] is None and data["next_offset"] is None
    assert read(client, scope, completion, offset=1).status_code == 422


@pytest.mark.parametrize(
    "mode",
    [
        "partial",
        "played",
        "not_played",
        "unknown",
        "older",
        "revoked",
        "playback_only",
        "intermediate",
        "zero",
    ],
)
def test_assistant_final_and_safe_playback_are_independent(client, scope, mode):
    row = playback()
    rows = [row]
    final = event(
        role="assistant",
        response_id=row["response_id"],
        turn_id=row["turn_id"],
        text=row["generated_text"],
    )
    transcripts = [final]
    expected_status, expected_played, expected_revision = "partial", row["played_text"], 1
    if mode == "played":
        row.update(delivery_status="played", played_text=row["generated_text"])
        expected_status, expected_played = "played", row["generated_text"]
    elif mode == "not_played":
        row.update(delivery_status="not_played", played_text="", played_until_ms=0)
        expected_status, expected_played, expected_revision = "not_played", None, None
    elif mode == "unknown":
        rows = []
        expected_status, expected_played, expected_revision = "unknown", None, None
    elif mode == "older":
        row["transcript_final"] = False
        rows.append(frozen(row))
        final.update(revision=2, text="An entirely different final suffix.")
    elif mode == "revoked":
        rows += [
            frozen(row),
            {
                "event_id": str(uuid4()),
                "sequence": 3,
                "kind": "revoke",
                "response_id": row["response_id"],
            },
        ]
        expected_status, expected_played, expected_revision = "revoked", None, None
    elif mode == "playback_only":
        transcripts = []
    elif mode == "intermediate":
        row["transcript_final"] = False
        transcripts = []
        expected_status, expected_played, expected_revision = "unknown", None, None
    elif mode == "zero":
        row = frozen(
            row,
            sequence=1,
            transcript_revision=0,
            playback_revision=0,
            generated_text="",
            transcript_final=False,
            delivery_status="unknown",
            played_text="",
            played_until_ms=None,
            evidence_source="unknown",
        )
        rows, transcripts = [row], []
        expected_status, expected_played, expected_revision = "unknown", None, None
    _, completion = seal(client, scope, transcripts, rows)
    response = read(client, scope, completion)
    assert response.status_code == 200, response.text
    item = response.json()["items"][0]
    assert item["playback_status"] == expected_status
    assert item["played_text"] == expected_played and item["played_revision"] == expected_revision
    assert item["final_text"] == (None if mode in {"intermediate", "zero"} else final["text"])
    assert item["final_source"] == (
        None
        if mode in {"intermediate", "zero"}
        else "playback_final"
        if mode == "playback_only"
        else "final_transcript"
    )
    if mode == "zero":
        assert item["revision"] == 0


@pytest.mark.parametrize(
    "mutation",
    [
        "DELETE FROM final_transcripts",
        "UPDATE final_transcripts SET text='changed private text'",
        "UPDATE final_transcripts SET event_digest=repeat('b',64)",
        "UPDATE completion_connections SET snapshot_hash=repeat('b',64)",
        "UPDATE practice_completions SET input_hash=repeat('b',64)",
    ],
)
def test_source_mutation_or_deletion_is_never_rendered(client, scope, factory, mutation):
    from sqlalchemy import text

    _, completion = seal(client, scope, [event(text="private source")])
    with factory.begin() as db:
        db.execute(text(mutation))
    result = read(client, scope, completion)
    assert result.status_code == 409 and result.json()["code"] == "saved_transcript_changed"
    assert "private" not in result.text


def successful_review(client, scope, completion, factory):
    import asyncio

    from simontalk_api.review_gateway import ReviewCapability, ReviewGeneration
    from simontalk_api.review_worker import run_review_batch

    source = client.post(
        base(scope) + "/review-input",
        headers=scope.headers,
        json={"input_revision": 1, "input_hash": completion["input_hash"]},
    ).json()

    class Gateway:
        capability = ReviewCapability("saved-text-test", False)

        async def generate(self, request):
            target = request.targets[-1]
            return ReviewGeneration(
                [
                    {
                        "source_connection_id": target["source_connection_id"],
                        "source_turn_id": target["source_turn_id"],
                        "revision": target["revision"],
                        "exact_quote": target["text"][2:8],
                        "kind": "polish",
                        "basis": "text_only",
                        "explanation": "Optional",
                        "suggestion": "Alternative",
                    }
                ]
            )

    gateway = Gateway()
    # Create deterministically without the background runner consuming this fixture.
    from uuid import UUID

    from simontalk_api.review_jobs import ReviewJobRequest, create_review_job

    with factory() as db:
        create_review_job(
            db,
            UUID(scope.identity["user"]["id"]),
            UUID(scope.session["id"]),
            ReviewJobRequest(
                **{
                    key: source[key]
                    for key in (
                        "input_revision",
                        "practice_input_hash",
                        "review_input_hash",
                        "policy_version",
                    )
                }
            ),
            uuid4(),
            gateway,
        )
    assert asyncio.run(run_review_batch(factory, gateway)) == 1
    result = client.get(base(scope) + "/review", headers=scope.headers).json()
    assert result["status"] == "succeeded", result
    return result


def test_focus_uses_actual_item_and_starts_at_target_then_validates_every_page(
    client, scope, factory
):
    originals = [event(i) for i in range(1, 20)]
    connection, completion = seal(client, scope, originals)
    job = successful_review(client, scope, completion, factory)
    item = job["result"]["items"][0]
    response = read(client, scope, completion, review_item_id=item["id"])
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["offset"] == 18 and data["items"][0]["ordinal"] == 19
    assert data["focus"] == {
        "item_id": item["id"],
        "job_id": job["id"],
        "result_hash": job["result"]["result_hash"],
        "connection_id": connection["id"],
        "turn_id": originals[-1]["turn_id"],
        "revision": 1,
        "exact_quote": originals[-1]["text"][2:8],
        "ordinal": 19,
    }
    other_page = read(client, scope, completion, review_item_id=item["id"], offset=0).json()
    assert other_page["focus"] == data["focus"] and other_page["offset"] == 0
    assert read(client, scope, completion, review_item_id=uuid4()).status_code == 404


@pytest.mark.parametrize(
    "mutation",
    [
        "UPDATE review_results SET result_hash=repeat('b',64)",
        "UPDATE review_jobs SET status='invalidated'",
    ],
)
def test_focus_rejects_invalidated_or_tampered_result(client, scope, factory, mutation):
    from sqlalchemy import text

    _, completion = seal(client, scope, [event()])
    job = successful_review(client, scope, completion, factory)
    with factory.begin() as db:
        db.execute(text(mutation))
    result = read(client, scope, completion, review_item_id=job["result"]["items"][0]["id"])
    assert result.status_code == 409
    assert "English" not in result.text


def test_focus_without_job_is_unknown_item(client, scope):
    _, completion = seal(client, scope, [event()])
    assert read(client, scope, completion, review_item_id=uuid4()).status_code == 404


def test_multiple_epochs_keep_same_turn_uuid_separate_and_focus_exact_connection(
    client, scope, factory
):
    first = event()
    second = event(turn_id=first["turn_id"], text="Another original sentence.")
    old = reserve(client, scope)
    upload(client, scope, old, [first])
    result = client.post(
        base(scope) + f"/connections/{old['id']}/cancel-preparation",
        headers=scope.headers,
        json={"client_instance_id": old["client_instance_id"], "epoch": old["epoch"]},
    )
    assert result.status_code == 200
    current = reserve(client, scope, expected_epoch=1)
    upload(client, scope, current, [second])
    result = client.post(
        base(scope) + f"/connections/{current['id']}/end",
        headers=scope.headers | {"Idempotency-Key": str(uuid4())},
        json={"client_instance_id": current["client_instance_id"], "epoch": 2},
    )
    assert result.status_code == 200
    for connection, original in [(old, first), (current, second)]:
        result = client.post(
            base(scope) + f"/connections/{connection['id']}/completion-manifest",
            headers=scope.headers,
            json={
                "client_instance_id": connection["client_instance_id"],
                "epoch": connection["epoch"],
                "transcripts": ledger([original]),
                "playback": ledger([], playback=True),
                "tail_status": "complete",
                "unfinalized_turn_ids": [],
                "unconfirmed_response_ids": [],
                "transcript_rejected_count": 0,
                "playback_rejected_count": 0,
                "journal_unavailable": False,
            },
        )
        assert result.status_code == 200, result.text
    completion = result.json()
    assert completion["status"] == "sealed"
    page1 = read(client, scope, completion, limit=1).json()
    page2 = read(client, scope, completion, limit=1, offset=1).json()
    assert page1["total_turns"] == page2["total_turns"] == 2
    assert page1["items"][0]["epoch"] == 1 and page2["items"][0]["epoch"] == 2
    assert page1["items"][0]["turn_id"] == page2["items"][0]["turn_id"]
    assert page1["items"][0]["final_text"] == first["text"]
    assert page2["items"][0]["final_text"] == second["text"]
    job = successful_review(client, scope, completion, factory)
    item = job["result"]["items"][0]
    focused = read(client, scope, completion, review_item_id=item["id"]).json()
    assert focused["offset"] == 1 and focused["focus"]["connection_id"] == current["id"]
    assert focused["items"][0]["connection_id"] == current["id"]


@pytest.mark.parametrize(
    "budget,value", [("MAX_MEMBERS", 0), ("MAX_SOURCE_EVENTS", 0), ("MAX_SOURCE_BYTES", 1)]
)
def test_source_budgets_reject_before_materializing_source_rows(
    client, scope, monkeypatch, budget, value
):
    from simontalk_api import review_inputs

    _, completion = seal(client, scope, [event()])
    monkeypatch.setattr(review_inputs, budget, value)
    monkeypatch.setattr(
        review_inputs,
        "_source_row",
        lambda *_: pytest.fail("materialized source before aggregate limit"),
    )
    result = read(client, scope, completion)
    assert result.status_code == 409 and result.json()["code"] == "saved_transcript_limit_exceeded"


def test_response_limit_counts_json_escaping_and_allows_smaller_page(client, scope):
    # Legal source text expands sixfold in JSON; character counts miss the bound.
    events = [event(i, text="\x01" * 8192) for i in range(1, 17)]
    _, completion = seal(client, scope, events)
    result = read(client, scope, completion)
    assert result.status_code == 409 and result.json()["code"] == "saved_transcript_limit_exceeded"
    result = read(client, scope, completion, limit=1)
    assert result.status_code == 200 and len(result.content) <= 512 * 1024
    assert result.json()["items"][0]["final_text"] == events[0]["text"]


@pytest.mark.parametrize(
    "field,value",
    [("exact_quote", "unrelated quote"), ("source_connection_id", str(uuid4())), ("revision", 2)],
)
def test_focus_rechecks_quote_and_scope_after_result_hash_is_recomputed(
    client, scope, factory, field, value
):
    from sqlalchemy import select

    from simontalk_api.models import ReviewResult
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    _, completion = seal(client, scope, [event()])
    job = successful_review(client, scope, completion, factory)
    with factory.begin() as db:
        record = db.scalar(select(ReviewResult))
        snapshot = {**record.snapshot, "items": [{**record.snapshot["items"][0], field: value}]}
        record.snapshot, record.result_hash = snapshot, digest(canonical(snapshot))
    result = read(client, scope, completion, review_item_id=job["result"]["items"][0]["id"])
    assert result.status_code == 409 and result.json()["code"] == "saved_transcript_changed"
    assert "unrelated quote" not in result.text


@pytest.mark.parametrize(
    "mutation",
    [
        "UPDATE practice_completions SET coverage='incomplete'",
        "UPDATE practice_completions SET gap_codes='[\"tail_unconfirmed\"]'::jsonb",
    ],
)
def test_global_coverage_and_gap_summary_must_match_sealed_members(
    client, scope, factory, mutation
):
    from sqlalchemy import text

    _, completion = seal(client, scope, [event()])
    with factory.begin() as db:
        db.execute(text(mutation))
    response = read(client, scope, completion)
    assert response.status_code == 409 and response.json()["code"] == "saved_transcript_changed"
