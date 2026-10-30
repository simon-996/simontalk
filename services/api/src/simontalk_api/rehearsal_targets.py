"""Pure reads of verified review sources and immutable first-level targets."""

import re
from uuid import UUID

from simontalk_api.errors import APIError
from simontalk_api.practice import own_preparation
from simontalk_api.practice_completion import canonical
from simontalk_api.review_input_policy import wire_size
from simontalk_api.review_inputs import read_review_input
from simontalk_api.review_jobs import read_review_job
from simontalk_api.security import digest


def changed():
    raise APIError(409, "rehearsal_source_changed", "重练来源或目标已变化，请重新读取。")


def limit_exceeded():
    raise APIError(409, "rehearsal_target_limit_exceeded", "这项目标超出当前重练范围。")


def ordinary_source(db, user_id, session_id, *, lock=False):
    source = own_preparation(db, user_id, session_id, lock=lock)
    if source.kind != "ordinary":
        changed()
    return source


def _validate_text(value):
    if isinstance(value, str):
        if "\x00" in value:
            changed()
        value.encode("utf-8")
    elif isinstance(value, dict):
        for key, item in value.items():
            _validate_text(key)
            _validate_text(item)
    elif isinstance(value, list):
        for item in value:
            _validate_text(item)


def read_source_target(db, user_id, session_id, item_id):
    ordinary_source(db, user_id, session_id)
    try:
        job = read_review_job(db, user_id, session_id)
        if job["status"] not in {"succeeded", "no_suggestions"}:
            changed()
        item = next((i for i in job["result"]["items"] if i["id"] == str(item_id)), None)
        if item is None:
            raise APIError(404, "rehearsal_item_not_found", "没有找到这项重练来源。")
        data = read_review_input(db, user_id, session_id)
        scope, decision = next(
            (scope, decision)
            for scope in data["scopes"]
            if scope["connection_id"] == item["source_connection_id"]
            for decision in scope["decisions"]
            if decision["turn_id"] == item["source_turn_id"]
            and decision["revision"] == item["revision"]
            and decision["role"] == "user"
            and decision["eligibility"] != "excluded"
        )
        target = {
            "schema_version": "rehearsal_target_v1",
            "source": "server_derived",
            "evidence_source": "client_reported",
            "account_id": str(user_id),
            "source_session_id": str(session_id),
            "source_kind": "ordinary",
            "item_id": str(item_id),
            "job_id": str(job["id"]),
            "result_hash": job["result"]["result_hash"],
            **{
                key: data[key]
                for key in (
                    "input_revision",
                    "practice_input_hash",
                    "review_input_hash",
                    "policy_version",
                )
            },
            "generation_policy_version": job["generation_policy_version"],
            "source_connection_id": scope["connection_id"],
            "source_client_instance_id": scope["client_instance_id"],
            "source_epoch": scope["epoch"],
            "source_turn_id": decision["turn_id"],
            "revision": decision["revision"],
            "source_text": decision["text"],
            **{
                key: item[key]
                for key in ("exact_quote", "kind", "basis", "explanation", "suggestion")
            },
            "situation_mode": "source_original",
            "context_before": decision["context_before"]
            if item["basis"] == "conversation_context"
            else [],
        }
        _validate_text(target)
        for name, maximum in (
            ("source_text", 8192),
            ("exact_quote", 8192),
            ("suggestion", 8192),
            ("explanation", 16384),
        ):
            if len(target[name].encode("utf-8")) > maximum:
                limit_exceeded()
        result = {**target, "target_hash": digest(canonical(target))}
        if wire_size(result) > 64 * 1024:
            limit_exceeded()
        return result
    except APIError as error:
        if error.code in {"review_job_not_found", "rehearsal_item_not_found"}:
            raise
        if "limit_exceeded" in error.code:
            limit_exceeded()
        changed()
    except (KeyError, TypeError, ValueError, StopIteration, UnicodeError):
        changed()


def _frozen_shape(snapshot, child, user_id):
    fixed = {
        "schema_version": "rehearsal_target_v1",
        "source": "server_derived",
        "evidence_source": "client_reported",
        "source_kind": "ordinary",
        "account_id": str(user_id),
        "source_session_id": str(child.source_session_id),
        "item_id": str(child.source_review_item_id),
        "input_revision": 1,
        "policy_version": "review_input_v1",
        "generation_policy_version": "review_generation_v1",
        "situation_mode": "source_original",
    }
    ids = ("job_id", "source_connection_id", "source_client_instance_id", "source_turn_id")
    hashes = ("result_hash", "practice_input_hash", "review_input_hash")
    texts = ("source_text", "exact_quote", "explanation", "suggestion")
    numbers = ("source_epoch", "revision")
    if type(snapshot) is not dict or set(snapshot) != set(fixed) | set(
        ids + hashes + texts + numbers
    ) | {"kind", "basis", "context_before"}:
        changed()
    if any(
        type(snapshot[key]) is not type(value) or snapshot[key] != value
        for key, value in fixed.items()
    ):
        changed()
    if any(
        type(snapshot[key]) is not str or str(UUID(snapshot[key])) != snapshot[key] for key in ids
    ):
        changed()
    if any(
        type(snapshot[key]) is not str or re.fullmatch(r"[a-f0-9]{64}", snapshot[key]) is None
        for key in hashes
    ):
        changed()
    if any(type(snapshot[key]) is not int or snapshot[key] < 1 for key in numbers):
        changed()
    if any(type(snapshot[key]) is not str or not snapshot[key].strip() for key in texts):
        changed()
    if snapshot["kind"] not in {"correction", "polish", "extension"} or snapshot["basis"] not in {
        "text_only",
        "conversation_context",
    }:
        changed()
    context = snapshot["context_before"]
    if type(context) is not list or (snapshot["basis"] == "text_only" and context):
        changed()
    for ref in context:
        if type(ref) is not dict or set(ref) != {
            "ledger",
            "event_id",
            "event_digest",
            "turn_id",
            "turn_index",
            "role",
            "revision",
            "text",
        }:
            changed()
        if ref["ledger"] not in {"transcripts", "playback"} or ref["role"] not in {
            "user",
            "assistant",
        }:
            changed()
        for key in ("event_id", "turn_id"):
            if type(ref[key]) is not str or str(UUID(ref[key])) != ref[key]:
                changed()
        for key in ("revision", "turn_index"):
            if type(ref[key]) is not int or ref[key] < 1:
                changed()
        if (
            type(ref["text"]) is not str
            or type(ref["event_digest"]) is not str
            or re.fullmatch(r"[a-f0-9]{64}", ref["event_digest"]) is None
        ):
            changed()
    _validate_text(snapshot)
    if snapshot["exact_quote"] not in snapshot["source_text"]:
        changed()
    for key, maximum in (
        ("source_text", 8192),
        ("exact_quote", 8192),
        ("suggestion", 8192),
        ("explanation", 16384),
    ):
        if len(snapshot[key].encode("utf-8")) > maximum:
            limit_exceeded()
    if wire_size({**snapshot, "target_hash": child.rehearsal_target_hash}) > 64 * 1024:
        limit_exceeded()


def verified_frozen_target(db, user_id, child):
    try:
        snapshot = child.rehearsal_target
        _frozen_shape(snapshot, child, user_id)
        if type(snapshot) is not dict or digest(canonical(snapshot)) != child.rehearsal_target_hash:
            changed()
        current = read_source_target(
            db, user_id, child.source_session_id, child.source_review_item_id
        )
        if current != {**snapshot, "target_hash": child.rehearsal_target_hash}:
            changed()
        return current
    except APIError as error:
        if error.code == "rehearsal_target_limit_exceeded":
            raise
        changed()
    except (KeyError, ValueError, TypeError, UnicodeError):
        changed()


def read_child_target(db, user_id, child_id):
    child = own_preparation(db, user_id, child_id)
    if child.kind != "rehearsal":
        raise APIError(404, "rehearsal_not_found", "没有找到这次重练。")
    return verified_frozen_target(db, user_id, child)
