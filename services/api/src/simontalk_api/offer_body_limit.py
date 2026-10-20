import asyncio
import uuid

from starlette.responses import JSONResponse

MAX_OFFER_BODY_BYTES = 96 * 1024
MAX_OBSERVATION_BODY_BYTES = 8 * 1024
MAX_TRANSCRIPT_BODY_BYTES = 256 * 1024
BODY_TIMEOUT_SECONDS = 5


class ConnectionBodyLimitMiddleware:
    """Bound connection writes before FastAPI attempts JSON decoding."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        path = scope.get("path", "")
        if not (
            scope["type"] == "http"
            and scope.get("method") == "POST"
            and path.startswith("/v1/practice-sessions/")
            and "/connections/" in path
            and path.endswith(("/offer", "/observations", "/transcripts"))
        ):
            await self.app(scope, receive, send)
            return
        maximum = {
            "observations": MAX_OBSERVATION_BODY_BYTES,
            "transcripts": MAX_TRANSCRIPT_BODY_BYTES,
            "offer": MAX_OFFER_BODY_BYTES,
        }[path.rsplit("/", 1)[-1]]

        async def reject(status, code):
            request_id = scope.get("state", {}).get("request_id") or str(uuid.uuid4())
            response = JSONResponse(
                {
                    "code": code,
                    "message": "连接请求超出接收范围，请重新确认当前状态。",
                    "request_id": request_id,
                },
                status_code=status,
            )
            await response(scope, receive, send)

        chunks, size = [], 0
        too_large = False
        try:
            async with asyncio.timeout(BODY_TIMEOUT_SECONDS):
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    chunk = message.get("body", b"")
                    size += len(chunk)
                    if size > maximum:
                        too_large = True
                        break
                    chunks.append(chunk)
                    if not message.get("more_body", False):
                        break
        except TimeoutError:
            await reject(408, "request_timeout")
            return
        if too_large:
            # Only receiving is timed; a slow response send must not emit a second status.
            await reject(413, "request_too_large")
            return

        body = b"".join(chunks)
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        await self.app(scope, replay, send)
