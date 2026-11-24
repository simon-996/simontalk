"""Opt-in browser media endpoint for an explicitly supplied gateway."""

import asyncio
import logging
from uuid import UUID

from fastapi import APIRouter, WebSocket
from starlette.websockets import WebSocketDisconnect, WebSocketState

from simontalk_api.authenticated_websocket_claim import ClaimError, authenticate_and_claim
from simontalk_api.supervised_pump_session import SessionError, run_pump_session
from simontalk_api.websocket_handshake import HandshakeError, check_browser_headers
from simontalk_api.websocket_unknown import mark_websocket_unknown

_PROOF_TIMEOUT = 5.0
_WRITE_TIMEOUT = 3.0
_MAX_ENTRIES = 128
_ENTRIES = {}  # One slot through both the handler and its potentially late cleanup.
_LOG = logging.getLogger(__name__)


class _InvalidFrame(Exception):
    pass


class _BrowserPort:
    def __init__(self, socket):
        self.socket = socket
        self.incoming = asyncio.Queue(maxsize=4)
        self.ready = False
        self.closed = False

    async def announce_ready(self):
        async with asyncio.timeout(_WRITE_TIMEOUT):
            await self.send('{"kind":"ready"}')
        self.ready = True

    async def read_frames(self):
        """Sole ASGI reader after the proof, including while the DB or provider waits."""
        try:
            while True:
                frame = await self.socket.receive()
                if frame["type"] == "websocket.disconnect":
                    raise WebSocketDisconnect()
                if self.closed or not self.ready or self.incoming.full():
                    raise _InvalidFrame()
                data = frame.get("bytes")
                if data is None:
                    data = frame.get("text")
                    if type(data) is not str or len(data) > 1024 or len(data.encode()) > 1024:
                        raise _InvalidFrame()
                elif type(data) is not bytes or len(data) != 3213:
                    raise _InvalidFrame()
                self.incoming.put_nowait(data)
        finally:
            self.closed = True

    async def receive(self):
        if self.closed:
            raise WebSocketDisconnect()
        return await self.incoming.get()

    async def send(self, text):
        if self.closed:
            raise WebSocketDisconnect()
        await self.socket.send_text(text)

    async def close(self):
        self.closed = True


async def _close_socket(socket, code):
    if WebSocketState.DISCONNECTED in (socket.client_state, socket.application_state):
        return
    try:
        async with asyncio.timeout(_WRITE_TIMEOUT):
            await socket.close(code=code)
    except (TimeoutError, WebSocketDisconnect, OSError):
        pass


async def serve_browser_media(
    socket, gateway, *, session_id, connection_id, client_instance_id, epoch
):
    """Serve one bound socket. The production application does not mount this handler."""
    if len(_ENTRIES) >= _MAX_ENTRIES:
        await _close_socket(socket, 1013)
        return
    slot = object()
    _ENTRIES[slot] = None
    state = socket.app.state
    port = _BrowserPort(socket)
    unowned = None
    close_code = 1011
    reason = "network_failed"

    def supervisor_owns_claim():
        nonlocal unowned
        unowned = None

    try:
        check_browser_headers(
            socket.headers, socket.scope["query_string"], state.settings.allowed_origins
        )
        async with asyncio.timeout(_PROOF_TIMEOUT):
            await socket.accept()
            first = await socket.receive()
        if first["type"] == "websocket.disconnect":
            return
        proof = first.get("text")
        if type(proof) is not str or len(proof) > 1024:
            raise _InvalidFrame()

        try:
            async with asyncio.TaskGroup() as group:
                reader = group.create_task(port.read_frames())
                try:
                    identity, unowned = await authenticate_and_claim(
                        session_factory=state.session_factory,
                        admission=state.practice_admission,
                        gateway=gateway,
                        headers=socket.headers,
                        query=socket.scope["query_string"],
                        body=proof,
                        allowed_origins=state.settings.allowed_origins,
                        session_id=session_id,
                        connection_id=connection_id,
                        client_instance_id=client_instance_id,
                        epoch=epoch,
                    )
                    del first, proof
                    if port.closed:
                        raise WebSocketDisconnect()
                    await run_pump_session(
                        state.session_factory,
                        identity,
                        unowned,
                        state.practice_admission,
                        port,
                        on_owned=supervisor_owns_claim,
                        on_ready=port.announce_ready,
                    )
                    close_code = 1000
                finally:
                    reader.cancel()
        except* (WebSocketDisconnect, _InvalidFrame, ClaimError):
            close_code = 1008
        except* SessionError:
            close_code = 1011
    except (HandshakeError, _InvalidFrame, TimeoutError, WebSocketDisconnect):
        close_code = 1008
    except asyncio.CancelledError:
        reason = "cancelled"
        raise
    finally:
        port.closed = True

        # Capacity rejection, disconnect, or cancellation after commit but before
        # the supervisor took ownership. Keep this slot through any late DB write.
        async def finish():
            operations = [_close_socket(socket, close_code)]
            if unowned is not None:
                operations.append(
                    asyncio.to_thread(
                        mark_websocket_unknown, state.session_factory, unowned, reason
                    )
                )
            results = await asyncio.gather(*operations, return_exceptions=True)
            if any(isinstance(result, BaseException) for result in results):
                _LOG.warning("browser_media_cleanup_failed")

        cleanup = asyncio.create_task(finish())
        _ENTRIES[slot] = cleanup
        cleanup.add_done_callback(lambda _: _ENTRIES.pop(slot, None))
        await asyncio.wait({cleanup}, timeout=_WRITE_TIMEOUT)


def browser_media_router(gateway):
    router = APIRouter()

    @router.websocket(
        "/v1/practice-sessions/{session_id}/connections/{connection_id}"
        "/media/{client_instance_id}/{epoch}"
    )
    async def media(
        socket: WebSocket,
        session_id: UUID,
        connection_id: UUID,
        client_instance_id: UUID,
        epoch: int,
    ):
        await serve_browser_media(
            socket,
            gateway,
            session_id=session_id,
            connection_id=connection_id,
            client_instance_id=client_instance_id,
            epoch=epoch,
        )

    return router
