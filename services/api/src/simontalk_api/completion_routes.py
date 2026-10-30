from uuid import UUID

from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.orm import Session

from simontalk_api.connections import ConnectionControl
from simontalk_api.db import database_session
from simontalk_api.practice_completion import (
    CompletionManifest,
    CompletionReceipt,
    CompletionSummary,
    begin_completion,
    read_completion,
    read_completion_receipt,
    read_connection_completion,
    submit_manifest,
)
from simontalk_api.practice_routes import locked_identity
from simontalk_api.security import protect_mutation, session_identity
from simontalk_api.termination_checks import TerminationCheckSnapshot, read_termination_check

router = APIRouter(prefix="/v1/practice-sessions/{session_id}")


@router.post("/connections/{connection_id}/end", response_model=CompletionSummary)
def end(
    session_id: UUID,
    connection_id: UUID,
    payload: ConnectionControl,
    request: Request,
    idempotency_key: UUID = Header(),
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return begin_completion(db, user.id, session_id, connection_id, payload, idempotency_key)


@router.post("/connections/{connection_id}/completion-manifest", response_model=CompletionSummary)
def manifest(
    session_id: UUID,
    connection_id: UUID,
    payload: CompletionManifest,
    request: Request,
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return submit_manifest(db, user.id, session_id, connection_id, payload)


@router.get("/completion", response_model=CompletionSummary)
def summary(session_id: UUID, request: Request, db: Session = Depends(database_session)):
    user = session_identity(request, db)[1]
    return read_completion(db, user.id, session_id)


@router.get("/connections/{connection_id}/completion")
def connection_detail(
    session_id: UUID, connection_id: UUID, request: Request, db: Session = Depends(database_session)
):
    user = session_identity(request, db)[1]
    return read_connection_completion(db, user.id, session_id, connection_id)


@router.get("/connections/{connection_id}/completion-receipt", response_model=CompletionReceipt)
def receipt(
    session_id: UUID, connection_id: UUID, request: Request, db: Session = Depends(database_session)
):
    user = session_identity(request, db)[1]
    return read_completion_receipt(db, user.id, session_id, connection_id)


@router.get(
    "/connections/{connection_id}/termination-check", response_model=TerminationCheckSnapshot
)
def termination_check(
    session_id: UUID, connection_id: UUID, request: Request, db: Session = Depends(database_session)
):
    user = session_identity(request, db)[1]
    return read_termination_check(db, user.id, session_id, connection_id)
