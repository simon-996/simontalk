"""Real API/SQL/worker composition; supplier HTTP remains explicit MockTransport."""

import asyncio
import json

import httpx
import pytest
from sqlalchemy import select, text
from test_practice_deletion import erase, snapshot
from test_qwen_review_gateway import Parts, envelope, exchange, settings
from test_qwen_review_gateway import module as module
from test_review_inputs import create as create_input
from test_review_jobs import create_job, path, retry
from test_review_worker import batch
from test_saved_transcripts import event, seal
from test_saved_transcripts import scope as scope

from simontalk_api.models import ReviewJob
from simontalk_api.review_worker import claim_review_job, execute_review_job


def input_source(client, scope):
    _, completion = seal(client, scope, [event(text="Yesterday I go to the park.")])
    result = create_input(client, scope, completion)
    assert result.status_code == 200, result.text
    return result.json()


def queue(client, app, scope, gateway):
    source = input_source(client, scope)
    app.state.review_gateway = gateway
    result = create_job(client, scope, source)
    assert result.status_code == 202 and result.json()["status"] == "queued", result.text
    return result.json()


def test_default_api_is_blocked_without_an_attempt_or_http(client, app, scope, factory, module):
    _, calls, _, _ = exchange(module)
    job = create_job(client, scope, input_source(client, scope)).json()
    assert job["status"] == "blocked" and job["attempt_count"] == 0
    assert batch(factory, app.state.review_gateway) == 0 and calls == []


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_candidate_committed_claim_outside_lock_and_exact_result(
    client,
    app,
    scope,
    factory,
    module,
    model,
):
    def inspect_claim():
        with factory.begin() as db:
            job = db.scalar(select(ReviewJob).with_for_update(nowait=True))
            assert job.status == "running" and job.attempt_count == 1

    async def handler(_):
        inspect_claim()
        return httpx.Response(
            200,
            headers={"Content-Type": "application/json"},
            stream=Parts(json.dumps(envelope(model=model)).encode()),
        )

    gateway, calls, _, _ = exchange(module, handler=handler, model=model)
    queued = queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["id"] == queued["id"] and job["status"] == "succeeded"
    item = job["result"]["items"][0]
    assert item["exact_quote"] == "I go" and item["revision"] == 1
    with factory() as db:
        assert db.execute(text("SELECT input_tokens,output_tokens FROM review_attempts")).one() == (
            150,
            40,
        )
    assert batch(factory, gateway) == 0 and len(calls) == 1


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_valid_empty_result_is_no_suggestions(client, app, scope, factory, module, model):
    gateway, calls, _, _ = exchange(
        module, envelope(json.dumps({"suggestions": []}), usage=None, model=model), model=model
    )
    queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "no_suggestions" and job["result"]["items"] == []
    with factory() as db:
        assert db.execute(text("SELECT input_tokens,output_tokens FROM review_attempts")).one() == (
            None,
            None,
        )
    assert len(calls) == 1


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_invalid_quote_is_invalid_output_never_empty_success(
    client, app, scope, factory, module, model
):
    from test_qwen_review_gateway import suggestion

    gateway, calls, _, _ = exchange(
        module,
        envelope(
            json.dumps({"suggestions": [suggestion(exact_quote="invented quote")]}), model=model
        ),
        model=model,
    )
    queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "invalid_output"
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0
    assert batch(factory, gateway) == 0 and len(calls) == 1


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_unknown_is_not_dispatched_again_even_on_explicit_retry(
    client,
    app,
    scope,
    factory,
    module,
    model,
):
    async def handler(_):
        raise httpx.ReadError("private upstream details")

    gateway, calls, _, _ = exchange(module, handler=handler, model=model)
    queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "outcome_unknown"
    assert job["attempt_count"] == 1
    response = retry(client, scope, job)
    assert response.status_code == 202 and response.json()["attempt_count"] == 1
    assert batch(factory, gateway) == 0 and len(calls) == 1
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_attempts")) == 1
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0


def test_explicit_429_is_permanent_without_automatic_retry(client, app, scope, factory, module):
    gateway, calls, _, _ = exchange(module, status=429)
    queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "generation_failed"
    assert batch(factory, gateway) == 0 and len(calls) == 1


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_deleted_source_cannot_be_restored_by_late_candidate_result(
    client,
    app,
    scope,
    factory,
    module,
    model,
):
    async def handler(_):
        current = snapshot(client, scope.session["id"], scope.headers)
        deleted = erase(client, scope.session["id"], scope.headers, current)
        assert deleted.status_code == 200
        return httpx.Response(
            200,
            headers={"Content-Type": "application/json"},
            stream=Parts(json.dumps(envelope(model=model)).encode()),
        )

    gateway, calls, _, _ = exchange(module, handler=handler, model=model)
    queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    assert client.get(path(scope), headers=scope.headers).status_code == 404
    with factory() as db:
        for table in ["review_jobs", "review_inputs", "review_results", "final_transcripts"]:
            assert db.scalar(text(f"SELECT count(*) FROM {table}")) == 0
        assert db.scalar(text("SELECT count(*) FROM practice_deletion_receipts")) == 1
    assert len(calls) == 1 and batch(factory, gateway) == 0


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_changed_candidate_config_blocks_captured_claim_before_http(
    client,
    app,
    scope,
    factory,
    module,
    model,
):
    gateway, calls, _, _ = exchange(module, model=model)
    queue(client, app, scope, gateway)
    claim = claim_review_job(factory, gateway)
    assert claim is not None
    changed = module.QwenReviewGateway(
        settings(module, workspace_id="changed-workspace", model=model),
        client_factory=lambda: (_ for _ in ()).throw(AssertionError("must not create client")),
    )
    assert asyncio.run(execute_review_job(factory, changed, claim))
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "blocked" and job["error_code"] == "gateway_configuration_changed"
    assert calls == []


@pytest.mark.parametrize("choices", [[], None, [{"index": 0, "finish_reason": "stop"}]])
def test_malformed_outer_remains_unknown_after_explicit_retry(
    client, app, scope, factory, module, choices
):
    gateway, calls, _, _ = exchange(module, envelope(choices=choices))
    queue(client, app, scope, gateway)
    assert batch(factory, gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "outcome_unknown"
    assert job["attempt_count"] == 1
    retried = retry(client, scope, job)
    assert retried.status_code == 202 and retried.json()["attempt_count"] == 1
    assert batch(factory, gateway) == 0 and len(calls) == 1
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_attempts")) == 1
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0
