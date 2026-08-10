"""add invitation batches and normalized display names

Revision ID: c7b4e2a91d35
Revises: f4a9c2d8e6b1
Create Date: 2026-08-10 18:00:00
"""

from typing import Sequence, Union
import unicodedata

from alembic import op
import sqlalchemy as sa


revision: str = "c7b4e2a91d35"
down_revision: Union[str, None] = "f4a9c2d8e6b1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _set_sqlite_foreign_keys(enabled: bool) -> None:
    connection = op.get_bind()
    if connection.dialect.name != "sqlite":
        return
    with op.get_context().autocommit_block():
        connection.exec_driver_sql(
            f"PRAGMA foreign_keys={'ON' if enabled else 'OFF'}"
        )


def _normalized_display_name(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value.strip()).casefold()
    if not normalized or len(normalized) > 512:
        raise RuntimeError("an existing display name cannot be normalized safely")
    return normalized


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("normalized_display_name", sa.String(length=512), nullable=True),
    )
    users = sa.table(
        "users",
        sa.column("id", sa.String(length=36)),
        sa.column("org_id", sa.String(length=36)),
        sa.column("display_name", sa.String(length=128)),
        sa.column("normalized_display_name", sa.String(length=512)),
    )
    connection = op.get_bind()
    seen: set[tuple[str, str]] = set()
    rows = connection.execute(
        sa.select(users.c.id, users.c.org_id, users.c.display_name).where(
            users.c.display_name.is_not(None)
        )
    )
    for user_id, org_id, display_name in rows:
        normalized = _normalized_display_name(display_name)
        identity = (org_id, normalized)
        if identity in seen:
            raise RuntimeError(
                "cannot add nickname uniqueness while duplicate display names exist"
            )
        seen.add(identity)
        connection.execute(
            users.update()
            .where(users.c.id == user_id)
            .values(normalized_display_name=normalized)
        )
    op.create_index(
        "uq_user_org_normalized_display_name",
        "users",
        ["org_id", "normalized_display_name"],
        unique=True,
    )

    op.create_table(
        "invitation_batches",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("org_id", sa.String(length=36), nullable=False),
        sa.Column("created_by_user_id", sa.String(length=36), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("capacity", sa.Integer(), nullable=False),
        sa.Column("claimed_count", sa.Integer(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "capacity BETWEEN 1 AND 50", name="ck_invitation_batch_capacity"
        ),
        sa.CheckConstraint(
            "claimed_count BETWEEN 0 AND capacity",
            name="ck_invitation_batch_claimed_count",
        ),
        sa.ForeignKeyConstraint(
            ["org_id"], ["organizations.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["created_by_user_id", "org_id"],
            ["users.id", "users.org_id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "uq_invitation_batch_token_hash",
        "invitation_batches",
        ["token_hash"],
        unique=True,
    )
    op.create_index(
        "ix_invitation_batch_org_created",
        "invitation_batches",
        ["org_id", "created_at"],
        unique=False,
    )


def downgrade() -> None:
    connection = op.get_bind()
    users = sa.table(
        "users",
        sa.column("email", sa.String(length=254)),
    )
    invitation_batches = sa.table(
        "invitation_batches",
        sa.column("id", sa.String(length=36)),
    )
    participant_count = connection.scalar(
        sa.select(sa.func.count())
        .select_from(users)
        .where(users.c.email.is_(None))
    )
    batch_count = connection.scalar(
        sa.select(sa.func.count()).select_from(invitation_batches)
    )
    if participant_count or batch_count:
        raise RuntimeError(
            "cannot downgrade invitation batches while participants or batches exist"
        )

    _set_sqlite_foreign_keys(False)
    op.drop_index(
        "ix_invitation_batch_org_created", table_name="invitation_batches"
    )
    op.drop_index(
        "uq_invitation_batch_token_hash", table_name="invitation_batches"
    )
    op.drop_table("invitation_batches")
    op.drop_index("uq_user_org_normalized_display_name", table_name="users")
    with op.batch_alter_table("users") as batch_op:
        batch_op.drop_column("normalized_display_name")
    _set_sqlite_foreign_keys(True)
