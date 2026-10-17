from sqlalchemy import and_, case, or_, select

from simontalk_api.connections import ConnectionOutput
from simontalk_api.models import OCCUPIED_CONNECTION_STATES, PracticeSession, RealtimeConnection
from simontalk_api.practice import PracticeOutput
from simontalk_api.schemas import InputModel


class PracticeRecoveryOutput(InputModel):
    practice: PracticeOutput | None
    connection: ConnectionOutput | None


def current_preparation(db, user_id):
    """One read snapshot; recovery never renews, readmits, or transfers a connection."""
    occupied = RealtimeConnection.status.in_(OCCUPIED_CONNECTION_STATES)
    result = db.execute(
        select(PracticeSession, RealtimeConnection)
        .outerjoin(
            RealtimeConnection,
            and_(
                RealtimeConnection.session_id == PracticeSession.id,
                RealtimeConnection.user_id == PracticeSession.user_id,
                or_(RealtimeConnection.epoch == PracticeSession.connection_epoch, occupied),
            ),
        )
        .where(
            PracticeSession.user_id == user_id,
            or_(
                PracticeSession.status.in_(
                    ["created", "connecting", "active", "interrupted", "ending"]
                ),
                occupied,
            ),
        )
        .order_by(
            case((occupied, 0), else_=1),
            PracticeSession.created_at.desc(),
            PracticeSession.id,
        )
        .limit(1)
    ).one_or_none()
    if result is None:
        return PracticeRecoveryOutput(practice=None, connection=None)
    return PracticeRecoveryOutput(practice=result[0], connection=result[1])
