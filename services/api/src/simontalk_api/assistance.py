"""Live assistance based on the caller's acknowledged final user turns."""

import asyncio
import json
import re
from dataclasses import dataclass
from datetime import timedelta
from typing import Literal
from uuid import UUID

from pydantic import Field
from sqlalchemy import func, or_, select, text, update

from simontalk_api.connections import own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import (
    AssistanceAction,
    AssistanceAttempt,
    AssistanceJob,
    AuthSession,
    FinalTranscript,
    User,
)
from simontalk_api.practice import own_preparation
from simontalk_api.practice_topics import practice_topic
from simontalk_api.review_gateway import ReviewGatewayError, ReviewUsage
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest, now

AssistanceKind = Literal["english_starter", "translation"]
MAX_TRANSLATION_SOURCE_LENGTH = 400
_MAX_ATTEMPTS = 2
_MAX_ACTION_KEYS = 32


class AssistanceScope(InputModel):
    connection_id: UUID
    epoch: int = Field(strict=True, ge=1, le=2147483647)


@dataclass(frozen=True, slots=True)
class AssistanceTarget:
    kind: AssistanceKind = "english_starter"
    turn_id: UUID | None = None
    turn_revision: int | None = None


def _target(job):
    return AssistanceTarget(job.kind, job.source_turn_id, job.source_turn_revision)


@dataclass(frozen=True, slots=True)
class StarterContext:
    difficulty: str
    topic: str | None
    turns: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class StarterGeneration:
    starter: str | None
    usage: ReviewUsage | None = None


@dataclass(frozen=True, slots=True)
class TranslationContext:
    text: str


@dataclass(frozen=True, slots=True)
class TranslationGeneration:
    translation: str | None
    usage: ReviewUsage | None = None


def starter_text(value):
    if (
        type(value) is str
        and 2 <= len(value) <= 160
        and value == value.strip()
        and all(character.isprintable() for character in value)
        and re.search(r"[A-Za-z]{2}", value)
        and not re.search(r"[<>]", value)
    ):
        return value
    return None


def _hash(value):
    return digest(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def translation_text(value):
    if (
        type(value) is str
        and 1 <= len(value) <= 240
        and value == value.strip()
        and all(character.isprintable() for character in value)
        and re.search(r"[\u3400-\u9fff]", value)
        and not re.search(r"[<>]", value)
    ):
        return value
    return None


def context(db, user_id, session_id, connection_id, epoch, *, target, lock=False):
    practice = own_preparation(db, user_id, session_id, lock=lock)
    connection = own_connection(db, user_id, session_id, connection_id, lock=lock)
    if (
        practice.status not in {"connecting", "active"}
        or practice.connection_epoch != epoch
        or connection.epoch != epoch
        or connection.status not in {"configuring", "ready"}
        or connection.signalling_finished_at is None
        or connection.lease_expires_at <= now()
    ):
        raise APIError(409, "assistance_context_unavailable", "当前通话已变化，无法生成提示。")
    if target.kind == "translation":
        return _translation_context(db, user_id, session_id, connection_id, epoch, target)
    if target.turn_id is not None or target.turn_revision is not None:
        raise APIError(422, "invalid_assistance_selection", "英文开头无需指定话轮。")
    topic = practice_topic(practice)
    difficulty = practice.configuration.get("effective_difficulty")
    if difficulty not in ("beginner", "intermediate", "advanced"):
        raise APIError(409, "assistance_context_unavailable", "当前练习缺少可用的提示配置。")
    t = FinalTranscript
    latest = (
        select(
            t.turn_index,
            t.event_digest,
            t.text,
            func.row_number()
            .over(
                partition_by=t.turn_id,
                order_by=t.revision.desc(),
            )
            .label("position"),
        )
        .where(t.connection_id == connection_id, t.epoch == epoch, t.role == "user")
        .subquery()
    )
    # Empty revisions suppress older text from that turn.
    rows = list(
        db.execute(
            select(latest)
            .where(latest.c.position == 1)
            .order_by(latest.c.turn_index.desc())
            .limit(2)
        )
    )[::-1]
    revision = _hash(
        [
            "english_starter_v1",
            str(user_id),
            str(session_id),
            str(connection_id),
            epoch,
            difficulty,
            topic.id if topic else None,
            topic.prompt if topic else None,
            [row.event_digest for row in rows],
        ]
    )
    return revision, StarterContext(
        difficulty,
        topic.prompt if topic else None,
        tuple(row.text.strip()[:400] for row in rows if row.text.strip()),
    )


def _translation_context(db, user_id, session_id, connection_id, epoch, target):
    if target.turn_id is None or target.turn_revision is None:
        raise APIError(422, "invalid_assistance_selection", "请选择一条已确认的英文话轮。")
    t = FinalTranscript
    row = db.execute(
        select(t.revision, t.event_digest, t.text)
        .where(t.connection_id == connection_id, t.epoch == epoch, t.turn_id == target.turn_id)
        .order_by(t.revision.desc())
        .limit(1)
    ).first()
    if row is None or row.revision != target.turn_revision:
        raise APIError(409, "assistance_context_changed", "这条话轮尚未确认或已修订。")
    original = row.text.strip()
    if len(original) > MAX_TRANSLATION_SOURCE_LENGTH or not re.search(r"[A-Za-z]{2}", original):
        raise APIError(422, "invalid_assistance_selection", "这条文字无法作为逐句翻译的输入。")
    revision = _hash(
        [
            "translation_v1",
            str(user_id),
            str(session_id),
            str(connection_id),
            epoch,
            str(target.turn_id),
            target.turn_revision,
            row.event_digest,
        ]
    )
    return revision, TranslationContext(original)


def _matches(job, revision):
    if job.input_revision != revision:
        raise APIError(409, "assistance_context_changed", "对话已有新内容，请重新请求提示。")


def _job(db, user_id, session_id, job_id):
    job = db.get(AssistanceJob, job_id)
    if job is None or job.user_id != user_id or job.session_id != session_id:
        raise APIError(404, "assistance_not_found", "没有找到这条提示请求。")
    return job


def find_current_job(db, user_id, session_id, kind, revision):
    return db.scalar(
        select(AssistanceJob).where(
            AssistanceJob.session_id == session_id,
            AssistanceJob.user_id == user_id,
            AssistanceJob.kind == kind,
            AssistanceJob.input_revision == revision,
        )
    )


def gateway_binding(gateway, kind):
    field = "translation_binding" if kind == "translation" else "assistance_binding"
    return getattr(gateway, field, None)


def summary(job, gateway):
    return {
        "id": job.id,
        "account_id": job.user_id,
        "session_id": job.session_id,
        "connection_id": job.connection_id,
        "epoch": job.epoch,
        "kind": job.kind,
        "input_revision": job.input_revision,
        "status": job.status,
        **(
            {"starter": job.result}
            if job.kind == "english_starter"
            else {
                "translation": job.result,
                "source_turn_id": job.source_turn_id,
                "source_turn_revision": job.source_turn_revision,
            }
        ),
        "attempt_count": job.attempt_count,
        "can_retry": (
            job.status == "failed"
            and job.attempt_count < _MAX_ATTEMPTS
            and gateway_binding(gateway, job.kind) == job.config_id
        ),
    }


def submit(db, user_id, session_id, payload, key, gateway, *, auth_session_id, retry_id=None):
    revision, _ = context(
        db,
        user_id,
        session_id,
        payload.connection_id,
        payload.epoch,
        lock=True,
        target=payload.target,
    )
    fingerprint = _hash(
        [str(session_id), str(retry_id), payload.model_dump(mode="json", exclude_none=True)]
    )
    action = db.get(AssistanceAction, (user_id, key))
    if action is not None:
        if action.request_hash != fingerprint:
            raise APIError(409, "idempotency_conflict", "该请求标识已用于其他提示。")
        job = _job(db, user_id, session_id, action.job_id)
        _matches(job, revision)
        return summary(job, gateway)
    if revision != payload.input_revision:
        raise APIError(409, "assistance_context_changed", "对话已有新内容，请重新请求提示。")
    if retry_id is not None:
        job = _job(db, user_id, session_id, retry_id)
        _matches(job, revision)
        if not summary(job, gateway)["can_retry"] or job.attempt_count != payload.attempt_count:
            raise APIError(409, "assistance_retry_unavailable", "这条提示目前不能重试。")
        job.status, job.deadline = "queued", now() + timedelta(seconds=30)
        job.auth_session_id = auth_session_id
    else:
        job = find_current_job(db, user_id, session_id, payload.kind, revision)
        if job is None:
            binding = gateway_binding(gateway, payload.kind)
            if binding is None:
                raise APIError(503, "assistance_unavailable", "英文开头服务暂不可用。")
            stamp = now()
            job = AssistanceJob(
                user_id=user_id,
                auth_session_id=auth_session_id,
                session_id=session_id,
                connection_id=payload.connection_id,
                epoch=payload.epoch,
                kind=payload.kind,
                source_turn_id=payload.source_turn_id,
                source_turn_revision=payload.source_turn_revision,
                input_revision=revision,
                config_id=binding,
                status="queued",
                attempt_count=0,
                deadline=stamp + timedelta(seconds=30),
                created_at=stamp,
            )
            db.add(job)
            db.flush()
    action_count = db.scalar(select(func.count()).where(AssistanceAction.job_id == job.id))
    if action_count >= _MAX_ACTION_KEYS:
        raise APIError(429, "assistance_action_limit", "这条辅助请求的确认次数已达上限。")
    db.add(AssistanceAction(user_id=user_id, key=key, job_id=job.id, request_hash=fingerprint))
    db.commit()
    return summary(job, gateway)


def read(db, user_id, session_id, job_id, gateway):
    # Verify practice ownership before looking up any job.
    own_preparation(db, user_id, session_id)
    job = _job(db, user_id, session_id, job_id)
    revision, _ = context(
        db, user_id, session_id, job.connection_id, job.epoch, target=_target(job)
    )
    _matches(job, revision)
    return summary(job, gateway)


def _owner_lock(db, user_id, *, skip=False):
    db.execute(text("SET LOCAL lock_timeout = '150ms'"))
    return db.scalar(select(User).where(User.id == user_id).with_for_update(skip_locked=skip))


def _is_authorized(db, job, user, stamp):
    auth = db.get(AuthSession, job.auth_session_id)
    return (
        user.disabled_at is None
        and auth is not None
        and auth.user_id == user.id
        and auth.expires_at > stamp
        and auth.revoked_at is None
    )


def _claim(factory, gateway):
    with factory() as db:
        candidates = db.execute(
            select(AssistanceJob.id, AssistanceJob.user_id, AssistanceJob.session_id)
            .where(
                or_(
                    AssistanceJob.status == "queued",
                    (AssistanceJob.status == "running") & (AssistanceJob.deadline <= now()),
                )
            )
            .order_by(AssistanceJob.deadline, AssistanceJob.id)
            .limit(16)
        ).all()
    for candidate in candidates:
        with factory.begin() as db:
            user = _owner_lock(db, candidate.user_id, skip=True)
            if user is None:
                continue
            j = db.get(AssistanceJob, candidate.id)
            if j is None:
                continue
            stamp = now()
            if j.status == "running" and j.deadline <= stamp:
                attempt = db.get(AssistanceAttempt, (j.id, j.attempt_count))
                if attempt is None:
                    j.status = "failed"
                    j.attempt_count -= 1
                else:
                    j.status = "unknown"
                    attempt.finished_at = stamp
            if j.status != "queued":
                continue
            if not _is_authorized(db, j, user, stamp):
                j.status = "expired"
                continue
            if j.deadline <= stamp:
                j.status = "failed"
                continue
            try:
                revision, _ = context(
                    db,
                    j.user_id,
                    j.session_id,
                    j.connection_id,
                    j.epoch,
                    lock=True,
                    target=_target(j),
                )
                _matches(j, revision)
            except APIError:
                j.status = "expired"
                continue
            if gateway_binding(gateway, j.kind) != j.config_id:
                j.status = "expired"
                continue
            j.status, j.deadline = "running", stamp + timedelta(seconds=15)
            j.attempt_count += 1
            return j.id, j.user_id, j.attempt_count
    return None


def _dispatch(factory, claim, gateway, stop):
    job_id, user_id, number = claim
    with factory.begin() as db:
        user = _owner_lock(db, user_id)
        job = db.get(AssistanceJob, job_id)
        if user is None or job is None or job.status != "running" or job.attempt_count != number:
            return None
        try:
            revision, source = context(
                db,
                user_id,
                job.session_id,
                job.connection_id,
                job.epoch,
                lock=True,
                target=_target(job),
            )
            _matches(job, revision)
        except APIError:
            job.status = "expired"
            job.attempt_count -= 1
            return None
        stamp = now()
        if (
            not _is_authorized(db, job, user, stamp)
            or gateway_binding(gateway, job.kind) != job.config_id
        ):
            job.status = "expired"
            job.attempt_count -= 1
            return None
        if stamp >= job.deadline or stop is not None and stop.is_set():
            job.status = "failed"
            job.attempt_count -= 1
            return None
        db.add(AssistanceAttempt(job_id=job_id, number=number, started_at=stamp))
        return source


def _cancel_dispatch(factory, claim):
    job_id, user_id, number = claim
    with factory.begin() as db:
        if _owner_lock(db, user_id) is None:
            return
        job = db.get(AssistanceJob, job_id)
        attempt = db.get(AssistanceAttempt, (job_id, number))
        if attempt is not None:
            db.delete(attempt)
        if job is not None and job.status == "running" and job.attempt_count == number:
            job.status = "failed"
            job.attempt_count -= 1


def _finish(factory, claim, status, generation):
    job_id, user_id, number = claim
    with factory.begin() as db:
        user = _owner_lock(db, user_id)
        if user is None:
            return
        job = db.get(AssistanceJob, job_id)
        attempt = db.get(AssistanceAttempt, (job_id, number))
        if job is None or attempt is None:
            return
        attempt.finished_at = attempt.finished_at or now()
        usage = (
            generation.usage
            if type(generation) in {StarterGeneration, TranslationGeneration}
            else None
        )
        if type(usage) is ReviewUsage:
            attempt.input_tokens, attempt.output_tokens = usage.input_tokens, usage.output_tokens
        if job.status != "running" or job.attempt_count != number:
            return
        if job.deadline <= now():
            job.status = "unknown"
            return
        try:
            revision, _ = context(
                db,
                user_id,
                job.session_id,
                job.connection_id,
                job.epoch,
                lock=True,
                target=_target(job),
            )
            _matches(job, revision)
        except APIError:
            job.status = "expired"
            return
        if not _is_authorized(db, job, user, now()):
            job.status = "expired"
            return
        result = None
        if job.kind == "english_starter" and type(generation) is StarterGeneration:
            result = starter_text(generation.starter)
        if job.kind == "translation" and type(generation) is TranslationGeneration:
            result = translation_text(generation.translation)
        db.execute(
            update(AssistanceJob)
            .where(AssistanceJob.id == job_id, AssistanceJob.deadline > func.clock_timestamp())
            .values(result=result, status="succeeded" if result is not None else status)
        )


async def run_assistance_batch(factory, gateway, *, limit=5, stop=None):
    for _ in range(limit):
        if stop is not None and stop.is_set():
            return
        claim = _claim(factory, gateway)
        if claim is None:
            return
        source = _dispatch(factory, claim, gateway, stop)
        if source is None:
            continue
        if stop is not None and stop.is_set():
            _cancel_dispatch(factory, claim)
            return
        generation, status = None, "failed"
        try:
            async with asyncio.timeout(8):
                generation = (
                    await gateway.translate_turn(source)
                    if type(source) is TranslationContext
                    else await gateway.english_starter(source)
                )
        except ReviewGatewayError:
            pass
        except Exception:
            status = "unknown"
        _finish(factory, claim, status, generation)
