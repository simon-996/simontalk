import re
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BeforeValidator
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.saved_transcripts import read_saved_transcript
from simontalk_api.security import session_identity

router = APIRouter(prefix="/v1/practice-sessions/{session_id}/saved-transcript")


def _integer(value):
    if type(value) is int:
        return value
    if not isinstance(value, str) or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise ValueError("Expected a decimal query integer")
    return int(value)


QueryInteger = Annotated[int, BeforeValidator(_integer)]


@router.get("")
def read(
    session_id: UUID,
    request: Request,
    input_revision: Annotated[QueryInteger, Query(ge=1, le=1)],
    input_hash: Annotated[str, Query(pattern=r"^[a-f0-9]{64}$")],
    db: Annotated[Session, Depends(database_session)],
    offset: Annotated[QueryInteger | None, Query(ge=0, le=8192)] = None,
    limit: Annotated[QueryInteger, Query(ge=1, le=16)] = 16,
    review_item_id: UUID | None = None,
):
    user = session_identity(request, db)[1]
    return read_saved_transcript(
        db, user.id, session_id, input_revision, input_hash, offset, limit, review_item_id
    )
