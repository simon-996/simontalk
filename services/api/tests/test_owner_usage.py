"""Owner read-only usage endpoints across ordinary, rehearsal, review, and deletion."""

from datetime import timedelta
from uuid import UUID, uuid4

from test_practice_preparation import account as account

from simontalk_api.models import (
    PracticeSession,
    RealtimeConnection,
    ReviewAttempt,
    ReviewInput,
    ReviewJob,
    User,
    UserPreferences,
    VoiceResponseUsage,
)
from simontalk_api.practice_deletion import DeletionInput, delete_practice, read_scope
from simontalk_api.security import PASSWORD_HASHER, create_session, digest, now


def _second_account(factory):
    with factory.begin() as db:
        user = User(
            username=f"peer_{uuid4().hex[:10]}",
            display_name="Peer",
            password_hash=PASSWORD_HASHER.hash("StrongPassword123!"),
        )
        db.add(user)
        db.flush()
        db.add(UserPreferences(user_id=user.id, difficulty="intermediate"))
        token = create_session(db, user, "mobile")
        return user.id, {
            "Authorization": f"Bearer {token}",
            "X-Account-ID": str(user.id),
        }


def _seed_practice_with_usage(
    db,
    user_id,
    *,
    kind="ordinary",
    source_id=None,
    termination="confirmed",
    conn_status="closed",
    usages=(),
    review_attempts=(),
):
    stamp = now()
    session_id = uuid4()
    session = PracticeSession(
        id=session_id,
        user_id=user_id,
        creation_key=uuid4(),
        request_digest=digest(f"req-{session_id}"),
        mode="free_chat",
        kind=kind,
        source_session_id=source_id,
        source_kind="ordinary" if kind == "rehearsal" else None,
        source_review_item_id=uuid4() if kind == "rehearsal" else None,
        rehearsal_target={"quote": "hi"} if kind == "rehearsal" else None,
        rehearsal_target_hash=digest("target") if kind == "rehearsal" else None,
        status="completed",
        connection_epoch=1,
        configuration={
            "schema_version": 1,
            "effective_difficulty": "beginner",
            "preferences": {
                "difficulty": "beginner",
                "speech_pace": "normal",
                "subtitle_default": True,
                "chinese_hints_enabled": True,
                "translation_mode": "on_demand",
                "version": 1,
            },
            "provider": {
                "provider": "dashscope",
                "region": "cn-beijing",
                "model": "qwen3.8-omni-flash-realtime",
                "config_id": "cfg-1",
            },
        },
        created_at=stamp,
        ended_at=stamp,
    )
    db.add(session)
    db.flush()
    conn_id = uuid4()
    connection = RealtimeConnection(
        id=conn_id,
        session_id=session_id,
        user_id=user_id,
        creation_key=uuid4(),
        request_digest=digest(f"conn-{conn_id}"),
        client_instance_id=uuid4(),
        epoch=1,
        configuration=session.configuration["provider"],
        status=conn_status,
        termination_status=termination,
        last_seen_at=stamp,
        lease_expires_at=stamp + timedelta(seconds=45),
        ended_at=stamp if conn_status in {"closed", "failed"} else None,
        offer_digest=digest(f"offer-{conn_id}"),
        signalling_started_at=stamp,
        signalling_finished_at=stamp,
    )
    db.add(connection)
    db.flush()
    for idx, spec in enumerate(usages, start=1):
        db.add(
            VoiceResponseUsage(
                connection_id=conn_id,
                response_digest=digest(f"{conn_id}-{idx}"),
                status=spec.get("status", "completed"),
                input_tokens=spec.get("in"),
                output_tokens=spec.get("out"),
                input_text_tokens=spec.get("in_text"),
                input_audio_tokens=spec.get("in_audio"),
                output_text_tokens=spec.get("out_text"),
                output_audio_tokens=spec.get("out_audio"),
                recorded_at=spec.get("at", stamp),
            )
        )
    if review_attempts:
        review_hash = digest(f"rev-{session_id}")
        practice_hash = digest(f"prac-{session_id}")
        db.add(
            ReviewInput(
                session_id=session_id,
                input_revision=1,
                policy_version="review_input_v1",
                user_id=user_id,
                practice_input_hash=practice_hash,
                review_input_hash=review_hash,
                snapshot={"turns": []},
            )
        )
        db.flush()
        job = ReviewJob(
            session_id=session_id,
            user_id=user_id,
            input_revision=1,
            policy_version="review_input_v1",
            practice_input_hash=practice_hash,
            review_input_hash=review_hash,
            generation_policy_version="review_generation_v1",
            status="succeeded",
            attempt_count=len(review_attempts),
        )
        db.add(job)
        db.flush()
        for ordinal, spec in enumerate(review_attempts, start=1):
            db.add(
                ReviewAttempt(
                    job_id=job.id,
                    source_job_id=job.id,
                    user_id=user_id,
                    review_input_hash=review_hash,
                    ordinal=ordinal,
                    run_token=uuid4(),
                    logical_request_key=digest(f"{job.id}-{ordinal}"),
                    gateway_config_id="qwen-review-v1",
                    gateway_idempotent=False,
                    started_at=spec.get("at", stamp),
                    lease_expires_at=stamp + timedelta(seconds=15),
                    finished_at=spec.get("finished_at"),
                    outcome=spec.get("outcome", "succeeded"),
                    input_tokens=spec.get("in"),
                    output_tokens=spec.get("out"),
                )
            )
    return session_id, conn_id


def test_empty_account_usage_and_identity_guards(client, factory, account):
    identity, headers = account
    owner_id = identity["user"]["id"]
    peer_id, peer_headers = _second_account(factory)

    assert client.get("/v1/usage").status_code == 401
    mismatch = client.get(
        "/v1/usage",
        headers={**headers, "X-Account-ID": str(peer_id)},
    )
    assert mismatch.status_code == 409 and mismatch.json()["code"] == "account_changed"

    empty = client.get("/v1/usage", headers=headers)
    assert empty.status_code == 200
    body = empty.json()
    assert body["schema_version"] == "account_usage_v1"
    assert body["source"] == "server_recorded"
    assert body["account_id"] == owner_id
    assert body["latest_recorded_at"] is None
    assert body["connection_pending_count"] == 0
    assert body["deleted_practice_count"] == 0
    assert body["voice_ordinary"]["response_count"] == 0
    assert body["voice_rehearsal"]["response_count"] == 0
    assert body["review"]["attempt_count"] == 0

    missing = client.get(f"/v1/usage/practices/{uuid4()}", headers=headers)
    assert missing.status_code == 404 and missing.json()["code"] == "practice_not_found"
    assert client.get("/v1/usage", headers=peer_headers).status_code == 200


def test_aggregates_ordinary_rehearsal_and_review_and_retains_deleted_usage(
    client, factory, account
):
    identity, headers = account
    owner_id = UUID(identity["user"]["id"])
    peer_id, peer_headers = _second_account(factory)
    t1 = now() - timedelta(minutes=10)
    t2 = now() - timedelta(minutes=5)
    t3 = now() - timedelta(minutes=1)

    with factory.begin() as db:
        ordinary_id, _ = _seed_practice_with_usage(
            db,
            owner_id,
            kind="ordinary",
            termination="unknown",
            conn_status="unknown",
            usages=[
                {
                    "in": 770,
                    "out": 29,
                    "in_text": 728,
                    "in_audio": 42,
                    "out_text": 7,
                    "out_audio": 22,
                    "at": t1,
                },
                {
                    "status": "cancelled",
                    "in": None,
                    "out": None,
                    "in_text": None,
                    "in_audio": None,
                    "out_text": None,
                    "out_audio": None,
                    "at": t2,
                },
            ],
            review_attempts=[
                {"outcome": "no_suggestions", "in": 645, "out": 5, "at": t2, "finished_at": t2},
                {"outcome": "outcome_unknown", "in": None, "out": None, "at": t3},
            ],
        )
        rehearsal_id, _ = _seed_practice_with_usage(
            db,
            owner_id,
            kind="rehearsal",
            source_id=ordinary_id,
            usages=[
                {
                    "in": 310,
                    "out": 18,
                    "in_text": 290,
                    "in_audio": 20,
                    "out_text": None,
                    "out_audio": None,
                    "at": t2,
                }
            ],
            review_attempts=[
                {"outcome": "succeeded", "in": 500, "out": 40, "at": t2, "finished_at": t2}
            ],
        )
        _seed_practice_with_usage(
            db,
            peer_id,
            kind="ordinary",
            usages=[{"in": 9999, "out": 9999, "at": t3}],
            review_attempts=[{"in": 8888, "out": 8888, "at": t3}],
        )

    assert client.get(f"/v1/usage/practices/{ordinary_id}", headers=peer_headers).status_code == 404

    practice_res = client.get(f"/v1/usage/practices/{ordinary_id}", headers=headers)
    assert practice_res.status_code == 200
    practice_body = practice_res.json()
    assert practice_body["schema_version"] == "practice_usage_v1"
    assert practice_body["session_id"] == str(ordinary_id)
    assert practice_body["kind"] == "ordinary"
    assert practice_body["connection_count"] == 1
    assert practice_body["connection_pending"] is True
    assert practice_body["voice"] == {
        "response_count": 2,
        "incomplete_count": 1,
        "detail_incomplete_count": 1,
        "known_input_tokens": 770,
        "known_output_tokens": 29,
        "known_input_text_tokens": 728,
        "known_input_audio_tokens": 42,
        "known_output_text_tokens": 7,
        "known_output_audio_tokens": 22,
    }
    assert practice_body["review"] == {
        "attempt_count": 2,
        "incomplete_count": 1,
        "known_input_tokens": 645,
        "known_output_tokens": 5,
    }

    before_delete = client.get("/v1/usage", headers=headers).json()
    assert before_delete["connection_pending_count"] == 1
    assert before_delete["deleted_practice_count"] == 0
    assert before_delete["voice_ordinary"]["response_count"] == 2
    assert before_delete["voice_ordinary"]["deleted_response_count"] == 0
    assert before_delete["voice_rehearsal"]["response_count"] == 1
    assert before_delete["voice_rehearsal"]["detail_incomplete_count"] == 1
    assert before_delete["voice_rehearsal"]["known_input_tokens"] == 310
    assert before_delete["review"] == {
        "attempt_count": 3,
        "deleted_attempt_count": 0,
        "incomplete_count": 1,
        "known_input_tokens": 1145,
        "known_output_tokens": 45,
    }

    with factory() as db:
        scope = read_scope(db, owner_id, ordinary_id)
        delete_practice(
            db,
            owner_id,
            ordinary_id,
            DeletionInput(scope_version=scope["scope_version"]),
            uuid4(),
        )

    for deleted_id in (ordinary_id, rehearsal_id):
        assert client.get(f"/v1/usage/practices/{deleted_id}", headers=headers).status_code == 404

    after_delete = client.get("/v1/usage", headers=headers).json()
    serialized = str(after_delete)
    assert str(ordinary_id) not in serialized and str(rehearsal_id) not in serialized
    assert after_delete["deleted_practice_count"] == 2
    assert after_delete["connection_pending_count"] == 1
    assert after_delete["voice_ordinary"]["response_count"] == 2
    assert after_delete["voice_ordinary"]["deleted_response_count"] == 2
    assert after_delete["voice_ordinary"]["known_input_tokens"] == 770
    assert after_delete["voice_rehearsal"]["response_count"] == 1
    assert after_delete["voice_rehearsal"]["deleted_response_count"] == 1
    assert after_delete["voice_rehearsal"]["known_input_tokens"] == 310
    assert after_delete["review"] == {
        "attempt_count": 3,
        "deleted_attempt_count": 3,
        "incomplete_count": 1,
        "known_input_tokens": 1145,
        "known_output_tokens": 45,
    }
