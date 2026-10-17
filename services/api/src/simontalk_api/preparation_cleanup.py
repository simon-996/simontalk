from datetime import timedelta

from sqlalchemy import or_, select

from simontalk_api.models import (
    OCCUPIED_CONNECTION_STATES,
    PracticeSession,
    RealtimeConnection,
    User,
)
from simontalk_api.security import now

PREPARATION_IDLE_SECONDS = 300


def _idle_criteria(cutoff):
    unsafe_or_recent = (
        select(RealtimeConnection.id)
        .where(
            RealtimeConnection.session_id == PracticeSession.id,
            or_(
                RealtimeConnection.status.in_(OCCUPIED_CONNECTION_STATES),
                RealtimeConnection.termination_status != "not_started",
                RealtimeConnection.ended_at.is_(None),
                RealtimeConnection.ended_at > cutoff,
            ),
        )
        .exists()
    )
    return (
        PracticeSession.status == "created",
        PracticeSession.created_at <= cutoff,
        ~unsafe_or_recent,
    )


def _idle_candidates(db, cutoff, limit):
    return db.execute(
        select(PracticeSession.id, PracticeSession.user_id)
        .where(*_idle_criteria(cutoff))
        .order_by(PracticeSession.created_at, PracticeSession.id)
        .limit(limit)
    ).all()


def expire_idle_preparations(db, *, limit=100):
    """Caller commits. Preserve rows/keys; never finalize any upstream history."""
    if type(limit) is not int or not 1 <= limit <= 1000:
        raise ValueError("Invalid scan limit")
    stamp = now()
    cutoff = stamp - timedelta(seconds=PREPARATION_IDLE_SECONDS)
    count = 0
    for session_id, user_id in _idle_candidates(db, cutoff, limit):
        owner = db.scalar(
            select(User.id).where(User.id == user_id).with_for_update(skip_locked=True)
        )
        if owner is None:
            continue
        # All trusted connection mutations also acquire User then Practice first.
        # This second statement sees activity committed after candidate selection.
        practice = db.scalar(
            select(PracticeSession)
            .where(
                PracticeSession.id == session_id,
                PracticeSession.user_id == user_id,
                *_idle_criteria(cutoff),
            )
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if practice is None:
            continue
        practice.status = "cancelled"
        practice.state_reason = "preparation_expired"
        practice.ended_at = stamp
        count += 1
    return count
