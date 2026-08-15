"""add one-time community share grants

Revision ID: 9a342e52bb08
Revises: c7b4e2a91d35
Create Date: 2026-08-15 23:55:00
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "9a342e52bb08"
down_revision: Union[str, None] = "c7b4e2a91d35"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "community_share_grants",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("org_id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=False),
        sa.Column("grant_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["org_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(
            ["user_id", "org_id"],
            ["users.id", "users.org_id"],
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["device_id", "user_id", "org_id"],
            ["devices.id", "devices.user_id", "devices.org_id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "uq_community_share_grant_hash",
        "community_share_grants",
        ["grant_hash"],
        unique=True,
    )
    op.create_index(
        "ix_community_share_grant_expires",
        "community_share_grants",
        ["expires_at"],
    )
    op.create_index(
        "ix_community_share_grant_device_consumed",
        "community_share_grants",
        ["device_id", "consumed_at"],
    )


def downgrade() -> None:
    connection = op.get_bind()
    grants = sa.table(
        "community_share_grants",
        sa.column("id", sa.String(length=36)),
    )
    grant_count = connection.scalar(sa.select(sa.func.count()).select_from(grants))
    if grant_count:
        raise RuntimeError(
            "cannot downgrade community share grants while grant records exist"
        )
    op.drop_index("ix_community_share_grant_device_consumed", "community_share_grants")
    op.drop_index("ix_community_share_grant_expires", "community_share_grants")
    op.drop_index("uq_community_share_grant_hash", "community_share_grants")
    op.drop_table("community_share_grants")
