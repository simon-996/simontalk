from uuid import UUID

from fastapi import APIRouter, Request

from simontalk_api.security import protect_mutation
from simontalk_api.signalling import AnswerOutput, OfferInput, exchange_offer

router = APIRouter(prefix="/v1/practice-sessions/{session_id}/connections/{connection_id}")


@router.post("/offer", response_model=AnswerOutput)
async def offer(session_id: UUID, connection_id: UUID, payload: OfferInput, request: Request):
    protect_mutation(request)
    return await exchange_offer(request, session_id, connection_id, payload)
