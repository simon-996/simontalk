"""Persist owned practice preparations without enabling provider calls."""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "2acda42539f0"
down_revision = "c08af48b475f"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "practice_sessions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("creation_key", sa.Uuid(), nullable=False),
        sa.Column("request_digest", sa.String(64), nullable=False),
        sa.Column("mode", sa.String(16), nullable=False),
        sa.Column("status", sa.String(16), server_default="created", nullable=False),
        sa.Column("configuration", postgresql.JSONB(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "creation_key", name="practice_creation_key"),
        sa.CheckConstraint("mode = 'free_chat'", name="practice_mode"),
        sa.CheckConstraint(
            "status IN ('created','connecting','active','interrupted',"
            "'ending','completed','cancelled','failed')",
            name="practice_status",
        ),
    )
    op.create_index(
        "one_open_practice_per_user",
        "practice_sessions",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text(
            "status IN ('created','connecting','active','interrupted','ending')"
        ),
    )


def downgrade():
    op.drop_table("practice_sessions")
