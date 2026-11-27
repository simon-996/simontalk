"""Persist owner-scoped assistance jobs and text model attempts."""

import sqlalchemy as sa

from alembic import op

revision = "7cfa81b28360"
down_revision = "329ce39bc5a2"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "assistance_jobs",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("auth_session_id", sa.Uuid(), nullable=False),
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("input_revision", sa.String(64), nullable=False),
        sa.Column("config_id", sa.String(128), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("attempt_count", sa.Integer(), nullable=False),
        sa.Column("result", sa.String(240)),
        sa.Column("deadline", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            ondelete="CASCADE",
            name="assistance_practice_owner",
        ),
        sa.UniqueConstraint("session_id", "kind", "input_revision", name="assistance_input_unique"),
        sa.CheckConstraint("epoch > 0 AND attempt_count BETWEEN 0 AND 2", name="assistance_bounds"),
        sa.CheckConstraint(
            "status IN ('queued','running','succeeded','failed','unknown','expired') "
            "AND ((status = 'succeeded') = (result IS NOT NULL))",
            name="assistance_result_state",
        ),
    )
    op.create_index(
        "assistance_due",
        "assistance_jobs",
        ["deadline", "id"],
        postgresql_where=sa.text("status IN ('queued','running')"),
    )
    op.create_table(
        "assistance_actions",
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
        ),
        sa.Column("key", sa.Uuid(), primary_key=True),
        sa.Column(
            "job_id",
            sa.Uuid(),
            sa.ForeignKey("assistance_jobs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("request_hash", sa.String(64), nullable=False),
    )
    op.create_table(
        "assistance_attempts",
        sa.Column(
            "job_id",
            sa.Uuid(),
            sa.ForeignKey("assistance_jobs.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("number", sa.Integer(), primary_key=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
        sa.Column("input_tokens", sa.Integer()),
        sa.Column("output_tokens", sa.Integer()),
        sa.CheckConstraint(
            "number BETWEEN 1 AND 2 AND input_tokens BETWEEN 0 AND 1000000000",
            name="assistance_attempt_bounds",
        ),
        sa.CheckConstraint(
            "output_tokens BETWEEN 0 AND 1000000000", name="assistance_attempt_output_bounds"
        ),
    )


def downgrade():
    db = op.get_bind()
    db.execute(
        sa.text(
            "LOCK TABLE assistance_jobs, assistance_actions, assistance_attempts "
            "IN ACCESS EXCLUSIVE MODE"
        )
    )
    if db.scalar(sa.text("SELECT EXISTS(SELECT 1 FROM assistance_jobs)")):
        raise RuntimeError("Refusing to discard assistance usage")
    op.drop_table("assistance_attempts")
    op.drop_table("assistance_actions")
    op.drop_table("assistance_jobs")
