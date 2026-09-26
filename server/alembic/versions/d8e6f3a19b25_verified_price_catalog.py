"""verified price provenance and scoped maintenance credentials

Revision ID: d8e6f3a19b25
Revises: 9a342e52bb08
"""
from alembic import op
import sqlalchemy as sa

revision = "d8e6f3a19b25"
down_revision = "9a342e52bb08"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("organizations", sa.Column("price_catalog_revision", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("price_versions", sa.Column("source_url", sa.String(512)))
    op.add_column("price_versions", sa.Column("source_checked_at", sa.Date()))
    op.add_column("price_versions", sa.Column("effective_basis", sa.String(32)))
    op.create_table("price_management_credentials",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("org_id", sa.String(36), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["org_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["created_by_user_id", "org_id"], ["users.id", "users.org_id"], ondelete="CASCADE"))
    op.create_index("uq_price_management_token_hash", "price_management_credentials", ["token_hash"], unique=True)
    op.create_index("ix_price_management_org_active", "price_management_credentials", ["org_id", "is_active"])


def downgrade():
    bind = op.get_bind()
    table = sa.table("price_management_credentials", sa.column("id"))
    prices = sa.table("price_versions", sa.column("source_url"))
    if bind.scalar(sa.select(sa.func.count()).select_from(table)) or bind.scalar(
            sa.select(sa.func.count()).select_from(prices).where(prices.c.source_url.is_not(None))):
        raise RuntimeError("cannot downgrade while verified prices or maintenance credentials exist")
    op.drop_index("ix_price_management_org_active", "price_management_credentials")
    op.drop_index("uq_price_management_token_hash", "price_management_credentials")
    op.drop_table("price_management_credentials")
    op.drop_column("price_versions", "effective_basis")
    op.drop_column("price_versions", "source_checked_at")
    op.drop_column("price_versions", "source_url")
    op.drop_column("organizations", "price_catalog_revision")
