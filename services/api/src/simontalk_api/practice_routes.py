from uuid import UUID

from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.models import User
from simontalk_api.practice import (
    PracticeInput,
    PracticeOutput,
    cancel_preparation,
    create_preparation,
    own_preparation,
)
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-sessions")


def locked_identity(request, db):
    user = session_identity(request, db)[1]
    db.scalar(select(User.id).where(User.id == user.id).with_for_update())
    # A revoke/disable may have committed while waiting for the owner lock.
    return session_identity(request, db)[1]


@router.post("", status_code=201, response_model=PracticeOutput)
def create(
    payload: PracticeInput,
    request: Request,
    idempotency_key: UUID = Header(),
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return create_preparation(
        db, user.id, payload, idempotency_key, request.app.state.practice_admission
    )


@router.get("/{session_id}", response_model=PracticeOutput)
def detail(session_id: UUID, request: Request, db: Session = Depends(database_session)):
    user = session_identity(request, db)[1]
    return own_preparation(db, user.id, session_id)


@router.post("/{session_id}/cancel-preparation", response_model=PracticeOutput)
def cancel(session_id: UUID, request: Request, db: Session = Depends(database_session)):
    protect_mutation(request)
    user = locked_identity(request, db)
    return cancel_preparation(db, user.id, session_id)
