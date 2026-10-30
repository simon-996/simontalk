"""Deterministic text qualification. No ASR confidence or device claims are inferred."""

import json

POLICY_VERSION = "review_input_v1"
UNLOCATED_GAPS = {
    "context_missing",
    "manifest_missing",
    "manifest_totals_mismatch",
    "journal_unavailable",
    "transcript_missing",
    "transcript_unexpected",
    "transcript_rejected",
    "playback_missing",
    "playback_unexpected",
    "playback_rejected",
}


class ReviewInputLimit(Exception):
    pass


def wire_size(value):
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def source_ref(row, *, playback=False):
    return {
        "ledger": "playback" if playback else "transcripts",
        "event_id": row["event_id"],
        "event_digest": row["event_digest"],
        "turn_id": row["turn_id"],
        "turn_index": row["turn_index"],
        "role": "assistant" if playback else row["role"],
        "revision": row["transcript_revision"] if playback else row["revision"],
    }


def resolve_ref(ref, sources):
    row = sources[(ref["ledger"], ref["event_id"])]
    expected = source_ref(row, playback=ref["ledger"] == "playback")
    if ref != expected:
        raise ValueError("Source reference changed")
    return {**ref, "text": row["played_text"] if ref["ledger"] == "playback" else row["text"]}


def derive_scope(scope, transcripts, playback, seal, manifest, *, remaining_bytes):
    """Return body-free decisions; check repeated context cost before copying refs."""
    sources = {("transcripts", row["event_id"]): row for row in transcripts}
    sources.update({("playback", row["event_id"]): row for row in playback})
    latest = {}
    for row in transcripts:
        previous = latest.get(row["turn_id"])
        if previous is None or row["revision"] > previous["revision"]:
            latest[row["turn_id"]] = row
    by_turn = {}
    for row in transcripts:
        by_turn.setdefault(row["turn_id"], []).append(row)
    sealed_turns = {turn["turn_id"]: turn for turn in seal["turns"]}
    unfinalized = set((manifest or {}).get("unfinalized_turn_ids", []))
    unconfirmed = set((manifest or {}).get("unconfirmed_response_ids", []))
    known_responses = {row["response_id"] for row in playback if row["kind"] != "revoke"}
    known_responses.update(row["response_id"] for row in transcripts if row["role"] == "assistant")
    revoked = {row["response_id"] for row in playback if row["kind"] == "revoke"}
    missing = unfinalized - set(latest)
    unlocated_missing = missing - {row["turn_id"] for row in playback}
    incomplete = bool(
        set(seal["gap_codes"]) & UNLOCATED_GAPS
        or unlocated_missing
        or unconfirmed - known_responses
        or revoked - known_responses
    )
    context, context_bytes, consumed = [], 0, wire_size(scope) + 32
    decisions = []
    order = sorted(sealed_turns.values(), key=lambda turn: (turn["turn_index"], turn["turn_id"]))
    for turn in order:
        turn_id = turn["turn_id"]
        current = latest.get(turn_id)
        rows = sorted(by_turn.get(turn_id, []), key=lambda row: row["revision"])
        for row in rows:
            is_latest = row is current
            reasons = []
            if not is_latest:
                eligibility, reasons = "excluded", ["superseded_revision"]
            elif row["role"] == "assistant":
                eligibility, reasons = "excluded", ["assistant_text"]
            elif not row["text"].strip():
                eligibility, reasons = "excluded", ["empty_text"]
            elif turn_id in unfinalized:
                eligibility, reasons = "uncertain", ["unfinalized_turn"]
            else:
                eligibility, reasons = "eligible", ["user_final_text"]
            allowed = [] if eligibility == "excluded" else ["text_only"]
            if eligibility != "excluded" and incomplete:
                eligibility = "uncertain"
                reasons.append("context_incomplete")
            if eligibility != "excluded" and not incomplete and turn_id not in unfinalized:
                allowed.append("conversation_context")
            item = {
                "turn_id": turn_id,
                "turn_index": row["turn_index"],
                "role": row["role"],
                "revision": row["revision"],
                "transcript_event_id": row["event_id"],
                "event_digest": row["event_digest"],
                "eligibility": eligibility,
                "reason_codes": reasons,
                "allowed_bases": allowed,
                "confidence": None,
                "quality_source": "unavailable",
                "context_before": [],
            }
            cost = wire_size(item)
            if eligibility != "excluded":
                # Include actual UTF-8 body and each repeated context entry before expansion.
                cost = wire_size({**item, "text": row["text"]})
                if "conversation_context" in allowed:
                    cost += context_bytes
            consumed += cost + 1
            if consumed > remaining_bytes:
                raise ReviewInputLimit
            if "conversation_context" in allowed:
                item["context_before"] = list(context)
            decisions.append(item)
        if turn["role"] == "assistant":
            prefix = turn["interrupted_prefix"] or turn["final_prefix"]
            response_rows = [row for row in playback if row["turn_id"] == turn_id]
            response_ids = {row["response_id"] for row in response_rows}
            if current:
                response_ids.add(current["response_id"])
            not_played = any(
                row["transcript_final"]
                and row["delivery_status"] == "not_played"
                and row["transcript_revision"] == turn["revision"]
                for row in response_rows
            )
            if response_ids & revoked:
                incomplete = True
            elif prefix:
                row = sources[("playback", prefix["playback_event_id"])]
                if row["turn_id"] != turn_id or any(
                    row[field] != prefix[field]
                    for field in ("transcript_revision", "playback_revision", "delivery_status")
                ):
                    raise ValueError("Selected playback reference changed")
                ref = source_ref(row, playback=True)
                context.append(ref)
                context_bytes += wire_size(resolve_ref(ref, sources)) + (
                    1 if len(context) > 1 else 0
                )
            elif not not_played:
                incomplete = True
            if response_ids & unconfirmed:
                incomplete = True
        elif current:
            if current["text"].strip() and turn_id not in unfinalized:
                ref = source_ref(current)
                context.append(ref)
                context_bytes += wire_size(resolve_ref(ref, sources)) + (
                    1 if len(context) > 1 else 0
                )
            else:
                incomplete = True
    for turn_id in sorted(missing):
        item = {
            "turn_id": turn_id,
            "turn_index": None,
            "role": "unknown",
            "revision": None,
            "transcript_event_id": None,
            "event_digest": None,
            "eligibility": "excluded",
            "reason_codes": ["missing_final_text"],
            "allowed_bases": [],
            "confidence": None,
            "quality_source": "unavailable",
            "context_before": [],
        }
        consumed += wire_size(item) + 1
        if consumed > remaining_bytes:
            raise ReviewInputLimit
        decisions.append(item)
    return {**scope, "decisions": decisions}, consumed
