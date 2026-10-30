import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from simontalk_api.db import Base

OCCUPIED_CONNECTION_STATES = (
    "preparing",
    "negotiating",
    "configuring",
    "ready",
    "closing",
    "unknown",
)


class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    username: Mapped[str] = mapped_column(String(32), unique=True)
    display_name: Mapped[str] = mapped_column(String(60))
    password_hash: Mapped[str] = mapped_column(Text)
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    __table_args__ = (
        CheckConstraint("username ~ '^[a-z][a-z0-9_]{2,31}$'", name="username_format"),
        CheckConstraint("length(display_name) BETWEEN 1 AND 60", name="display_name_length"),
    )


class Invite(Base):
    __tablename__ = "invites"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    token_digest: Mapped[str] = mapped_column(String(64), unique=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    consumed_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    token_digest: Mapped[str] = mapped_column(String(64), unique=True)
    platform: Mapped[str] = mapped_column(String(8))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    __table_args__ = (CheckConstraint("platform IN ('web', 'mobile')", name="session_platform"),)


class PasswordResetGrant(Base):
    __tablename__ = "password_reset_grants"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    token_digest: Mapped[str] = mapped_column(String(64), unique=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class UserPreferences(Base):
    __tablename__ = "user_preferences"
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    difficulty: Mapped[str | None] = mapped_column(String(16))
    speech_pace: Mapped[str] = mapped_column(String(8), server_default="normal")
    subtitle_default: Mapped[bool] = mapped_column(Boolean, server_default="true")
    chinese_hints_enabled: Mapped[bool] = mapped_column(Boolean, server_default="true")
    translation_mode: Mapped[str] = mapped_column(String(16), server_default="on_demand")
    version: Mapped[int] = mapped_column(Integer, server_default="1")
    __table_args__ = (
        CheckConstraint(
            "difficulty IS NULL OR difficulty IN ('beginner', 'intermediate', 'advanced')",
            name="difficulty_values",
        ),
        CheckConstraint("speech_pace IN ('normal', 'slow')", name="pace_values"),
        CheckConstraint("translation_mode = 'on_demand'", name="translation_values"),
        CheckConstraint("version > 0", name="positive_version"),
    )


class RateLimitBucket(Base):
    __tablename__ = "rate_limit_buckets"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    window_start: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    attempts: Mapped[int] = mapped_column(Integer)
    __table_args__ = (CheckConstraint("attempts > 0", name="positive_attempts"),)


class PracticeSession(Base):
    __tablename__ = "practice_sessions"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    creation_key: Mapped[uuid.UUID] = mapped_column()
    request_digest: Mapped[str] = mapped_column(String(64))
    mode: Mapped[str] = mapped_column(String(16))
    kind: Mapped[str] = mapped_column(String(16), server_default="ordinary")
    source_session_id: Mapped[uuid.UUID | None] = mapped_column()
    source_kind: Mapped[str | None] = mapped_column(String(16))
    source_review_item_id: Mapped[uuid.UUID | None] = mapped_column()
    rehearsal_target: Mapped[dict | None] = mapped_column(JSONB(none_as_null=True))
    rehearsal_target_hash: Mapped[str | None] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16), server_default="created")
    state_reason: Mapped[str | None] = mapped_column(String(48))
    connection_epoch: Mapped[int] = mapped_column(Integer, server_default="0")
    configuration: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    __table_args__ = (
        UniqueConstraint("user_id", "creation_key", name="practice_creation_key"),
        UniqueConstraint("id", "user_id", name="practice_id_owner"),
        UniqueConstraint("id", "user_id", "kind", name="practice_id_owner_kind"),
        ForeignKeyConstraint(
            ["source_session_id", "user_id", "source_kind"],
            ["practice_sessions.id", "practice_sessions.user_id", "practice_sessions.kind"],
            name="practice_rehearsal_source",
            ondelete="CASCADE",
        ),
        CheckConstraint(
            "(kind = 'ordinary' AND source_session_id IS NULL AND source_kind IS NULL "
            "AND source_review_item_id IS NULL AND rehearsal_target IS NULL "
            "AND rehearsal_target_hash IS NULL) OR "
            "(kind = 'rehearsal' AND source_session_id IS NOT NULL "
            "AND source_kind IS NOT NULL AND source_kind = 'ordinary' "
            "AND source_session_id <> id AND source_review_item_id IS NOT NULL "
            "AND rehearsal_target IS NOT NULL AND jsonb_typeof(rehearsal_target) = 'object' "
            "AND rehearsal_target_hash IS NOT NULL "
            "AND rehearsal_target_hash ~ '^[a-f0-9]{64}$')",
            name="practice_rehearsal_shape",
        ),
        CheckConstraint("connection_epoch >= 0", name="practice_connection_epoch"),
        CheckConstraint("mode = 'free_chat'", name="practice_mode"),
        CheckConstraint(
            "status IN ('created','connecting','active','interrupted',"
            "'ending','completed','cancelled','failed')",
            name="practice_status",
        ),
        Index(
            "rehearsal_parent_seek",
            "source_session_id",
            "user_id",
            "created_at",
            "id",
            postgresql_where=text("kind = 'rehearsal'"),
        ),
        Index("practice_history_owner_seek", "user_id", "created_at", "id"),
        Index(
            "idle_practice_preparations",
            "created_at",
            "id",
            postgresql_where=text("status = 'created'"),
        ),
        Index(
            "one_open_practice_per_user",
            "user_id",
            unique=True,
            postgresql_where=text(
                "status IN ('created','connecting','active','interrupted','ending')"
            ),
        ),
    )


class RealtimeConnection(Base):
    __tablename__ = "realtime_connections"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column()
    user_id: Mapped[uuid.UUID] = mapped_column()
    creation_key: Mapped[uuid.UUID] = mapped_column()
    request_digest: Mapped[str] = mapped_column(String(64))
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    configuration: Mapped[dict] = mapped_column(JSONB)
    status: Mapped[str] = mapped_column(String(16), server_default="preparing")
    termination_status: Mapped[str] = mapped_column(String(16), server_default="not_started")
    state_reason: Mapped[str | None] = mapped_column(String(48))
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    lease_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    offer_digest: Mapped[str | None] = mapped_column(String(64))
    signalling_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    signalling_finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    __table_args__ = (
        CheckConstraint(
            "(offer_digest IS NULL) = (signalling_started_at IS NULL) AND "
            "(offer_digest IS NULL OR offer_digest ~ '^[a-f0-9]{64}$') AND "
            "(signalling_finished_at IS NULL OR (signalling_started_at IS NOT NULL "
            "AND signalling_finished_at >= signalling_started_at))",
            name="signalling_intent_evidence",
        ),
        CheckConstraint(
            "offer_digest IS NULL OR termination_status <> 'not_started'",
            name="signalling_termination_evidence",
        ),
        ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="connection_practice_owner",
            ondelete="CASCADE",
        ),
        UniqueConstraint("user_id", "creation_key", name="connection_creation_key"),
        UniqueConstraint("session_id", "epoch", name="connection_epoch"),
        UniqueConstraint(
            "id", "client_instance_id", "epoch", name="connection_observation_identity"
        ),
        CheckConstraint("epoch > 0", name="positive_connection_epoch"),
        CheckConstraint(
            "status IN ('preparing','negotiating','configuring','ready',"
            "'closing','closed','failed','unknown')",
            name="connection_status",
        ),
        CheckConstraint(
            "termination_status IN ('not_started','unknown','confirmed')",
            name="connection_termination_status",
        ),
        CheckConstraint(
            "(status='preparing' AND termination_status='not_started') OR "
            "(status IN ('negotiating','configuring','ready','closing','unknown') "
            "AND termination_status='unknown') OR "
            "(status IN ('closed','failed') AND termination_status IN ('not_started','confirmed'))",
            name="connection_termination_evidence",
        ),
        CheckConstraint(
            "(status IN ('closed','failed')) = (ended_at IS NOT NULL)",
            name="connection_ended_at",
        ),
        Index(
            "one_open_connection_per_user",
            "user_id",
            unique=True,
            postgresql_where=text("status NOT IN ('closed','failed')"),
        ),
        Index(
            "one_open_connection_per_practice",
            "session_id",
            unique=True,
            postgresql_where=text("status NOT IN ('closed','failed')"),
        ),
    )


class ConnectionObservation(Base):
    __tablename__ = "connection_observations"
    connection_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    sequence: Mapped[int] = mapped_column(Integer)
    code: Mapped[str] = mapped_column(String(32))
    elapsed_ms: Mapped[int] = mapped_column(Integer)
    reason: Mapped[str | None] = mapped_column(String(32))
    event_digest: Mapped[str] = mapped_column(String(64))
    source: Mapped[str] = mapped_column(String(16), server_default="client_observed")
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="observation_connection_identity",
            ondelete="CASCADE",
        ),
        UniqueConstraint("connection_id", "sequence", name="observation_sequence"),
        CheckConstraint(
            "sequence > 0 AND elapsed_ms BETWEEN 0 AND 86400000", name="observation_numeric_bounds"
        ),
        CheckConstraint("source = 'client_observed'", name="observation_source"),
        CheckConstraint("event_digest ~ '^[a-f0-9]{64}$'", name="observation_digest"),
        CheckConstraint(
            "code IN ('requesting_microphone','negotiating','transport_connected',"
            "'configuration_confirmed','microphone_active','playback_waiting','playback_blocked',"
            "'playback_playing','playback_paused','muted','unmuted','local_closed')",
            name="observation_code",
        ),
        CheckConstraint(
            "reason IS NULL OR (code = 'local_closed' AND reason IN "
            "('user_stop','background','disposed','account_changed','lease_expired',"
            "'connection_failed','configuration_failed','other'))",
            name="observation_reason",
        ),
    )


class FinalTranscript(Base):
    __tablename__ = "final_transcripts"
    connection_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    sequence: Mapped[int] = mapped_column(Integer)
    turn_id: Mapped[uuid.UUID] = mapped_column()
    turn_index: Mapped[int] = mapped_column(Integer)
    role: Mapped[str] = mapped_column(String(16))
    revision: Mapped[int] = mapped_column(Integer)
    text: Mapped[str] = mapped_column(Text)
    response_id: Mapped[uuid.UUID | None] = mapped_column()
    provider_item_id: Mapped[str | None] = mapped_column(String(256))
    event_digest: Mapped[str] = mapped_column(String(64))
    source: Mapped[str] = mapped_column(String(16), server_default="client_reported")
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    __table_args__ = (
        ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="transcript_connection_identity",
            ondelete="CASCADE",
        ),
        UniqueConstraint("connection_id", "sequence", name="transcript_sequence"),
        UniqueConstraint("connection_id", "turn_id", "revision", name="transcript_turn_revision"),
        CheckConstraint(
            "sequence > 0 AND turn_index > 0 AND revision > 0", name="transcript_numeric_bounds"
        ),
        CheckConstraint("source = 'client_reported'", name="transcript_source"),
        CheckConstraint("event_digest ~ '^[a-f0-9]{64}$'", name="transcript_digest"),
        CheckConstraint("octet_length(text) <= 8192", name="transcript_text_bytes"),
        CheckConstraint(
            "provider_item_id IS NULL OR length(provider_item_id) BETWEEN 1 AND 256",
            name="transcript_provider_item",
        ),
        CheckConstraint(
            "(role = 'user' AND response_id IS NULL) OR "
            "(role = 'assistant' AND response_id IS NOT NULL)",
            name="transcript_role_response",
        ),
    )


class PlaybackEvidence(Base):
    __tablename__ = "playback_evidence"
    connection_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    sequence: Mapped[int] = mapped_column(Integer)
    kind: Mapped[str] = mapped_column(String(16))
    response_id: Mapped[uuid.UUID] = mapped_column()
    turn_id: Mapped[uuid.UUID | None] = mapped_column()
    turn_index: Mapped[int | None] = mapped_column(Integer)
    transcript_revision: Mapped[int | None] = mapped_column(Integer)
    generated_text: Mapped[str | None] = mapped_column(Text)
    transcript_final: Mapped[bool | None] = mapped_column(Boolean)
    playback_revision: Mapped[int | None] = mapped_column(Integer)
    delivery_status: Mapped[str | None] = mapped_column(String(16))
    played_text: Mapped[str | None] = mapped_column(Text)
    played_until_ms: Mapped[int | None] = mapped_column(Integer)
    evidence_source: Mapped[str | None] = mapped_column(String(32))
    stop_boundary_ms: Mapped[int | None] = mapped_column(Integer)
    reason: Mapped[str | None] = mapped_column(String(16))
    event_digest: Mapped[str] = mapped_column(String(64))
    source: Mapped[str] = mapped_column(String(16), server_default="client_reported")
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="playback_connection_identity",
            ondelete="CASCADE",
        ),
        UniqueConstraint("connection_id", "sequence", name="playback_sequence"),
        CheckConstraint("sequence > 0", name="playback_numeric_bounds"),
        CheckConstraint("source = 'client_reported'", name="playback_source"),
        CheckConstraint("event_digest ~ '^[a-f0-9]{64}$'", name="playback_digest"),
        CheckConstraint("kind IN ('alignment','freeze','revoke')", name="playback_kind"),
        CheckConstraint(
            "(kind = 'revoke' AND turn_id IS NULL AND turn_index IS NULL AND "
            "transcript_revision IS NULL AND generated_text IS NULL AND transcript_final IS NULL "
            "AND playback_revision IS NULL AND delivery_status IS NULL AND played_text IS NULL "
            "AND played_until_ms IS NULL AND evidence_source IS NULL AND stop_boundary_ms IS NULL "
            "AND reason IS NULL) OR (kind IN ('alignment','freeze') AND turn_id IS NOT NULL "
            "AND turn_index IS NOT NULL AND turn_index > 0 AND transcript_revision IS NOT NULL "
            "AND transcript_revision >= 0 AND generated_text IS NOT NULL AND "
            "transcript_final IS NOT NULL "
            "AND playback_revision IS NOT NULL AND playback_revision >= 0 AND "
            "delivery_status IS NOT NULL "
            "AND played_text IS NOT NULL AND evidence_source IS NOT NULL)",
            name="playback_event_shape",
        ),
        CheckConstraint(
            "kind = 'revoke' OR (octet_length(generated_text) <= 8192 AND "
            "octet_length(played_text) <= 8192)",
            name="playback_text_bytes",
        ),
        CheckConstraint(
            "kind = 'revoke' OR ((kind = 'alignment' AND transcript_revision > 0 AND "
            "playback_revision > 0 "
            "AND stop_boundary_ms IS NULL AND reason IS NULL) OR (kind = 'freeze' AND"
            " stop_boundary_ms IS NOT NULL "
            "AND stop_boundary_ms BETWEEN 0 AND 86400000 AND reason IS NOT NULL AND "
            "reason IN ('interrupted','normal_end') "
            "AND (played_until_ms IS NULL OR played_until_ms <= stop_boundary_ms)))",
            name="playback_freeze_shape",
        ),
        CheckConstraint(
            "kind = 'revoke' OR (transcript_revision > 0 OR (generated_text = '' AND "
            "NOT transcript_final "
            "AND playback_revision = 0))",
            name="playback_untranscribed",
        ),
        CheckConstraint(
            "kind = 'revoke' OR (playback_revision > 0 OR delivery_status = 'unknown')",
            name="playback_unaligned",
        ),
        CheckConstraint(
            "kind = 'revoke' OR ((delivery_status = 'unknown' AND played_text = '' "
            "AND played_until_ms IS NULL "
            "AND evidence_source = 'unknown') OR (evidence_source = 'device_output_aligned' AND "
            "((delivery_status = 'not_played' AND transcript_final AND played_text = "
            "'' AND played_until_ms IS NOT NULL "
            "AND played_until_ms = 0) OR (delivery_status IN ('partial','played') AND"
            " played_text <> '' "
            "AND played_until_ms IS NOT NULL AND played_until_ms BETWEEN 1 AND 86400000 AND "
            "((delivery_status = 'partial' AND generated_text <> played_text AND "
            "left(generated_text,length(played_text)) = played_text) OR "
            "(delivery_status = 'played' "
            "AND transcript_final AND generated_text = played_text))))))",
            name="playback_alignment_shape",
        ),
    )


class PracticeCompletion(Base):
    __tablename__ = "practice_completions"
    session_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column()
    origin_connection_id: Mapped[uuid.UUID] = mapped_column()
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    end_key: Mapped[uuid.UUID] = mapped_column()
    request_digest: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16))
    accepted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    final_upload_deadline: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    sealed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    input_revision: Mapped[int] = mapped_column(Integer, default=0)
    input_hash: Mapped[str | None] = mapped_column(String(64))
    coverage: Mapped[str] = mapped_column(String(16), default="pending")
    connection_count: Mapped[int] = mapped_column(Integer)
    gap_codes: Mapped[list] = mapped_column(JSONB, default=list)
    __table_args__ = (
        ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="completion_practice_owner",
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["origin_connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="completion_origin_identity",
            ondelete="CASCADE",
        ),
        UniqueConstraint("user_id", "end_key", name="completion_end_key"),
        CheckConstraint("epoch > 0 AND connection_count > 0", name="completion_numeric_bounds"),
        CheckConstraint("request_digest ~ '^[a-f0-9]{64}$'", name="completion_request_digest"),
        CheckConstraint(
            "final_upload_deadline = accepted_at + interval '30 seconds'",
            name="completion_fixed_deadline",
        ),
        CheckConstraint(
            "(status='ending' AND sealed_at IS NULL AND input_revision=0 AND "
            "input_hash IS NULL AND coverage='pending') OR (status='sealed' AND "
            "sealed_at IS NOT NULL AND sealed_at >= accepted_at AND input_revision=1 "
            "AND input_hash IS NOT NULL AND input_hash ~ '^[a-f0-9]{64}$' AND "
            "coverage IN ('complete','incomplete'))",
            name="completion_seal_state",
        ),
        Index(
            "due_practice_completions",
            "final_upload_deadline",
            "session_id",
            postgresql_where=text("status = 'ending'"),
        ),
    )


class CompletionConnection(Base):
    __tablename__ = "completion_connections"
    connection_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("practice_completions.session_id", ondelete="CASCADE"), index=True
    )
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    empty_not_started: Mapped[bool] = mapped_column(Boolean)
    manifest: Mapped[dict | None] = mapped_column(JSONB(none_as_null=True))
    manifest_digest: Mapped[str | None] = mapped_column(String(64))
    manifest_received_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    snapshot: Mapped[dict | None] = mapped_column(JSONB(none_as_null=True))
    snapshot_hash: Mapped[str | None] = mapped_column(String(64))
    __table_args__ = (
        ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="completion_member_identity",
            ondelete="CASCADE",
        ),
        CheckConstraint("epoch > 0", name="completion_member_epoch"),
        CheckConstraint(
            "(manifest IS NULL AND manifest_digest IS NULL AND "
            "manifest_received_at IS NULL) OR (manifest IS NOT NULL AND "
            "manifest_digest IS NOT NULL AND manifest_digest ~ "
            "'^[a-f0-9]{64}$' AND manifest_received_at IS NOT NULL)",
            name="completion_manifest_state",
        ),
        CheckConstraint(
            "(snapshot IS NULL AND snapshot_hash IS NULL) OR (snapshot IS NOT NULL "
            "AND snapshot_hash IS NOT NULL AND snapshot_hash ~ '^[a-f0-9]{64}$')",
            name="completion_snapshot_state",
        ),
    )


class TerminationCheck(Base):
    __tablename__ = "termination_checks"
    connection_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    client_instance_id: Mapped[uuid.UUID] = mapped_column()
    epoch: Mapped[int] = mapped_column(Integer)
    attempt_digest: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16), default="blocked")
    reason: Mapped[str] = mapped_column(String(32), default="capability_unavailable")
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    __table_args__ = (
        ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="termination_check_identity",
            ondelete="CASCADE",
        ),
        CheckConstraint("epoch > 0 AND attempts = 0", name="termination_check_attempts"),
        CheckConstraint("attempt_digest ~ '^[a-f0-9]{64}$'", name="termination_check_digest"),
        CheckConstraint(
            "status = 'blocked' AND reason = 'capability_unavailable'",
            name="termination_check_unavailable",
        ),
    )


class ReviewInput(Base):
    __tablename__ = "review_inputs"
    session_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    input_revision: Mapped[int] = mapped_column(Integer, primary_key=True)
    policy_version: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column()
    practice_input_hash: Mapped[str] = mapped_column(String(64))
    review_input_hash: Mapped[str] = mapped_column(String(64))
    snapshot: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    __table_args__ = (
        ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="review_input_practice_owner",
            ondelete="CASCADE",
        ),
        CheckConstraint("input_revision = 1", name="review_input_revision"),
        CheckConstraint("policy_version = 'review_input_v1'", name="review_input_policy"),
        CheckConstraint(
            "practice_input_hash ~ '^[a-f0-9]{64}$'", name="review_input_practice_hash"
        ),
        CheckConstraint("review_input_hash ~ '^[a-f0-9]{64}$'", name="review_input_hash"),
    )


class ReviewJob(Base):
    __tablename__ = "review_jobs"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column()
    user_id: Mapped[uuid.UUID] = mapped_column()
    input_revision: Mapped[int] = mapped_column(Integer)
    policy_version: Mapped[str] = mapped_column(String(32))
    practice_input_hash: Mapped[str] = mapped_column(String(64))
    review_input_hash: Mapped[str] = mapped_column(String(64))
    generation_policy_version: Mapped[str] = mapped_column(String(32))
    status: Mapped[str] = mapped_column(String(24))
    attempt_count: Mapped[int] = mapped_column(Integer, default=0)
    next_attempt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    run_token: Mapped[uuid.UUID | None] = mapped_column()
    lease_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    gateway_config_id: Mapped[str | None] = mapped_column(String(128))
    gateway_idempotent: Mapped[bool | None] = mapped_column(Boolean)
    outcome_unknown: Mapped[bool] = mapped_column(Boolean, default=False)
    error_code: Mapped[str | None] = mapped_column(String(48))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    __table_args__ = (
        ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="review_job_practice_owner",
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["session_id", "input_revision", "policy_version"],
            [
                "review_inputs.session_id",
                "review_inputs.input_revision",
                "review_inputs.policy_version",
            ],
            name="review_job_source_input",
            ondelete="CASCADE",
        ),
        UniqueConstraint(
            "session_id",
            "input_revision",
            "policy_version",
            "generation_policy_version",
            name="review_job_input_generation",
        ),
        CheckConstraint("attempt_count BETWEEN 0 AND 3", name="review_job_attempt_limit"),
        CheckConstraint(
            "generation_policy_version = 'review_generation_v1'", name="review_job_policy"
        ),
        CheckConstraint(
            "practice_input_hash ~ '^[a-f0-9]{64}$' AND review_input_hash ~ '^[a-f0-9]{64}$'",
            name="review_job_hashes",
        ),
        CheckConstraint(
            "status IN ('queued','running','retry_wait','blocked','succeeded',"
            "'no_suggestions','no_evaluable_content','failed','invalidated')",
            name="review_job_status",
        ),
        CheckConstraint(
            "(status = 'running' AND run_token IS NOT NULL AND lease_expires_at IS NOT NULL)"
            " OR (status <> 'running' AND run_token IS NULL AND lease_expires_at IS NULL)",
            name="review_job_running_lease",
        ),
        Index("review_job_due", "status", "next_attempt_at", "created_at"),
    )


class ReviewAttempt(Base):
    __tablename__ = "review_attempts"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    job_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("review_jobs.id", ondelete="SET NULL")
    )
    source_job_id: Mapped[uuid.UUID] = mapped_column()
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    review_input_hash: Mapped[str] = mapped_column(String(64))
    ordinal: Mapped[int] = mapped_column(Integer)
    run_token: Mapped[uuid.UUID] = mapped_column(unique=True)
    logical_request_key: Mapped[str] = mapped_column(String(64))
    gateway_config_id: Mapped[str] = mapped_column(String(128))
    gateway_idempotent: Mapped[bool] = mapped_column(Boolean)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    lease_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    outcome: Mapped[str] = mapped_column(String(24), default="outcome_unknown")
    input_tokens: Mapped[int | None] = mapped_column(Integer)
    output_tokens: Mapped[int | None] = mapped_column(Integer)
    __table_args__ = (
        UniqueConstraint("source_job_id", "ordinal", name="review_attempt_ordinal"),
        CheckConstraint("ordinal BETWEEN 1 AND 3", name="review_attempt_limit"),
        CheckConstraint(
            "outcome IN ('outcome_unknown','succeeded','no_suggestions',"
            "'invalid_output','retryable_error','permanent_error','discarded')",
            name="review_attempt_outcome",
        ),
        CheckConstraint(
            "(input_tokens IS NULL OR input_tokens >= 0) AND "
            "(output_tokens IS NULL OR output_tokens >= 0)",
            name="review_attempt_usage",
        ),
    )


class ReviewResult(Base):
    __tablename__ = "review_results"
    job_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("review_jobs.id", ondelete="CASCADE"), primary_key=True
    )
    version: Mapped[int] = mapped_column(Integer, default=1)
    result_hash: Mapped[str] = mapped_column(String(64))
    snapshot: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    __table_args__ = (
        CheckConstraint("version = 1", name="review_result_version"),
        CheckConstraint("result_hash ~ '^[a-f0-9]{64}$'", name="review_result_hash"),
    )


class ReviewAction(Base):
    __tablename__ = "review_actions"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    idempotency_key: Mapped[uuid.UUID] = mapped_column()
    operation: Mapped[str] = mapped_column(String(16))
    request_digest: Mapped[str] = mapped_column(String(64))
    job_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("review_jobs.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    __table_args__ = (
        UniqueConstraint("user_id", "idempotency_key", name="review_action_user_key"),
        CheckConstraint("operation IN ('create','retry')", name="review_action_operation"),
        CheckConstraint("request_digest ~ '^[a-f0-9]{64}$'", name="review_action_digest"),
    )


class PracticeDeletionReceipt(Base):
    __tablename__ = "practice_deletion_receipts"
    # Decisions also survive replay into backups predating the account itself.
    user_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    request_key: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    session_id: Mapped[uuid.UUID] = mapped_column()
    scope_version: Mapped[str] = mapped_column(String(64))
    record_count: Mapped[int] = mapped_column(Integer)
    rehearsal_count: Mapped[int] = mapped_column(Integer)
    connection_pending: Mapped[bool] = mapped_column(Boolean)
    deleted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    members: Mapped[list] = mapped_column(JSONB)
    __table_args__ = (
        CheckConstraint("scope_version ~ '^[a-f0-9]{64}$'", name="deletion_scope_digest"),
        CheckConstraint(
            "jsonb_typeof(members) = 'array' AND jsonb_array_length(members) = record_count",
            name="deletion_member_count",
        ),
        CheckConstraint(
            "record_count > 0 AND rehearsal_count >= 0 AND rehearsal_count <= record_count",
            name="deletion_counts",
        ),
    )
