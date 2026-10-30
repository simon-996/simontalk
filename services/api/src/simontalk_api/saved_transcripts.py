"""Bounded, owner-scoped reading of sealed text and client-reported playback."""

from types import SimpleNamespace
from uuid import UUID

from fastapi.encoders import jsonable_encoder
from pydantic import ValidationError

from simontalk_api.errors import APIError
from simontalk_api.practice_completion import _turns
from simontalk_api.review_input_policy import ReviewInputLimit, wire_size
from simontalk_api.review_inputs import _completion, _load_sources
from simontalk_api.review_jobs import read_review_job

MAX_RESPONSE_BYTES = 512 * 1024
MAX_TURNS = 8192


def _changed():
    raise APIError(
        409, "saved_transcript_changed", "已保存文字的来源发生变化，请重新读取保存状态。"
    )


def _limit():
    raise APIError(409, "saved_transcript_limit_exceeded", "这次练习超出当前已保存文字读取范围。")


def _not_found():
    raise APIError(404, "review_item_not_found", "未找到这条复盘建议。")


def _project_scope(scope, transcripts, playback, view, manifest):
    # Check the selected versions/references against their original source rows,
    # independently of a seal's hash. Reading is independent of review eligibility.
    expected = _turns(
        [SimpleNamespace(**row) for row in transcripts],
        [SimpleNamespace(**row) for row in playback],
        manifest,
        set(),
    )
    if expected != view["turns"]:
        _changed()
    finals = {row["event_id"]: row for row in transcripts}
    evidence = {row["event_id"]: row for row in playback}
    by_turn = {}
    for row in playback:
        if row["kind"] != "revoke":
            by_turn.setdefault(row["turn_id"], []).append(row)
    revoked = {row["response_id"] for row in playback if row["kind"] == "revoke"}
    items = []
    for turn in expected:
        final = finals.get(turn["transcript_event_id"])
        rows = by_turn.get(turn["turn_id"], [])
        final_text = final["text"] if final else None
        final_source = "final_transcript" if final else None
        status = played_text = played_revision = None
        if turn["role"] == "assistant":
            if final is None:
                candidates = [
                    row
                    for row in rows
                    if row["transcript_revision"] == turn["revision"] and row["transcript_final"]
                ]
                if candidates:
                    latest = max(
                        candidates, key=lambda row: (row["playback_revision"], row["sequence"])
                    )
                    final_text, final_source = latest["generated_text"], "playback_final"
            response_ids = {row["response_id"] for row in rows}
            if final:
                response_ids.add(final["response_id"])
            status = "unknown"
            prefix = turn["interrupted_prefix"] or turn["final_prefix"]
            if response_ids & revoked:
                status = "revoked"
            elif prefix:
                row = evidence[prefix["playback_event_id"]]
                if row["turn_id"] != turn["turn_id"] or any(
                    row[key] != prefix[key]
                    for key in ("transcript_revision", "playback_revision", "delivery_status")
                ):
                    _changed()
                status, played_text, played_revision = (
                    row["delivery_status"],
                    row["played_text"],
                    row["transcript_revision"],
                )
            elif final_source and any(
                row["transcript_final"]
                and row["transcript_revision"] == turn["revision"]
                and row["generated_text"] == final_text
                and row["delivery_status"] == "not_played"
                for row in rows
            ):
                status = "not_played"
        items.append(
            {
                "connection_id": scope["connection_id"],
                "client_instance_id": scope["client_instance_id"],
                "epoch": scope["epoch"],
                **{key: turn[key] for key in ("turn_id", "turn_index", "revision", "role")},
                "final_text": final_text,
                "final_source": final_source,
                "playback_status": status,
                "played_text": played_text,
                "played_revision": played_revision,
            }
        )
    return items


def _focus(db, completion, items, item_id):
    try:
        job = read_review_job(db, completion.user_id, completion.session_id)
    except APIError as error:
        if error.status == 404:
            _not_found()
        raise
    if job["status"] not in {"succeeded", "no_suggestions"} or job["result"] is None:
        _changed()
    if job["input_revision"] != 1 or job["practice_input_hash"] != completion.input_hash:
        _changed()
    result = job["result"]
    suggestion = next((row for row in result["items"] if UUID(row["id"]) == item_id), None)
    if suggestion is None:
        _not_found()
    target = next(
        (
            row
            for row in items
            if row["connection_id"] == suggestion["source_connection_id"]
            and row["turn_id"] == suggestion["source_turn_id"]
            and row["revision"] == suggestion["revision"]
        ),
        None,
    )
    quote = suggestion["exact_quote"]
    if (
        target is None
        or target["role"] != "user"
        or not quote.strip()
        or quote not in target["final_text"]
    ):
        _changed()
    return {
        "item_id": suggestion["id"],
        "job_id": str(job["id"]),
        "result_hash": result["result_hash"],
        "connection_id": target["connection_id"],
        "turn_id": target["turn_id"],
        "revision": target["revision"],
        "exact_quote": quote,
        "ordinal": target["ordinal"],
    }


def read_saved_transcript(
    db, user_id, session_id, input_revision, input_hash, offset, limit, review_item_id
):
    """No writes, business commits, leases, media, or gateway calls on this path."""
    try:
        completion = _completion(db, user_id, session_id)
        if input_revision != 1 or completion.input_hash != input_hash:
            _changed()
        scopes, _ = _load_sources(db, completion)
        gaps = sorted({code for _, _, _, view, _ in scopes for code in view["gap_codes"]})
        if completion.gap_codes != gaps or completion.coverage != (
            "incomplete" if gaps else "complete"
        ):
            _changed()
        items = []
        for source in scopes:
            items.extend(_project_scope(*source))
        if len(items) > MAX_TURNS:
            _limit()
        for ordinal, item in enumerate(items, 1):
            item["ordinal"] = ordinal
        focus = _focus(db, completion, items, review_item_id) if review_item_id else None
        if offset is None:
            offset = focus["ordinal"] - 1 if focus else 0
        if offset > len(items):
            raise APIError(422, "validation_error", "输入格式不正确，请检查后重试。")
        page = items[offset : offset + limit]
        response = {
            "schema_version": "saved_transcript_v1",
            "source": "server_derived",
            "evidence_source": "client_reported",
            "account_id": str(user_id),
            "session_id": str(session_id),
            "input_revision": 1,
            "practice_input_hash": completion.input_hash,
            "sealed_at": completion.sealed_at.isoformat().replace("+00:00", "Z"),
            "coverage": completion.coverage,
            "gap_codes": completion.gap_codes,
            "total_turns": len(items),
            "offset": offset,
            "limit": limit,
            "previous_offset": max(0, offset - limit) if offset else None,
            "next_offset": offset + len(page) if offset + len(page) < len(items) else None,
            "focus": focus,
            "items": page,
        }
        if wire_size(jsonable_encoder(response)) > MAX_RESPONSE_BYTES:
            _limit()
        return response
    except APIError as error:
        if error.code == "review_input_limit_exceeded":
            _limit()
        if error.status == 409 and error.code != "completion_not_sealed":
            if error.code == "saved_transcript_limit_exceeded":
                raise
            _changed()
        raise
    except ReviewInputLimit:
        _limit()
    except (AttributeError, KeyError, ValueError, TypeError, ValidationError):
        _changed()
