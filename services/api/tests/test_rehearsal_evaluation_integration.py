from types import SimpleNamespace
from uuid import UUID

import pytest
from sqlalchemy import text
from test_rehearsal_preparations import create, release
from test_rehearsal_targets import target_source as target_source
from test_review_inputs import create as create_input
from test_review_jobs import create_job, path
from test_review_worker import batch
from test_saved_transcripts import base, event, seal
from test_saved_transcripts import scope as scope

from simontalk_api.models import ReviewJob, ReviewResult
from simontalk_api.review_gateway import ReviewCapability, ReviewGeneration


@pytest.fixture
def child(client, target_source, factory):
    source = target_source
    target = client.get(source.path, headers=source.scope.headers).json()
    release(factory, source)
    response = create(client, source, target["target_hash"])
    assert response.status_code == 201, response.text
    return SimpleNamespace(
        headers=source.scope.headers,
        session=response.json()["practice"],
        target=target,
        parent=source,
        identity=source.scope.identity,
    )


class Gateway:
    capability = ReviewCapability("rehearsal-test", False)

    def __init__(self, *, missing=False):
        self.missing = missing
        self.calls = []

    async def generate(self, request):
        self.calls.append(request)
        if self.missing:
            return ReviewGeneration([])
        target = request.targets[0]
        evidence = {
            key: target[key] for key in ("source_connection_id", "source_turn_id", "revision")
        }
        evidence["exact_quote"] = target["text"]
        return ReviewGeneration(
            [],
            rehearsal_evaluation={
                "schema_version": "rehearsal_evaluation_v1",
                "target_hash": request.rehearsal_target["target_hash"],
                "intent": {
                    "status": "conveyed",
                    "explanation": "原意已表达",
                    "evidence": [evidence],
                },
                "target_issue": {
                    "status": "demonstrated",
                    "explanation": "已展示改善",
                    "evidence": [evidence],
                },
            },
        )


def queue(client, app, child, *, events=None, gateway=None):
    _, completion = seal(
        client, child, [event(text="I enjoy learning English.")] if events is None else events
    )
    source = create_input(client, child, completion)
    assert source.status_code == 200, source.text
    gateway = gateway or Gateway()
    app.state.review_gateway = gateway
    job = create_job(client, child, source.json())
    assert job.status_code == 202, job.text
    return gateway, job.json()


def test_zero_suggestions_with_evaluation_is_succeeded_and_durable(client, app, child, factory):
    gateway, _ = queue(client, app, child)
    assert batch(factory, gateway) == 1
    response = client.get(path(child), headers=child.headers)
    assert response.status_code == 200, response.text
    job = response.json()
    assert job["status"] == "succeeded", job
    assert job["result"]["items"] == []
    assert job["result"]["rehearsal_evaluation"]["target_hash"] == child.target["target_hash"]
    assert gateway.calls[0].rehearsal_target == child.target
    assert client.get(path(child), headers=child.headers).json() == job
    assert batch(factory, gateway) == 0


def test_missing_evaluation_fails_new_child_but_empty_input_calls_zero(client, app, child, factory):
    gateway, _ = queue(client, app, child, gateway=Gateway(missing=True))
    batch(factory, gateway)
    job = client.get(path(child), headers=child.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "invalid_output"


def test_child_no_evaluable_content_is_zero_call(client, app, child, factory):
    gateway, job = queue(client, app, child, events=[])
    assert job["status"] == "no_evaluable_content"
    assert batch(factory, gateway) == 0 and gateway.calls == []


@pytest.mark.parametrize("stage", ["claim", "dispatch", "complete", "read"])
def test_parent_invalidated_at_every_boundary_with_child_history_preserved(
    client, app, child, factory, stage
):
    import asyncio

    from simontalk_api.review_worker import (
        claim_review_job,
        complete_review_job,
        review_dispatch_ready,
    )

    gateway, _ = queue(client, app, child)
    claim = None
    if stage != "claim":
        claim = claim_review_job(factory, gateway)
        assert claim is not None
    if stage == "read":
        assert complete_review_job(
            factory, claim, generation=asyncio.run(gateway.generate(claim.request))
        )
    with factory.begin() as db:
        db.execute(
            text("UPDATE review_results SET result_hash=repeat('b',64) WHERE job_id=:id"),
            {"id": child.parent.job["id"]},
        )
    if stage == "claim":
        assert claim_review_job(factory, gateway) is None
    elif stage == "dispatch":
        assert review_dispatch_ready(factory, claim) is False
    elif stage == "complete":
        assert complete_review_job(factory, claim, generation=ReviewGeneration([])) is False
    response = client.get(path(child), headers=child.headers)
    assert response.status_code == 409
    assert "rehearsal_evaluation" not in response.text
    history = client.get(base(child), headers=child.headers)
    assert history.status_code == 200, history.text


def test_legacy_child_result_without_extension_still_reads(client, app, child, factory):
    gateway, job = queue(client, app, child)
    batch(factory, gateway)
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    with factory.begin() as db:
        row = db.get(ReviewResult, UUID(job["id"]))
        assert row is not None
        snapshot = dict(row.snapshot)
        snapshot.pop("rehearsal_evaluation")
        row.snapshot, row.result_hash = snapshot, digest(canonical(snapshot))
        db.get(ReviewJob, UUID(job["id"])).status = "no_suggestions"
    response = client.get(path(child), headers=child.headers)
    assert response.status_code == 200, response.text
    assert "rehearsal_evaluation" not in response.json()["result"]


@pytest.mark.parametrize("mutation", ["hash", "revision", "quote", "extra", "null"])
def test_rehashed_result_extension_still_must_pass_current_evidence(
    client, app, child, factory, mutation
):
    from copy import deepcopy

    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    gateway, job = queue(client, app, child)
    batch(factory, gateway)
    with factory.begin() as db:
        row = db.get(ReviewResult, UUID(job["id"]))
        snapshot = deepcopy(row.snapshot)
        evaluation = snapshot["rehearsal_evaluation"]
        if mutation == "hash":
            evaluation["target_hash"] = "b" * 64
        elif mutation == "revision":
            evaluation["intent"]["evidence"][0]["revision"] = 2
        elif mutation == "quote":
            evaluation["intent"]["evidence"][0]["exact_quote"] = child.target["source_text"]
        elif mutation == "extra":
            evaluation["intent"]["extra"] = "ignored?"
        else:
            snapshot["rehearsal_evaluation"] = None
        row.snapshot, row.result_hash = snapshot, digest(canonical(snapshot))
    response = client.get(path(child), headers=child.headers)
    assert response.status_code == 409 and response.json()["code"] == "review_result_invalid"


def test_ordinary_worker_cannot_persist_evaluation(client, app, scope, factory):
    from test_rehearsal_evaluation import fixtures

    class OrdinaryGateway:
        capability = ReviewCapability("ordinary-eval-test", False)

        async def generate(self, request):
            return ReviewGeneration([], rehearsal_evaluation=fixtures()[2])

    gateway, _ = queue(client, app, scope, gateway=OrdinaryGateway())
    batch(factory, gateway)
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "invalid_output"


def test_result_hash_covers_evaluation(client, app, child, factory):
    from copy import deepcopy

    gateway, job = queue(client, app, child)
    batch(factory, gateway)
    with factory.begin() as db:
        row = db.get(ReviewResult, UUID(job["id"]))
        snapshot = deepcopy(row.snapshot)
        snapshot["rehearsal_evaluation"]["intent"]["explanation"] = "Changed"
        row.snapshot = snapshot
    assert client.get(path(child), headers=child.headers).json()["code"] == "review_result_invalid"


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_qwen_child_full_http_boundary_worker_and_pure_read(
    client, app, child, factory, monkeypatch, model
):
    import importlib
    import json

    from sqlalchemy.orm import Session
    from test_qwen_rehearsal_evaluation import output
    from test_qwen_review_gateway import envelope, exchange
    from test_rehearsal_targets import rows

    module = importlib.import_module("simontalk_api.qwen_review_gateway")
    value = output()
    for name in ("intent", "target_issue"):
        value["rehearsal_evaluation"][name]["evidence"][0]["exact_quote"] = "I enjoy"
    gateway, calls, _, _ = exchange(module, envelope(json.dumps(value), model=model), model=model)
    _, queued = queue(client, app, child, gateway=gateway)
    assert batch(factory, gateway) == 1 and len(calls) == 1
    with factory() as db:
        attempt = db.execute(
            text("SELECT input_tokens,output_tokens FROM review_attempts WHERE job_id=:id"),
            {"id": queued["id"]},
        ).one()
        assert attempt == (150, 40)
    before = rows(factory)
    monkeypatch.setattr(Session, "commit", lambda _: pytest.fail("read committed"))
    response = client.get(path(child), headers=child.headers)
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "succeeded"
    assert (
        response.json()["result"]["rehearsal_evaluation"]["intent"]["evidence"][0]["exact_quote"]
        == "I enjoy"
    )
    assert rows(factory) == before
