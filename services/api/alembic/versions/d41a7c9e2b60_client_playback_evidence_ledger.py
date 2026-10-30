"""Append bounded client-reported playback evidence without media authority."""

import sqlalchemy as sa

from alembic import op

revision = "d41a7c9e2b60"
down_revision = "b97d2a641e30"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "playback_evidence",
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column("event_id", sa.Uuid(), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("response_id", sa.Uuid(), nullable=False),
        sa.Column("turn_id", sa.Uuid(), nullable=True),
        sa.Column("turn_index", sa.Integer(), nullable=True),
        sa.Column("transcript_revision", sa.Integer(), nullable=True),
        sa.Column("generated_text", sa.Text(), nullable=True),
        sa.Column("transcript_final", sa.Boolean(), nullable=True),
        sa.Column("playback_revision", sa.Integer(), nullable=True),
        sa.Column("delivery_status", sa.String(length=16), nullable=True),
        sa.Column("played_text", sa.Text(), nullable=True),
        sa.Column("played_until_ms", sa.Integer(), nullable=True),
        sa.Column("evidence_source", sa.String(length=32), nullable=True),
        sa.Column("stop_boundary_ms", sa.Integer(), nullable=True),
        sa.Column("reason", sa.String(length=16), nullable=True),
        sa.Column("event_digest", sa.String(length=64), nullable=False),
        sa.Column("source", sa.String(length=16), server_default="client_reported", nullable=False),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "(kind = 'revoke' AND turn_id IS NULL AND turn_index IS NULL AND "
            "transcript_revision IS NULL AND generated_text IS NULL AND "
            "transcript_final IS NULL AND playback_revision IS NULL AND "
            "delivery_status IS NULL AND played_text IS NULL AND played_until_ms IS "
            "NULL AND evidence_source IS NULL AND stop_boundary_ms IS NULL AND reason"
            " IS NULL) OR (kind IN ('alignment','freeze') AND turn_id IS NOT NULL AND"
            " turn_index IS NOT NULL AND turn_index > 0 AND transcript_revision IS "
            "NOT NULL AND transcript_revision >= 0 AND generated_text IS NOT NULL AND"
            " transcript_final IS NOT NULL AND playback_revision IS NOT NULL AND "
            "playback_revision >= 0 AND delivery_status IS NOT NULL AND played_text "
            "IS NOT NULL AND evidence_source IS NOT NULL)",
            name="playback_event_shape",
        ),
        sa.CheckConstraint("event_digest ~ '^[a-f0-9]{64}$'", name="playback_digest"),
        sa.CheckConstraint(
            "kind = 'revoke' OR ((delivery_status = 'unknown' AND played_text = '' "
            "AND played_until_ms IS NULL AND evidence_source = 'unknown') OR "
            "(evidence_source = 'device_output_aligned' AND ((delivery_status = "
            "'not_played' AND transcript_final AND played_text = '' AND "
            "played_until_ms IS NOT NULL AND played_until_ms = 0) OR (delivery_status"
            " IN ('partial','played') AND played_text <> '' AND played_until_ms IS "
            "NOT NULL AND played_until_ms BETWEEN 1 AND 86400000 AND "
            "((delivery_status = 'partial' AND generated_text <> played_text AND "
            "left(generated_text,length(played_text)) = played_text) OR "
            "(delivery_status = 'played' AND transcript_final AND generated_text = "
            "played_text))))))",
            name="playback_alignment_shape",
        ),
        sa.CheckConstraint(
            "kind = 'revoke' OR ((kind = 'alignment' AND transcript_revision > 0 AND "
            "playback_revision > 0 AND stop_boundary_ms IS NULL AND reason IS NULL) "
            "OR (kind = 'freeze' AND stop_boundary_ms IS NOT NULL AND "
            "stop_boundary_ms BETWEEN 0 AND 86400000 AND reason IS NOT NULL AND "
            "reason IN ('interrupted','normal_end') AND (played_until_ms IS NULL OR "
            "played_until_ms <= stop_boundary_ms)))",
            name="playback_freeze_shape",
        ),
        sa.CheckConstraint(
            "kind = 'revoke' OR (octet_length(generated_text) <= 8192 AND "
            "octet_length(played_text) <= 8192)",
            name="playback_text_bytes",
        ),
        sa.CheckConstraint(
            "kind = 'revoke' OR (playback_revision > 0 OR delivery_status = 'unknown')",
            name="playback_unaligned",
        ),
        sa.CheckConstraint(
            "kind = 'revoke' OR (transcript_revision > 0 OR (generated_text = '' AND "
            "NOT transcript_final AND playback_revision = 0))",
            name="playback_untranscribed",
        ),
        sa.CheckConstraint("kind IN ('alignment','freeze','revoke')", name="playback_kind"),
        sa.CheckConstraint("source = 'client_reported'", name="playback_source"),
        sa.CheckConstraint("sequence > 0", name="playback_numeric_bounds"),
        sa.ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="playback_connection_identity",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("connection_id", "event_id"),
        sa.UniqueConstraint("connection_id", "sequence", name="playback_sequence"),
    )


def downgrade():
    op.drop_table("playback_evidence")
