"""Text/audio candidates only: no device playback or provider assumptions."""

import json
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest


def map_candidate_alignment(*args):
    from importlib import import_module

    try:
        mapper = import_module("simontalk_api.tts_candidate_alignment")
    except ModuleNotFoundError:
        pytest.fail("Candidate mapper is missing")
    text, words, duration = args
    sentence = {"index": 0, "original_text": text, "words": words}
    return mapper.map_candidate_alignment(text, [sentence], duration)


def word(text, start, end, *, sentence=0):
    return {"text": text, "begin_time": start, "end_time": end, "sentence_index": sentence}


@pytest.mark.parametrize(
    "name",
    ["2026-10-29-qwen-tts-timestamps.json", "2026-10-29-qwen-tts-timestamps-checked.json"],
)
def test_real_english_output_maps_exact_original_utf8_prefixes(name):
    evidence = Path(__file__).resolve().parents[3] / "docs/development/evidence" / name
    result = json.loads(evidence.read_text())
    text = result["synthetic_text"]
    boundaries = map_candidate_alignment(text, result["result"]["words"], 3810)
    encoded = text.encode("utf-8")
    assert len(boundaries) == 12
    assert [encoded[: entry.utf8_end].decode("utf-8") for entry in boundaries[:3]] == [
        "Hello",
        "Hello there",
        "Hello there. What",
    ]
    assert encoded[: boundaries[-1].utf8_end].decode("utf-8") == text
    assert boundaries[-1].audio_end_ms == 3280


def test_offsets_are_utf8_boundaries_and_results_are_immutable():
    text = "中👩‍💻文"
    boundaries = map_candidate_alignment(
        text, [word("中", 0, 50), word("👩‍💻", 50, 100), word("文", 100, 200)], 200
    )
    assert [b.utf8_end for b in boundaries] == [3, 14, 17]
    with pytest.raises(FrozenInstanceError):
        boundaries[0].utf8_end = 4
    assert isinstance(boundaries, tuple)


@pytest.mark.parametrize(
    ("text", "segments", "duration"),
    [
        ("turn off", [word("turnoff", 0, 1)], 1),
        ("Hello world", [word("hello", 0, 1), word(" world", 1, 2)], 2),
        ("Hello world", [word("Hello", 0, 1)], 1),
        ("Hello", [word("Hello!", 0, 1)], 1),
        ("Hello\x00", [word("Hello", 0, 1)], 1),
        ("\ud800", [word("x", 0, 1)], 1),
        ("a" * 8193, [word("a", 0, 1)], 1),
        ("x", [word("x", 0, 0)], 1),
        ("xy", [word("x", 0, 2), word("y", 1, 3)], 3),
        ("x", [word("x", 0, 2)], 1),
        ("x", [word("x", False, 1)], 1),
        ("x", [word("x", 0, 1, sentence=1)], 1),
        ("x", [word("x", 0, 1)], True),
    ],
)
def test_uncertain_mappings_are_rejected_without_echoing_text(text, segments, duration):
    with pytest.raises(ValueError, match="Invalid candidate alignment") as exc:
        map_candidate_alignment(text, segments, duration)
    assert str(exc.value) == "Invalid candidate alignment"


def test_punctuation_space_is_the_only_relaxed_difference():
    result = map_candidate_alignment(
        "Hello. World!", [word("Hello", 0, 10), word(".World", 10, 20), word("!", 20, 30)], 30
    )
    assert [entry.utf8_end for entry in result] == [5, 12, 13]
    with pytest.raises(ValueError):
        map_candidate_alignment("abc def", [word("abcdef", 0, 1)], 1)


def test_trailing_whitespace_is_never_invented_as_spoken():
    result = map_candidate_alignment("Hi.   ", [word("Hi.", 0, 10)], 10)
    assert result[-1].utf8_end == len(b"Hi.")


def test_rejects_boundaries_inside_combining_and_joined_emoji():
    with pytest.raises(ValueError, match="Invalid candidate alignment"):
        map_candidate_alignment("Cafe\u0301", [word("Cafe", 0, 10), word("\u0301", 10, 20)], 20)
    with pytest.raises(ValueError, match="Invalid candidate alignment"):
        map_candidate_alignment("👩‍💻", [word("👩", 0, 10), word("‍💻", 10, 20)], 20)


def test_rejects_more_than_256_segments():
    with pytest.raises(ValueError, match="Invalid candidate alignment"):
        map_candidate_alignment("x" * 257, [word("x", n, n + 1) for n in range(257)], 257)


def test_mapper_requires_one_structural_sentence_result():
    from simontalk_api.tts_candidate_alignment import map_candidate_alignment as real_map

    one = {"index": 0, "original_text": "ab", "words": [word("a", 0, 10), word("b", 10, 20)]}
    assert real_map("ab", [one], 20)[-1].utf8_end == 2
    duplicate = [
        {"index": 0, "original_text": "a", "words": [word("a", 0, 10)]},
        {"index": 0, "original_text": "b", "words": [word("b", 10, 20)]},
    ]
    with pytest.raises(ValueError, match="Invalid candidate alignment"):
        real_map("ab", duplicate, 20)
