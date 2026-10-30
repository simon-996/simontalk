"""freeze practice inputs and record termination intent"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "0e1874613efa"
down_revision = "d41a7c9e2b60"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "practice_completions",
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("origin_connection_id", sa.Uuid(), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("end_key", sa.Uuid(), nullable=False),
        sa.Column("request_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("final_upload_deadline", sa.DateTime(timezone=True), nullable=False),
        sa.Column("sealed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("input_revision", sa.Integer(), nullable=False),
        sa.Column("input_hash", sa.String(length=64), nullable=True),
        sa.Column("coverage", sa.String(length=16), nullable=False),
        sa.Column("connection_count", sa.Integer(), nullable=False),
        sa.Column("gap_codes", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.CheckConstraint(
            "(status='ending' AND sealed_at IS NULL AND input_revision=0 AND input_hash IS "
            "NULL AND coverage='pending') OR (status='sealed' AND sealed_at IS NOT NULL AND "
            "sealed_at >= accepted_at AND input_revision=1 AND input_hash IS "
            "NOT NULL AND input_hash ~ "
            "'^[a-f0-9]{64}$' AND coverage IN ('complete','incomplete'))",
            name="completion_seal_state",
        ),
        sa.CheckConstraint(
            "final_upload_deadline = accepted_at + interval '30 seconds'",
            name="completion_fixed_deadline",
        ),
        sa.CheckConstraint("request_digest ~ '^[a-f0-9]{64}$'", name="completion_request_digest"),
        sa.CheckConstraint("epoch > 0 AND connection_count > 0", name="completion_numeric_bounds"),
        sa.ForeignKeyConstraint(
            ["origin_connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="completion_origin_identity",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="completion_practice_owner",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("session_id"),
        sa.UniqueConstraint("user_id", "end_key", name="completion_end_key"),
    )
    op.create_index(
        "due_practice_completions",
        "practice_completions",
        ["final_upload_deadline", "session_id"],
        unique=False,
        postgresql_where=sa.text("status = 'ending'"),
    )
    op.create_table(
        "termination_checks",
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("attempt_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("reason", sa.String(length=32), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("attempt_digest ~ '^[a-f0-9]{64}$'", name="termination_check_digest"),
        sa.CheckConstraint(
            "status = 'blocked' AND reason = 'capability_unavailable'",
            name="termination_check_unavailable",
        ),
        sa.CheckConstraint("epoch > 0 AND attempts = 0", name="termination_check_attempts"),
        sa.ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="termination_check_identity",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("connection_id"),
    )
    op.create_table(
        "completion_connections",
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("empty_not_started", sa.Boolean(), nullable=False),
        sa.Column(
            "manifest", postgresql.JSONB(none_as_null=True, astext_type=sa.Text()), nullable=True
        ),
        sa.Column("manifest_digest", sa.String(length=64), nullable=True),
        sa.Column("manifest_received_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "snapshot", postgresql.JSONB(none_as_null=True, astext_type=sa.Text()), nullable=True
        ),
        sa.Column("snapshot_hash", sa.String(length=64), nullable=True),
        sa.CheckConstraint(
            "(manifest IS NULL AND manifest_digest IS NULL AND manifest_received_at IS "
            "NULL) OR (manifest IS NOT NULL AND manifest_digest IS NOT NULL "
            "AND manifest_digest ~ '^[a-f0-9]{64}$' AND "
            "manifest_received_at IS NOT NULL)",
            name="completion_manifest_state",
        ),
        sa.CheckConstraint(
            "(snapshot IS NULL AND snapshot_hash IS NULL) OR (snapshot IS NOT NULL AND "
            "snapshot_hash IS NOT NULL AND snapshot_hash ~ '^[a-f0-9]{64}$')",
            name="completion_snapshot_state",
        ),
        sa.CheckConstraint("epoch > 0", name="completion_member_epoch"),
        sa.ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="completion_member_identity",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id"], ["practice_completions.session_id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("connection_id"),
    )
    op.create_index(
        op.f("ix_completion_connections_session_id"),
        "completion_connections",
        ["session_id"],
        unique=False,
    )


def downgrade():
    op.drop_index(op.f("ix_completion_connections_session_id"), table_name="completion_connections")
    op.drop_table("completion_connections")
    op.drop_table("termination_checks")
    op.drop_index(
        "due_practice_completions",
        table_name="practice_completions",
        postgresql_where=sa.text("status = 'ending'"),
    )
    op.drop_table("practice_completions")
