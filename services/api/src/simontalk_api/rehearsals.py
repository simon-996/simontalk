"""Atomic independent preparations and bounded owner/parent seek reads."""

from typing import Literal

from pydantic import Field
from sqlalchemy import select, tuple_

from simontalk_api.errors import APIError
from simontalk_api.models import PracticeSession
from simontalk_api.practice import PracticeInput, PracticeOutput, build_preparation
from simontalk_api.practice_completion import canonical
from simontalk_api.rehearsal_targets import (
    changed,
    ordinary_source,
    read_source_target,
    verified_frozen_target,
)
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest


class RehearsalInput(InputModel):
    target_hash: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")
    difficulty_override: Literal["beginner", "intermediate", "advanced"] | None = None


def create_rehearsal(db, user_id, session_id, item_id, payload, key, admission):
    request_hash = digest(
        canonical(
            {
                "operation": "rehearsal_create",
                "source_session_id": str(session_id),
                "item_id": str(item_id),
                "body": payload.model_dump(mode="json"),
            }
        )
    )
    existing = db.scalar(
        select(PracticeSession).where(
            PracticeSession.user_id == user_id,
            PracticeSession.creation_key == key,
        )
    )
    if existing is not None and existing.request_digest != request_hash:
        raise APIError(409, "idempotency_conflict", "此请求标识已用于其他练习操作。")
    ordinary_source(db, user_id, session_id, lock=True)
    target = read_source_target(db, user_id, session_id, item_id)
    if target["target_hash"] != payload.target_hash:
        changed()
    if existing is not None:
        if existing.kind != "rehearsal" or verified_frozen_target(db, user_id, existing) != target:
            changed()
        practice = existing
    else:
        practice = build_preparation(
            db,
            user_id,
            PracticeInput(mode="free_chat", difficulty_override=payload.difficulty_override),
            key,
            request_hash,
            admission,
        )
        practice.kind = "rehearsal"
        practice.source_session_id = session_id
        practice.source_kind = "ordinary"
        practice.source_review_item_id = item_id
        practice.rehearsal_target = {
            key: value for key, value in target.items() if key != "target_hash"
        }
        practice.rehearsal_target_hash = target["target_hash"]
        db.add(practice)
        db.commit()
    return {
        "schema_version": "rehearsal_preparation_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "practice": PracticeOutput.model_validate(practice),
        "target": target,
    }


def list_rehearsals(db, user_id, session_id, limit=10, before_id=None):
    ordinary_source(db, user_id, session_id)
    query = select(PracticeSession).where(
        PracticeSession.user_id == user_id,
        PracticeSession.source_session_id == session_id,
        PracticeSession.deleted_at.is_(None),
        PracticeSession.kind == "rehearsal",
    )
    if before_id is not None:
        cursor = db.scalar(query.where(PracticeSession.id == before_id))
        if cursor is None:
            raise APIError(404, "rehearsal_cursor_not_found", "没有找到这项分页记录。")
        query = query.where(
            tuple_(PracticeSession.created_at, PracticeSession.id)
            < tuple_(cursor.created_at, cursor.id)
        )
    rows = db.scalars(
        query.order_by(PracticeSession.created_at.desc(), PracticeSession.id.desc()).limit(
            limit + 1
        )
    ).all()
    items = [
        {
            key: getattr(row, key)
            for key in (
                "id",
                "kind",
                "source_session_id",
                "source_review_item_id",
                "status",
                "created_at",
                "ended_at",
            )
        }
        for row in rows[:limit]
    ]
    return {
        "schema_version": "rehearsal_list_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "source_session_id": session_id,
        "limit": limit,
        "items": items,
        "next_before_id": rows[limit - 1].id if len(rows) > limit else None,
    }
