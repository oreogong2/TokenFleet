"""add public participants

Revision ID: f4a9c2d8e6b1
Revises: bb8d4e1a2f73
Create Date: 2026-08-09 16:00:00
"""

from typing import Sequence, Union
import uuid

from alembic import op
import sqlalchemy as sa


revision: str = "f4a9c2d8e6b1"
down_revision: Union[str, None] = "bb8d4e1a2f73"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _set_sqlite_foreign_keys(enabled: bool) -> None:
    connection = op.get_bind()
    if connection.dialect.name != "sqlite":
        return
    # SQLite batch table recreation must temporarily drop the referenced users
    # table. PRAGMA changes only take effect outside a transaction, hence the
    # explicit Alembic autocommit block. Application connections re-enable FK
    # enforcement independently in database.build_engine.
    with op.get_context().autocommit_block():
        connection.exec_driver_sql(
            f"PRAGMA foreign_keys={'ON' if enabled else 'OFF'}"
        )


def upgrade() -> None:
    _set_sqlite_foreign_keys(False)
    op.add_column(
        "price_versions",
        sa.Column(
            "public_estimate",
            sa.Boolean(),
            server_default=sa.false(),
            nullable=False,
        ),
    )
    op.add_column(
        "users",
        sa.Column("public_id", sa.String(length=36), nullable=True),
    )
    op.add_column(
        "users",
        sa.Column(
            "public_profile_enabled",
            sa.Boolean(),
            server_default=sa.false(),
            nullable=False,
        ),
    )

    users = sa.table(
        "users",
        sa.column("id", sa.String(length=36)),
        sa.column("public_id", sa.String(length=36)),
    )
    connection = op.get_bind()
    user_ids = list(connection.execute(sa.select(users.c.id)).scalars())
    for user_id in user_ids:
        connection.execute(
            users.update()
            .where(users.c.id == user_id)
            .values(public_id=str(uuid.uuid4()))
        )

    # Batch mode recreates the table only on SQLite and emits ordinary ALTERs
    # on PostgreSQL, keeping one migration valid for both supported backends.
    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column(
            "email",
            existing_type=sa.String(length=254),
            nullable=True,
        )
        batch_op.alter_column(
            "password_hash",
            existing_type=sa.String(length=512),
            nullable=True,
        )
        batch_op.alter_column(
            "public_id",
            existing_type=sa.String(length=36),
            nullable=False,
        )
        batch_op.create_check_constraint(
            "ck_user_login_credentials_pair",
            "(email IS NULL AND password_hash IS NULL) OR "
            "(email IS NOT NULL AND password_hash IS NOT NULL)",
        )
    op.create_index("ix_users_public_id", "users", ["public_id"], unique=True)
    op.create_index(
        "ix_usage_public_org_tool_date",
        "daily_usage",
        ["org_id", "tool", "usage_date"],
        unique=False,
    )
    op.create_index(
        "ix_usage_public_org_model_date",
        "daily_usage",
        ["org_id", "model", "usage_date"],
        unique=False,
    )
    _set_sqlite_foreign_keys(True)


def downgrade() -> None:
    users = sa.table(
        "users",
        sa.column("email", sa.String(length=254)),
        sa.column("password_hash", sa.String(length=512)),
    )
    connection = op.get_bind()
    participant_count = connection.scalar(
        sa.select(sa.func.count()).select_from(users).where(users.c.email.is_(None))
    )
    if participant_count:
        raise RuntimeError(
            "cannot downgrade while non-login participants exist; "
            "export or convert them to login members first"
        )

    _set_sqlite_foreign_keys(False)
    op.drop_index("ix_usage_public_org_model_date", table_name="daily_usage")
    op.drop_index("ix_usage_public_org_tool_date", table_name="daily_usage")
    op.drop_index("ix_users_public_id", table_name="users")
    with op.batch_alter_table("users") as batch_op:
        batch_op.drop_constraint("ck_user_login_credentials_pair", type_="check")
        batch_op.alter_column(
            "password_hash",
            existing_type=sa.String(length=512),
            nullable=False,
        )
        batch_op.alter_column(
            "email",
            existing_type=sa.String(length=254),
            nullable=False,
        )
        batch_op.drop_column("public_profile_enabled")
        batch_op.drop_column("public_id")
    with op.batch_alter_table("price_versions") as batch_op:
        batch_op.drop_column("public_estimate")
    _set_sqlite_foreign_keys(True)
