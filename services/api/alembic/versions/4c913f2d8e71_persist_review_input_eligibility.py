"""Persist deterministic review-input references without rewriting completion seals.

Revision ID: 4c913f2d8e71
Revises: 0e1874613efa
"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "4c913f2d8e71"
down_revision = "0e1874613efa"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "review_inputs",
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("input_revision", sa.Integer(), nullable=False),
        sa.Column("policy_version", sa.String(32), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("practice_input_hash", sa.String(64), nullable=False),
        sa.Column("review_input_hash", sa.String(64), nullable=False),
        sa.Column("snapshot", postgresql.JSONB(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("input_revision = 1", name="review_input_revision"),
        sa.CheckConstraint("policy_version = 'review_input_v1'", name="review_input_policy"),
        sa.CheckConstraint(
            "practice_input_hash ~ '^[a-f0-9]{64}$'", name="review_input_practice_hash"
        ),
        sa.CheckConstraint("review_input_hash ~ '^[a-f0-9]{64}$'", name="review_input_hash"),
        sa.ForeignKeyConstraint(
            ["session_id", "user_id"],
            ["practice_sessions.id", "practice_sessions.user_id"],
            name="review_input_practice_owner",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("session_id", "input_revision", "policy_version"),
    )


def downgrade():
    op.drop_table("review_inputs")
