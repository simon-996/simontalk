"""Identical binary wire vectors without a socket or user audio."""

import asyncio

import pytest

from simontalk_api.qwen_pcm_upstream import QwenPcmInput
from simontalk_api.websocket_pcm_wire import PcmWireError, decode_pcm_frame


def frame(epoch=0x01020304, sequence=0x010203040506):
    return (
        bytes([1])
        + epoch.to_bytes(4, "big")
        + sequence.to_bytes(8, "big")
        + bytes([0x12, 0x34])
        + bytes(3197)
        + bytes([0x56])
    )


def test_fixed_vector_and_copy_have_only_safe_metadata():
    value = frame()
    assert value[:13].hex() == "01010203040000010203040506"
    decoded = decode_pcm_frame(value)
    assert decoded.epoch == 0x01020304 and decoded.sequence == 0x010203040506
    assert len(decoded.pcm) == 3200 and decoded.pcm[:2] == bytes([0x12, 0x34])
    assert decoded.pcm[-1] == 0x56 and "1234" not in repr(decoded)


@pytest.mark.parametrize(
    "value",
    [
        b"",
        frame()[:-1],
        frame() + b"x",
        bytes([2]) + frame()[1:],
        bytes([1]) + bytes(12) + bytes(3200),
        bytes([1]) + bytes(4) + (2**53).to_bytes(8, "big") + bytes(3200),
        bytearray(frame()),
        "secret",
    ],
)
def test_invalid_frames_are_rejected_without_leaking(value):
    with pytest.raises(PcmWireError) as caught:
        decode_pcm_frame(value)
    assert "secret" not in str(caught.value)


def test_decoded_pcm_can_feed_existing_bounded_upstream_adapter():
    class Connection:
        def __init__(self):
            self.sent = []

        async def send(self, value):
            self.sent.append(value)

        async def close(self):
            pass

    async def run():
        c = Connection()
        adapter = QwenPcmInput(c, clock=lambda: 0.0)
        await adapter.set_muted(False, 1)
        decoded = decode_pcm_frame(frame(1, 1))
        assert await adapter.append(decoded.epoch, decoded.sequence, decoded.pcm)
        assert len(c.sent) == 1 and "input_audio_buffer.append" in c.sent[0]
        await adapter.close()

    asyncio.run(run())
