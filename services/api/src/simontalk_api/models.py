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
    status: Mapped[str] = mapped_column(String(16), server_default="created")
    connection_epoch: Mapped[int] = mapped_column(Integer, server_default="0")
    configuration: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    __table_args__ = (
        UniqueConstraint("user_id", "creation_key", name="practice_creation_key"),
        UniqueConstraint("id", "user_id", name="practice_id_owner"),
        CheckConstraint("connection_epoch >= 0", name="practice_connection_epoch"),
        CheckConstraint("mode = 'free_chat'", name="practice_mode"),
        CheckConstraint(
            "status IN ('created','connecting','active','interrupted',"
            "'ending','completed','cancelled','failed')",
            name="practice_status",
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
    __table_args__ = (
        ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="connection_practice_owner",
            ondelete="CASCADE",
        ),
        UniqueConstraint("user_id", "creation_key", name="connection_creation_key"),
        UniqueConstraint("session_id", "epoch", name="connection_epoch"),
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
