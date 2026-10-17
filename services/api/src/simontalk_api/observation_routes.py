from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.orm import Session

from simontalk_api.connection_observations import (
    ObservationAcknowledgement,
    ObservationBatch,
    ObservationPage,
    append_observations,
    read_observations,
)
from simontalk_api.db import database_session
from simontalk_api.practice_routes import locked_identity
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(
    prefix="/v1/practice-sessions/{session_id}/connections/{connection_id}/observations"
)


@router.post("", response_model=ObservationAcknowledgement)
def append(
    session_id: UUID,
    connection_id: UUID,
    payload: ObservationBatch,
    request: Request,
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return append_observations(db, user.id, session_id, connection_id, payload)


@router.get("", response_model=ObservationPage)
def detail(
    session_id: UUID,
    connection_id: UUID,
    request: Request,
    after_sequence: int = Query(default=0, ge=0, le=2147483647),
    limit: int = Query(default=32, ge=1, le=32),
    db: Session = Depends(database_session),
):
    user = session_identity(request, db)[1]
    return read_observations(db, user.id, session_id, connection_id, after_sequence, limit)
