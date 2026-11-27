"""Bounded read-only history; sealing and connection occupancy stay independent."""

import base64
import binascii
import json
import re
from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import and_, case, exists, func, or_, select, tuple_

from simontalk_api.errors import APIError
from simontalk_api.models import (
    OCCUPIED_CONNECTION_STATES,
    PracticeCompletion,
    PracticeSession,
    RealtimeConnection,
)


def encode_cursor(user_id, created_at, session_id):
    payload = [
        str(user_id),
        created_at.astimezone(UTC).isoformat(timespec="microseconds"),
        str(session_id),
    ]
    return (
        base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode())
        .decode()
        .rstrip("=")
    )


def decode_cursor(value, user_id):
    try:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value):
            raise ValueError()
        data = json.loads(
            base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        )
        if type(data) is not list or len(data) != 3 or data[0] != str(user_id):
            raise ValueError()
        created_at, session_id = datetime.fromisoformat(data[1]), UUID(data[2])
        if created_at.tzinfo is None or encode_cursor(user_id, created_at, session_id) != value:
            raise ValueError()
        return created_at, session_id
    except (ValueError, TypeError, AttributeError, OverflowError, binascii.Error):
        raise APIError(400, "history_cursor_invalid", "分页位置无效，请刷新记录。") from None


def history_query(user_id):
    p, c, connection = PracticeSession, PracticeCompletion, RealtimeConnection
    topic = p.configuration["topic"]
    pending = exists().where(
        connection.user_id == p.user_id,
        connection.session_id == p.id,
        or_(
            connection.status.in_(OCCUPIED_CONNECTION_STATES),
            connection.termination_status == "unknown",
        ),
    )
    return (
        select(
            p.id,
            p.kind,
            p.source_session_id,
            p.status,
            p.created_at,
            p.ended_at,
            p.configuration["effective_difficulty"].as_string().label("difficulty"),
            case(
                (
                    p.mode == "daily_topic",
                    func.jsonb_build_object(
                        "id",
                        topic["id"].as_string(),
                        "title",
                        topic["title"].as_string(),
                        "goal",
                        topic["goal"].as_string(),
                    ),
                )
            ).label("topic"),
            func.coalesce(c.status, "unregistered").label("completion_status"),
            c.coverage,
            pending.label("connection_pending"),
        )
        .outerjoin(c, and_(c.session_id == p.id, c.user_id == p.user_id))
        .where(p.user_id == user_id, p.deleted_at.is_(None))
    )


def list_history(db, user_id, limit=10, cursor=None):
    query = history_query(user_id)
    if cursor is not None:
        created_at, session_id = decode_cursor(cursor, user_id)
        query = query.where(
            tuple_(PracticeSession.created_at, PracticeSession.id) < tuple_(created_at, session_id)
        )
    rows = (
        db.execute(
            query.order_by(PracticeSession.created_at.desc(), PracticeSession.id.desc()).limit(
                limit + 1
            )
        )
        .mappings()
        .all()
    )
    items = [dict(row) for row in rows[:limit]]
    return {
        "schema_version": "practice_history_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "limit": limit,
        "items": items,
        "next_cursor": encode_cursor(user_id, rows[limit - 1]["created_at"], rows[limit - 1]["id"])
        if len(rows) > limit
        else None,
    }


def read_history(db, user_id, session_id):
    row = (
        db.execute(history_query(user_id).where(PracticeSession.id == session_id))
        .mappings()
        .one_or_none()
    )
    if row is None:
        raise APIError(404, "practice_not_found", "没有找到这次练习。")
    return {
        "schema_version": "practice_history_detail_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "item": dict(row),
    }
