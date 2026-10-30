"""Owner-scoped review actions, exact source binding, and verified result reads."""

from datetime import UTC, datetime
from uuid import UUID

from pydantic import Field
from sqlalchemy import select

from simontalk_api.errors import APIError
from simontalk_api.models import ReviewAction, ReviewJob, ReviewResult
from simontalk_api.practice import own_preparation
from simontalk_api.practice_completion import canonical
from simontalk_api.rehearsal_evaluation import review_targets, validate_rehearsal_evaluation
from simontalk_api.review_gateway import capability
from simontalk_api.review_inputs import read_review_input, validate_review_suggestions
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest

GENERATION_POLICY = "review_generation_v1"
MAX_ATTEMPTS = 3
BINDING_FIELDS = ("input_revision", "practice_input_hash", "review_input_hash", "policy_version")


class ReviewJobRequest(InputModel):
    input_revision: int = Field(strict=True, ge=1)
    practice_input_hash: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")
    review_input_hash: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")
    policy_version: str = Field(strict=True, min_length=1, max_length=32)


class ReviewRetryRequest(InputModel):
    job_id: UUID
    expected_attempts: int = Field(strict=True, ge=0, le=3)


def now():
    return datetime.now(UTC)


def binding(job):
    return {key: getattr(job, key) for key in BINDING_FIELDS}


def source_for_job(db, job):
    data = read_review_input(db, job.user_id, job.session_id)
    if any(getattr(job, key) != data[key] for key in BINDING_FIELDS) or (
        job.generation_policy_version != GENERATION_POLICY
    ):
        raise APIError(409, "review_input_changed", "复盘输入依据发生变化。")
    return {**data, "rehearsal_target": rehearsal_target_for_job(db, job)}


def rehearsal_target_for_job(db, job):
    practice = own_preparation(db, job.user_id, job.session_id)
    if practice.kind != "rehearsal":
        return None
    # rehearsal_targets reads ordinary review jobs; keep this import local.
    from simontalk_api.rehearsal_targets import read_child_target

    return read_child_target(db, job.user_id, job.session_id)


def job_query(user_id, session_id):
    return select(ReviewJob).where(
        ReviewJob.user_id == user_id,
        ReviewJob.session_id == session_id,
        ReviewJob.input_revision == 1,
        ReviewJob.policy_version == "review_input_v1",
        ReviewJob.generation_policy_version == GENERATION_POLICY,
    )


def _result(db, job):
    row = db.get(ReviewResult, job.id)
    if job.status not in {"succeeded", "no_suggestions"}:
        return None
    try:
        snapshot = row.snapshot
        expected = {
            "schema_version": "review_result_v1",
            "version": 1,
            "job_id": str(job.id),
            **binding(job),
            "generation_policy_version": GENERATION_POLICY,
        }
        if (
            row.version != 1
            or digest(canonical(snapshot)) != row.result_hash
            or set(snapshot)
            not in (set(expected) | {"items"}, set(expected) | {"items", "rehearsal_evaluation"})
            or any(snapshot.get(key) != value for key, value in expected.items())
        ):
            raise ValueError()
        items = snapshot["items"]
        if type(items) is not list:
            raise ValueError()
        ids = []
        suggestions = []
        for ordinal, item in enumerate(items, 1):
            if item["ordinal"] != ordinal or type(item["ordinal"]) is not int:
                raise ValueError()
            ids.append(str(UUID(item["id"])))
            suggestions.append(
                {key: value for key, value in item.items() if key not in {"id", "ordinal"}}
            )
        data = source_for_job(db, job)
        evaluation = validate_rehearsal_evaluation(
            snapshot.get("rehearsal_evaluation"),
            data["rehearsal_target"],
            review_targets(data),
            required=False,
        )
        if "rehearsal_evaluation" in snapshot and evaluation is None:
            raise ValueError()
        if len(set(ids)) != len(ids) or (job.status == "succeeded") != bool(items or evaluation):
            raise ValueError()
        validate_review_suggestions(
            db, job.user_id, job.session_id, **binding(job), suggestions=suggestions
        )
        return {**snapshot, "result_hash": row.result_hash, "created_at": row.created_at}
    except (AttributeError, KeyError, ValueError, TypeError, APIError):
        raise APIError(409, "review_result_invalid", "复盘结果未通过来源核对。") from None


def summary(db, job):
    return {
        "id": job.id,
        "account_id": job.user_id,
        "session_id": job.session_id,
        **binding(job),
        "generation_policy_version": job.generation_policy_version,
        "status": job.status,
        "attempt_count": job.attempt_count,
        "next_attempt_at": job.next_attempt_at,
        "error_code": job.error_code,
        "outcome_unknown": job.outcome_unknown,
        "created_at": job.created_at,
        "updated_at": job.updated_at,
        "result": _result(db, job),
    }


def _action(db, user_id, key, operation, session_id, payload):
    request_hash = digest(
        canonical(
            {
                "method": "POST",
                "operation": operation,
                "path": f"/v1/practice-sessions/{session_id}/review"
                + ("/retry" if operation == "retry" else ""),
                "body": payload.model_dump(mode="json"),
            }
        )
    )
    existing = db.scalar(
        select(ReviewAction).where(
            ReviewAction.user_id == user_id, ReviewAction.idempotency_key == key
        )
    )
    if existing and (existing.request_digest != request_hash or existing.operation != operation):
        raise APIError(409, "idempotency_conflict", "此请求标识已用于其他操作。")
    return existing, request_hash


def _remember(db, user_id, key, operation, request_hash, job):
    db.add(
        ReviewAction(
            user_id=user_id,
            idempotency_key=key,
            operation=operation,
            request_digest=request_hash,
            job_id=job.id,
        )
    )


def create_review_job(db, user_id, session_id, payload, key, gateway):
    own_preparation(db, user_id, session_id, lock=True)
    existing, request_hash = _action(db, user_id, key, "create", session_id, payload)
    data = read_review_input(db, user_id, session_id)
    if any(getattr(payload, field) != data[field] for field in BINDING_FIELDS):
        raise APIError(409, "review_input_changed", "复盘输入依据发生变化。")
    job = db.scalar(job_query(user_id, session_id).with_for_update())
    if job is not None:
        source_for_job(db, job)
    else:
        cap = capability(gateway)
        empty = data["status"] == "no_evaluable_content"
        job = ReviewJob(
            user_id=user_id,
            session_id=session_id,
            **payload.model_dump(),
            generation_policy_version=GENERATION_POLICY,
            status="no_evaluable_content" if empty else ("queued" if cap else "blocked"),
            error_code=None if empty or cap else "capability_unavailable",
        )
        db.add(job)
        db.flush()
        source_for_job(db, job)
    if existing is None:
        _remember(db, user_id, key, "create", request_hash, job)
    elif existing.job_id != job.id:
        raise APIError(409, "idempotency_conflict", "此请求标识已用于其他操作。")
    result = summary(db, job)
    db.commit()
    return result


def retry_review_job(db, user_id, session_id, payload, key, gateway):
    own_preparation(db, user_id, session_id, lock=True)
    existing, request_hash = _action(db, user_id, key, "retry", session_id, payload)
    job = db.scalar(
        job_query(user_id, session_id).where(ReviewJob.id == payload.job_id).with_for_update()
    )
    if job is None:
        raise APIError(404, "review_job_not_found", "这次练习尚无复盘任务。")
    source_for_job(db, job)
    if existing is None:
        if job.attempt_count != payload.expected_attempts:
            raise APIError(409, "review_retry_changed", "任务尝试次数已变化，请重新读取。")
        if (
            job.status in {"blocked", "failed"}
            and job.attempt_count < MAX_ATTEMPTS
            and not (job.outcome_unknown and job.gateway_idempotent is not True)
        ):
            cap = capability(gateway)
            if cap is None:
                status, code = "blocked", "capability_unavailable"
            elif job.gateway_config_id is not None and (
                job.gateway_config_id != cap.config_id
                or job.gateway_idempotent != cap.supports_idempotency
            ):
                status, code = "blocked", "gateway_configuration_changed"
            else:
                status, code = "queued", None
            if (job.status, job.error_code) != (status, code):
                job.status, job.error_code, job.updated_at = status, code, now()
                job.next_attempt_at = None
        _remember(db, user_id, key, "retry", request_hash, job)
    result = summary(db, job)
    db.commit()
    return result


def read_review_job(db, user_id, session_id):
    own_preparation(db, user_id, session_id)
    job = db.scalar(job_query(user_id, session_id))
    if job is None:
        raise APIError(404, "review_job_not_found", "这次练习尚无复盘任务。")
    source_for_job(db, job)
    return summary(db, job)
