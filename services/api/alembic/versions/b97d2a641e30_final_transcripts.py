"""Append bounded client-reported final transcript revisions."""

import sqlalchemy as sa

from alembic import op

revision = "b97d2a641e30"
down_revision = "f80e9c1a24bd"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "final_transcripts",
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column("event_id", sa.Uuid(), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("turn_id", sa.Uuid(), nullable=False),
        sa.Column("turn_index", sa.Integer(), nullable=False),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.Column("response_id", sa.Uuid(), nullable=True),
        sa.Column("provider_item_id", sa.String(256), nullable=True),
        sa.Column("event_digest", sa.String(64), nullable=False),
        sa.Column("source", sa.String(16), server_default="client_reported", nullable=False),
        sa.Column(
            "received_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.PrimaryKeyConstraint("connection_id", "event_id"),
        sa.ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="transcript_connection_identity",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("connection_id", "sequence", name="transcript_sequence"),
        sa.UniqueConstraint(
            "connection_id", "turn_id", "revision", name="transcript_turn_revision"
        ),
        sa.CheckConstraint(
            "sequence > 0 AND turn_index > 0 AND revision > 0", name="transcript_numeric_bounds"
        ),
        sa.CheckConstraint("source = 'client_reported'", name="transcript_source"),
        sa.CheckConstraint("event_digest ~ '^[a-f0-9]{64}$'", name="transcript_digest"),
        sa.CheckConstraint("octet_length(text) <= 8192", name="transcript_text_bytes"),
        sa.CheckConstraint(
            "provider_item_id IS NULL OR length(provider_item_id) BETWEEN 1 AND 256",
            name="transcript_provider_item",
        ),
        sa.CheckConstraint(
            "(role = 'user' AND response_id IS NULL) OR "
            "(role = 'assistant' AND response_id IS NOT NULL)",
            name="transcript_role_response",
        ),
    )


def downgrade():
    op.drop_table("final_transcripts")
