from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.practice_deletion import DeletionInput, delete_practice, read_receipt, read_scope
from simontalk_api.practice_routes import locked_identity
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-history")


@router.get("/{session_id}/deletion-scope")
def scope(session_id: UUID, request: Request, db: Annotated[Session, Depends(database_session)]):
    user = session_identity(request, db)[1]
    return read_scope(db, user.id, session_id)


@router.delete("/{session_id}")
def erase(
    session_id: UUID,
    payload: DeletionInput,
    request: Request,
    idempotency_key: Annotated[UUID, Header()],
    db: Annotated[Session, Depends(database_session)],
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return delete_practice(db, user.id, session_id, payload, idempotency_key)


@router.get("/{session_id}/deletion")
def receipt(
    session_id: UUID, key: UUID, request: Request, db: Annotated[Session, Depends(database_session)]
):
    user = session_identity(request, db)[1]
    return read_receipt(db, user.id, session_id, key)
