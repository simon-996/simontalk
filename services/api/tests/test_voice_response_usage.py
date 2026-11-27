import asyncio
from dataclasses import replace
from threading import Event
from uuid import uuid4

from sqlalchemy import select
from test_practice_preparation import account as account
from test_qwen_turn_pump import msg
from test_qwen_turn_pump_supervisor import PumpSocket
from test_supervised_pump_session import Downstream
from test_websocket_supervisor_integration import FakeSocket, make_claim
from test_websocket_supervisor_integration import supervisor_scope as supervisor_scope

from simontalk_api import supervised_pump_session
from simontalk_api.models import VoiceResponseUsage
from simontalk_api.qwen_response_usage import read_qwen_response_usage
from simontalk_api.voice_response_usage import record_response_usage
from simontalk_api.websocket_supervisor import supervise_websocket


def test_records_once_for_the_original_claim_even_after_media_closes(
    factory, app, supervisor_scope
):
    _, _, identity, _ = supervisor_scope
    claim, _ = make_claim(factory, app, supervisor_scope, FakeSocket())
    measured = read_qwen_response_usage(
        "response_test", "completed", {"input_tokens": 11, "output_tokens": 0}
    )
    assert record_response_usage(factory, claim, measured) is False

    async def run():
        async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
            pass

    asyncio.run(run())
    for wrong in (
        replace(claim, user_id=uuid4()),
        replace(claim, client_instance_id=uuid4()),
        replace(claim, epoch=claim.epoch + 1),
        replace(claim, fingerprint="0" * 64),
    ):
        assert record_response_usage(factory, wrong, measured) is False
    assert record_response_usage(factory, claim, measured) is True
    assert record_response_usage(factory, claim, replace(measured, input_tokens=23)) is False
    with factory() as db:
        row = db.scalars(select(VoiceResponseUsage)).one()
        assert row.connection_id == claim.connection_id
        assert row.status == "completed" and row.input_tokens == 11 and row.output_tokens == 0
        assert row.input_audio_tokens is None and row.response_digest == measured.response_digest


def test_slow_usage_write_does_not_delay_provider_terminal_delivery(
    factory, app, supervisor_scope, monkeypatch
):
    entered, release, written = Event(), Event(), Event()

    def slow_write(*args):
        entered.set()
        if not release.wait(5):
            raise TimeoutError()
        result = record_response_usage(*args)
        written.set()
        return result

    monkeypatch.setattr(supervised_pump_session, "record_response_usage", slow_write)

    async def run():
        socket, browser = PumpSocket(), Downstream()
        _, _, identity, _ = supervisor_scope
        claim, _ = make_claim(factory, app, supervisor_scope, socket)
        session = asyncio.create_task(
            supervised_pump_session.run_pump_session(
                factory, identity, claim, app.state.practice_admission, browser
            )
        )
        try:
            for index, kind in enumerate(("speech_started", "speech_stopped", "committed")):
                socket.incoming.put_nowait(
                    msg(f"input_audio_buffer.{kind}", f"event_{index}", item_id="learner")
                )
            socket.incoming.put_nowait(
                msg(
                    "conversation.item.input_audio_transcription.completed",
                    "asr",
                    item_id="learner",
                    content_index=0,
                    transcript="Hello.",
                )
            )
            socket.incoming.put_nowait(
                msg("response.created", "created", response={"id": "response_a"})
            )
            socket.incoming.put_nowait(
                msg("response.done", "done", response={"id": "response_a", "status": "completed"})
            )
            async with asyncio.timeout(2):
                while (await browser.output.get())["event"]["type"] != "response.done":
                    pass
            assert await asyncio.to_thread(entered.wait, 1)
            with factory() as db:
                assert db.scalars(select(VoiceResponseUsage)).first() is None
            await browser.incoming.put('{"kind":"stop"}')
            assert await asyncio.wait_for(asyncio.shield(session), 2) == "stopped"
            assert socket.close_calls == browser.closed == 1 and not written.is_set()
            release.set()
            assert await asyncio.to_thread(written.wait, 2)
        finally:
            release.set()
            if not session.done():
                session.cancel()
            await asyncio.gather(session, return_exceptions=True)

    asyncio.run(run())
    with factory() as db:
        row = db.scalars(select(VoiceResponseUsage)).one()
        assert row.status == "completed" and row.input_tokens is None
