from __future__ import annotations

import json
import os
import secrets
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.engine import Engine, URL, make_url
from sqlalchemy.orm import Session

from app.config import Settings
from app.main import create_app
from app.models import (
    DailyUsage,
    Device,
    DeviceNonce,
    EnrollmentToken,
    InvitationBatch,
    Organization,
    User,
    UserRole,
    utcnow,
)
from app.schemas import DailyUsageReport
from app.security import hash_password, opaque_token_hash, sign_device_request
from app.services import ingest_daily_usage

SERVER_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True, slots=True)
class PostgresRuntime:
    database_url: str = field(repr=False)
    engine: Engine


@dataclass(frozen=True, slots=True)
class Team:
    org_id: str
    org_slug: str
    admin_id: str
    admin_email: str
    member_id: str
    password: str = field(repr=False)


def _normalized_postgres_url() -> URL:
    raw_url = os.getenv("TEST_POSTGRES_URL")
    if not raw_url:
        pytest.skip("TEST_POSTGRES_URL is not set; real PostgreSQL smoke skipped")
    parse_error: str | None = None
    try:
        url = make_url(raw_url)
    except Exception as exc:
        parse_error = type(exc).__name__
    if parse_error is not None:
        pytest.fail(
            f"TEST_POSTGRES_URL could not be parsed ({parse_error})",
            pytrace=False,
        )
    if url.get_backend_name() != "postgresql":
        pytest.fail("TEST_POSTGRES_URL must use PostgreSQL", pytrace=False)
    if url.drivername == "postgresql":
        url = url.set(drivername="postgresql+psycopg")
    return url


def _alembic_config(database_url: str | None = None) -> Config:
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    if database_url is not None:
        config.attributes["database_url"] = database_url
    return config


@pytest.fixture(scope="module")
def postgres_runtime() -> PostgresRuntime:
    admin_url = _normalized_postgres_url()
    temporary_database = f"tokenfleet_smoke_{uuid.uuid4().hex[:16]}"
    # The identifier is generated locally from a fixed prefix and lowercase hex.
    quoted_database = f'"{temporary_database}"'
    admin_engine = create_engine(
        admin_url,
        isolation_level="AUTOCOMMIT",
        pool_pre_ping=True,
    )
    test_engine: Engine | None = None
    created = False
    try:
        setup_error: str | None = None
        try:
            with admin_engine.connect() as connection:
                connection.exec_driver_sql(
                    f"CREATE DATABASE {quoted_database} TEMPLATE template0 ENCODING 'UTF8'"
                )
            created = True
            test_url = admin_url.set(database=temporary_database)
            database_url = test_url.render_as_string(hide_password=False)
            command.upgrade(_alembic_config(database_url), "head")
            test_engine = create_engine(
                test_url,
                pool_pre_ping=True,
                pool_size=10,
                max_overflow=10,
            )
        except Exception as exc:
            setup_error = type(exc).__name__
        if setup_error is not None:
            pytest.fail(
                f"real PostgreSQL smoke setup failed ({setup_error})",
                pytrace=False,
            )
        assert test_engine is not None
        yield PostgresRuntime(database_url=database_url, engine=test_engine)
    finally:
        if test_engine is not None:
            test_engine.dispose()
        cleanup_error: str | None = None
        if created:
            try:
                with admin_engine.connect() as connection:
                    connection.execute(
                        text(
                            "SELECT pg_terminate_backend(pid) "
                            "FROM pg_stat_activity "
                            "WHERE datname = :database_name "
                            "AND pid <> pg_backend_pid()"
                        ),
                        {"database_name": temporary_database},
                    )
                    connection.exec_driver_sql(f"DROP DATABASE {quoted_database}")
            except Exception as exc:
                cleanup_error = type(exc).__name__
        admin_engine.dispose()
        if cleanup_error is not None:
            pytest.fail(
                f"temporary PostgreSQL database cleanup failed ({cleanup_error})",
                pytrace=False,
            )


def _new_team(runtime: PostgresRuntime, prefix: str) -> Team:
    suffix = uuid.uuid4().hex[:12]
    slug = f"{prefix}-{suffix}"
    admin_email = f"admin-{suffix}@example.com"
    password = secrets.token_urlsafe(24)
    with Session(runtime.engine, expire_on_commit=False) as session:
        organization = Organization(slug=slug, name=f"Smoke {prefix}")
        session.add(organization)
        session.flush()
        admin = User(
            org_id=organization.id,
            email=admin_email,
            password_hash=hash_password(password, 1_000),
            role=UserRole.ADMIN,
        )
        member = User(
            org_id=organization.id,
            email=f"member-{suffix}@example.com",
            password_hash=hash_password(password, 1_000),
            role=UserRole.MEMBER,
        )
        session.add_all([admin, member])
        session.commit()
        return Team(
            org_id=organization.id,
            org_slug=slug,
            admin_id=admin.id,
            admin_email=admin.email,
            member_id=member.id,
            password=password,
        )


def _app(runtime: PostgresRuntime, *, public_org_slug: str = ""):
    return create_app(
        settings=Settings(
            database_url=runtime.database_url,
            web_root="",
            jwt_secret=secrets.token_urlsafe(32),
            pbkdf2_iterations=1_000,
            public_org_slug=public_org_slug,
        ),
        engine=runtime.engine,
    )


def _admin_headers(client: TestClient, team: Team) -> dict[str, str]:
    login = client.post(
        "/api/v1/auth/token",
        json={
            "org_slug": team.org_slug,
            "email": team.admin_email,
            "password": team.password,
        },
    )
    assert login.status_code == 200
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


def _issue_enrollment_token(
    client: TestClient, team: Team, admin_headers: dict[str, str]
) -> str:
    invitation = client.post(
        "/api/v1/enrollment-tokens",
        headers=admin_headers,
        json={"user_id": team.member_id, "expires_in_minutes": 60},
    )
    assert invitation.status_code == 201
    return invitation.json()["enrollment_token"]


def _enroll(
    client: TestClient,
    token: str,
    public_id: str,
) -> dict[str, str]:
    response = client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": token,
            "device_public_id": public_id,
            "platform": "postgres-smoke",
            "app_version": "1.0.0",
            "collector_version": "1.0.0",
        },
    )
    assert response.status_code == 201
    return response.json()


def _usage_payload(*, generated_at: datetime) -> dict[str, object]:
    return {
        "schema_version": 1,
        "collector_version": "1.0.0",
        "generated_at": generated_at.astimezone(timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "buckets": [
            {
                "date": datetime.now(timezone.utc).date().isoformat(),
                "timezone": "UTC",
                "tool": "Codex",
                "model": "postgres-smoke-model",
                "source": "local",
                "input_tokens": 120,
                "output_tokens": 80,
                "cache_read_tokens": 1_000,
                "cache_write_tokens": 50,
                "completeness": "exact",
            }
        ],
    }


def _tombstone_payload(*, generated_at: datetime) -> dict[str, object]:
    payload = _usage_payload(generated_at=generated_at)
    payload["buckets"][0].update(
        {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "completeness": "exact",
            "deleted": True,
        }
    )
    return payload


def _signed_usage(
    client: TestClient,
    *,
    device_id: str,
    device_secret: str,
    payload: dict[str, object],
):
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    timestamp = str(int(time.time()))
    nonce = str(uuid.uuid4())
    signature = sign_device_request(
        device_secret=device_secret,
        timestamp_text=timestamp,
        nonce=nonce,
        method="POST",
        path="/api/v1/usage/daily",
        body=body,
    )
    return client.post(
        "/api/v1/usage/daily",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-Device-ID": device_id,
            "X-Timestamp": timestamp,
            "X-Nonce": nonce,
            "X-Signature": signature,
        },
    )


def test_postgres_migration_starts_from_fresh_database(
    postgres_runtime: PostgresRuntime,
) -> None:
    migration_config = _alembic_config(postgres_runtime.database_url)
    # Exercise the real PostgreSQL downgrade path before any fixture data is
    # created, then prove non-login participant data blocks a destructive
    # downgrade without changing the revision.
    command.downgrade(migration_config, "bb8d4e1a2f73")
    command.upgrade(migration_config, "head")
    with Session(postgres_runtime.engine) as session:
        organization = Organization(slug="downgrade-guard", name="Guard")
        session.add(organization)
        session.flush()
        session.add(
            User(
                org_id=organization.id,
                email=None,
                password_hash=None,
                display_name="Guard Participant",
                role=UserRole.MEMBER,
            )
        )
        session.commit()
    with pytest.raises(
        RuntimeError,
        match="cannot downgrade invitation batches while participants or batches exist",
    ):
        command.downgrade(migration_config, "bb8d4e1a2f73")
    with postgres_runtime.engine.begin() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "c7b4e2a91d35"
        )
        connection.execute(
            text("DELETE FROM organizations WHERE slug = 'downgrade-guard'")
        )
    command.downgrade(migration_config, "bb8d4e1a2f73")
    command.upgrade(migration_config, "head")

    expected_tables = {
        "alembic_version",
        "organizations",
        "users",
        "devices",
        "enrollment_tokens",
        "device_nonces",
        "invitation_batches",
        "price_versions",
        "daily_usage",
    }
    assert expected_tables <= set(inspect(postgres_runtime.engine).get_table_names())
    usage_columns = {
        column["name"]
        for column in inspect(postgres_runtime.engine).get_columns("daily_usage")
    }
    assert "is_deleted" in usage_columns
    user_columns = {
        column["name"]
        for column in inspect(postgres_runtime.engine).get_columns("users")
    }
    assert {
        "normalized_display_name",
        "public_id",
        "public_profile_enabled",
    } <= user_columns
    price_columns = {
        column["name"]
        for column in inspect(postgres_runtime.engine).get_columns("price_versions")
    }
    assert "public_estimate" in price_columns
    usage_indexes = {
        item["name"]
        for item in inspect(postgres_runtime.engine).get_indexes("daily_usage")
    }
    assert {
        "ix_usage_public_org_tool_date",
        "ix_usage_public_org_model_date",
    } <= usage_indexes
    with postgres_runtime.engine.connect() as connection:
        database_revision = connection.scalar(text("SELECT version_num FROM alembic_version"))
    script_head = ScriptDirectory.from_config(_alembic_config()).get_current_head()
    assert database_revision == script_head


def test_postgres_readiness_ignores_ambiguous_public_organization(
    postgres_runtime: PostgresRuntime,
) -> None:
    duplicate_slug = f"ambiguous-{uuid.uuid4().hex[:12]}"
    index_dropped = False
    try:
        with postgres_runtime.engine.begin() as connection:
            connection.exec_driver_sql("DROP INDEX ix_organizations_slug")
            connection.execute(
                text(
                    "INSERT INTO organizations "
                    "(id, slug, name, default_timezone, retention_days, "
                    "ledger_version, created_at) VALUES "
                    "(:first_id, :slug, 'First', 'UTC', 395, 0, :now), "
                    "(:second_id, :slug, 'Second', 'UTC', 395, 0, :now)"
                ),
                {
                    "first_id": str(uuid.uuid4()),
                    "second_id": str(uuid.uuid4()),
                    "slug": duplicate_slug,
                    "now": datetime.now(timezone.utc),
                },
            )
        index_dropped = True

        app = _app(postgres_runtime, public_org_slug=duplicate_slug)
        with TestClient(app) as client:
            readiness = client.get("/readyz")
            public = client.get("/api/v1/public/leaderboard")
        assert readiness.status_code == 200
        assert readiness.json() == {"status": "ready"}
        assert public.status_code == 404
        assert public.json() == {"detail": "public leaderboard not found"}
        assert duplicate_slug not in public.text
    finally:
        if index_dropped:
            with postgres_runtime.engine.begin() as connection:
                connection.execute(
                    text("DELETE FROM organizations WHERE slug = :slug"),
                    {"slug": duplicate_slug},
                )
                connection.exec_driver_sql(
                    "CREATE UNIQUE INDEX ix_organizations_slug "
                    "ON organizations (slug)"
                )


def test_postgres_public_participant_projection_and_immediate_hide(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "public")
    app = _app(postgres_runtime, public_org_slug=team.org_slug)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        created = client.post(
            "/api/v1/admin/participants",
            headers=admin_headers,
            json={
                "display_name": "PG Public",
                "public_profile_enabled": True,
                "expires_in_minutes": 60,
            },
        )
        assert created.status_code == 201
        participant = created.json()["participant"]
        assert participant["email"] is None
        assert participant["can_login"] is False
        enrolled = _enroll(
            client,
            created.json()["enrollment_token"],
            str(uuid.uuid4()),
        )
        price = client.post(
            "/api/v1/prices",
            headers=admin_headers,
            json={
                "tool": "Codex",
                "model": "postgres-smoke-model",
                "currency": "USD",
                "public_estimate": True,
                "input_per_million": "1",
                "output_per_million": "1",
                "cache_read_per_million": "1",
                "cache_write_per_million": "1",
                "effective_from": datetime.now(timezone.utc).date().isoformat(),
            },
        )
        assert price.status_code == 201
        uploaded = _signed_usage(
            client,
            device_id=enrolled["device_id"],
            device_secret=enrolled["device_secret"],
            payload=_usage_payload(generated_at=datetime.now(timezone.utc)),
        )
        assert uploaded.status_code == 200

        leaderboard = client.get(
            "/api/v1/public/leaderboard",
            params={"period": "all", "metric": "cost"},
        )
        assert leaderboard.status_code == 200
        entry = leaderboard.json()["entries"][0]
        assert entry["public_id"] == participant["public_id"]
        assert entry["metric_value"] == "1250"
        assert entry["totals"]["unpriced"] is False
        assert "unpriced_rows" not in entry["totals"]
        assert leaderboard.json()["available_tools"] == ["Codex"]
        assert leaderboard.json()["available_models"] == [
            "postgres-smoke-model"
        ]
        assert team.admin_email not in leaderboard.text
        assert team.member_id not in leaderboard.text
        assert enrolled["device_id"] not in leaderboard.text
        detail = client.get(
            f"/api/v1/public/members/{participant['public_id']}",
            params={"period": "all", "metric": "cost"},
        )
        assert detail.status_code == 200
        assert detail.json()["rank"] == 1
        assert detail.json()["metric_value"] == "1250"

        hidden = client.patch(
            f"/api/v1/users/{participant['id']}",
            headers=admin_headers,
            json={"is_active": False},
        )
        assert hidden.status_code == 200
        assert hidden.json()["public_profile_enabled"] is False
        assert client.get(
            f"/api/v1/public/members/{participant['public_id']}",
            params={"period": "all", "metric": "cost"},
        ).status_code == 404
        assert client.get(
            "/api/v1/public/leaderboard",
            params={"period": "all", "metric": "cost"},
        ).json()["entries"] == []


def test_postgres_fifty_member_beta_capacity(postgres_runtime: PostgresRuntime) -> None:
    team = _new_team(postgres_runtime, "beta50")
    app = _app(postgres_runtime, public_org_slug=team.org_slug)
    public_ids: set[str] = set()
    device_ids: set[str] = set()

    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        for index in range(50):
            created = client.post(
                "/api/v1/admin/participants",
                headers=admin_headers,
                json={
                    "display_name": f"PG Beta {index + 1:02d}",
                    "public_profile_enabled": True,
                    "expires_in_minutes": 60,
                },
            )
            assert created.status_code == 201, created.text
            created_body = created.json()
            enrolled = _enroll(
                client,
                created_body["enrollment_token"],
                str(uuid.uuid4()),
            )
            payload = _usage_payload(generated_at=datetime.now(timezone.utc))
            payload["buckets"][0]["input_tokens"] = index + 1
            uploaded = _signed_usage(
                client,
                device_id=enrolled["device_id"],
                device_secret=enrolled["device_secret"],
                payload=payload,
            )
            assert uploaded.status_code == 200, uploaded.text
            public_ids.add(created_body["participant"]["public_id"])
            device_ids.add(enrolled["device_id"])

        leaderboard = client.get(
            "/api/v1/public/leaderboard",
            params={"period": "all", "metric": "tokens", "limit": 100},
        )
        assert leaderboard.status_code == 200, leaderboard.text
        response = leaderboard.json()
        assert response["total_entries"] == 50
        assert len(response["entries"]) == 50
        assert {item["public_id"] for item in response["entries"]} == public_ids
        assert len(public_ids) == 50
        assert len(device_ids) == 50
        assert all(device_id not in leaderboard.text for device_id in device_ids)

    with Session(postgres_runtime.engine) as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.org_id == team.org_id)
        ) == 50


def test_postgres_invitation_batch_sixty_concurrent_claims_accept_exactly_fifty(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "batch-capacity")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        created = client.post(
            "/api/v1/admin/invitation-batches",
            headers=_admin_headers(client, team),
            json={"capacity": 50, "expires_in_hours": 24},
        )
        assert created.status_code == 201, created.text
        batch_id = created.json()["batch"]["id"]
        invitation_token = created.json()["invitation_token"]

    barrier = threading.Barrier(60)

    def attempt(index: int) -> tuple[int, dict[str, object]]:
        with TestClient(
            app,
            client=(f"198.51.100.{index + 1}", 50_000 + index),
        ) as concurrent_client:
            barrier.wait(timeout=30)
            response = concurrent_client.post(
                "/api/v1/public/invitation-batches/claim",
                json={
                    "invitation_token": invitation_token,
                    "display_name": f"并发成员-{index:02d}",
                    "public_profile_enabled": True,
                },
            )
            return response.status_code, response.json()

    with ThreadPoolExecutor(max_workers=60) as executor:
        results = list(executor.map(attempt, range(60)))

    accepted = [body for status, body in results if status == 201]
    rejected = [body for status, body in results if status == 409]
    assert all(status != 429 for status, _body in results)
    assert len(accepted) == 50
    assert len(rejected) == 10
    assert all(body == {"detail": "invitation batch unavailable"} for body in rejected)
    assert all(
        set(body) == {"nickname", "enrollment_token", "expires_at"}
        for body in accepted
    )

    with Session(postgres_runtime.engine) as session:
        batch = session.get(InvitationBatch, batch_id)
        assert batch is not None and batch.claimed_count == 50
        assert session.scalar(
            select(func.count())
            .select_from(User)
            .where(User.org_id == team.org_id, User.email.is_(None))
        ) == 50
        assert session.scalar(
            select(func.count())
            .select_from(EnrollmentToken)
            .where(EnrollmentToken.org_id == team.org_id)
        ) == 50


def test_postgres_invitation_batch_and_admin_same_nickname_have_one_winner(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "batch-nickname")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        created = client.post(
            "/api/v1/admin/invitation-batches",
            headers=admin_headers,
            json={"capacity": 50, "expires_in_hours": 24},
        )
        assert created.status_code == 201
        batch_id = created.json()["batch"]["id"]
        invitation_token = created.json()["invitation_token"]

    barrier = threading.Barrier(2)

    def claim() -> tuple[str, int]:
        with TestClient(app) as concurrent_client:
            barrier.wait(timeout=10)
            response = concurrent_client.post(
                "/api/v1/public/invitation-batches/claim",
                json={
                    "invitation_token": invitation_token,
                    "display_name": "ＲＡＣＥ NAME",
                    "public_profile_enabled": True,
                },
            )
            return "claim", response.status_code

    def create_admin() -> tuple[str, int]:
        with TestClient(app) as concurrent_client:
            barrier.wait(timeout=10)
            response = concurrent_client.post(
                "/api/v1/admin/users",
                headers=admin_headers,
                json={
                    "email": f"race-{uuid.uuid4().hex[:12]}@example.com",
                    "password": secrets.token_urlsafe(24),
                    "role": "admin",
                    "display_name": "race name",
                },
            )
            return "admin", response.status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(function) for function in (claim, create_admin)]
        outcomes = dict(future.result() for future in futures)

    assert sorted(outcomes.values()) == [201, 409]
    with Session(postgres_runtime.engine) as session:
        assert session.scalar(
            select(func.count())
            .select_from(User)
            .where(
                User.org_id == team.org_id,
                User.normalized_display_name == "race name",
            )
        ) == 1
        batch = session.get(InvitationBatch, batch_id)
        assert batch is not None
        assert batch.claimed_count == (1 if outcomes["claim"] == 201 else 0)
        assert session.scalar(
            select(func.count())
            .select_from(EnrollmentToken)
            .where(EnrollmentToken.org_id == team.org_id)
        ) == (1 if outcomes["claim"] == 201 else 0)


def test_postgres_invitation_batch_rbac_and_claim_response_whitelist(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "batch-rbac")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        with Session(postgres_runtime.engine) as session:
            member = session.get(User, team.member_id)
            assert member is not None and member.email is not None
            member_email = member.email
        member_login = client.post(
            "/api/v1/auth/token",
            json={
                "org_slug": team.org_slug,
                "email": member_email,
                "password": team.password,
            },
        )
        assert member_login.status_code == 200
        member_headers = {
            "Authorization": f"Bearer {member_login.json()['access_token']}"
        }
        assert client.post(
            "/api/v1/admin/invitation-batches",
            json={"capacity": 1, "expires_in_hours": 1},
        ).status_code == 401
        assert client.post(
            "/api/v1/admin/invitation-batches",
            headers=member_headers,
            json={"capacity": 1, "expires_in_hours": 1},
        ).status_code == 403
        assert client.get(
            "/api/v1/admin/invitation-batches",
            headers=member_headers,
        ).status_code == 403

        created = client.post(
            "/api/v1/admin/invitation-batches",
            headers=_admin_headers(client, team),
            json={"capacity": 1, "expires_in_hours": 1},
        )
        assert created.status_code == 201
        assert client.post(
            f"/api/v1/admin/invitation-batches/{created.json()['batch']['id']}/close",
            headers=member_headers,
        ).status_code == 403

        active = client.post(
            "/api/v1/admin/invitation-batches",
            headers=_admin_headers(client, team),
            json={"capacity": 1, "expires_in_hours": 1},
        )
        claimed = client.post(
            "/api/v1/public/invitation-batches/claim",
            json={
                "invitation_token": active.json()["invitation_token"],
                "display_name": "匿名入口成员",
                "public_profile_enabled": True,
            },
        )
        assert claimed.status_code == 201
        assert claimed.headers["Cache-Control"] == "no-store"
        assert set(claimed.json()) == {"nickname", "enrollment_token", "expires_at"}
        forbidden = {
            "batch_id",
            "created_by_user_id",
            "id",
            "org_id",
            "organization",
            "participant",
            "public_id",
            "user_id",
        }
        assert forbidden.isdisjoint(claimed.json())


def test_two_postgres_connections_upsert_same_natural_key_once(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "usage")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        public_id = str(uuid.uuid4())
        enrolled = _enroll(
            client,
            _issue_enrollment_token(client, team, admin_headers),
            public_id,
        )
        report = DailyUsageReport.model_validate(
            _usage_payload(generated_at=datetime.now(timezone.utc) - timedelta(seconds=2))
        )
        barrier = threading.Barrier(2)

        def write_from_independent_connection():
            with Session(postgres_runtime.engine, expire_on_commit=False) as session:
                backend_pid = session.scalar(text("SELECT pg_backend_pid()"))
                device = session.scalar(
                    select(Device).where(Device.id == enrolled["device_id"])
                )
                assert device is not None
                barrier.wait(timeout=10)
                result = ingest_daily_usage(
                    session,
                    device=device,
                    report=report,
                    max_rows_per_device=100_000,
                    max_rows_per_org=2_000_000,
                )
                return backend_pid, result

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(
                executor.map(
                    lambda _index: write_from_independent_connection(), range(2)
                )
            )

        assert len({backend_pid for backend_pid, _result in results}) == 2
        classifications = sorted(result[:3] for _pid, result in results)
        assert classifications == [(0, 0, 1), (1, 0, 0)]
        assert {result[3] for _pid, result in results} == {1}

        dashboard = client.get("/api/v1/dashboard", headers=admin_headers)
        assert dashboard.status_code == 200
        assert len(dashboard.json()["rows"]) == 1
        assert dashboard.json()["totals"]["input_tokens"] == 120
        assert dashboard.json()["totals"]["total_tokens"] == 1_250
        with Session(postgres_runtime.engine) as session:
            assert session.scalar(
                select(func.count())
                .select_from(DailyUsage)
                .where(DailyUsage.org_id == team.org_id)
            ) == 1
            organization = session.scalar(
                select(Organization).where(Organization.id == team.org_id)
            )
            assert organization is not None and organization.ledger_version == 1


def test_postgres_concurrent_org_quota_has_exactly_one_winner(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "quota")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        enrolled_devices = [
            _enroll(
                client,
                _issue_enrollment_token(client, team, admin_headers),
                str(uuid.uuid4()),
            )
            for _ in range(2)
        ]

    reports = []
    base_time = datetime.now(timezone.utc) - timedelta(seconds=3)
    for index in range(2):
        payload = _usage_payload(
            generated_at=base_time + timedelta(milliseconds=index)
        )
        payload["buckets"][0]["model"] = f"concurrent-quota-{index}"
        reports.append(DailyUsageReport.model_validate(payload))
    barrier = threading.Barrier(2)

    def write_from_independent_connection(index: int):
        with Session(postgres_runtime.engine, expire_on_commit=False) as session:
            backend_pid = session.scalar(text("SELECT pg_backend_pid()"))
            device = session.scalar(
                select(Device).where(Device.id == enrolled_devices[index]["device_id"])
            )
            assert device is not None
            barrier.wait(timeout=10)
            try:
                result = ingest_daily_usage(
                    session,
                    device=device,
                    report=reports[index],
                    max_rows_per_device=10,
                    max_rows_per_org=1,
                )
                return backend_pid, "accepted", result
            except HTTPException as exc:
                assert exc.status_code == 422
                assert exc.detail["code"] == "usage_row_quota_exceeded"
                assert exc.detail["scope"] == "organization"
                return backend_pid, "rejected", None

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(write_from_independent_connection, range(2)))

    assert len({backend_pid for backend_pid, _status, _result in results}) == 2
    assert sorted(status for _pid, status, _result in results) == [
        "accepted",
        "rejected",
    ]
    accepted_result = next(
        result for _pid, status, result in results if status == "accepted"
    )
    assert accepted_result is not None and accepted_result[:3] == (1, 0, 0)

    with Session(postgres_runtime.engine) as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.org_id == team.org_id)
        ) == 1
        organization = session.scalar(
            select(Organization).where(Organization.id == team.org_id)
        )
        devices = list(
            session.scalars(
                select(Device)
                .where(Device.org_id == team.org_id)
                .order_by(Device.id)
            )
        )
        assert organization is not None and organization.ledger_version == 1
        assert sum(device.last_successful_sync_at is not None for device in devices) == 1


def test_postgres_usage_rate_limit_is_shared_across_connections(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "request-rate")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        enrolled_devices = [
            _enroll(
                client,
                _issue_enrollment_token(client, team, admin_headers),
                str(uuid.uuid4()),
            )
            for _ in range(2)
        ]
    app.state.settings = replace(
        app.state.settings,
        usage_rate_limit_device_attempts=10,
        usage_rate_limit_org_attempts=1,
        usage_rate_limit_window_seconds=60,
    )
    payloads = []
    for index in range(2):
        payload = _usage_payload(
            generated_at=datetime.now(timezone.utc) - timedelta(seconds=2)
        )
        payload["buckets"][0]["model"] = f"request-rate-{index}"
        payloads.append(payload)
    barrier = threading.Barrier(2)

    def attempt(index: int) -> int:
        with TestClient(app) as concurrent_client:
            barrier.wait(timeout=10)
            response = _signed_usage(
                concurrent_client,
                device_id=enrolled_devices[index]["device_id"],
                device_secret=enrolled_devices[index]["device_secret"],
                payload=payloads[index],
            )
            if response.status_code == 429:
                assert int(response.headers["Retry-After"]) >= 1
            return response.status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        statuses = sorted(executor.map(attempt, range(2)))
    assert statuses == [200, 429]
    with Session(postgres_runtime.engine) as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.org_id == team.org_id)
        ) == 1
        assert session.scalar(
            select(func.count())
            .select_from(DeviceNonce)
            .join(Device, Device.id == DeviceNonce.device_id)
            .where(Device.org_id == team.org_id)
        ) == 1


def test_postgres_device_rate_limit_serializes_same_device(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "device-rate")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        enrolled = _enroll(
            client,
            _issue_enrollment_token(client, team, admin_headers),
            str(uuid.uuid4()),
        )
    app.state.settings = replace(
        app.state.settings,
        usage_rate_limit_device_attempts=1,
        usage_rate_limit_org_attempts=10,
        usage_rate_limit_window_seconds=60,
    )
    payloads = []
    for index in range(2):
        payload = _usage_payload(
            generated_at=datetime.now(timezone.utc) - timedelta(seconds=2)
        )
        payload["buckets"][0]["model"] = f"device-rate-{index}"
        payloads.append(payload)
    barrier = threading.Barrier(2)

    def attempt(index: int) -> int:
        with TestClient(app) as concurrent_client:
            barrier.wait(timeout=10)
            return _signed_usage(
                concurrent_client,
                device_id=enrolled["device_id"],
                device_secret=enrolled["device_secret"],
                payload=payloads[index],
            ).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(attempt, range(2))) == [200, 429]
    with Session(postgres_runtime.engine) as session:
        assert session.scalar(
            select(func.count())
            .select_from(DeviceNonce)
            .where(DeviceNonce.device_id == enrolled["device_id"])
        ) == 1
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.device_id == enrolled["device_id"])
        ) == 1


def test_postgres_concurrent_quality_resolution_always_keeps_exact(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "quality")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        enrolled = _enroll(
            client,
            _issue_enrollment_token(client, team, admin_headers),
            str(uuid.uuid4()),
        )

    base_time = datetime.now(timezone.utc) - timedelta(seconds=3)
    exact_payload = _usage_payload(generated_at=base_time)
    exact_payload["buckets"][0]["input_tokens"] = 777
    fallback_payload = _usage_payload(generated_at=base_time + timedelta(seconds=1))
    fallback_payload["buckets"][0]["input_tokens"] = 1
    fallback_payload["buckets"][0]["completeness"] = "fallback_estimate"
    reports = [
        DailyUsageReport.model_validate(exact_payload),
        DailyUsageReport.model_validate(fallback_payload),
    ]
    barrier = threading.Barrier(2)

    def write_from_independent_connection(report: DailyUsageReport):
        with Session(postgres_runtime.engine, expire_on_commit=False) as session:
            device = session.scalar(
                select(Device).where(Device.id == enrolled["device_id"])
            )
            assert device is not None
            barrier.wait(timeout=10)
            return ingest_daily_usage(
                session,
                device=device,
                report=report,
                max_rows_per_device=100_000,
                max_rows_per_org=2_000_000,
            )

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(write_from_independent_connection, reports))

    classifications = [result[:3] for result in results]
    assert classifications.count((1, 0, 0)) == 1
    remaining = next(
        classification
        for classification in classifications
        if classification != (1, 0, 0)
    )
    # If exact inserts first, the estimate is unchanged. If the estimate wins
    # the insert race, exact performs one quality upgrade. Both orders converge.
    assert remaining in {(0, 0, 1), (0, 1, 0)}

    with Session(postgres_runtime.engine) as session:
        row = session.scalar(
            select(DailyUsage).where(DailyUsage.org_id == team.org_id)
        )
        organization = session.scalar(
            select(Organization).where(Organization.id == team.org_id)
        )
        assert row is not None
        assert row.completeness == "exact"
        assert row.input_tokens == 777
        assert organization is not None
        assert organization.ledger_version == (2 if remaining == (0, 1, 0) else 1)


def test_postgres_concurrent_equal_version_tombstone_always_wins(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "tombstone")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        enrolled = _enroll(
            client,
            _issue_enrollment_token(client, team, admin_headers),
            str(uuid.uuid4()),
        )

    generated_at = datetime.now(timezone.utc) - timedelta(seconds=3)
    active_payload = _usage_payload(generated_at=generated_at)
    active_payload["buckets"][0]["input_tokens"] = 777
    reports = [
        DailyUsageReport.model_validate(active_payload),
        DailyUsageReport.model_validate(
            _tombstone_payload(generated_at=generated_at)
        ),
    ]
    barrier = threading.Barrier(2)

    def write_from_independent_connection(report: DailyUsageReport):
        with Session(postgres_runtime.engine, expire_on_commit=False) as session:
            backend_pid = session.scalar(text("SELECT pg_backend_pid()"))
            device = session.scalar(
                select(Device).where(Device.id == enrolled["device_id"])
            )
            assert device is not None
            barrier.wait(timeout=10)
            result = ingest_daily_usage(
                session,
                device=device,
                report=report,
                max_rows_per_device=100_000,
                max_rows_per_org=2_000_000,
            )
            return backend_pid, result

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(write_from_independent_connection, reports))

    assert len({backend_pid for backend_pid, _result in results}) == 2
    active_result = results[0][1]
    tombstone_result = results[1][1]
    assert active_result[:3] in {(1, 0, 0), (0, 0, 1)}
    assert tombstone_result[:3] == (0, 1, 0)

    with Session(postgres_runtime.engine) as session:
        row = session.scalar(
            select(DailyUsage).where(DailyUsage.org_id == team.org_id)
        )
        organization = session.scalar(
            select(Organization).where(Organization.id == team.org_id)
        )
        assert row is not None and row.is_deleted
        assert row.input_tokens == 0
        assert organization is not None
        assert organization.ledger_version in {1, 2}

    with TestClient(app) as client:
        dashboard = client.get(
            "/api/v1/dashboard", headers=_admin_headers(client, team)
        )
        assert dashboard.status_code == 200
        assert dashboard.json()["rows"] == []
        assert dashboard.json()["totals"]["total_tokens"] == 0


def test_postgres_concurrent_enrollment_token_has_one_winner(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "enrollment")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        token = _issue_enrollment_token(client, team, admin_headers)

    barrier = threading.Barrier(2)

    def attempt(public_id: str) -> int:
        with TestClient(app) as concurrent_client:
            barrier.wait(timeout=10)
            response = concurrent_client.post(
                "/api/v1/devices/enroll",
                json={
                    "enrollment_token": token,
                    "device_public_id": public_id,
                    "platform": "postgres-smoke",
                    "app_version": "1.0.0",
                    "collector_version": "1.0.0",
                },
            )
            return response.status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        statuses = sorted(executor.map(attempt, [str(uuid.uuid4()), str(uuid.uuid4())]))
    assert statuses == [201, 400]
    with Session(postgres_runtime.engine) as session:
        assert session.scalar(
            select(func.count())
            .select_from(Device)
            .where(Device.org_id == team.org_id)
        ) == 1
        stored_token = session.scalar(
            select(EnrollmentToken).where(
                EnrollmentToken.token_hash == opaque_token_hash(token)
            )
        )
        assert stored_token is not None and stored_token.used_at is not None


def test_postgres_concurrent_reissue_leaves_exactly_one_live_token(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "reissue")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        lost_token = _issue_enrollment_token(client, team, admin_headers)

    barrier = threading.Barrier(2)

    def attempt() -> tuple[int, str | None]:
        with TestClient(app) as concurrent_client:
            headers = _admin_headers(concurrent_client, team)
            barrier.wait(timeout=10)
            response = concurrent_client.post(
                "/api/v1/enrollment-tokens",
                headers=headers,
                json={"user_id": team.member_id, "expires_in_minutes": 60},
            )
            return response.status_code, response.json().get("enrollment_token")

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: attempt(), range(2)))
    assert [status for status, _ in results] == [201, 201]

    issued_tokens = [token for _, token in results if token is not None]
    assert len(issued_tokens) == 2
    now = utcnow()
    with Session(postgres_runtime.engine) as session:
        live_rows = list(
            session.scalars(
                select(EnrollmentToken).where(
                    EnrollmentToken.org_id == team.org_id,
                    EnrollmentToken.user_id == team.member_id,
                    EnrollmentToken.used_at.is_(None),
                    EnrollmentToken.expires_at > now,
                )
            )
        )
        assert len(live_rows) == 1
        live_hash = live_rows[0].token_hash

    live_tokens = [
        token for token in issued_tokens if opaque_token_hash(token) == live_hash
    ]
    assert len(live_tokens) == 1
    with TestClient(app) as client:
        refused_tokens = [lost_token] + [
            token for token in issued_tokens if token != live_tokens[0]
        ]
        for token in refused_tokens:
            response = client.post(
                "/api/v1/devices/enroll",
                json={
                    "enrollment_token": token,
                    "device_public_id": str(uuid.uuid4()),
                    "platform": "postgres-smoke",
                    "app_version": "1.0.0",
                    "collector_version": "1.0.0",
                },
            )
            assert response.status_code == 400
        _enroll(client, live_tokens[0], str(uuid.uuid4()))


def test_postgres_stable_device_reenrollment_does_not_duplicate_history(
    postgres_runtime: PostgresRuntime,
) -> None:
    team = _new_team(postgres_runtime, "reenrollment")
    app = _app(postgres_runtime)
    with TestClient(app) as client:
        admin_headers = _admin_headers(client, team)
        public_id = str(uuid.uuid4())
        first = _enroll(
            client,
            _issue_enrollment_token(client, team, admin_headers),
            public_id,
        )
        initial_payload = _usage_payload(
            generated_at=datetime.now(timezone.utc) - timedelta(seconds=2)
        )
        assert _signed_usage(
            client,
            device_id=first["device_id"],
            device_secret=first["device_secret"],
            payload=initial_payload,
        ).status_code == 200

        reenrolled = _enroll(
            client,
            _issue_enrollment_token(client, team, admin_headers),
            public_id,
        )
        assert reenrolled["device_id"] == first["device_id"]
        updated_payload = _usage_payload(generated_at=datetime.now(timezone.utc))
        assert _signed_usage(
            client,
            device_id=first["device_id"],
            device_secret=first["device_secret"],
            payload=updated_payload,
        ).status_code == 401
        assert _signed_usage(
            client,
            device_id=reenrolled["device_id"],
            device_secret=reenrolled["device_secret"],
            payload=updated_payload,
        ).status_code == 200

        dashboard = client.get("/api/v1/dashboard", headers=admin_headers)
        assert dashboard.status_code == 200
        assert len(dashboard.json()["rows"]) == 1
        assert dashboard.json()["totals"]["total_tokens"] == 1_250
        with Session(postgres_runtime.engine) as session:
            assert session.scalar(
                select(func.count())
                .select_from(Device)
                .where(
                    Device.org_id == team.org_id,
                    Device.device_public_id == public_id,
                )
            ) == 1
            assert session.scalar(
                select(func.count())
                .select_from(DailyUsage)
                .where(DailyUsage.org_id == team.org_id)
            ) == 1
