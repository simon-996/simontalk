from uuid import UUID

from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.orm import Session

from simontalk_api.connections import (
    ConnectionControl,
    ConnectionInput,
    ConnectionOutput,
    cancel_connection,
    create_connection,
    own_connection,
    renew_connection,
)
from simontalk_api.db import database_session
from simontalk_api.practice_routes import locked_identity
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-sessions/{session_id}/connections")


@router.post("", status_code=201, response_model=ConnectionOutput)
def create(
    session_id: UUID,
    payload: ConnectionInput,
    request: Request,
    idempotency_key: UUID = Header(),
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return create_connection(
        db, user.id, session_id, payload, idempotency_key, request.app.state.practice_admission
    )


@router.get("/{connection_id}", response_model=ConnectionOutput)
def detail(
    session_id: UUID, connection_id: UUID, request: Request, db: Session = Depends(database_session)
):
    user = session_identity(request, db)[1]
    return own_connection(db, user.id, session_id, connection_id)


@router.post("/{connection_id}/renew-lease", response_model=ConnectionOutput)
def renew(
    session_id: UUID,
    connection_id: UUID,
    payload: ConnectionControl,
    request: Request,
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return renew_connection(db, user.id, session_id, connection_id, payload)


@router.post("/{connection_id}/cancel-preparation", response_model=ConnectionOutput)
def cancel(
    session_id: UUID,
    connection_id: UUID,
    payload: ConnectionControl,
    request: Request,
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return cancel_connection(db, user.id, session_id, connection_id, payload)
