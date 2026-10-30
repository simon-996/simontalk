"""Real sealed review fixtures for owner-scoped rehearsal targets."""

from types import SimpleNamespace

import pytest
from test_saved_transcripts import base, event, seal, successful_review
from test_saved_transcripts import scope as scope


@pytest.fixture
def target_source(client, scope, factory):
    original = event(text="I enjoy English. 我喜欢英语。")
    connection, completion = seal(client, scope, [original])
    job = successful_review(client, scope, completion, factory)
    item = job["result"]["items"][0]
    return SimpleNamespace(
        scope=scope,
        original=original,
        connection=connection,
        completion=completion,
        job=job,
        item=item,
        path=base(scope) + f"/review-items/{item['id']}/rehearsal-target",
    )


def test_real_successful_item_has_frozen_target(client, target_source):
    source = target_source
    result = client.get(source.path, headers=source.scope.headers)
    assert result.status_code == 200, result.text
    data = result.json()
    assert data["schema_version"] == "rehearsal_target_v1"
    assert data["source_text"] == source.original["text"]
    assert data["exact_quote"] == source.item["exact_quote"]
    assert data["source_connection_id"] == source.connection["id"]
    assert data["context_before"] == []


def rows(factory):
    from sqlalchemy import text

    with factory() as db:
        tables = db.scalars(
            text("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
        ).all()
        return {
            table: db.execute(
                text(f'SELECT row_to_json(t) FROM "{table}" t ORDER BY row_to_json(t)::text')
            )
            .scalars()
            .all()
            for table in tables
        }


def test_target_get_is_zero_write_and_has_exact_fields(client, target_source, factory, monkeypatch):
    from sqlalchemy.orm import Session

    source = target_source
    before = rows(factory)
    monkeypatch.setattr(Session, "commit", lambda _: pytest.fail("read committed"))
    response = client.get(source.path, headers=source.scope.headers)
    assert response.status_code == 200
    target = response.json()
    assert set(target) == set(
        (
            "schema_version source evidence_source account_id source_session_id source_kind "
            "item_id job_id result_hash input_revision practice_input_hash review_input_hash "
            "policy_version generation_policy_version source_connection_id "
            "source_client_instance_id source_epoch source_turn_id revision source_text "
            "exact_quote kind basis explanation suggestion situation_mode context_before "
            "target_hash "
        ).split()
    )
    assert response.headers["Cache-Control"] == "no-store"
    assert rows(factory) == before
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    assert target.pop("target_hash") == digest(canonical(target))


def test_source_identity_missing_item_and_ordinary_target(client, target_source, signup):
    from uuid import uuid4

    source = target_source
    assert client.get(source.path).status_code == 401
    bob = signup("bob")
    headers = {"Authorization": f"Bearer {bob['access_token']}"}
    assert client.get(source.path, headers=headers).status_code == 404
    assert (
        client.get(
            source.path, headers=source.scope.headers | {"X-Account-ID": bob["user"]["id"]}
        ).status_code
        == 409
    )
    assert (
        client.get(
            source.path.replace(source.item["id"], str(uuid4())), headers=source.scope.headers
        ).status_code
        == 404
    )
    assert (
        client.get(
            base(source.scope) + "/rehearsal-target", headers=source.scope.headers
        ).status_code
        == 404
    )


@pytest.mark.parametrize(
    "mutation",
    [
        "DELETE FROM final_transcripts",
        "UPDATE final_transcripts SET text='changed'",
        "UPDATE final_transcripts SET event_digest=repeat('b',64)",
        "UPDATE completion_connections SET snapshot_hash=repeat('b',64)",
        "UPDATE practice_completions SET input_hash=repeat('b',64)",
        "UPDATE review_inputs SET review_input_hash=repeat('b',64)",
        "UPDATE review_inputs SET snapshot='{}'::jsonb",
        "UPDATE review_results SET result_hash=repeat('b',64)",
        "UPDATE review_results SET snapshot='{}'::jsonb",
        "DELETE FROM review_results",
        "UPDATE review_jobs SET practice_input_hash=repeat('b',64)",
    ],
)
def test_all_source_mutations_fail_without_body(client, target_source, factory, mutation):
    from sqlalchemy import text

    with factory.begin() as db:
        db.execute(text(mutation))
    response = client.get(target_source.path, headers=target_source.scope.headers)
    assert response.status_code == 409 and response.json()["code"] == "rehearsal_source_changed"
    assert target_source.original["text"] not in response.text


@pytest.mark.parametrize(
    "status", ["queued", "blocked", "retry_wait", "failed", "invalidated", "no_evaluable_content"]
)
def test_non_successful_jobs_conflict(client, target_source, factory, status):
    from sqlalchemy import text

    with factory.begin() as db:
        db.execute(text("UPDATE review_jobs SET status=:status"), {"status": status})
    response = client.get(target_source.path, headers=target_source.scope.headers)
    assert response.status_code == 409 and response.json()["code"] == "rehearsal_source_changed"


def test_no_job_and_valid_empty_result_are_404(client, target_source, factory):
    from uuid import UUID

    from simontalk_api.models import ReviewJob, ReviewResult
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    with factory.begin() as db:
        job = db.get(ReviewJob, UUID(target_source.job["id"]))
        job.status = "no_suggestions"
        result = db.get(ReviewResult, job.id)
        result.snapshot = {**result.snapshot, "items": []}
        result.result_hash = digest(canonical(result.snapshot))
    assert client.get(target_source.path, headers=target_source.scope.headers).status_code == 404
    with factory.begin() as db:
        db.delete(db.get(ReviewJob, UUID(target_source.job["id"])))
    assert client.get(target_source.path, headers=target_source.scope.headers).status_code == 404


def change_suggestion(factory, source, **changes):
    from uuid import UUID

    from simontalk_api.models import ReviewResult
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    with factory.begin() as db:
        result = db.get(ReviewResult, UUID(source.job["id"]))
        result.snapshot = {**result.snapshot, "items": [{**source.item, **changes}]}
        result.result_hash = digest(canonical(result.snapshot))


@pytest.mark.parametrize(
    "field,value,code",
    [
        ("suggestion", "英" * 3000, "rehearsal_target_limit_exceeded"),
        ("explanation", "private\x00text", "rehearsal_source_changed"),
    ],
)
def test_valid_review_strings_still_obey_target_byte_and_nul_limits(
    client, target_source, factory, field, value, code
):
    # PostgreSQL rejects NUL itself, so the NUL branch tests the pure validator.
    if "\x00" in value:
        from simontalk_api.errors import APIError
        from simontalk_api.rehearsal_targets import _validate_text

        with pytest.raises(APIError) as error:
            _validate_text(value)
        assert error.value.code == code
        return
    change_suggestion(factory, target_source, **{field: value})
    response = client.get(target_source.path, headers=target_source.scope.headers)
    assert response.status_code == 409 and response.json()["code"] == code


def test_safe_context_uses_only_played_original_revision(client, scope, factory):
    from test_saved_transcripts import frozen, playback

    assistant = playback(
        generated_text="Hello, secret generated suffix.",
        played_text="Hello,",
        transcript_final=False,
    )
    final = event(
        role="assistant",
        turn_id=assistant["turn_id"],
        response_id=assistant["response_id"],
        revision=2,
        text="Changed final secret.",
    )
    original = event(2, text="I enjoy English.")
    _, completion = seal(client, scope, [final, original], [assistant, frozen(assistant)])
    job = successful_review(client, scope, completion, factory)
    source = SimpleNamespace(item=job["result"]["items"][0], job=job)
    change_suggestion(factory, source, basis="conversation_context")
    path = base(scope) + f"/review-items/{source.item['id']}/rehearsal-target"
    result = client.get(path, headers=scope.headers)
    assert result.status_code == 200, result.text
    context = result.json()["context_before"]
    assert len(context) == 1 and context[0]["text"] == "Hello," and context[0]["revision"] == 1
    assert "secret" not in result.text
    change_suggestion(factory, source, basis="text_only")
    assert client.get(path, headers=scope.headers).json()["context_before"] == []


def test_large_safe_context_is_rejected_without_truncation(client, scope, factory):
    originals = [event(i, text="a" * 8000) for i in range(1, 10)]
    originals.append(event(10))
    _, completion = seal(client, scope, originals)
    job = successful_review(client, scope, completion, factory)
    source = SimpleNamespace(item=job["result"]["items"][0], job=job)
    change_suggestion(factory, source, basis="conversation_context")
    path = base(scope) + f"/review-items/{source.item['id']}/rehearsal-target"
    result = client.get(path, headers=scope.headers)
    assert result.status_code == 409 and result.json()["code"] == "rehearsal_target_limit_exceeded"


def test_invalid_unicode_is_rejected():
    from simontalk_api.rehearsal_targets import _validate_text

    with pytest.raises(UnicodeError):
        _validate_text("\ud800")


@pytest.mark.parametrize(
    "budget,value",
    [
        ("MAX_MEMBERS", 0),
        ("MAX_SOURCE_EVENTS", 0),
        ("MAX_SOURCE_BYTES", 1),
        ("MAX_EXPANDED_BYTES", 1),
    ],
)
def test_existing_source_budgets_are_mapped_and_do_not_return_source(
    client, target_source, monkeypatch, budget, value
):
    from simontalk_api import review_inputs

    monkeypatch.setattr(review_inputs, budget, value)
    result = client.get(target_source.path, headers=target_source.scope.headers)
    assert result.status_code == 409 and result.json()["code"] == "rehearsal_target_limit_exceeded"
    assert "English" not in result.text


def test_source_text_byte_budget_and_read_without_difficulty(client, scope, factory):
    from sqlalchemy import text

    original = event(text="英" * 2730)
    _, completion = seal(client, scope, [original])
    job = successful_review(client, scope, completion, factory)
    with factory.begin() as db:
        db.execute(text("UPDATE user_preferences SET difficulty=NULL"))
    result = client.get(
        base(scope) + f"/review-items/{job['result']['items'][0]['id']}/rehearsal-target",
        headers=scope.headers,
    )
    assert result.status_code == 200, result.text
    assert result.json()["source_text"] == original["text"]


def test_context_budget_counts_actual_escaped_json(client, scope, factory):
    originals = [event(i, text="\x01" * 8000) for i in range(1, 3)] + [event(3)]
    _, completion = seal(client, scope, originals)
    job = successful_review(client, scope, completion, factory)
    source = SimpleNamespace(item=job["result"]["items"][0], job=job)
    change_suggestion(factory, source, basis="conversation_context")
    result = client.get(
        base(scope) + f"/review-items/{source.item['id']}/rehearsal-target", headers=scope.headers
    )
    assert result.status_code == 409 and result.json()["code"] == "rehearsal_target_limit_exceeded"


def test_same_turn_in_two_epochs_uses_exact_source_scope(client, scope, factory):
    from uuid import uuid4

    from test_saved_transcripts import ledger, reserve, upload

    first = event()
    second = event(turn_id=first["turn_id"], text="Another original sentence.")
    old = reserve(client, scope)
    upload(client, scope, old, [first])
    result = client.post(
        base(scope) + f"/connections/{old['id']}/cancel-preparation",
        headers=scope.headers,
        json={"client_instance_id": old["client_instance_id"], "epoch": 1},
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
    for connection, original in ((old, first), (current, second)):
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
        assert result.status_code == 200
    job = successful_review(client, scope, result.json(), factory)
    item = job["result"]["items"][0]
    result = client.get(
        base(scope) + f"/review-items/{item['id']}/rehearsal-target", headers=scope.headers
    )
    assert result.status_code == 200, result.text
    assert result.json()["source_connection_id"] == current["id"]
    assert result.json()["source_epoch"] == 2 and result.json()["source_text"] == second["text"]
