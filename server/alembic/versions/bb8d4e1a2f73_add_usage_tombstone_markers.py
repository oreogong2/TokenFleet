"""add usage tombstone markers

Revision ID: bb8d4e1a2f73
Revises: 317c7501d905
Create Date: 2026-08-09 13:20:00
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "bb8d4e1a2f73"
down_revision: Union[str, None] = "317c7501d905"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "daily_usage",
        sa.Column(
            "is_deleted",
            sa.Boolean(),
            server_default=sa.false(),
            nullable=False,
        ),
    )


def downgrade() -> None:
    with op.batch_alter_table("daily_usage") as batch_op:
        batch_op.drop_column("is_deleted")
