from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.practice_routes import locked_identity
from simontalk_api.review_inputs import ReviewInputRequest, create_review_input, read_review_input
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-sessions/{session_id}/review-input")


@router.post("")
def create(
    session_id: UUID,
    payload: ReviewInputRequest,
    request: Request,
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return create_review_input(db, user.id, session_id, payload)


@router.get("")
def read(session_id: UUID, request: Request, db: Session = Depends(database_session)):
    user = session_identity(request, db)[1]
    return read_review_input(db, user.id, session_id)
