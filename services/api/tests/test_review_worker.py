import asyncio
from uuid import UUID

import pytest
from sqlalchemy import text
from test_connection_reservations import prepared as prepared
from test_review_jobs import create_job, path, ready, retry


class Gateway:
    def __init__(self, *, items=None, idempotent=False, error=None, callback=None):
        from simontalk_api.review_gateway import ReviewCapability

        self.capability = ReviewCapability("test-review-v1", idempotent)
        self.items = items
        self.error = error
        self.callback = callback
        self.calls = []

    async def generate(self, request):
        from simontalk_api.review_gateway import ReviewGeneration

        self.calls.append(request)
        if self.callback:
            await self.callback(request)
        if self.error:
            raise self.error
        items = self.items
        if items is None:
            target = request.targets[0]
            items = [
                {
                    "source_connection_id": target["source_connection_id"],
                    "source_turn_id": target["source_turn_id"],
                    "revision": target["revision"],
                    "exact_quote": target["text"],
                    "kind": "polish",
                    "basis": "text_only",
                    "explanation": "Optional expression",
                    "suggestion": "Alternative.",
                }
            ]
        return ReviewGeneration(items)


def queued(client, app, prepared, gateway):
    app.state.review_gateway = gateway
    return create_job(client, prepared, ready(client, prepared)).json()


def batch(factory, gateway, **kwargs):
    from simontalk_api.review_worker import run_review_batch

    return asyncio.run(run_review_batch(factory, gateway, **kwargs))


def test_success_is_durable_and_safe_payload_has_no_account(client, app, prepared, factory):
    gateway = Gateway()
    job = queued(client, app, prepared, gateway)
    assert job["status"] == "queued"
    assert batch(factory, gateway) == 1
    response = client.get(path(prepared), headers=prepared.headers).json()
    assert response["status"] == "succeeded" and response["attempt_count"] == 1
    result = response["result"]
    assert result["schema_version"] == "review_result_v1" and result["version"] == 1
    assert len(result["items"]) == 1 and result["items"][0]["ordinal"] == 1
    UUID(result["items"][0]["id"])
    assert result["result_hash"] and "account" not in str(gateway.calls[0])
    assert batch(factory, gateway) == 0
    assert client.get(path(prepared), headers=prepared.headers).json() == response
    with factory() as db:
        attempt = db.execute(text("SELECT * FROM review_attempts")).mappings().one()
        assert attempt["outcome"] == "succeeded" and attempt["input_tokens"] is None
        assert attempt["output_tokens"] is None
        assert "Alternative." not in str(attempt)


@pytest.mark.parametrize(
    "items,status", [([], "no_suggestions"), ([{"bad": "response"}], "failed")]
)
def test_zero_suggestions_and_invalid_structure(client, app, prepared, factory, items, status):
    gateway = Gateway(items=items)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    response = client.get(path(prepared), headers=prepared.headers).json()
    assert response["status"] == status
    if status == "failed":
        assert response["result"] is None and response["error_code"] == "invalid_output"


def test_gateway_runs_without_holding_user_lock(client, app, prepared, factory):
    async def callback(request):
        with factory.begin() as db:
            db.execute(text("SET LOCAL lock_timeout = '100ms'"))
            db.execute(text("SELECT id FROM users FOR UPDATE"))
            db.execute(text("SELECT id FROM practice_sessions FOR UPDATE"))

    gateway = Gateway(callback=callback)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    assert client.get(path(prepared), headers=prepared.headers).json()["status"] == "succeeded"


@pytest.mark.parametrize("idempotent", [False, True])
def test_unknown_outcome_requires_verified_idempotency(client, app, prepared, factory, idempotent):
    gateway = Gateway(error=RuntimeError("secret must not persist"), idempotent=idempotent)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    job = client.get(path(prepared), headers=prepared.headers).json()
    assert job["status"] == ("retry_wait" if idempotent else "failed")
    retry(client, prepared, job)
    if idempotent:
        with factory.begin() as db:
            db.execute(text("UPDATE review_jobs SET next_attempt_at=now()-interval '1 second'"))
        batch(factory, gateway)
        assert gateway.calls[0].logical_request_key == gateway.calls[1].logical_request_key
    else:
        assert batch(factory, gateway) == 0
        assert len(gateway.calls) == 1
    with factory() as db:
        assert "secret" not in str(db.execute(text("SELECT * FROM review_attempts")).all())


def test_known_retry_backoff_and_three_attempt_limit(client, app, prepared, factory):
    from simontalk_api.review_gateway import ReviewGatewayError

    gateway = Gateway(error=ReviewGatewayError("temporary_unavailable", retryable=True))
    queued(client, app, prepared, gateway)
    for count in range(1, 4):
        batch(factory, gateway)
        job = client.get(path(prepared), headers=prepared.headers).json()
        assert job["attempt_count"] == count
        assert job["status"] == ("retry_wait" if count < 3 else "failed")
        with factory.begin() as db:
            db.execute(text("UPDATE review_jobs SET next_attempt_at=now()-interval '1 second'"))
    retry(client, prepared, job)
    assert batch(factory, gateway) == 0 and len(gateway.calls) == 3


@pytest.mark.parametrize(
    "mutation",
    [
        "UPDATE users SET disabled_at=now()",
        "UPDATE practice_completions SET input_hash=repeat('b',64)",
        "DELETE FROM practice_sessions",
    ],
)
def test_late_result_never_restores_deleted_changed_or_disabled_source(
    client, app, prepared, factory, mutation
):
    async def callback(request):
        with factory.begin() as db:
            db.execute(text(mutation))

    gateway = Gateway(callback=callback)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0
        attempt = db.execute(text("SELECT * FROM review_attempts")).mappings().one()
        if mutation.startswith("DELETE"):
            assert attempt["job_id"] is None and attempt["source_job_id"]
        else:
            assert db.scalar(text("SELECT status FROM review_jobs")) == "invalidated"


def test_result_hash_and_quotes_are_checked_on_read(client, app, prepared, factory):
    gateway = Gateway()
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    with factory.begin() as db:
        db.execute(text("UPDATE review_results SET result_hash=repeat('b',64)"))
    response = client.get(path(prepared), headers=prepared.headers)
    assert response.status_code == 409 and response.json()["code"] == "review_result_invalid"


def test_claim_fences_old_worker_and_expired_lease(client, app, prepared, factory):
    from simontalk_api.review_gateway import ReviewGeneration
    from simontalk_api.review_worker import claim_review_job, complete_review_job

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    first = claim_review_job(factory, gateway)
    assert first is not None
    assert claim_review_job(factory, gateway) is None
    with factory.begin() as db:
        db.execute(text("UPDATE review_jobs SET lease_expires_at=now()-interval '1 second'"))
    assert complete_review_job(factory, first, generation=ReviewGeneration([])) is False
    batch(factory, gateway)
    assert len(gateway.calls) == 0
    job = client.get(path(prepared), headers=prepared.headers).json()
    assert job["status"] == "failed" and job["attempt_count"] == 1


def test_default_runner_does_not_retry_blocked_on_restart(client, prepared, factory):
    from simontalk_api.review_gateway import UnavailableReviewGateway

    job = create_job(client, prepared, ready(client, prepared)).json()
    assert batch(factory, UnavailableReviewGateway()) == 0
    assert client.get(path(prepared), headers=prepared.headers).json() == job


def test_safe_errors_never_persist_arbitrary_exception_code(client, app, prepared, factory):
    from simontalk_api.review_gateway import ReviewGatewayError

    error = ReviewGatewayError()
    error.code = "SECRET_RAW_ERROR"
    gateway = Gateway(error=error)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    job = client.get(path(prepared), headers=prepared.headers).json()
    assert job["error_code"] == "generation_failed"


def test_two_workers_only_dispatch_once(client, app, prepared, factory):
    from concurrent.futures import ThreadPoolExecutor

    async def delay(request):
        await asyncio.sleep(0.05)

    gateway = Gateway(callback=delay)
    queued(client, app, prepared, gateway)
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sum(pool.map(lambda _: batch(factory, gateway), range(2))) == 1
    assert len(gateway.calls) == 1


def test_timeout_discards_even_cancellation_suppressing_late_result(
    client, app, prepared, factory, monkeypatch
):
    from simontalk_api import review_worker

    monkeypatch.setattr(review_worker, "GENERATE_TIMEOUT_SECONDS", 0.01)

    async def slow(request):
        try:
            await asyncio.sleep(0.1)
        except asyncio.CancelledError:
            await asyncio.sleep(0.02)

    gateway = Gateway(callback=slow)
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    response = client.get(path(prepared), headers=prepared.headers).json()
    assert response["status"] == "failed" and response["outcome_unknown"]
    assert response["result"] is None
    assert retry(client, prepared, response).json()["attempt_count"] == 1
    assert batch(factory, gateway) == 0


def test_expired_verified_attempt_reuses_logical_key_but_rejects_old_fence(
    client, app, prepared, factory
):
    from simontalk_api.review_gateway import ReviewGeneration
    from simontalk_api.review_worker import (
        claim_review_job,
        complete_review_job,
        execute_review_job,
    )

    gateway = Gateway(idempotent=True)
    queued(client, app, prepared, gateway)
    first = claim_review_job(factory, gateway)
    with factory.begin() as db:
        db.execute(text("UPDATE review_jobs SET lease_expires_at=now()-interval '1 second'"))
    assert claim_review_job(factory, gateway) is None
    with factory.begin() as db:
        db.execute(text("UPDATE review_jobs SET next_attempt_at=now()-interval '1 second'"))
    second = claim_review_job(factory, gateway)
    assert first.run_token != second.run_token
    assert first.request.logical_request_key == second.request.logical_request_key
    assert complete_review_job(factory, first, generation=ReviewGeneration([])) is False
    asyncio.run(execute_review_job(factory, gateway, second))
    assert client.get(path(prepared), headers=prepared.headers).json()["attempt_count"] == 2


def test_configuration_change_never_dispatches_another_adapter(client, app, prepared, factory):
    from simontalk_api.review_gateway import ReviewCapability, ReviewGatewayError

    gateway = Gateway(error=ReviewGatewayError())
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    job = client.get(path(prepared), headers=prepared.headers).json()
    gateway.capability = ReviewCapability("different-config", False)
    retried = retry(client, prepared, job).json()
    assert (
        retried["status"] == "blocked" and retried["error_code"] == "gateway_configuration_changed"
    )
    assert batch(factory, gateway) == 0 and len(gateway.calls) == 1


def test_bad_quote_is_rejected_atomically_and_reverified_even_with_valid_hash(
    client, app, prepared, factory
):
    from simontalk_api.models import ReviewResult
    from simontalk_api.practice_completion import canonical
    from simontalk_api.security import digest

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    with factory.begin() as db:
        row = db.query(ReviewResult).one()
        value = dict(row.snapshot)
        value["items"] = [{**value["items"][0], "exact_quote": "forged quote"}]
        row.snapshot, row.result_hash = value, digest(canonical(value))
    assert (
        client.get(path(prepared), headers=prepared.headers).json()["code"]
        == "review_result_invalid"
    )


def test_reported_usage_is_nullable_strict_and_never_fabricated(client, app, prepared, factory):
    from simontalk_api.review_gateway import ReviewGeneration, ReviewUsage

    class Counted(Gateway):
        async def generate(self, request):
            return ReviewGeneration([], ReviewUsage(input_tokens=12, output_tokens=0))

    gateway = Counted()
    queued(client, app, prepared, gateway)
    batch(factory, gateway)
    with factory() as db:
        assert db.execute(text("SELECT input_tokens,output_tokens FROM review_attempts")).one() == (
            12,
            0,
        )
    for value in (-1, True, "12", 2.1):
        with pytest.raises(ValueError):
            ReviewUsage(input_tokens=value)


def test_source_change_before_claim_uses_no_attempt(client, app, prepared, factory):
    gateway = Gateway()
    queued(client, app, prepared, gateway)
    with factory.begin() as db:
        db.execute(text("UPDATE final_transcripts SET text='changed'"))
    assert batch(factory, gateway) == 0
    with factory() as db:
        assert db.scalar(text("SELECT status FROM review_jobs")) == "invalidated"
        assert db.scalar(text("SELECT count(*) FROM review_attempts")) == 0


def test_runner_resumes_persistent_queue_and_stops(client, app, prepared, factory):
    from threading import Event

    from simontalk_api.review_worker import ReviewJobRunner

    finished = Event()

    async def signal(request):
        finished.set()

    gateway = Gateway(callback=signal)
    queued(client, app, prepared, gateway)
    runner = ReviewJobRunner(
        str(factory.kw["bind"].url.render_as_string(hide_password=False)),
        lambda: gateway,
        interval_seconds=0.01,
    )
    runner.start()
    assert finished.wait(3)
    runner.stop()
    assert not runner.running
    assert client.get(path(prepared), headers=prepared.headers).json()["status"] == "succeeded"


@pytest.mark.parametrize("during", ["source", "quote"])
def test_commit_rechecks_lease_after_expensive_source_and_quote_validation(
    client, app, prepared, factory, monkeypatch, during
):
    from datetime import timedelta

    from simontalk_api import review_worker
    from simontalk_api.review_gateway import ReviewGatewayError, ReviewGeneration

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    claim = review_worker.claim_review_job(factory, gateway)
    clock = [review_worker.now()]
    monkeypatch.setattr(review_worker, "now", lambda: clock[0])
    name = "source_for_job" if during == "source" else "validate_review_suggestions"
    original = getattr(review_worker, name)

    def slow(*args, **kwargs):
        result = original(*args, **kwargs)
        clock[0] += timedelta(seconds=16)
        return result

    monkeypatch.setattr(review_worker, name, slow)
    kwargs = (
        {"error": ReviewGatewayError()}
        if during == "source"
        else {"generation": ReviewGeneration([])}
    )
    assert review_worker.complete_review_job(factory, claim, **kwargs) is False
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0
        assert db.scalar(text("SELECT status FROM review_jobs")) == "running"
        assert db.scalar(text("SELECT outcome FROM review_attempts")) == "outcome_unknown"


def test_claim_captures_full_idempotency_capability_before_dispatch(client, app, prepared, factory):
    from simontalk_api.review_gateway import ReviewCapability
    from simontalk_api.review_worker import claim_review_job, execute_review_job

    gateway = Gateway(idempotent=True)
    queued(client, app, prepared, gateway)
    claim = claim_review_job(factory, gateway)
    gateway.capability = ReviewCapability("test-review-v1", False)
    asyncio.run(execute_review_job(factory, gateway, claim))
    assert gateway.calls == []
    with factory() as db:
        assert db.scalar(text("SELECT outcome_unknown FROM review_jobs")) is False


def test_candidate_scan_has_local_database_timeouts(client, app, prepared, factory):
    from concurrent.futures import ThreadPoolExecutor

    from sqlalchemy.exc import OperationalError

    from simontalk_api.review_worker import claim_review_job

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    with ThreadPoolExecutor(max_workers=1) as pool:
        with factory.begin() as db:
            db.execute(text("LOCK TABLE review_jobs IN ACCESS EXCLUSIVE MODE"))
            pending = pool.submit(claim_review_job, factory, gateway)
            with pytest.raises(OperationalError):
                pending.result(timeout=3)


def test_lifespan_stops_media_runner_even_if_review_stop_fails(app, monkeypatch):
    from fastapi.testclient import TestClient

    from simontalk_api import main

    stopped = []

    class ReviewRunner:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            pass

        def stop(self):
            stopped.append("review")
            raise RuntimeError("stop failed")

    class MediaRunner:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            pass

        def stop(self):
            stopped.append("media")

    monkeypatch.setattr(main, "ReviewJobRunner", ReviewRunner)
    monkeypatch.setattr(main, "PracticeMaintenanceRunner", MediaRunner)
    with pytest.raises(RuntimeError), TestClient(app):
        pass
    assert stopped == ["review", "media"]


@pytest.mark.parametrize(
    "mutation",
    [
        "UPDATE review_jobs SET lease_expires_at=now()-interval '1 second'",
        "DELETE FROM practice_sessions",
        "UPDATE users SET disabled_at=now()",
        "UPDATE practice_completions SET input_hash=repeat('b',64)",
        "UPDATE review_jobs SET run_token='a742351a-d6c0-46cb-a878-4606236bda16'",
    ],
)
def test_dispatch_rechecks_claim_source_owner_lease_and_fence(
    client, app, prepared, factory, mutation
):
    from simontalk_api.review_worker import claim_review_job, execute_review_job

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    claim = claim_review_job(factory, gateway)
    with factory.begin() as db:
        db.execute(text(mutation))
    asyncio.run(execute_review_job(factory, gateway, claim))
    assert gateway.calls == []
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_results")) == 0
        assert db.scalar(text("SELECT ordinal FROM review_attempts")) == 1
        if mutation.startswith("DELETE"):
            assert db.scalar(text("SELECT job_id FROM review_attempts")) is None
        else:
            assert db.scalar(text("SELECT attempt_count FROM review_jobs")) == 1


def test_dispatch_rechecks_lease_after_source_validation(
    client, app, prepared, factory, monkeypatch
):
    from datetime import timedelta

    from simontalk_api import review_worker

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    claim = review_worker.claim_review_job(factory, gateway)
    clock = [review_worker.now()]
    monkeypatch.setattr(review_worker, "now", lambda: clock[0])
    original = review_worker.source_for_job

    def slow(*args, **kwargs):
        source = original(*args, **kwargs)
        clock[0] += timedelta(seconds=16)
        return source

    monkeypatch.setattr(review_worker, "source_for_job", slow)
    asyncio.run(review_worker.execute_review_job(factory, gateway, claim))
    assert gateway.calls == []
    with factory() as db:
        assert db.scalar(text("SELECT status FROM review_jobs")) == "running"
        assert db.scalar(text("SELECT outcome FROM review_attempts")) == "outcome_unknown"


def test_claim_checks_stop_between_candidates(client, app, prepared, factory, monkeypatch):
    from threading import Event
    from types import SimpleNamespace
    from uuid import uuid4

    from simontalk_api import review_worker
    from simontalk_api.errors import APIError

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    session = client.post(
        "/v1/practice-sessions",
        headers=prepared.headers | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    ).json()
    second = SimpleNamespace(session=session, headers=prepared.headers, identity=prepared.identity)
    queued(client, app, second, gateway)
    stop = Event()
    calls = []
    original = review_worker.source_for_job

    def stop_first(db, job):
        calls.append(job.id)
        source = original(db, job)
        if len(calls) == 1:
            stop.set()
            raise APIError(409, "review_input_changed", "Source changed")
        return source

    monkeypatch.setattr(review_worker, "source_for_job", stop_first)
    assert review_worker.claim_review_job(factory, gateway, stop=stop) is None
    assert len(calls) == 1
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_attempts")) == 0


def test_stop_after_claim_does_not_dispatch_or_reset_attempt(client, app, prepared, factory):
    from threading import Event

    from simontalk_api.review_worker import claim_review_job, execute_review_job

    gateway = Gateway()
    queued(client, app, prepared, gateway)
    claim = claim_review_job(factory, gateway)
    stop = Event()
    stop.set()
    assert asyncio.run(execute_review_job(factory, gateway, claim, stop=stop)) is False
    assert gateway.calls == []
    with factory() as db:
        assert db.scalar(text("SELECT status FROM review_jobs")) == "running"
        assert db.scalar(text("SELECT attempt_count FROM review_jobs")) == 1
        assert db.scalar(text("SELECT outcome FROM review_attempts")) == "outcome_unknown"
