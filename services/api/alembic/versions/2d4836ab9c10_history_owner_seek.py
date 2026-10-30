"""Index owner history without modifying saved practice records."""

from alembic import op

revision = "2d4836ab9c10"
down_revision = "1a6de74c9f20"
branch_labels = None
depends_on = None


def upgrade():
    op.create_index(
        "practice_history_owner_seek", "practice_sessions", ["user_id", "created_at", "id"]
    )


def downgrade():
    op.drop_index("practice_history_owner_seek", table_name="practice_sessions")
