from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Request
from pydantic import Field
from sqlalchemy.orm import Session

from simontalk_api import assistance
from simontalk_api.db import database_session
from simontalk_api.practice_routes import locked_identity
from simontalk_api.saved_transcript_routes import QueryInteger
from simontalk_api.security import protect_mutation, session_identity

router = APIRouter(prefix="/v1/practice-sessions/{session_id}/assistance")


class AssistanceRequest(assistance.AssistanceScope):
    kind: assistance.AssistanceKind
    input_revision: str = Field(pattern=r"^[0-9a-f]{64}$")
    source_turn_id: UUID | None = None
    source_turn_revision: int | None = Field(default=None, strict=True, ge=1, le=2147483647)

    @property
    def target(self):
        return assistance.AssistanceTarget(
            self.kind, self.source_turn_id, self.source_turn_revision
        )


class AssistanceRetry(AssistanceRequest):
    attempt_count: int = Field(strict=True, ge=0, le=2)


@router.get("/context")
def read_context(
    session_id: UUID,
    connection_id: UUID,
    epoch: Annotated[QueryInteger, Query(ge=1, le=2147483647)],
    request: Request,
    db: Annotated[Session, Depends(database_session)],
    kind: assistance.AssistanceKind = "english_starter",
    source_turn_id: UUID | None = None,
    source_turn_revision: Annotated[QueryInteger | None, Query(ge=1, le=2147483647)] = None,
):
    user = session_identity(request, db)[1]
    target = assistance.AssistanceTarget(kind, source_turn_id, source_turn_revision)
    revision, _ = assistance.context(db, user.id, session_id, connection_id, epoch, target=target)
    existing = assistance.find_current_job(db, user.id, session_id, kind, revision)
    return {
        "account_id": user.id,
        "session_id": session_id,
        "connection_id": connection_id,
        "epoch": epoch,
        "kind": kind,
        **(
            {"source_turn_id": source_turn_id, "source_turn_revision": source_turn_revision}
            if kind == "translation"
            else {}
        ),
        "input_revision": revision,
        "job_id": existing.id if existing is not None else None,
        "can_generate": assistance.gateway_binding(request.app.state.assistance_gateway, kind)
        is not None,
    }


@router.post("", status_code=202)
def create(
    session_id: UUID,
    payload: AssistanceRequest,
    request: Request,
    idempotency_key: Annotated[UUID, Header()],
    db: Annotated[Session, Depends(database_session)],
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return assistance.submit(
        db,
        user.id,
        session_id,
        payload,
        idempotency_key,
        request.app.state.assistance_gateway,
        auth_session_id=session_identity(request, db)[0].id,
    )


@router.get("/{job_id}")
def read(
    session_id: UUID,
    job_id: UUID,
    request: Request,
    db: Annotated[Session, Depends(database_session)],
):
    user = session_identity(request, db)[1]
    return assistance.read(db, user.id, session_id, job_id, request.app.state.assistance_gateway)


@router.post("/{job_id}/retry", status_code=202)
def retry(
    session_id: UUID,
    job_id: UUID,
    payload: AssistanceRetry,
    request: Request,
    idempotency_key: Annotated[UUID, Header()],
    db: Annotated[Session, Depends(database_session)],
):
    protect_mutation(request)
    user = locked_identity(request, db)
    return assistance.submit(
        db,
        user.id,
        session_id,
        payload,
        idempotency_key,
        request.app.state.assistance_gateway,
        auth_session_id=session_identity(request, db)[0].id,
        retry_id=job_id,
    )
