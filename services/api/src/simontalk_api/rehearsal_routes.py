from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Request
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.practice_routes import locked_identity
from simontalk_api.rehearsal_targets import read_child_target, read_source_target
from simontalk_api.rehearsals import RehearsalInput, create_rehearsal, list_rehearsals
from simontalk_api.saved_transcript_routes import QueryInteger
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-sessions")
Database = Annotated[Session, Depends(database_session)]


@router.get("/{session_id}/review-items/{item_id}/rehearsal-target")
def source_target(session_id: UUID, item_id: UUID, request: Request, db: Database):
    user = session_identity(request, db)[1]
    return read_source_target(db, user.id, session_id, item_id)


@router.get("/{session_id}/rehearsal-target")
def child_target(session_id: UUID, request: Request, db: Database):
    user = session_identity(request, db)[1]
    return read_child_target(db, user.id, session_id)


@router.post("/{session_id}/review-items/{item_id}/rehearsals", status_code=201)
def create(
    session_id: UUID,
    item_id: UUID,
    payload: RehearsalInput,
    request: Request,
    db: Database,
    idempotency_key: Annotated[UUID, Header()],
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return create_rehearsal(
        db,
        user.id,
        session_id,
        item_id,
        payload,
        idempotency_key,
        request.app.state.practice_admission,
    )


@router.get("/{session_id}/rehearsals")
def siblings(
    session_id: UUID,
    request: Request,
    db: Database,
    limit: Annotated[QueryInteger, Query(ge=1, le=20)] = 10,
    before_id: UUID | None = None,
):
    user = session_identity(request, db)[1]
    return list_rehearsals(db, user.id, session_id, limit, before_id)
