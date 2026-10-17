"""Record preparation endings and index bounded idle scans."""

import sqlalchemy as sa

from alembic import op

revision = "c43a7de028f1"
down_revision = "8e637f95bca1"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("practice_sessions", sa.Column("state_reason", sa.String(48), nullable=True))
    op.create_index(
        "idle_practice_preparations",
        "practice_sessions",
        ["created_at", "id"],
        postgresql_where=sa.text("status = 'created'"),
    )


def downgrade():
    op.drop_index("idle_practice_preparations", table_name="practice_sessions")
    op.drop_column("practice_sessions", "state_reason")
