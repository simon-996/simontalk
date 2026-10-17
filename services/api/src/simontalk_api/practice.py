from dataclasses import dataclass
from datetime import datetime
from typing import Literal, Protocol
from uuid import UUID

from pydantic import ConfigDict
from sqlalchemy import select

from simontalk_api.errors import APIError
from simontalk_api.models import PracticeSession, UserPreferences
from simontalk_api.schemas import InputModel, PreferencesOutput
from simontalk_api.security import digest, now


@dataclass(frozen=True)
class AdmissionPermit:
    provider: str
    region: str
    model: str
    config_id: str


class PracticeAdmission(Protocol):
    def admit(self, user_id: UUID) -> AdmissionPermit: ...


class UnavailableAdmission:
    def admit(self, user_id: UUID) -> AdmissionPermit:
        raise APIError(503, "realtime_unavailable", "实时语音尚未配置，暂时无法开始练习。")


class PracticeInput(InputModel):
    mode: Literal["free_chat"]
    difficulty_override: Literal["beginner", "intermediate", "advanced"] | None = None


class PracticeOutput(InputModel):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    mode: str
    status: str
    configuration: dict
    created_at: datetime
    ended_at: datetime | None


def create_preparation(db, user_id, payload: PracticeInput, key, admission: PracticeAdmission):
    request_digest = digest(payload.model_dump_json())
    existing = db.scalar(
        select(PracticeSession).where(
            PracticeSession.user_id == user_id,
            PracticeSession.creation_key == key,
        )
    )
    if existing is not None:
        if existing.request_digest != request_digest:
            raise APIError(
                409, "idempotency_conflict", "这个请求已用于不同的练习设置，请重新确认。"
            )
        return existing
    active = db.scalar(
        select(PracticeSession.id)
        .where(
            PracticeSession.user_id == user_id,
            PracticeSession.status.in_(
                ["created", "connecting", "active", "interrupted", "ending"]
            ),
        )
        .limit(1)
    )
    if active is not None:
        raise APIError(409, "practice_in_progress", "已有练习尚未结束，请先处理当前练习。")
    preferences = db.get(UserPreferences, user_id)
    if preferences.difficulty is None:
        raise APIError(409, "preferences_required", "请先选择个人对话难度。")
    permit = admission.admit(user_id)
    practice = PracticeSession(
        user_id=user_id,
        creation_key=key,
        request_digest=request_digest,
        mode=payload.mode,
        configuration={
            "schema_version": 1,
            "preferences": PreferencesOutput.model_validate(preferences).model_dump(mode="json"),
            "effective_difficulty": payload.difficulty_override or preferences.difficulty,
            "provider": {
                "provider": permit.provider,
                "region": permit.region,
                "model": permit.model,
                "config_id": permit.config_id,
            },
        },
    )
    db.add(practice)
    db.commit()
    return practice


def own_preparation(db, user_id, session_id, *, lock=False):
    query = select(PracticeSession).where(
        PracticeSession.id == session_id,
        PracticeSession.user_id == user_id,
    )
    if lock:
        query = query.with_for_update()
    result = db.scalar(query)
    if result is None:
        raise APIError(404, "practice_not_found", "没有找到这次练习。")
    return result


def cancel_preparation(db, user_id, session_id):
    practice = own_preparation(db, user_id, session_id, lock=True)
    if practice.status == "cancelled":
        return practice
    if practice.status != "created":
        raise APIError(
            409, "preparation_not_cancellable", "练习已进入建连或结束处理，无法作为准备取消。"
        )
    practice.status = "cancelled"
    practice.ended_at = now()
    db.commit()
    return practice
