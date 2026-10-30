"""Validate candidate text/audio boundaries without asserting device playback.

Provider indices are deliberately ignored. Boundaries refer to UTF-8 bytes of
one exact source transcript and timing reported for its complete audio. A
caller must independently validate the audio, timing source and device output.
"""

from dataclasses import dataclass
from unicodedata import category

_MAX_TEXT_BYTES = 8192
_MAX_WORDS = 256
_MAX_AUDIO_MS = 86_400_000
_PUNCTUATION = frozenset(".,!?;:")


@dataclass(frozen=True, slots=True)
class CandidateBoundary:
    utf8_end: int
    audio_end_ms: int


def map_candidate_alignment(text, sentence_results, audio_duration_ms):
    """Return immutable candidates, or reject the entire uncertain mapping."""

    def invalid():
        raise ValueError("Invalid candidate alignment") from None

    if type(text) is not str or not text or "\x00" in text:
        invalid()
    try:
        if len(text.encode("utf-8")) > _MAX_TEXT_BYTES:
            invalid()
    except UnicodeError:
        invalid()
    if type(sentence_results) not in (list, tuple) or len(sentence_results) != 1:
        invalid()
    sentence = sentence_results[0]
    if (
        type(sentence) is not dict
        or type(sentence.get("index")) is not int
        or sentence["index"] != 0
        or sentence.get("original_text") != text
    ):
        invalid()
    words = sentence.get("words")
    if type(words) not in (list, tuple) or not 0 < len(words) <= _MAX_WORDS:
        invalid()
    if type(audio_duration_ms) is not int or not 0 < audio_duration_ms <= _MAX_AUDIO_MS:
        invalid()

    cursor = 0
    last_end_ms = 0
    accumulated_bytes = 0
    boundaries = []
    for word in words:
        if type(word) is not dict:
            invalid()
        token = word.get("text")
        begin = word.get("begin_time")
        end = word.get("end_time")
        if (
            type(token) is not str
            or not token
            or not any(not char.isspace() for char in token)
            or "\x00" in token
            or type(word.get("sentence_index")) is not int
            or word["sentence_index"] != 0
            or type(begin) is not int
            or type(end) is not int
            or begin < last_end_ms
            or end <= begin
            or end > audio_duration_ms
        ):
            invalid()
        try:
            accumulated_bytes += len(token.encode("utf-8"))
        except UnicodeError:
            invalid()
        if accumulated_bytes > _MAX_TEXT_BYTES:
            invalid()

        for char in token:
            if (
                cursor < len(text)
                and text[cursor] != char
                and text[cursor].isspace()
                and not char.isspace()
                and cursor > 0
                and text[cursor - 1] in _PUNCTUATION
            ):
                while cursor < len(text) and text[cursor].isspace():
                    cursor += 1
            if cursor >= len(text) or text[cursor] != char:
                invalid()
            cursor += 1
        if cursor < len(text):
            previous, following = text[cursor - 1], text[cursor]
            next_code = ord(following)
            if (
                category(following).startswith("M")
                or category(following) == "Cf"
                or previous == "\u200d"
                or 0x1F3FB <= next_code <= 0x1F3FF
                or (0x1F1E6 <= ord(previous) <= 0x1F1FF and 0x1F1E6 <= next_code <= 0x1F1FF)
                or (previous == "\r" and following == "\n")
            ):
                invalid()
        boundaries.append(CandidateBoundary(len(text[:cursor].encode("utf-8")), end))
        last_end_ms = end

    if cursor < len(text) and not text[cursor:].isspace():
        invalid()
    return tuple(boundaries)
