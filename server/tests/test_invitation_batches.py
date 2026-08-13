from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.exc import IntegrityError

from app.middleware import parse_trusted_proxy_cidrs
from app.models import EnrollmentToken, InvitationBatch, User, UserRole, utcnow
from app.rate_limit import PublicReadRateLimiter
from app.security import opaque_token_hash


SERVER_ROOT = Path(__file__).resolve().parents[1]
EXPANDING_NICKNAMES = (
    "\ufdfa" * 29,
    "\ufdfa" * 28 + "\u0390" * 3,
)


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


def _claim_database_state(harness, batch_id: str) -> tuple[int, int, int]:
    with harness.session_factory() as session:
        batch = session.get(InvitationBatch, batch_id)
        assert batch is not None
        return (
            session.scalar(select(func.count()).select_from(User)) or 0,
            session.scalar(select(func.count()).select_from(EnrollmentToken)) or 0,
            batch.claimed_count,
        )


def _recursive_keys(value) -> set[str]:
    if isinstance(value, dict):
        return set(value) | set().union(*(_recursive_keys(item) for item in value.values()), set())
    if isinstance(value, list):
        return set().union(*(_recursive_keys(item) for item in value), set())
    return set()


def test_admin_reissues_existing_member_without_duplicate_or_batch_slot(harness) -> None:
    created = _create_batch(harness, capacity=2)
    claimed = _claim(harness, created["invitation_token"], "漏存设备码成员")
    assert claimed.status_code == 201, claimed.text
    original_token = claimed.json()["enrollment_token"]

    enrolled = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": original_token,
            "device_public_id": str(uuid4()),
            "platform": "macos",
            "app_version": "0.1.0-beta.8",
            "collector_version": "0.1.0-beta.8",
        },
    )
    assert enrolled.status_code == 201, enrolled.text

    with harness.session_factory() as session:
        member = session.scalar(
            select(User).where(
                User.org_id == harness.users["a_admin"].org_id,
                User.display_name == "漏存设备码成员",
            )
        )
        assert member is not None
        before_user_count = session.scalar(select(func.count()).select_from(User))
        before_token_count = session.scalar(
            select(func.count()).select_from(EnrollmentToken)
        )
        batch = session.get(InvitationBatch, created["batch"]["id"])
        assert batch is not None and batch.claimed_count == 1
        original_row = session.scalar(
            select(EnrollmentToken).where(
                EnrollmentToken.token_hash == opaque_token_hash(original_token)
            )
        )
        assert original_row is not None and original_row.used_at is not None
        original_used_at = original_row.used_at
        member_id = member.id

    reissued = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={"user_id": member_id, "expires_in_minutes": 60},
    )
    assert reissued.status_code == 201, reissued.text
    assert reissued.headers["Cache-Control"] == "no-store"
    assert set(reissued.json()) == {"enrollment_token", "expires_at"}
    reissued_token = reissued.json()["enrollment_token"]
    assert reissued_token != original_token

    with harness.session_factory() as session:
        batch = session.get(InvitationBatch, created["batch"]["id"])
        assert batch is not None and batch.claimed_count == 1
        assert session.scalar(select(func.count()).select_from(User)) == before_user_count
        assert (
            session.scalar(select(func.count()).select_from(EnrollmentToken))
            == before_token_count + 1
        )
        original_row = session.scalar(
            select(EnrollmentToken).where(
                EnrollmentToken.token_hash == opaque_token_hash(original_token)
            )
        )
        reissued_row = session.scalar(
            select(EnrollmentToken).where(
                EnrollmentToken.token_hash == opaque_token_hash(reissued_token)
            )
        )
        assert original_row is not None and original_row.used_at == original_used_at
        assert reissued_row is not None and reissued_row.used_at is None
        assert reissued_row.user_id == member_id
        assert reissued_token not in repr(reissued_row.__dict__)

    second_device = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": reissued_token,
            "device_public_id": str(uuid4()),
            "platform": "macos",
            "app_version": "0.1.0-beta.8",
            "collector_version": "0.1.0-beta.8",
        },
    )
    assert second_device.status_code == 201, second_device.text

    reused = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": reissued_token,
            "device_public_id": str(uuid4()),
            "platform": "macos",
            "app_version": "0.1.0-beta.8",
            "collector_version": "0.1.0-beta.8",
        },
    )
    assert reused.status_code == 400


def test_admin_reissue_invalidates_lost_unused_code_and_keeps_one_live_code(harness) -> None:
    created = _create_batch(harness, capacity=2)
    claimed = _claim(harness, created["invitation_token"], "漏存未绑定成员")
    assert claimed.status_code == 201, claimed.text
    lost_token = claimed.json()["enrollment_token"]

    with harness.session_factory() as session:
        member = session.scalar(
            select(User).where(
                User.org_id == harness.users["a_admin"].org_id,
                User.display_name == "漏存未绑定成员",
            )
        )
        assert member is not None
        member_id = member.id
        before_user_count = session.scalar(select(func.count()).select_from(User))
        batch = session.get(InvitationBatch, created["batch"]["id"])
        assert batch is not None and batch.claimed_count == 1

    first_reissue = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={"user_id": member_id, "expires_in_minutes": 60},
    )
    assert first_reissue.status_code == 201, first_reissue.text
    first_reissued_token = first_reissue.json()["enrollment_token"]

    second_reissue = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={"user_id": member_id, "expires_in_minutes": 60},
    )
    assert second_reissue.status_code == 201, second_reissue.text
    live_token = second_reissue.json()["enrollment_token"]

    payload = {
        "device_public_id": str(uuid4()),
        "platform": "macos",
        "app_version": "0.1.0-beta.8",
        "collector_version": "0.1.0-beta.8",
    }
    for invalid_token in (lost_token, first_reissued_token):
        refused = harness.client.post(
            "/api/v1/devices/enroll",
            json={"enrollment_token": invalid_token, **payload},
        )
        assert refused.status_code == 400

    accepted = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": live_token,
            **{**payload, "device_public_id": str(uuid4())},
        },
    )
    assert accepted.status_code == 201, accepted.text

    with harness.session_factory() as session:
        batch = session.get(InvitationBatch, created["batch"]["id"])
        assert batch is not None and batch.claimed_count == 1
        assert session.scalar(select(func.count()).select_from(User)) == before_user_count
        rows = list(
            session.scalars(
                select(EnrollmentToken).where(
                    EnrollmentToken.org_id == harness.users["a_admin"].org_id,
                    EnrollmentToken.user_id == member_id,
                )
            )
        )
        assert len(rows) == 3
        assert sum(row.used_at is not None for row in rows) == 1
        assert session.scalar(
            select(func.count())
            .select_from(EnrollmentToken)
            .where(
                EnrollmentToken.org_id == harness.users["a_admin"].org_id,
                EnrollmentToken.user_id == member_id,
                EnrollmentToken.used_at.is_(None),
                EnrollmentToken.expires_at > utcnow(),
            )
        ) == 0


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


@pytest.mark.parametrize("nickname", EXPANDING_NICKNAMES)
def test_expanding_claim_nickname_returns_422_without_side_effects(
    harness,
    nickname: str,
) -> None:
    created = _create_batch(harness, capacity=2)
    with harness.session_factory() as session:
        before_users = session.scalar(select(func.count()).select_from(User)) or 0
        before_tokens = (
            session.scalar(select(func.count()).select_from(EnrollmentToken)) or 0
        )

    response = _claim(
        harness,
        created["invitation_token"],
        f"  {nickname}  ",
    )
    assert response.status_code == 422
    assert response.headers["Cache-Control"] == "no-store"
    assert nickname not in response.text
    assert created["invitation_token"] not in response.text

    with harness.session_factory() as session:
        batch = session.get(InvitationBatch, created["batch"]["id"])
        assert batch is not None and batch.claimed_count == 0
        assert session.scalar(select(func.count()).select_from(User)) == before_users
        assert (
            session.scalar(select(func.count()).select_from(EnrollmentToken))
            == before_tokens
        )


@pytest.mark.parametrize("nickname", EXPANDING_NICKNAMES)
def test_expanding_admin_nickname_returns_422_without_side_effects(
    harness,
    nickname: str,
) -> None:
    with harness.session_factory() as session:
        before_users = session.scalar(select(func.count()).select_from(User)) or 0
        before_tokens = (
            session.scalar(select(func.count()).select_from(EnrollmentToken)) or 0
        )

    response = harness.client.post(
        "/api/v1/admin/participants",
        headers=harness.auth("a_admin"),
        json={
            "display_name": f"  {nickname}  ",
            "public_profile_enabled": True,
            "expires_in_minutes": 60,
        },
    )
    assert response.status_code == 422
    assert response.headers["Cache-Control"] == "no-store"
    assert nickname not in response.text

    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(User)) == before_users
        assert (
            session.scalar(select(func.count()).select_from(EnrollmentToken))
            == before_tokens
        )


def test_claim_uses_direct_ip_and_an_independent_process_local_bucket(harness) -> None:
    created = _create_batch(harness, capacity=2)
    before = _claim_database_state(harness, created["batch"]["id"])
    limiter = PublicReadRateLimiter(attempts=2, window_seconds=60, max_keys=10)
    harness.app.state.claim_rate_limiter = limiter

    with TestClient(
        harness.app,
        client=("198.51.100.25", 50_000),
    ) as direct_client:
        for index, forwarded_for in enumerate(
            ("203.0.113.99", "203.0.113.100"),
            start=1,
        ):
            rejected = direct_client.post(
                "/api/v1/public/invitation-batches/claim",
                headers={"X-Forwarded-For": forwarded_for},
                json={
                    "invitation_token": f"invalid-claim-token-{index:02d}" + "x" * 32,
                    "display_name": f"无效直连-{index}",
                    "public_profile_enabled": True,
                },
            )
            assert rejected.status_code == 409

        limited = direct_client.post(
            "/api/v1/public/invitation-batches/claim",
            headers={"X-Forwarded-For": "203.0.113.101"},
            json={
                "invitation_token": created["invitation_token"],
                "display_name": "不会创建的成员",
                "public_profile_enabled": True,
            },
        )

    assert limited.status_code == 429
    assert limited.json() == {"detail": "too many invitation batch claim attempts"}
    assert int(limited.headers["Retry-After"]) >= 1
    assert created["invitation_token"] not in limited.text
    assert len(limiter._events) == 1
    assert harness.app.state.enrollment_rate_limiter._events == {}
    assert limiter is not harness.app.state.enrollment_rate_limiter
    assert _claim_database_state(harness, created["batch"]["id"]) == before


def test_claim_uses_verified_forwarded_ip_for_trusted_proxy_buckets(harness) -> None:
    created = _create_batch(harness, capacity=2)
    before = _claim_database_state(harness, created["batch"]["id"])
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = PublicReadRateLimiter(attempts=2, window_seconds=60, max_keys=10)
    harness.app.state.claim_rate_limiter = limiter

    with TestClient(
        harness.app,
        client=("10.20.30.40", 50_000),
    ) as proxy_client:
        for index in range(2):
            rejected = proxy_client.post(
                "/api/v1/public/invitation-batches/claim",
                headers={"X-Forwarded-For": "198.51.100.25"},
                json={
                    "invitation_token": f"invalid-proxy-token-{index:02d}" + "x" * 32,
                    "display_name": f"无效代理-{index}",
                    "public_profile_enabled": True,
                },
            )
            assert rejected.status_code == 409

        limited = proxy_client.post(
            "/api/v1/public/invitation-batches/claim",
            headers={"X-Forwarded-For": "198.51.100.25"},
            json={
                "invitation_token": created["invitation_token"],
                "display_name": "不会创建的代理成员",
                "public_profile_enabled": True,
            },
        )
        separate_client = proxy_client.post(
            "/api/v1/public/invitation-batches/claim",
            headers={"X-Forwarded-For": "198.51.100.26"},
            json={
                "invitation_token": "separate-forwarded-client-" + "x" * 32,
                "display_name": "另一来源",
                "public_profile_enabled": True,
            },
        )

    assert limited.status_code == 429
    assert int(limited.headers["Retry-After"]) >= 1
    assert separate_client.status_code == 409
    assert len(limiter._events) == 2
    assert _claim_database_state(harness, created["batch"]["id"]) == before


@pytest.mark.parametrize(
    ("client_address", "forwarded_for"),
    [
        (("10.20.30.40", 50_000), None),
        (("10.20.30.40", 50_000), "bogus, 198.51.100.25"),
        (("10.20.30.40", 50_000), "unknown, 198.51.100.25"),
        (("10.20.30.40", 50_000), "198.51.100.25:443"),
        (("10.20.30.40", 50_000), ", ".join(["198.51.100.25"] * 33)),
        (("192.0.2.10", 50_000), "198.51.100.25"),
    ],
)
def test_claim_rejects_unverifiable_proxy_identity_without_side_effects(
    harness,
    client_address: tuple[str, int],
    forwarded_for: str | None,
) -> None:
    created = _create_batch(harness, capacity=2)
    before = _claim_database_state(harness, created["batch"]["id"])
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = PublicReadRateLimiter(attempts=2, window_seconds=60, max_keys=10)
    harness.app.state.claim_rate_limiter = limiter
    headers = {"X-Forwarded-For": forwarded_for} if forwarded_for else {}

    with TestClient(harness.app, client=client_address) as proxy_client:
        rejected = proxy_client.post(
            "/api/v1/public/invitation-batches/claim",
            headers=headers,
            json={
                "invitation_token": created["invitation_token"],
                "display_name": "不会创建的错误代理成员",
                "public_profile_enabled": True,
            },
        )

    assert rejected.status_code == 400
    assert rejected.json() == {"detail": "invalid client network identity"}
    assert limiter._events == {}
    assert _claim_database_state(harness, created["batch"]["id"]) == before


def test_claim_rejects_uds_peer_without_side_effects(harness) -> None:
    created = _create_batch(harness, capacity=2)
    before = _claim_database_state(harness, created["batch"]["id"])
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = PublicReadRateLimiter(attempts=2, window_seconds=60, max_keys=10)
    harness.app.state.claim_rate_limiter = limiter

    with TestClient(harness.app, client=None) as uds_client:
        rejected = uds_client.post(
            "/api/v1/public/invitation-batches/claim",
            headers={"X-Forwarded-For": "198.51.100.25"},
            json={
                "invitation_token": created["invitation_token"],
                "display_name": "不会创建的 UDS 成员",
                "public_profile_enabled": True,
            },
        )

    assert rejected.status_code == 400
    assert rejected.json() == {"detail": "invalid client network identity"}
    assert limiter._events == {}
    assert _claim_database_state(harness, created["batch"]["id"]) == before


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
