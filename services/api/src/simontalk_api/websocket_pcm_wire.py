"""Strict PCM binary framing for a future authenticated downstream socket."""

import struct
from dataclasses import dataclass, field

_HEADER = struct.Struct(">BIQ")
_FRAME_BYTES = 3200
_MAX_SEQUENCE = 9007199254740991


class PcmWireError(Exception):
    """Fixed diagnostic without audio content."""


@dataclass(frozen=True, slots=True)
class PcmWireFrame:
    epoch: int
    sequence: int
    pcm: bytes = field(repr=False)


def decode_pcm_frame(value):
    if type(value) is not bytes or len(value) != _HEADER.size + _FRAME_BYTES:
        raise PcmWireError("invalid_pcm_frame")
    version, epoch, sequence = _HEADER.unpack_from(value)
    if version != 1 or not 1 <= sequence <= _MAX_SEQUENCE:
        raise PcmWireError("invalid_pcm_frame")
    return PcmWireFrame(epoch, sequence, value[_HEADER.size :])
