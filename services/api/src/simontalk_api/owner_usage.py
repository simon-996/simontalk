"""Owner-scoped read-only aggregation of recorded voice and review model usage."""

from sqlalchemy import and_, case, func, or_, select

from simontalk_api.errors import APIError
from simontalk_api.models import (
    OCCUPIED_CONNECTION_STATES,
    AssistanceAttempt,
    AssistanceJob,
    PracticeSession,
    RealtimeConnection,
    ReviewAttempt,
    ReviewJob,
    VoiceResponseUsage,
)
from simontalk_api.security import now


def _voice_summary(db, *predicates, include_deleted: bool):
    u, c, p = VoiceResponseUsage, RealtimeConnection, PracticeSession
    incomplete = or_(u.input_tokens.is_(None), u.output_tokens.is_(None))
    detail_incomplete = or_(
        u.input_text_tokens.is_(None),
        u.input_audio_tokens.is_(None),
        u.output_text_tokens.is_(None),
        u.output_audio_tokens.is_(None),
    )
    row = (
        db.execute(
            select(
                func.count().label("response_count"),
                func.coalesce(func.sum(case((p.deleted_at.is_not(None), 1), else_=0)), 0).label(
                    "deleted_response_count"
                ),
                func.coalesce(func.sum(case((incomplete, 1), else_=0)), 0).label(
                    "incomplete_count"
                ),
                func.coalesce(func.sum(case((detail_incomplete, 1), else_=0)), 0).label(
                    "detail_incomplete_count"
                ),
                func.coalesce(func.sum(u.input_tokens), 0).label("known_input_tokens"),
                func.coalesce(func.sum(u.output_tokens), 0).label("known_output_tokens"),
                func.coalesce(func.sum(u.input_text_tokens), 0).label("known_input_text_tokens"),
                func.coalesce(func.sum(u.input_audio_tokens), 0).label("known_input_audio_tokens"),
                func.coalesce(func.sum(u.output_text_tokens), 0).label("known_output_text_tokens"),
                func.coalesce(func.sum(u.output_audio_tokens), 0).label(
                    "known_output_audio_tokens"
                ),
                func.max(u.recorded_at).label("latest_recorded_at"),
            )
            .select_from(u)
            .join(c, u.connection_id == c.id)
            .join(p, and_(c.session_id == p.id, c.user_id == p.user_id))
            .where(*predicates)
        )
        .mappings()
        .one()
    )
    bucket = {
        "response_count": int(row["response_count"]),
        "incomplete_count": int(row["incomplete_count"]),
        "detail_incomplete_count": int(row["detail_incomplete_count"]),
        "known_input_tokens": int(row["known_input_tokens"]),
        "known_output_tokens": int(row["known_output_tokens"]),
        "known_input_text_tokens": int(row["known_input_text_tokens"]),
        "known_input_audio_tokens": int(row["known_input_audio_tokens"]),
        "known_output_text_tokens": int(row["known_output_text_tokens"]),
        "known_output_audio_tokens": int(row["known_output_audio_tokens"]),
    }
    if include_deleted:
        bucket["deleted_response_count"] = int(row["deleted_response_count"])
    return bucket, row["latest_recorded_at"]


def _review_summary(db, query, *, include_deleted: bool):
    row = db.execute(query).mappings().one()
    bucket = {
        "attempt_count": int(row["attempt_count"]),
        "incomplete_count": int(row["incomplete_count"]),
        "known_input_tokens": int(row["known_input_tokens"]),
        "known_output_tokens": int(row["known_output_tokens"]),
    }
    if include_deleted:
        bucket["deleted_attempt_count"] = int(row["deleted_attempt_count"])
    return bucket, row["latest_recorded_at"]


def _latest(*stamps):
    present = [stamp for stamp in stamps if stamp is not None]
    return max(present) if present else None


def _assistance_summary(db, user_id, session_id=None):
    a, j, p = AssistanceAttempt, AssistanceJob, PracticeSession
    account_scope = session_id is None
    query = (
        select(
            func.count().label("attempt_count"),
            func.coalesce(
                func.sum(
                    case(
                        (
                            or_(a.input_tokens.is_(None), a.output_tokens.is_(None)),
                            1,
                        ),
                        else_=0,
                    )
                ),
                0,
            ).label("incomplete_count"),
            func.coalesce(func.sum(a.input_tokens), 0).label("known_input_tokens"),
            func.coalesce(func.sum(a.output_tokens), 0).label("known_output_tokens"),
            func.max(func.coalesce(a.finished_at, a.started_at)).label("latest_recorded_at"),
            func.coalesce(func.sum(case((p.deleted_at.is_not(None), 1), else_=0)), 0).label(
                "deleted_attempt_count"
            ),
        )
        .select_from(a)
        .join(j, a.job_id == j.id)
        .join(p, and_(j.session_id == p.id, j.user_id == p.user_id))
        .where(j.user_id == user_id)
    )
    if not account_scope:
        query = query.where(j.session_id == session_id, p.deleted_at.is_(None))
    return _review_summary(db, query, include_deleted=account_scope)


def read_account_usage(db, user_id, *, include_assistance=False):
    checked_at = now()
    c, p, a = RealtimeConnection, PracticeSession, ReviewAttempt
    ordinary, ordinary_latest = _voice_summary(
        db, c.user_id == user_id, p.kind == "ordinary", include_deleted=True
    )
    rehearsal, rehearsal_latest = _voice_summary(
        db, c.user_id == user_id, p.kind == "rehearsal", include_deleted=True
    )
    review_incomplete = or_(
        a.outcome == "outcome_unknown", a.input_tokens.is_(None), a.output_tokens.is_(None)
    )
    review, review_latest = _review_summary(
        db,
        select(
            func.count().label("attempt_count"),
            func.coalesce(func.sum(case((a.job_id.is_(None), 1), else_=0)), 0).label(
                "deleted_attempt_count"
            ),
            func.coalesce(func.sum(case((review_incomplete, 1), else_=0)), 0).label(
                "incomplete_count"
            ),
            func.coalesce(func.sum(a.input_tokens), 0).label("known_input_tokens"),
            func.coalesce(func.sum(a.output_tokens), 0).label("known_output_tokens"),
            func.max(func.coalesce(a.finished_at, a.started_at)).label("latest_recorded_at"),
        )
        .select_from(a)
        .where(a.user_id == user_id),
        include_deleted=True,
    )
    pending_count = int(
        db.scalar(
            select(func.count())
            .select_from(c)
            .where(
                c.user_id == user_id,
                or_(c.status.in_(OCCUPIED_CONNECTION_STATES), c.termination_status == "unknown"),
            )
        )
    )
    deleted_practices = int(
        db.scalar(
            select(func.count())
            .select_from(p)
            .where(p.user_id == user_id, p.deleted_at.is_not(None))
        )
    )
    result = {
        "schema_version": "account_usage_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "checked_at": checked_at,
        "latest_recorded_at": _latest(ordinary_latest, rehearsal_latest, review_latest),
        "connection_pending_count": pending_count,
        "deleted_practice_count": deleted_practices,
        "voice_ordinary": ordinary,
        "voice_rehearsal": rehearsal,
        "review": review,
    }
    if include_assistance:
        assistance, latest = _assistance_summary(db, user_id)
        result["assistance"] = assistance
        result["latest_recorded_at"] = _latest(result["latest_recorded_at"], latest)
    return result


def read_practice_usage(db, user_id, session_id, *, include_assistance=False):
    p, c, a, j = PracticeSession, RealtimeConnection, ReviewAttempt, ReviewJob
    practice = db.scalar(
        select(p).where(p.id == session_id, p.user_id == user_id, p.deleted_at.is_(None))
    )
    if practice is None:
        raise APIError(404, "practice_not_found", "没有找到这次练习。")
    checked_at = now()
    conn_row = (
        db.execute(
            select(
                func.count().label("connection_count"),
                func.coalesce(
                    func.sum(
                        case(
                            (
                                or_(
                                    c.status.in_(OCCUPIED_CONNECTION_STATES),
                                    c.termination_status == "unknown",
                                ),
                                1,
                            ),
                            else_=0,
                        )
                    ),
                    0,
                ).label("pending_count"),
            )
            .select_from(c)
            .where(c.user_id == user_id, c.session_id == session_id)
        )
        .mappings()
        .one()
    )
    voice, voice_latest = _voice_summary(
        db, c.user_id == user_id, c.session_id == session_id, include_deleted=False
    )
    review_incomplete = or_(
        a.outcome == "outcome_unknown", a.input_tokens.is_(None), a.output_tokens.is_(None)
    )
    review, review_latest = _review_summary(
        db,
        select(
            func.count().label("attempt_count"),
            func.coalesce(func.sum(case((review_incomplete, 1), else_=0)), 0).label(
                "incomplete_count"
            ),
            func.coalesce(func.sum(a.input_tokens), 0).label("known_input_tokens"),
            func.coalesce(func.sum(a.output_tokens), 0).label("known_output_tokens"),
            func.max(func.coalesce(a.finished_at, a.started_at)).label("latest_recorded_at"),
        )
        .select_from(a)
        .join(j, and_(a.job_id == j.id, a.user_id == j.user_id))
        .where(a.user_id == user_id, j.session_id == session_id),
        include_deleted=False,
    )
    result = {
        "schema_version": "practice_usage_v1",
        "source": "server_recorded",
        "account_id": user_id,
        "session_id": session_id,
        "kind": practice.kind,
        "checked_at": checked_at,
        "latest_recorded_at": _latest(voice_latest, review_latest),
        "connection_count": int(conn_row["connection_count"]),
        "connection_pending": int(conn_row["pending_count"]) > 0,
        "voice": voice,
        "review": review,
    }
    if include_assistance:
        assistance, latest = _assistance_summary(db, user_id, session_id)
        result["assistance"] = assistance
        result["latest_recorded_at"] = _latest(result["latest_recorded_at"], latest)
    return result
