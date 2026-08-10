from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from alembic import command
from alembic.config import Config
import pytest
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.exc import IntegrityError

from app.models import EnrollmentToken, InvitationBatch, User, UserRole, utcnow
from app.security import opaque_token_hash


SERVER_ROOT = Path(__file__).resolve().parents[1]


def _create_batch(harness, *, capacity: int = 50, expires_in_hours: int = 24):
    response = harness.client.post(
        "/api/v1/admin/invitation-batches",
        headers=harness.auth("a_admin"),
        json={"capacity": capacity, "expires_in_hours": expires_in_hours},
    )
    assert response.status_code == 201, response.text
    assert response.headers["Cache-Control"] == "no-store"
    return response.json()


def _claim(harness, token: str, nickname: str):
    return harness.client.post(
        "/api/v1/public/invitation-batches/claim",
        json={
            "invitation_token": token,
            "display_name": nickname,
            "public_profile_enabled": True,
        },
    )


def _recursive_keys(value) -> set[str]:
    if isinstance(value, dict):
        return set(value) | set().union(*(_recursive_keys(item) for item in value.values()), set())
    if isinstance(value, list):
        return set().union(*(_recursive_keys(item) for item in value), set())
    return set()


def test_admin_batch_rbac_lifecycle_and_raw_token_is_returned_once(harness) -> None:
    unauthenticated = harness.client.post(
        "/api/v1/admin/invitation-batches",
        json={"capacity": 2, "expires_in_hours": 1},
    )
    assert unauthenticated.status_code == 401
    member = harness.client.post(
        "/api/v1/admin/invitation-batches",
        headers=harness.auth("a_member"),
        json={"capacity": 2, "expires_in_hours": 1},
    )
    assert member.status_code == 403

    created = _create_batch(harness, capacity=2, expires_in_hours=1)
    assert set(created) == {"batch", "invitation_token"}
    assert created["batch"]["status"] == "open"
    assert created["batch"]["capacity"] == 2
    raw_token = created["invitation_token"]

    listed = harness.client.get(
        "/api/v1/admin/invitation-batches",
        headers=harness.auth("a_admin"),
    )
    assert listed.status_code == 200
    assert raw_token not in listed.text
    assert listed.json()[0]["id"] == created["batch"]["id"]
    assert "invitation_token" not in listed.json()[0]

    with harness.session_factory() as session:
        stored = session.scalar(
            select(InvitationBatch).where(
                InvitationBatch.id == created["batch"]["id"]
            )
        )
        assert stored is not None
        assert stored.token_hash == opaque_token_hash(raw_token)
        assert raw_token not in stored.token_hash

    closed = harness.client.post(
        f"/api/v1/admin/invitation-batches/{created['batch']['id']}/close",
        headers=harness.auth("a_admin"),
    )
    assert closed.status_code == 200
    assert closed.json()["status"] == "closed"
    assert closed.headers["Cache-Control"] == "no-store"


def test_anonymous_claim_is_atomic_and_response_is_public_field_whitelist(harness) -> None:
    created = _create_batch(harness, capacity=2)
    response = _claim(harness, created["invitation_token"], "  成员甲  ")
    assert response.status_code == 201, response.text
    body = response.json()
    assert set(body) == {"nickname", "enrollment_token", "expires_at"}
    assert _recursive_keys(body) == {"nickname", "enrollment_token", "expires_at"}
    assert body["nickname"] == "成员甲"
    assert response.headers["Cache-Control"] == "no-store"

    with harness.session_factory() as session:
        batch = session.scalar(
            select(InvitationBatch).where(
                InvitationBatch.id == created["batch"]["id"]
            )
        )
        participant = session.scalar(
            select(User).where(
                User.org_id == harness.users["a_admin"].org_id,
                User.display_name == "成员甲",
            )
        )
        assert batch is not None and batch.claimed_count == 1
        assert participant is not None
        assert participant.role == UserRole.MEMBER
        assert participant.email is None and participant.password_hash is None
        assert participant.public_profile_enabled
        assert session.scalar(
            select(func.count())
            .select_from(EnrollmentToken)
            .where(EnrollmentToken.user_id == participant.id)
        ) == 1


def test_batch_unavailable_response_is_identical_for_invalid_closed_expired_and_full(
    harness,
) -> None:
    expected = {"detail": "invitation batch unavailable"}
    invalid = _claim(harness, "x" * 43, "无效批次")
    assert invalid.status_code == 409 and invalid.json() == expected

    closed_batch = _create_batch(harness, capacity=1)
    assert harness.client.post(
        f"/api/v1/admin/invitation-batches/{closed_batch['batch']['id']}/close",
        headers=harness.auth("a_admin"),
    ).status_code == 200
    closed = _claim(harness, closed_batch["invitation_token"], "关闭批次")
    assert closed.status_code == 409 and closed.json() == expected

    expired_batch = _create_batch(harness, capacity=1)
    with harness.session_factory() as session:
        batch = session.get(InvitationBatch, expired_batch["batch"]["id"])
        assert batch is not None
        batch.expires_at = utcnow() - timedelta(seconds=1)
        session.commit()
    expired = _claim(harness, expired_batch["invitation_token"], "过期批次")
    assert expired.status_code == 409 and expired.json() == expected

    full_batch = _create_batch(harness, capacity=1)
    assert _claim(harness, full_batch["invitation_token"], "满额一号").status_code == 201
    full = _claim(harness, full_batch["invitation_token"], "满额二号")
    assert full.status_code == 409 and full.json() == expected


def test_normalized_nickname_unique_constraint_rolls_back_entire_claim(harness) -> None:
    existing = harness.client.post(
        "/api/v1/admin/participants",
        headers=harness.auth("a_admin"),
        json={
            "display_name": "Alpha Member",
            "public_profile_enabled": True,
            "expires_in_minutes": 60,
        },
    )
    assert existing.status_code == 201
    created = _create_batch(harness, capacity=2)

    before_users: int
    before_tokens: int
    with harness.session_factory() as session:
        before_users = session.scalar(select(func.count()).select_from(User)) or 0
        before_tokens = (
            session.scalar(select(func.count()).select_from(EnrollmentToken)) or 0
        )

    rejected = _claim(harness, created["invitation_token"], "  ALPHA MEMBER  ")
    assert rejected.status_code == 409
    assert rejected.json() == {"detail": "nickname unavailable"}

    with harness.session_factory() as session:
        batch = session.get(InvitationBatch, created["batch"]["id"])
        assert batch is not None and batch.claimed_count == 0
        assert session.scalar(select(func.count()).select_from(User)) == before_users
        assert (
            session.scalar(select(func.count()).select_from(EnrollmentToken))
            == before_tokens
        )


def test_batch_claim_requires_explicit_public_profile_consent(harness) -> None:
    created = _create_batch(harness, capacity=1)
    response = harness.client.post(
        "/api/v1/public/invitation-batches/claim",
        json={
            "invitation_token": created["invitation_token"],
            "display_name": "未同意公开",
            "public_profile_enabled": False,
        },
    )
    assert response.status_code == 422
    assert created["invitation_token"] not in response.text


def test_sqlite_invitation_migration_backfills_uniqueness_and_downgrades_safely(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "invitation-migration.db"
    database_url = f"sqlite:///{database_path}"
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    config.attributes["database_url"] = database_url
    command.upgrade(config, "f4a9c2d8e6b1")

    engine = create_engine(database_url)
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO organizations "
                "(id, slug, name, default_timezone, retention_days, ledger_version, created_at) "
                "VALUES ('org', 'batch-migration', 'Batch', 'UTC', 395, 0, :now)"
            ),
            {"now": now},
        )
        connection.execute(
            text(
                "INSERT INTO users "
                "(id, org_id, email, display_name, password_hash, public_id, "
                "public_profile_enabled, role, is_active, created_at) VALUES "
                "('admin', 'org', 'admin@example.com', 'Admin', 'hash', :admin_public_id, "
                "0, 'ADMIN', 1, :now), "
                "('participant', 'org', NULL, 'Ａlpha Member', NULL, :participant_public_id, "
                "1, 'MEMBER', 1, :now)"
            ),
            {
                "admin_public_id": str(uuid4()),
                "participant_public_id": str(uuid4()),
                "now": now,
            },
        )
    engine.dispose()

    command.upgrade(config, "head")
    engine = create_engine(database_url)
    assert "invitation_batches" in inspect(engine).get_table_names()
    assert "normalized_display_name" in {
        column["name"] for column in inspect(engine).get_columns("users")
    }
    assert "uq_user_org_normalized_display_name" in {
        item["name"] for item in inspect(engine).get_indexes("users")
    }
    with engine.connect() as connection:
        assert connection.scalar(
            text(
                "SELECT normalized_display_name FROM users "
                "WHERE id='participant'"
            )
        ) == "alpha member"

    with pytest.raises(IntegrityError):
        with engine.begin() as connection:
            connection.execute(
                text(
                    "INSERT INTO users "
                    "(id, org_id, email, display_name, normalized_display_name, "
                    "password_hash, public_id, public_profile_enabled, role, is_active, created_at) "
                    "VALUES ('duplicate', 'org', NULL, 'alpha member', 'alpha member', "
                    "NULL, :public_id, 1, 'MEMBER', 1, :now)"
                ),
                {"public_id": str(uuid4()), "now": now},
            )
    engine.dispose()

    with pytest.raises(
        RuntimeError,
        match="cannot downgrade invitation batches while participants or batches exist",
    ):
        command.downgrade(config, "f4a9c2d8e6b1")
    engine = create_engine(database_url)
    with engine.begin() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "c7b4e2a91d35"
        )
        connection.execute(text("DELETE FROM users WHERE id='participant'"))
    engine.dispose()

    command.downgrade(config, "f4a9c2d8e6b1")
    engine = create_engine(database_url)
    assert "invitation_batches" not in inspect(engine).get_table_names()
    assert "normalized_display_name" not in {
        column["name"] for column in inspect(engine).get_columns("users")
    }
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "f4a9c2d8e6b1"
        )
    engine.dispose()
