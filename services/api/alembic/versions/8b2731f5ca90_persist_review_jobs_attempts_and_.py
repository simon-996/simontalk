"""persist review jobs attempts and validated results"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "8b2731f5ca90"
down_revision = "4c913f2d8e71"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "review_jobs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("input_revision", sa.Integer(), nullable=False),
        sa.Column("policy_version", sa.String(length=32), nullable=False),
        sa.Column("practice_input_hash", sa.String(length=64), nullable=False),
        sa.Column("review_input_hash", sa.String(length=64), nullable=False),
        sa.Column("generation_policy_version", sa.String(length=32), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("attempt_count", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("run_token", sa.Uuid(), nullable=True),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("gateway_config_id", sa.String(length=128), nullable=True),
        sa.Column("gateway_idempotent", sa.Boolean(), nullable=True),
        sa.Column("outcome_unknown", sa.Boolean(), nullable=False),
        sa.Column("error_code", sa.String(length=48), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "(status = 'running' AND run_token IS NOT NULL AND lease_expires_at IS NOT NULL)"
            " OR (status <> 'running' AND run_token IS NULL AND lease_expires_at IS NULL)",
            name="review_job_running_lease",
        ),
        sa.CheckConstraint(
            "generation_policy_version = 'review_generation_v1'", name="review_job_policy"
        ),
        sa.CheckConstraint(
            "practice_input_hash ~ '^[a-f0-9]{64}$' AND review_input_hash ~ '^[a-f0-9]{64}$'",
            name="review_job_hashes",
        ),
        sa.CheckConstraint(
            "status IN ('queued','running','retry_wait','blocked','succeeded',"
            "'no_suggestions','no_evaluable_content','failed','invalidated')",
            name="review_job_status",
        ),
        sa.CheckConstraint("attempt_count BETWEEN 0 AND 3", name="review_job_attempt_limit"),
        sa.ForeignKeyConstraint(
            ["session_id", "input_revision", "policy_version"],
            [
                "review_inputs.session_id",
                "review_inputs.input_revision",
                "review_inputs.policy_version",
            ],
            name="review_job_source_input",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="review_job_practice_owner",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "session_id",
            "input_revision",
            "policy_version",
            "generation_policy_version",
            name="review_job_input_generation",
        ),
    )
    op.create_index(
        "review_job_due", "review_jobs", ["status", "next_attempt_at", "created_at"], unique=False
    )
    op.create_table(
        "review_actions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("idempotency_key", sa.Uuid(), nullable=False),
        sa.Column("operation", sa.String(length=16), nullable=False),
        sa.Column("request_digest", sa.String(length=64), nullable=False),
        sa.Column("job_id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("operation IN ('create','retry')", name="review_action_operation"),
        sa.CheckConstraint("request_digest ~ '^[a-f0-9]{64}$'", name="review_action_digest"),
        sa.ForeignKeyConstraint(["job_id"], ["review_jobs.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "idempotency_key", name="review_action_user_key"),
    )
    op.create_table(
        "review_attempts",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("job_id", sa.Uuid(), nullable=True),
        sa.Column("source_job_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("review_input_hash", sa.String(length=64), nullable=False),
        sa.Column("ordinal", sa.Integer(), nullable=False),
        sa.Column("run_token", sa.Uuid(), nullable=False),
        sa.Column("logical_request_key", sa.String(length=64), nullable=False),
        sa.Column("gateway_config_id", sa.String(length=128), nullable=False),
        sa.Column("gateway_idempotent", sa.Boolean(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("outcome", sa.String(length=24), nullable=False),
        sa.Column("input_tokens", sa.Integer(), nullable=True),
        sa.Column("output_tokens", sa.Integer(), nullable=True),
        sa.CheckConstraint(
            "outcome IN ('outcome_unknown','succeeded','no_suggestions',"
            "'invalid_output','retryable_error','permanent_error','discarded')",
            name="review_attempt_outcome",
        ),
        sa.CheckConstraint(
            "(input_tokens IS NULL OR input_tokens >= 0) AND "
            "(output_tokens IS NULL OR output_tokens >= 0)",
            name="review_attempt_usage",
        ),
        sa.CheckConstraint("ordinal BETWEEN 1 AND 3", name="review_attempt_limit"),
        sa.ForeignKeyConstraint(["job_id"], ["review_jobs.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("run_token"),
        sa.UniqueConstraint("source_job_id", "ordinal", name="review_attempt_ordinal"),
    )
    op.create_table(
        "review_results",
        sa.Column("job_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("result_hash", sa.String(length=64), nullable=False),
        sa.Column("snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("result_hash ~ '^[a-f0-9]{64}$'", name="review_result_hash"),
        sa.CheckConstraint("version = 1", name="review_result_version"),
        sa.ForeignKeyConstraint(["job_id"], ["review_jobs.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("job_id"),
    )


def downgrade():
    op.drop_table("review_results")
    op.drop_table("review_attempts")
    op.drop_table("review_actions")
    op.drop_index("review_job_due", table_name="review_jobs")
    op.drop_table("review_jobs")
