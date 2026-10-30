from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.practice_history import list_history, read_history
from simontalk_api.saved_transcript_routes import QueryInteger
from simontalk_api.security import session_identity

router = APIRouter(prefix="/v1/practice-history")


@router.get("")
def listing(
    request: Request,
    db: Annotated[Session, Depends(database_session)],
    limit: Annotated[QueryInteger, Query(ge=1, le=20)] = 10,
    cursor: str | None = None,
):
    user = session_identity(request, db)[1]
    return list_history(db, user.id, limit, cursor)


@router.get("/{session_id}")
def detail(session_id: UUID, request: Request, db: Annotated[Session, Depends(database_session)]):
    user = session_identity(request, db)[1]
    return read_history(db, user.id, session_id)
