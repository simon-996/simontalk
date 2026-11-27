from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.owner_usage import read_account_usage, read_practice_usage
from simontalk_api.security import session_identity

router = APIRouter(prefix="/v1/usage")


@router.get("")
def account_usage(
    request: Request,
    db: Annotated[Session, Depends(database_session)],
    include_assistance: bool = False,
):
    user = session_identity(request, db)[1]
    return read_account_usage(db, user.id, include_assistance=include_assistance)


@router.get("/practices/{session_id}")
def practice_usage(
    session_id: UUID,
    request: Request,
    db: Annotated[Session, Depends(database_session)],
    include_assistance: bool = False,
):
    user = session_identity(request, db)[1]
    return read_practice_usage(db, user.id, session_id, include_assistance=include_assistance)
