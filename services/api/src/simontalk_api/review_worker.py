"""Short durable claims, transaction-free generation, and fenced atomic result commits."""

import asyncio
import logging
import math
from dataclasses import dataclass
from datetime import timedelta
from threading import Event, Lock, Thread
from uuid import UUID, uuid4

from sqlalchemy import and_, or_, select, text

from simontalk_api.db import create_database
from simontalk_api.errors import APIError
from simontalk_api.models import PracticeSession, ReviewAttempt, ReviewJob, ReviewResult, User
from simontalk_api.practice_completion import canonical
from simontalk_api.rehearsal_evaluation import review_targets, validate_rehearsal_evaluation
from simontalk_api.review_gateway import (
    ReviewGatewayError,
    ReviewGeneration,
    ReviewRequest,
    ReviewUsage,
    capability,
)
from simontalk_api.review_inputs import validate_review_suggestions
from simontalk_api.review_jobs import GENERATION_POLICY, MAX_ATTEMPTS, binding, now, source_for_job
from simontalk_api.security import digest

logger = logging.getLogger(__name__)
LEASE_SECONDS = 15
GENERATE_TIMEOUT_SECONDS = 8


@dataclass(frozen=True)
class ReviewClaim:
    job_id: UUID
    user_id: UUID
    session_id: UUID
    attempt_id: UUID
    run_token: UUID
    gateway_config_id: str
    gateway_idempotent: bool
    request: ReviewRequest


def _bounded(db):
    db.execute(text("SET LOCAL transaction_timeout = '5s'"))
    db.execute(text("SET LOCAL statement_timeout = '2s'"))
    db.execute(text("SET LOCAL lock_timeout = '100ms'"))


def _locked(db, user_id, session_id, job_id, *, skip=False):
    # Every writer uses owner -> practice -> job, including lease recovery.
    user = db.scalar(select(User).where(User.id == user_id).with_for_update(skip_locked=skip))
    if user is None:
        return None, None
    practice = db.scalar(
        select(PracticeSession.id)
        .where(PracticeSession.id == session_id, PracticeSession.user_id == user_id)
        .with_for_update(skip_locked=skip)
    )
    if practice is None:
        return user, None
    job = db.scalar(
        select(ReviewJob)
        .where(
            ReviewJob.id == job_id, ReviewJob.user_id == user_id, ReviewJob.session_id == session_id
        )
        .with_for_update(skip_locked=skip)
    )
    return user, job


def _clear_lease(job):
    job.run_token = None
    job.lease_expires_at = None
    job.next_attempt_at = None
    job.updated_at = now()


def _unknown(job):
    job.outcome_unknown = True
    job.error_code = "outcome_unknown"
    job.status = (
        "retry_wait"
        if job.gateway_idempotent is True and job.attempt_count < MAX_ATTEMPTS
        else "failed"
    )
    _clear_lease(job)
    if job.status == "retry_wait":
        job.next_attempt_at = now() + timedelta(seconds=2 if job.attempt_count == 1 else 8)


def _invalidate(job):
    job.status, job.error_code = "invalidated", "source_invalidated"
    _clear_lease(job)


def _targets(data):
    return review_targets(data)


def _due(moment):
    return or_(
        ReviewJob.status == "queued",
        and_(ReviewJob.status == "retry_wait", ReviewJob.next_attempt_at <= moment),
        and_(ReviewJob.status == "running", ReviewJob.lease_expires_at <= moment),
    )


def claim_review_job(factory, gateway, *, limit=100, stop=None):
    if type(limit) is not int or not 1 <= limit <= 1000:
        raise ValueError("Invalid review scan limit")
    if stop is not None and stop.is_set():
        return None
    cap = capability(gateway)
    with factory.begin() as db:
        _bounded(db)
        candidates = list(
            db.execute(
                select(ReviewJob.id, ReviewJob.user_id, ReviewJob.session_id)
                .where(_due(now()))
                .order_by(ReviewJob.created_at, ReviewJob.id)
                .limit(limit)
            )
        )
    for job_id, user_id, session_id in candidates:
        if stop is not None and stop.is_set():
            break
        with factory.begin() as db:
            _bounded(db)
            user, job = _locked(db, user_id, session_id, job_id, skip=True)
            if job is None:
                continue
            moment = now()
            if not (
                job.status == "queued"
                or (job.status == "retry_wait" and job.next_attempt_at <= moment)
                or (job.status == "running" and job.lease_expires_at <= moment)
            ):
                continue
            try:
                data = source_for_job(db, job)
            except APIError:
                _invalidate(job)
                continue
            if user.disabled_at is not None:
                _invalidate(job)
                continue
            if job.status == "running":
                attempt = db.scalar(
                    select(ReviewAttempt).where(ReviewAttempt.run_token == job.run_token)
                )
                if attempt:
                    attempt.finished_at = moment
                _unknown(job)
                continue
            if job.attempt_count >= MAX_ATTEMPTS or (
                job.outcome_unknown and job.gateway_idempotent is not True
            ):
                job.status = "failed"
                job.error_code = "outcome_unknown" if job.outcome_unknown else "attempts_exhausted"
                _clear_lease(job)
                continue
            if data["status"] == "no_evaluable_content":
                job.status, job.error_code = "no_evaluable_content", None
                _clear_lease(job)
                continue
            if cap is None:
                job.status, job.error_code = "blocked", "capability_unavailable"
                _clear_lease(job)
                continue
            if job.gateway_config_id is not None and (
                job.gateway_config_id != cap.config_id
                or job.gateway_idempotent != cap.supports_idempotency
            ):
                job.status, job.error_code = "blocked", "gateway_configuration_changed"
                _clear_lease(job)
                continue
            if stop is not None and stop.is_set():
                return None
            job.gateway_config_id, job.gateway_idempotent = cap.config_id, cap.supports_idempotency
            job.attempt_count += 1
            job.status, job.error_code = "running", None
            job.next_attempt_at = None
            job.run_token = uuid4()
            job.lease_expires_at = moment + timedelta(seconds=LEASE_SECONDS)
            job.updated_at = moment
            logical_key = f"review:{job.id}"
            attempt = ReviewAttempt(
                job_id=job.id,
                source_job_id=job.id,
                user_id=user.id,
                review_input_hash=job.review_input_hash,
                ordinal=job.attempt_count,
                run_token=job.run_token,
                logical_request_key=logical_key,
                gateway_config_id=cap.config_id,
                gateway_idempotent=cap.supports_idempotency,
                started_at=moment,
                lease_expires_at=job.lease_expires_at,
            )
            db.add(attempt)
            db.flush()
            claim = ReviewClaim(
                job.id,
                user.id,
                job.session_id,
                attempt.id,
                job.run_token,
                cap.config_id,
                cap.supports_idempotency,
                ReviewRequest(
                    logical_key, GENERATION_POLICY, _targets(data), data["rehearsal_target"]
                ),
            )
        return claim
    return None


def _usage(attempt, generation):
    usage = generation.usage
    if type(usage) is ReviewUsage:
        # Revalidate even forged instances before copying nullable real counters.
        try:
            checked = ReviewUsage(usage.input_tokens, usage.output_tokens)
        except ValueError:
            return
        attempt.input_tokens, attempt.output_tokens = checked.input_tokens, checked.output_tokens


def _within_lease(db, deadline, result=True):
    # Expensive source/quote checks can cross the lease after the entry check.
    # Roll back every mutation (including autoflush) before releasing these locks.
    if deadline <= now():
        db.rollback()
        return False
    return result


def complete_review_job(factory, claim, *, generation=None, error=None):
    with factory.begin() as db:
        _bounded(db)
        user, job = _locked(db, claim.user_id, claim.session_id, claim.job_id)
        if job is None or job.status != "running" or job.run_token != claim.run_token:
            return False
        # A late completion cannot close/replace an expired attempt, even before recovery.
        if job.lease_expires_at <= now():
            return False
        deadline = job.lease_expires_at
        attempt = db.get(ReviewAttempt, claim.attempt_id)
        if attempt is None or attempt.run_token != claim.run_token:
            return False
        try:
            data = source_for_job(db, job)
        except APIError:
            _invalidate(job)
            attempt.finished_at, attempt.outcome = now(), "discarded"
            return _within_lease(db, deadline, False)
        if user.disabled_at is not None:
            _invalidate(job)
            attempt.finished_at, attempt.outcome = now(), "discarded"
            return _within_lease(db, deadline, False)
        attempt.finished_at = now()
        if type(error) is ReviewGatewayError:
            attempt.outcome = "retryable_error" if error.retryable else "permanent_error"
            job.status = (
                "retry_wait" if error.retryable and job.attempt_count < MAX_ATTEMPTS else "failed"
            )
            job.error_code = (
                "temporary_unavailable" if error.retryable is True else "generation_failed"
            )
            if error.code == "gateway_configuration_changed":
                job.status, job.error_code = "blocked", "gateway_configuration_changed"
            _clear_lease(job)
            if job.status == "retry_wait":
                job.next_attempt_at = now() + timedelta(seconds=2 if job.attempt_count == 1 else 8)
            return _within_lease(db, deadline)
        if error is not None:
            _unknown(job)
            return _within_lease(db, deadline)
        if type(generation) is not ReviewGeneration:
            job.status, job.error_code = "failed", "invalid_output"
            attempt.outcome = "invalid_output"
            _clear_lease(job)
            return _within_lease(db, deadline)
        _usage(attempt, generation)
        try:
            suggestions = validate_review_suggestions(
                db, job.user_id, job.session_id, **binding(job), suggestions=generation.suggestions
            )
            evaluation = validate_rehearsal_evaluation(
                generation.rehearsal_evaluation, data["rehearsal_target"], _targets(data)
            )
        except APIError as invalid:
            if invalid.code != "review_suggestions_invalid":
                _invalidate(job)
            else:
                job.status, job.error_code = "failed", "invalid_output"
                _clear_lease(job)
            attempt.outcome = "invalid_output"
            return _within_lease(db, deadline)
        if not _within_lease(db, deadline):
            return False
        snapshot = {
            "schema_version": "review_result_v1",
            "version": 1,
            "job_id": str(job.id),
            **binding(job),
            "generation_policy_version": GENERATION_POLICY,
            "items": [
                {"id": str(uuid4()), "ordinal": index, **item}
                for index, item in enumerate(suggestions, 1)
            ],
        }
        if evaluation is not None:
            snapshot["rehearsal_evaluation"] = evaluation
        db.add(
            ReviewResult(
                job_id=job.id, version=1, snapshot=snapshot, result_hash=digest(canonical(snapshot))
            )
        )
        job.status = "succeeded" if suggestions or evaluation else "no_suggestions"
        job.outcome_unknown, job.error_code = False, None
        attempt.outcome = job.status
        _clear_lease(job)
        return _within_lease(db, deadline)


def _consume(task):
    try:
        task.exception()
    except BaseException:
        pass


def review_dispatch_ready(factory, claim):
    """Recheck a durable claim immediately before releasing text to the gateway.

    The check and external dispatch cannot be atomic across these two systems.
    This transaction has ended before generate starts and never extends the lease.
    """
    with factory.begin() as db:
        _bounded(db)
        user, job = _locked(db, claim.user_id, claim.session_id, claim.job_id)
        if (
            job is None
            or job.status != "running"
            or job.run_token != claim.run_token
            or job.lease_expires_at <= now()
        ):
            return False
        deadline = job.lease_expires_at
        attempt = db.get(ReviewAttempt, claim.attempt_id)
        if (
            attempt is None
            or attempt.job_id != job.id
            or attempt.run_token != claim.run_token
            or attempt.review_input_hash != job.review_input_hash
        ):
            return False
        valid = user.disabled_at is None
        if valid:
            try:
                source_for_job(db, job)
            except APIError:
                valid = False
        if not valid:
            _invalidate(job)
            attempt.finished_at, attempt.outcome = now(), "discarded"
            return _within_lease(db, deadline, False)
        # Full source reconstruction may have consumed the remaining lease.
        return _within_lease(db, deadline)


async def execute_review_job(factory, gateway, claim, *, stop=None):
    if stop is not None and stop.is_set():
        return False
    if not review_dispatch_ready(factory, claim):
        return False
    # A changed adapter must never dispatch a captured claim to a different config.
    cap = capability(gateway)
    if (
        cap is None
        or cap.config_id != claim.gateway_config_id
        or cap.supports_idempotency != claim.gateway_idempotent
    ):
        return complete_review_job(
            factory, claim, error=ReviewGatewayError("gateway_configuration_changed")
        )
    if stop is not None and stop.is_set():
        return False
    task = asyncio.create_task(gateway.generate(claim.request))
    try:
        done, _ = await asyncio.wait({task}, timeout=GENERATE_TIMEOUT_SECONDS)
        if not done:
            task.cancel()
            task.add_done_callback(_consume)
            return complete_review_job(factory, claim, error=TimeoutError())
        try:
            generation = task.result()
        except Exception as error:
            return complete_review_job(factory, claim, error=error)
        return complete_review_job(factory, claim, generation=generation)
    except asyncio.CancelledError:
        task.cancel()
        task.add_done_callback(_consume)
        complete_review_job(factory, claim, error=TimeoutError())
        raise


async def run_review_batch(factory, gateway, *, limit=10, stop=None):
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError("Invalid review batch limit")
    count = 0
    for _ in range(limit):
        if stop is not None and stop.is_set():
            break
        claim = claim_review_job(factory, gateway, stop=stop)
        if claim is None:
            break
        await execute_review_job(factory, gateway, claim, stop=stop)
        count += 1
    return count


class ReviewJobRunner:
    """Private pool and serial async loop; database row locks coordinate API processes."""

    def __init__(self, database_url, gateway, *, interval_seconds=5, limit=5):
        if (
            type(interval_seconds) not in {int, float}
            or not math.isfinite(interval_seconds)
            or not 0.01 <= interval_seconds <= 300
        ):
            raise ValueError("Invalid review interval")
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError("Invalid review batch limit")
        self._engine, self._factory = create_database(database_url)
        self._gateway = gateway
        self._interval, self._limit = interval_seconds, limit
        self._stop, self._guard = Event(), Lock()
        self._thread = None

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        with self._guard:
            if self._thread is not None or self._stop.is_set():
                raise RuntimeError("Review runner already started or closed")
            self._thread = Thread(target=self._run, name="simontalk-review-jobs", daemon=True)
            self._thread.start()

    def stop(self):
        with self._guard:
            self._stop.set()
            thread = self._thread
            if thread is None:
                self._engine.dispose()
                return
        thread.join(timeout=20)
        if thread.is_alive():
            raise RuntimeError("Review runner did not stop within its deadline")

    def _run(self):
        loop = asyncio.new_event_loop()
        try:
            while not self._stop.wait(self._interval):
                try:
                    loop.run_until_complete(
                        run_review_batch(
                            self._factory, self._gateway(), limit=self._limit, stop=self._stop
                        )
                    )
                except Exception:
                    logger.warning("Review job batch failed")
        finally:
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.wait(pending, timeout=0.1))
            loop.close()
            self._engine.dispose()
