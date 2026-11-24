"""Local-only redirect checks with synthetic credentials; no provider calls."""

import asyncio

from websockets.asyncio.client import connect


async def exercise(factory):
    destinations = []

    async def sink(reader, writer):
        data = await reader.readuntil(b"\r\n\r\n")
        destinations.append(data)
        writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    target = await asyncio.start_server(sink, "127.0.0.1", 0)
    port = target.sockets[0].getsockname()[1]

    async def redirect(reader, writer):
        await reader.readuntil(b"\r\n\r\n")
        writer.write(
            b"HTTP/1.1 302 Found\r\nLocation: ws://127.0.0.1:"
            + str(port).encode()
            + b"/capture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    origin = await asyncio.start_server(redirect, "127.0.0.1", 0)
    origin_port = origin.sockets[0].getsockname()[1]
    try:
        try:
            await factory(
                f"ws://127.0.0.1:{origin_port}/original",
                additional_headers={"Authorization": "Bearer synthetic-test-only"},
                open_timeout=2,
                close_timeout=1,
                proxy=None,
            )
        except Exception:
            pass
        return destinations
    finally:
        origin.close()
        target.close()
        await origin.wait_closed()
        await target.wait_closed()


def test_default_websocket_client_follows_redirect_and_forwards_synthetic_header():
    result = asyncio.run(exercise(connect))
    assert len(result) == 1
    assert b"Bearer synthetic-test-only" in result[0]


def test_qwen_websocket_client_never_follows_redirect():
    from simontalk_api.qwen_websocket import no_redirect_connect

    result = asyncio.run(exercise(no_redirect_connect))
    assert result == []


def test_qwen_websocket_never_logs_authorization_even_at_debug_level():
    import io
    import logging

    from websockets.asyncio.server import serve

    from simontalk_api.qwen_websocket import no_redirect_connect

    async def run():
        async def handler(socket):
            async for message in socket:
                await socket.send(message)

        server_logger = logging.Logger("synthetic-server", level=logging.CRITICAL + 1)
        server_logger.disabled = True
        async with serve(handler, "127.0.0.1", 0, logger=server_logger) as server:
            port = server.sockets[0].getsockname()[1]
            stream = io.StringIO()
            log_handler = logging.StreamHandler(stream)
            root = logging.getLogger()
            old_level = root.level
            root.setLevel(logging.DEBUG)
            root.addHandler(log_handler)
            try:
                socket = await no_redirect_connect(
                    f"ws://127.0.0.1:{port}/",
                    additional_headers={"Authorization": "Bearer synthetic-private-marker"},
                    proxy=None,
                    logger=root,
                )
                await socket.send("synthetic-audio-marker")
                assert await socket.recv() == "synthetic-audio-marker"
                await socket.close()
            finally:
                root.removeHandler(log_handler)
                root.setLevel(old_level)
            assert "synthetic-private-marker" not in stream.getvalue()
            assert "synthetic-audio-marker" not in stream.getvalue()

    asyncio.run(run())
