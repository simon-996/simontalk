"""Persist connection attempts and conservative business leases, without provider calls."""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "8e637f95bca1"
down_revision = "2acda42539f0"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "practice_sessions",
        sa.Column("connection_epoch", sa.Integer(), server_default="0", nullable=False),
    )
    op.create_unique_constraint("practice_id_owner", "practice_sessions", ["id", "user_id"])
    op.create_check_constraint(
        "practice_connection_epoch", "practice_sessions", "connection_epoch >= 0"
    )
    op.create_table(
        "realtime_connections",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("creation_key", sa.Uuid(), nullable=False),
        sa.Column("request_digest", sa.String(64), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("configuration", postgresql.JSONB(), nullable=False),
        sa.Column("status", sa.String(16), server_default="preparing", nullable=False),
        sa.Column(
            "termination_status", sa.String(16), server_default="not_started", nullable=False
        ),
        sa.Column("state_reason", sa.String(48), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="connection_practice_owner",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("user_id", "creation_key", name="connection_creation_key"),
        sa.UniqueConstraint("session_id", "epoch", name="connection_epoch"),
        sa.CheckConstraint("epoch > 0", name="positive_connection_epoch"),
        sa.CheckConstraint(
            "status IN ('preparing','negotiating','configuring','ready',"
            "'closing','closed','failed','unknown')",
            name="connection_status",
        ),
        sa.CheckConstraint(
            "termination_status IN ('not_started','unknown','confirmed')",
            name="connection_termination_status",
        ),
        sa.CheckConstraint(
            "(status='preparing' AND termination_status='not_started') OR "
            "(status IN ('negotiating','configuring','ready','closing','unknown') "
            "AND termination_status='unknown') OR "
            "(status IN ('closed','failed') AND termination_status IN ('not_started','confirmed'))",
            name="connection_termination_evidence",
        ),
        sa.CheckConstraint(
            "(status IN ('closed','failed')) = (ended_at IS NOT NULL)", name="connection_ended_at"
        ),
    )
    op.create_index(
        "ix_realtime_connections_lease_expires_at", "realtime_connections", ["lease_expires_at"]
    )
    op.create_index(
        "one_open_connection_per_user",
        "realtime_connections",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("status NOT IN ('closed','failed')"),
    )
    op.create_index(
        "one_open_connection_per_practice",
        "realtime_connections",
        ["session_id"],
        unique=True,
        postgresql_where=sa.text("status NOT IN ('closed','failed')"),
    )


def downgrade():
    op.drop_table("realtime_connections")
    op.drop_constraint("practice_connection_epoch", "practice_sessions", type_="check")
    op.drop_constraint("practice_id_owner", "practice_sessions", type_="unique")
    op.drop_column("practice_sessions", "connection_epoch")
