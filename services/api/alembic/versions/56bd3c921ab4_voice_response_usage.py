"""Record source-bound usage from accepted voice response terminals."""

import sqlalchemy as sa

from alembic import op

revision = "56bd3c921ab4"
down_revision = "4f6a58cd2e32"
branch_labels = None
depends_on = None

_COUNTS = (
    "input_tokens",
    "output_tokens",
    "input_text_tokens",
    "input_audio_tokens",
    "output_text_tokens",
    "output_audio_tokens",
)


def upgrade():
    op.create_table(
        "voice_response_usage",
        sa.Column(
            "connection_id",
            sa.Uuid(),
            sa.ForeignKey("realtime_connections.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("response_digest", sa.String(64), primary_key=True),
        sa.Column("status", sa.String(10), nullable=False),
        *(sa.Column(column, sa.Integer()) for column in _COUNTS),
        sa.Column(
            "recorded_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "response_digest ~ '^[a-f0-9]{64}$'", name="voice_usage_response_digest"
        ),
        sa.CheckConstraint(
            "status IN ('completed','cancelled','failed','incomplete')", name="voice_usage_status"
        ),
        *(
            sa.CheckConstraint(f"{column} BETWEEN 0 AND 1000000000", name=f"voice_usage_{column}")
            for column in _COUNTS
        ),
    )


def downgrade():
    db = op.get_bind()
    db.execute(sa.text("LOCK TABLE voice_response_usage IN ACCESS EXCLUSIVE MODE"))
    if db.scalar(sa.text("SELECT EXISTS(SELECT 1 FROM voice_response_usage)")):
        raise RuntimeError("Refusing to discard recorded voice usage")
    op.drop_table("voice_response_usage")
