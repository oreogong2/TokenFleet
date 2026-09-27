"""Add a separate credential for existing-member device-code reissues.

Revision ID: e5a8c19d2f04
Revises: b72c34d8e901
"""
from alembic import op
import sqlalchemy as sa

revision = "e5a8c19d2f04"
down_revision = "b72c34d8e901"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table("enrollment_management_credentials",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("org_id", sa.String(36), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["created_by_user_id", "org_id"], ["users.id", "users.org_id"], ondelete="CASCADE"))
    op.create_index("uq_enrollment_management_token_hash", "enrollment_management_credentials", ["token_hash"], unique=True)
    op.create_index("ix_enrollment_management_org_active", "enrollment_management_credentials", ["org_id", "is_active"])


def downgrade() -> None:
    op.drop_index("ix_enrollment_management_org_active", table_name="enrollment_management_credentials")
    op.drop_index("uq_enrollment_management_token_hash", table_name="enrollment_management_credentials")
    op.drop_table("enrollment_management_credentials")
