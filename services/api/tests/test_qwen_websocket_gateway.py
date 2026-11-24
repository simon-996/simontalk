"""Lifecycle tests for the disabled Qwen socket candidate; no provider calls."""

import asyncio
import traceback

import pytest

from simontalk_api.qwen_websocket import (
    QwenWebSocketError,
    QwenWebSocketGateway,
    QwenWebSocketSettings,
)

SECRET = "synthetic-private-key-for-tests"
CONFIG = {
    "provider": "dashscope",
    "region": "cn-beijing",
    "model": "qwen3.8-omni-flash-realtime",
    "config_id": "candidate-v1",
}


def settings():
    return QwenWebSocketSettings(
        workspace_id="llm-test",
        model=CONFIG["model"],
        config_id=CONFIG["config_id"],
        api_key=SECRET,
    )


class Socket:
    def __init__(self):
        self.sent = []
        self.incoming = asyncio.Queue()
        self.close_calls = 0
        self.abort_calls = 0
        self.transport = self

    async def send(self, value):
        self.sent.append(value)

    async def recv(self):
        return await self.incoming.get()

    async def close(self, code=1000):
        self.close_calls += 1

    def abort(self):
        self.abort_calls += 1


def test_exact_configuration_single_attempt_and_fixed_endpoint():
    async def run():
        socket = Socket()
        calls = []

        async def connector(url, **kwargs):
            calls.append((url, kwargs))
            return socket

        gateway = QwenWebSocketGateway(settings(), connector=connector)
        assert SECRET not in repr(settings()) + repr(gateway)
        with pytest.raises(QwenWebSocketError):
            gateway.attempt({**CONFIG, "config_id": "other"})
        assert calls == []
        attempt = gateway.attempt(CONFIG)
        connection = await attempt.open()
        with pytest.raises(QwenWebSocketError):
            await attempt.open()
        assert len(calls) == 1
        url, args = calls[0]
        assert (
            url
            == "wss://llm-test.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen3.8-omni-flash-realtime"
        )
        assert args["proxy"] is None and args["compression"] is None
        assert args["additional_headers"]["Authorization"] == "Bearer " + SECRET
        await connection.send('{"type":"session.update"}')
        socket.incoming.put_nowait('{"type":"session.created"}')
        assert await connection.receive() == '{"type":"session.created"}'
        assert socket.sent == ['{"type":"session.update"}']
        await connection.close()
        assert socket.close_calls == 1

    asyncio.run(run())


def test_connection_failure_is_sanitized_and_attempt_cannot_reopen():
    async def run():
        calls = 0

        async def connector(url, **kwargs):
            nonlocal calls
            calls += 1
            raise RuntimeError("upstream secret " + SECRET)

        attempt = QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG)
        with pytest.raises(QwenWebSocketError) as caught:
            await attempt.open()
        assert SECRET not in "".join(traceback.format_exception(caught.value))
        with pytest.raises(QwenWebSocketError):
            await attempt.open()
        assert calls == 1

    asyncio.run(run())


@pytest.mark.parametrize("bad", ["", "{}", "[]", '{"type":null}', "x" * 131073, b'{"type":"x"}'])
def test_invalid_send_closes_and_cannot_be_reused(bad):
    async def run():
        socket = Socket()

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        with pytest.raises(QwenWebSocketError):
            await connection.send(bad)
        assert socket.sent == [] and socket.close_calls == 1
        with pytest.raises(QwenWebSocketError):
            await connection.send('{"type":"x"}')

    asyncio.run(run())


def test_invalid_receive_closes_without_leaking_provider_payload():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait("private payload " + SECRET)

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        with pytest.raises(QwenWebSocketError) as caught:
            await connection.receive()
        assert SECRET not in "".join(traceback.format_exception(caught.value))
        assert socket.close_calls == 1

    asyncio.run(run())


def test_cancelled_close_keeps_one_background_release():
    async def run():
        socket = Socket()
        entered, proceed = asyncio.Event(), asyncio.Event()

        async def slow_close(code=1000):
            socket.close_calls += 1
            entered.set()
            await proceed.wait()

        socket.close = slow_close

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        task = asyncio.create_task(connection.close())
        await entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        proceed.set()
        await connection.close()
        assert socket.close_calls == 1

    asyncio.run(run())


def test_duplicate_json_keys_are_rejected_before_send():
    async def run():
        socket = Socket()

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        with pytest.raises(QwenWebSocketError):
            await connection.send('{"type":"safe","type":"response.create"}')
        assert socket.sent == [] and socket.close_calls == 1

    asyncio.run(run())


def test_cancelled_receive_close_failure_does_not_leave_private_task_exception():
    async def run():
        socket = Socket()

        async def failed_close(code=1000):
            socket.close_calls += 1
            raise RuntimeError("provider secret " + SECRET)

        socket.close = failed_close

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        reader = asyncio.create_task(connection.receive())
        await asyncio.sleep(0)
        reader.cancel()
        with pytest.raises(asyncio.CancelledError):
            await reader
        done, _ = await asyncio.wait({connection._close_task}, timeout=0.1)
        assert connection._close_task in done
        assert socket.abort_calls == 1
        assert connection._close_task.exception() is None

    asyncio.run(run())


def test_cancelled_open_cannot_be_retried():
    async def run():
        started = asyncio.Event()
        calls = 0

        async def connector(*args, **kwargs):
            nonlocal calls
            calls += 1
            started.set()
            await asyncio.Event().wait()

        attempt = QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG)
        task = asyncio.create_task(attempt.open())
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        with pytest.raises(QwenWebSocketError):
            await attempt.open()
        assert calls == 1

    asyncio.run(run())


def test_close_timeout_aborts_local_transport(monkeypatch):
    from simontalk_api import qwen_websocket

    async def run():
        socket = Socket()

        async def blocked_close(code=1000):
            socket.close_calls += 1
            await asyncio.Event().wait()

        socket.close = blocked_close

        async def connector(*args, **kwargs):
            return socket

        monkeypatch.setattr(qwen_websocket, "_CLOSE_TIMEOUT", 0.01)
        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        await connection.close()
        assert socket.close_calls == 1 and socket.abort_calls == 1
        with pytest.raises(QwenWebSocketError):
            await connection.send('{"type":"session.update"}')

    asyncio.run(run())


def test_cancelled_open_closes_socket_returned_after_connector_ignores_cancellation():
    async def run():
        started, release = asyncio.Event(), asyncio.Event()
        socket = Socket()

        async def connector(*args, **kwargs):
            started.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()
            return socket

        attempt = QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG)
        task = asyncio.create_task(attempt.open())
        await started.wait()
        task.cancel()
        done, _ = await asyncio.wait({task}, timeout=0.1)
        try:
            assert task in done, "caller cancellation must not wait for a late connector"
            with pytest.raises(asyncio.CancelledError):
                await task
        finally:
            release.set()
        for _ in range(10):
            await asyncio.sleep(0)
            if socket.close_calls:
                break
        assert socket.close_calls == 1
        with pytest.raises(QwenWebSocketError):
            await attempt.open()

    asyncio.run(run())


def test_open_timeout_closes_a_late_socket(monkeypatch):
    from simontalk_api import qwen_websocket

    async def run():
        release = asyncio.Event()
        socket = Socket()

        async def connector(*args, **kwargs):
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()
            return socket

        monkeypatch.setattr(qwen_websocket, "_OPEN_TIMEOUT", 0.02)
        attempt = QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG)
        task = asyncio.create_task(attempt.open())
        done, _ = await asyncio.wait({task}, timeout=0.1)
        try:
            assert task in done, (
                "opening deadline must not await a cancellation-resistant connector"
            )
            with pytest.raises(QwenWebSocketError):
                await task
        finally:
            release.set()
        for _ in range(10):
            await asyncio.sleep(0)
            if socket.close_calls:
                break
        assert socket.close_calls == 1

    asyncio.run(run())


def test_close_deadline_does_not_wait_for_socket_that_ignores_cancellation(monkeypatch):
    from simontalk_api import qwen_websocket

    async def run():
        socket = Socket()
        release = asyncio.Event()

        async def stubborn_close(code=1000):
            socket.close_calls += 1
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()

        socket.close = stubborn_close

        async def connector(*args, **kwargs):
            return socket

        monkeypatch.setattr(qwen_websocket, "_CLOSE_TIMEOUT", 0.02)
        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        task = asyncio.create_task(connection.close())
        done, _ = await asyncio.wait({task}, timeout=0.1)
        try:
            assert task in done, "close must return after the deadline"
            await task
            assert socket.abort_calls == 1
        finally:
            release.set()
            await asyncio.sleep(0)

    asyncio.run(run())


def test_send_deadline_does_not_wait_for_a_cancellation_resistant_socket(monkeypatch):
    from simontalk_api import qwen_websocket

    async def run():
        socket = Socket()
        release = asyncio.Event()

        async def stubborn_send(value):
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()

        socket.send = stubborn_send

        async def connector(*args, **kwargs):
            return socket

        monkeypatch.setattr(qwen_websocket, "_SEND_TIMEOUT", 0.02)
        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        task = asyncio.create_task(connection.send('{"type":"session.update"}'))
        done, _ = await asyncio.wait({task}, timeout=0.1)
        try:
            assert task in done, "send must return after the deadline"
            with pytest.raises(QwenWebSocketError):
                await task
            assert socket.abort_calls == 1
            assert socket.close_calls == 1
        finally:
            release.set()
            await asyncio.sleep(0)

    asyncio.run(run())


def test_cancellation_resistant_receive_closes_and_discards_late_data():
    async def run():
        socket = Socket()
        entered, release = asyncio.Event(), asyncio.Event()

        async def stubborn_recv():
            entered.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()
            return '{"type":"late.private"}'

        socket.recv = stubborn_recv

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        task = asyncio.create_task(connection.receive())
        await entered.wait()
        task.cancel()
        done, _ = await asyncio.wait({task}, timeout=0.1)
        try:
            assert task in done
            with pytest.raises(asyncio.CancelledError):
                await task
            await connection.close()
            assert socket.abort_calls == 1 and socket.close_calls == 1
        finally:
            release.set()
            await asyncio.sleep(0)
        with pytest.raises(QwenWebSocketError):
            await connection.receive()

    asyncio.run(run())


def test_concurrent_receives_close_the_connection_and_prevent_late_result():
    async def run():
        socket = Socket()

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        first = asyncio.create_task(connection.receive())
        await asyncio.sleep(0)
        with pytest.raises(QwenWebSocketError):
            await connection.receive()
        socket.incoming.put_nowait('{"type":"session.created"}')
        with pytest.raises(QwenWebSocketError):
            await first
        assert socket.close_calls == 1 and socket.abort_calls == 1

    asyncio.run(run())


def test_concurrent_sends_do_not_leave_a_usable_connection():
    async def run():
        socket = Socket()
        entered, release = asyncio.Event(), asyncio.Event()

        async def delayed_send(value):
            entered.set()
            await release.wait()

        socket.send = delayed_send

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        first = asyncio.create_task(connection.send('{"type":"first"}'))
        await entered.wait()
        with pytest.raises(QwenWebSocketError):
            await connection.send('{"type":"second"}')
        release.set()
        with pytest.raises(QwenWebSocketError):
            await first
        assert socket.close_calls == 1 and socket.abort_calls == 1

    asyncio.run(run())


def test_cancelled_send_aborts_and_closes_before_discarding_late_completion():
    async def run():
        socket = Socket()
        entered, release = asyncio.Event(), asyncio.Event()

        async def stubborn_send(value):
            entered.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()

        socket.send = stubborn_send

        async def connector(*args, **kwargs):
            return socket

        connection = (
            await QwenWebSocketGateway(settings(), connector=connector).attempt(CONFIG).open()
        )
        sender = asyncio.create_task(connection.send('{"type":"session.update"}'))
        await entered.wait()
        sender.cancel()
        done, _ = await asyncio.wait({sender}, timeout=0.1)
        try:
            assert sender in done
            with pytest.raises(asyncio.CancelledError):
                await sender
            await connection.close()
            assert socket.abort_calls == 1 and socket.close_calls == 1
        finally:
            release.set()
            await asyncio.sleep(0)
        with pytest.raises(QwenWebSocketError):
            await connection.send('{"type":"session.update"}')

    asyncio.run(run())


@pytest.mark.parametrize(
    "bad",
    [
        {"workspace_id": "evil.example"},
        {"workspace_id": "user@host"},
        {"model": "qwen3.5-omni-flash-realtime"},
        {"config_id": "a/b"},
        {"api_key": " secret"},
    ],
)
def test_invalid_settings_are_rejected_without_echoing_input(bad):
    values = {
        "workspace_id": "llm-test",
        "model": CONFIG["model"],
        "config_id": "candidate-v1",
        "api_key": SECRET,
    }
    values.update(bad)
    with pytest.raises(ValueError) as caught:
        QwenWebSocketSettings(**values)
    assert SECRET not in str(caught.value)
