from uuid import UUID

from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.practice_routes import locked_identity
from simontalk_api.review_jobs import (
    ReviewJobRequest,
    ReviewRetryRequest,
    create_review_job,
    read_review_job,
    retry_review_job,
)
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-sessions/{session_id}/review")


@router.post("", status_code=202)
def create(
    session_id: UUID,
    payload: ReviewJobRequest,
    request: Request,
    idempotency_key: UUID = Header(),
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return create_review_job(
        db, user.id, session_id, payload, idempotency_key, request.app.state.review_gateway
    )


@router.get("")
def read(session_id: UUID, request: Request, db: Session = Depends(database_session)):
    user = session_identity(request, db)[1]
    return read_review_job(db, user.id, session_id)


@router.post("/retry", status_code=202)
def retry(
    session_id: UUID,
    payload: ReviewRetryRequest,
    request: Request,
    idempotency_key: UUID = Header(),
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return retry_review_job(
        db, user.id, session_id, payload, idempotency_key, request.app.state.review_gateway
    )
