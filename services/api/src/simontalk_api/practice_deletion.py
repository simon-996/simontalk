"""Atomic content erasure; deletion is never evidence of upstream termination."""

from pydantic import Field
from sqlalchemy import delete, or_, select

from simontalk_api.errors import APIError
from simontalk_api.models import (
    OCCUPIED_CONNECTION_STATES,
    ConnectionObservation,
    FinalTranscript,
    PlaybackEvidence,
    PracticeCompletion,
    PracticeDeletionReceipt,
    PracticeSession,
    RealtimeConnection,
    ReviewInput,
)
from simontalk_api.practice_completion import canonical
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest, now
from simontalk_api.termination_checks import ensure_termination_check


class DeletionInput(InputModel):
    scope_version: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")


def _missing():
    raise APIError(404, "practice_not_found", "没有找到这次练习。")


def _members(db, user_id, session_id, *, lock=False):
    q = (
        select(PracticeSession)
        .where(
            PracticeSession.user_id == user_id,
            PracticeSession.deleted_at.is_(None),
            or_(PracticeSession.id == session_id, PracticeSession.source_session_id == session_id),
        )
        .order_by(PracticeSession.id)
    )
    if lock:
        q = q.with_for_update().execution_options(populate_existing=True)
    members = list(db.scalars(q))
    root = next((r for r in members if r.id == session_id), None)
    if root is None:
        _missing()
    return root, members


def _version(session_id, members):
    return digest(
        canonical(
            {
                "target": str(session_id),
                "members": [
                    {
                        "id": str(r.id),
                        "kind": r.kind,
                        "parent": str(r.source_session_id) if r.source_session_id else None,
                    }
                    for r in members
                ],
            }
        )
    )


def _pending(db, user_id, ids):
    return (
        db.scalar(
            select(RealtimeConnection.id)
            .where(
                RealtimeConnection.user_id == user_id,
                RealtimeConnection.session_id.in_(ids),
                or_(
                    RealtimeConnection.status.in_(OCCUPIED_CONNECTION_STATES),
                    RealtimeConnection.termination_status == "unknown",
                ),
            )
            .limit(1)
        )
        is not None
    )


def read_scope(db, user_id, session_id):
    root, members = _members(db, user_id, session_id)
    return {
        "schema_version": "practice_deletion_scope_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "session_id": session_id,
        "kind": root.kind,
        "record_count": len(members),
        "rehearsal_count": sum(r.kind == "rehearsal" for r in members),
        "scope_version": _version(session_id, members),
        "connection_pending": _pending(db, user_id, [r.id for r in members]),
    }


def _receipt(row):
    return {
        "schema_version": "practice_deletion_receipt_v1",
        "source": "server_recorded",
        "account_id": row.user_id,
        **{
            n: getattr(row, n)
            for n in (
                "session_id",
                "request_key",
                "scope_version",
                "record_count",
                "rehearsal_count",
                "connection_pending",
                "deleted_at",
            )
        },
    }


def read_receipt(db, user_id, session_id, key):
    row = db.get(PracticeDeletionReceipt, (user_id, key))
    if row is None or row.session_id != session_id:
        raise APIError(404, "deletion_receipt_not_found", "尚未找到这次删除的确认凭据。")
    return _receipt(row)


def _safety_configuration(configuration):
    # No arbitrary JSON survives deletion. These scalar fields are required by
    # the existing recovery contract while an upstream connection remains unknown.
    prefs = configuration.get("preferences", {})
    provider = configuration.get("provider", {})
    return {
        "schema_version": 1,
        "effective_difficulty": configuration.get("effective_difficulty"),
        "preferences": {
            k: prefs[k]
            for k in (
                "difficulty",
                "speech_pace",
                "subtitle_default",
                "chinese_hints_enabled",
                "translation_mode",
                "version",
            )
            if k in prefs
        },
        "provider": {
            k: provider[k] for k in ("provider", "region", "model", "config_id") if k in provider
        },
    }


def delete_practice(db, user_id, session_id, payload, key):
    # The route holds the same owner lock as preparations/rehearsals and workers.
    existing = db.get(PracticeDeletionReceipt, (user_id, key))
    if existing is not None:
        if existing.session_id != session_id or existing.scope_version != payload.scope_version:
            raise APIError(409, "idempotency_conflict", "此删除请求标识已用于其他确认。")
        return _receipt(existing)
    _, members = _members(db, user_id, session_id, lock=True)
    if _version(session_id, members) != payload.scope_version:
        raise APIError(409, "deletion_scope_changed", "关联记录已变化，请重新查看并确认删除范围。")
    stamp = now()
    pending = purge_practice_content(db, user_id, members, stamp)
    receipt = PracticeDeletionReceipt(
        user_id=user_id,
        request_key=key,
        session_id=session_id,
        scope_version=payload.scope_version,
        record_count=len(members),
        rehearsal_count=sum(r.kind == "rehearsal" for r in members),
        connection_pending=pending,
        deleted_at=stamp,
        members=[
            {
                "id": str(r.id),
                "kind": r.kind,
                "parent": str(r.source_session_id) if r.source_session_id else None,
            }
            for r in members
        ],
    )
    db.add(receipt)
    db.commit()
    return _receipt(receipt)


def purge_practice_content(db, user_id, members, stamp):
    """Caller holds the owner and practice locks; never commits or creates receipts."""
    if not members or any(row.user_id != user_id for row in members):
        raise ValueError("Invalid deletion owner")
    ids = [r.id for r in members]
    connections = list(
        db.scalars(
            select(RealtimeConnection)
            .where(RealtimeConnection.user_id == user_id, RealtimeConnection.session_id.in_(ids))
            .order_by(RealtimeConnection.id)
            .with_for_update()
        )
    )
    pending_sessions = set()
    for c in connections:
        c.configuration = {
            k: c.configuration[k]
            for k in ("provider", "region", "model", "config_id")
            if k in c.configuration
        }
        if c.termination_status == "unknown":
            c.status, c.state_reason = "unknown", "content_deleted"
            pending_sessions.add(c.session_id)
            ensure_termination_check(db, c, stamp)
        elif c.status in OCCUPIED_CONNECTION_STATES:
            c.status, c.state_reason, c.ended_at = "closed", "content_deleted", stamp
    for row in members:
        row.deleted_at = stamp
        row.configuration = (
            _safety_configuration(row.configuration) if row.id in pending_sessions else {}
        )
        row.rehearsal_target = {} if row.kind == "rehearsal" else None
        row.status, row.state_reason = "completed", "content_deleted"
        row.ended_at = row.ended_at or max(stamp, row.created_at)
    for model in (ReviewInput, PracticeCompletion):
        db.execute(delete(model).where(model.session_id.in_(ids)))
    connection_ids = [c.id for c in connections]
    for model in (FinalTranscript, PlaybackEvidence, ConnectionObservation):
        db.execute(delete(model).where(model.connection_id.in_(connection_ids)))
    return bool(pending_sessions)
