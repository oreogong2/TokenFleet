from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError, OperationalError

from app.config import Settings
from app.cli import purge_retention
from app.database import Base, build_engine, build_session_factory
from app.main import create_app
from app.middleware import parse_trusted_proxy_cidrs
from app.models import DailyUsage, Device, DeviceNonce, Organization, User, UserRole
from app.rate_limit import LoginRateLimiter
from app.schemas import TOKEN_MAX


def test_database_errors_hide_bound_parameters(tmp_path) -> None:
    secret = "known-test-device-signing-capability"
    engine = build_engine(f"sqlite:///{tmp_path / 'hidden-parameters.db'}")
    assert engine.hide_parameters is True
    with engine.connect() as connection:
        with pytest.raises(OperationalError) as captured:
            connection.execute(
                text(
                    "INSERT INTO deliberately_missing_table(signing_key) "
                    "VALUES (:signing_key)"
                ),
                {"signing_key": secret},
            )
    rendered = str(captured.value)
    assert secret not in rendered
    assert "SQL parameters hidden due to hide_parameters=True" in rendered
    engine.dispose()


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("input_tokens", -1),
        ("output_tokens", 9_000_000_000_000_001),
        ("cache_read_tokens", "12"),
        ("cache_write_tokens", 1.5),
    ],
)
def test_token_schema_is_strict_and_bounded(harness, field, value) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    payload["buckets"][0][field] = value
    assert harness.signed_post(device, payload).status_code == 422


def test_dates_timezone_versions_and_bucket_limit_are_validated(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")

    invalid_timezone = harness.usage_payload()
    invalid_timezone["buckets"][0]["timezone"] = "Not/AZone"
    assert harness.signed_post(device, invalid_timezone).status_code == 422

    future_date = harness.usage_payload()
    future_date["buckets"][0]["date"] = (
        datetime.now(timezone.utc).date() + timedelta(days=3)
    ).isoformat()
    assert harness.signed_post(device, future_date).status_code == 422

    old_date = harness.usage_payload()
    old_date["buckets"][0]["date"] = (
        datetime.now(timezone.utc).date() - timedelta(days=366 * 6)
    ).isoformat()
    assert harness.signed_post(device, old_date).status_code == 422

    wrong_schema = harness.usage_payload()
    wrong_schema["schema_version"] = 2
    assert harness.signed_post(device, wrong_schema).status_code == 422

    too_many = harness.usage_payload()
    base = too_many["buckets"][0]
    too_many["buckets"] = [dict(base, model=f"model-{index}") for index in range(2001)]
    assert harness.signed_post(device, too_many).status_code == 422


@pytest.mark.parametrize(
    "bucket_changes",
    [
        {"deleted": True, "input_tokens": 1},
        {
            "deleted": True,
            "completeness": "fallback_estimate",
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
        },
        {
            "deleted": "true",
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
        },
    ],
)
def test_tombstone_schema_requires_strict_bool_exact_and_zero_counters(
    harness, bucket_changes
) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    payload["buckets"][0].update(bucket_changes)
    assert harness.signed_post(device, payload).status_code == 422


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("tool", "Codex\u0085C1-control"),
        ("model", "gpt\u200b-5"),
        ("source", "lo\u202ecal"),
        ("tool", "Codex\u2028line-separator"),
        ("model", "gpt\ud800surrogate"),
    ],
)
def test_usage_labels_reject_unicode_control_and_format_characters(
    harness, field, value
) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    payload["buckets"][0][field] = value
    response = harness.signed_post(device, payload)
    assert response.status_code == 422
    assert value not in response.text


def test_health_and_readiness_have_different_semantics(tmp_path) -> None:
    engine = build_engine(f"sqlite:///{tmp_path / 'empty.db'}")
    app = create_app(
        settings=Settings(
            jwt_secret="readiness-test-secret-with-at-least-32-bytes",
            pbkdf2_iterations=1_000,
        ),
        engine=engine,
    )
    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 200
        ready = client.get("/readyz")
        assert ready.status_code == 503
        assert "organizations" not in ready.text.lower()
        Base.metadata.create_all(engine)
        assert client.get("/readyz").status_code == 200

        # Simulate revision 317c7501d905, immediately before the current head.
        # Readiness must fail before traffic reaches queries that require the
        # tombstone column, then recover once the head column exists again.
        with engine.begin() as connection:
            connection.execute(text("ALTER TABLE daily_usage DROP COLUMN is_deleted"))
        assert client.get("/readyz").status_code == 503
        with engine.begin() as connection:
            connection.execute(
                text(
                    "ALTER TABLE daily_usage ADD COLUMN is_deleted BOOLEAN "
                    "DEFAULT 0 NOT NULL"
                )
            )
        assert client.get("/readyz").status_code == 200


def test_sqlite_foreign_keys_are_enabled_and_block_cross_tenant_rows(harness) -> None:
    with harness.session_factory() as session:
        assert session.execute(text("PRAGMA foreign_keys")).scalar_one() == 1

    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    with harness.session_factory() as session:
        cross_tenant = DailyUsage(
            org_id=harness.users["b_admin"].org_id,
            user_id=harness.users["b_member"].id,
            device_id=device.id,
            usage_date=datetime.now(timezone.utc).date(),
            timezone="Asia/Shanghai",
            tool="Codex",
            model="gpt-5",
            source="local",
            completeness="exact",
            input_tokens=1,
            output_tokens=1,
            cache_read_tokens=0,
            cache_write_tokens=0,
            report_schema_version=1,
            collector_version="0.2.0",
            reported_generated_at=datetime.now(timezone.utc),
        )
        session.add(cross_tenant)
        with pytest.raises(IntegrityError):
            session.commit()


def test_every_environment_rejects_default_or_short_jwt_secret() -> None:
    for environment in ("development", "staging", "prod", "production"):
        with pytest.raises(RuntimeError, match="JWT_SECRET") as default_error:
            create_app(settings=Settings(environment=environment))
        with pytest.raises(RuntimeError, match="JWT_SECRET") as short_error:
            create_app(
                settings=Settings(environment=environment, jwt_secret="too-short")
            )
        assert "production" not in str(default_error.value).lower()
        assert "production" not in str(short_error.value).lower()

    with pytest.raises(RuntimeError, match="JWT_SECRET"):
        create_app(settings=Settings(environment=" \tPrOdUcTiOn\n"))


def test_runtime_settings_reject_unsafe_nonce_and_rate_limits() -> None:
    safe_secret = "validation-test-secret-with-at-least-32-bytes"
    with pytest.raises(RuntimeError, match="JWT_SECRET"):
        create_app(settings=Settings(environment="production"))
    with pytest.raises(RuntimeError, match="NONCE_RETENTION"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                hmac_max_clock_skew_seconds=300,
                nonce_retention_seconds=599,
            )
        )
    with pytest.raises(RuntimeError, match="usage rate-limit"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                usage_rate_limit_device_attempts=0,
            )
        )
    with pytest.raises(RuntimeError, match="usage row-quota"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                usage_max_rows_per_org=0,
            )
        )
    with pytest.raises(RuntimeError, match="USAGE_MAX_ROWS_PER_DEVICE"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                usage_max_rows_per_device=11,
                usage_max_rows_per_org=10,
            )
        )
    with pytest.raises(RuntimeError, match="usage rate-limit window"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                usage_rate_limit_window_seconds=601,
                nonce_retention_seconds=600,
            )
        )
    with pytest.raises(RuntimeError, match="TRUSTED_PROXY_CIDRS"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                trusted_proxy_cidrs="not-a-network",
                trusted_proxy_hops=1,
            )
        )
    with pytest.raises(RuntimeError, match="TRUSTED_PROXY_HOPS"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                trusted_proxy_cidrs="10.0.0.0/8",
                trusted_proxy_hops=0,
            )
        )
    with pytest.raises(RuntimeError, match="TRUSTED_PROXY_HOPS"):
        create_app(
            settings=Settings(jwt_secret=safe_secret, trusted_proxy_hops=1)
        )
    with pytest.raises(RuntimeError, match="public cache"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                public_cache_ttl_seconds=0,
            )
        )
    with pytest.raises(RuntimeError, match="public cache"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                public_cache_ttl_seconds=301,
            )
        )
    with pytest.raises(RuntimeError, match="enrollment rate-limit"):
        create_app(
            settings=Settings(
                jwt_secret=safe_secret,
                enrollment_rate_limit_attempts=0,
            )
        )


def test_organization_settings_are_admin_only_and_validate_timezone(harness) -> None:
    forbidden = harness.client.patch(
        "/api/v1/organization/settings",
        headers=harness.auth("a_member"),
        json={"retention_days": 90},
    )
    assert forbidden.status_code == 403
    invalid = harness.client.patch(
        "/api/v1/organization/settings",
        headers=harness.auth("a_admin"),
        json={"default_timezone": "Mars/Olympus"},
    )
    assert invalid.status_code == 422
    updated = harness.client.patch(
        "/api/v1/organization/settings",
        headers=harness.auth("a_admin"),
        json={
            "name": "  Alpha Renamed  ",
            "default_timezone": "UTC",
            "retention_days": 180,
        },
    )
    assert updated.status_code == 200
    assert updated.json()["name"] == "Alpha Renamed"
    assert updated.json()["default_timezone"] == "UTC"
    assert updated.json()["retention_days"] == 180
    assert updated.json()["retention_enforcement"] == "external_scheduler_required"

    empty_name = harness.client.patch(
        "/api/v1/organization/settings",
        headers=harness.auth("a_admin"),
        json={"name": "   "},
    )
    assert empty_name.status_code == 422
    unknown = harness.client.patch(
        "/api/v1/organization/settings",
        headers=harness.auth("a_admin"),
        json={"name": "Alpha", "unknown": "not accepted"},
    )
    assert unknown.status_code == 422


def test_login_has_process_local_rate_limit_and_retry_after(harness) -> None:
    harness.app.state.login_rate_limiter = LoginRateLimiter(
        attempts=2, ip_attempts=3, window_seconds=60
    )
    payload = {
        "org_slug": "alpha",
        "email": harness.users["a_member"].email,
        "password": "definitely-wrong",
    }
    assert harness.client.post("/api/v1/auth/token", json=payload).status_code == 401
    assert harness.client.post("/api/v1/auth/token", json=payload).status_code == 401
    limited = harness.client.post("/api/v1/auth/token", json=payload)
    assert limited.status_code == 429
    assert int(limited.headers["Retry-After"]) >= 1

    # Without an explicit proxy boundary, direct TCP peers still use their
    # socket address rather than trusting caller-supplied forwarding headers.
    harness.app.state.login_rate_limiter = LoginRateLimiter(
        attempts=10, ip_attempts=1, window_seconds=60, max_keys=8
    )
    with TestClient(
        harness.app,
        client=("198.51.100.25", 50_000),
    ) as direct_client:
        first_rotated = dict(payload, email="random-1@example.com")
        assert direct_client.post(
            "/api/v1/auth/token",
            headers={"X-Forwarded-For": "203.0.113.99"},
            json=first_rotated,
        ).status_code == 401
        second_rotated = dict(payload, email="random-2@example.com")
        assert direct_client.post(
            "/api/v1/auth/token",
            headers={"X-Forwarded-For": "203.0.113.100"},
            json=second_rotated,
        ).status_code == 429
    assert "ip:unresolved" not in harness.app.state.login_rate_limiter._events

    # Once the operator pins the proxy range and hop count, X-Forwarded-For is
    # accepted only across that boundary and rotating accounts shares an IP
    # bucket as intended.
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    harness.app.state.login_rate_limiter = LoginRateLimiter(
        attempts=10, ip_attempts=2, window_seconds=60, max_keys=8
    )
    with TestClient(harness.app, client=("10.20.30.40", 50_000)) as proxy_client:
        for email in ("proxy-1@example.com", "proxy-2@example.com"):
            rotated = dict(payload, email=email)
            assert proxy_client.post(
                "/api/v1/auth/token",
                headers={"X-Forwarded-For": "198.51.100.25"},
                json=rotated,
            ).status_code == 401
        rotated = dict(payload, email="proxy-3@example.com")
        assert proxy_client.post(
            "/api/v1/auth/token",
            headers={"X-Forwarded-For": "198.51.100.25"},
            json=rotated,
        ).status_code == 429


@pytest.mark.parametrize(
    "forwarded_for",
    [
        "bogus, 198.51.100.25",
        "unknown, 198.51.100.25",
        "198.51.100.25:443",
        ", ".join(["198.51.100.25"] * 33),
    ],
)
def test_configured_proxy_malformed_xff_is_rejected_before_login(
    harness,
    forwarded_for: str,
) -> None:
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = LoginRateLimiter(
        attempts=100, ip_attempts=2, window_seconds=60, max_keys=16
    )
    harness.app.state.login_rate_limiter = limiter
    base_payload = {
        "org_slug": "alpha",
        "password": "definitely-wrong",
    }
    with TestClient(
        harness.app,
        client=("10.20.30.40", 50_000),
    ) as proxy_client:
        for index in range(3):
            response = proxy_client.post(
                "/api/v1/auth/token",
                headers={"X-Forwarded-For": forwarded_for},
                json={
                    **base_payload,
                    "email": f"malformed-{index}@example.com",
                },
            )
            assert response.status_code == 400
            assert response.json() == {"detail": "invalid client network identity"}
            assert response.headers["cache-control"] == "no-store"
    assert limiter._events == {}


def test_uds_peer_without_verifiable_network_identity_is_rejected(harness) -> None:
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = LoginRateLimiter(
        attempts=100, ip_attempts=2, window_seconds=60, max_keys=16
    )
    harness.app.state.login_rate_limiter = limiter
    with TestClient(harness.app, client=None) as uds_client:
        response = uds_client.post(
            "/api/v1/auth/token",
            headers={"X-Forwarded-For": "198.51.100.25"},
            json={
                "org_slug": "alpha",
                "email": "uds@example.com",
                "password": "definitely-wrong",
            },
        )
    assert response.status_code == 400
    assert response.json() == {"detail": "invalid client network identity"}
    assert limiter._events == {}


def test_login_account_limit_survives_client_ip_rotation(harness) -> None:
    harness.app.state.login_rate_limiter = LoginRateLimiter(
        attempts=2,
        ip_attempts=100,
        window_seconds=60,
        max_keys=16,
    )
    payload = {
        "org_slug": "alpha",
        "email": harness.users["a_member"].email.upper(),
        "password": "definitely-wrong",
    }
    statuses = []
    for index, host in enumerate(
        ("198.51.100.10", "203.0.113.20", "192.0.2.30"), start=1
    ):
        with TestClient(harness.app, client=(host, 50_000 + index)) as client:
            statuses.append(
                client.post("/api/v1/auth/token", json=payload).status_code
            )
    assert statuses == [401, 401, 429]


def test_usage_rate_limit_is_shared_by_device_and_organization(harness) -> None:
    first_device = harness.enroll(admin_name="a_admin", user_name="a_member")
    second_device = harness.enroll(admin_name="a_admin", user_name="a_other")
    harness.app.state.settings = replace(
        harness.app.state.settings,
        usage_rate_limit_device_attempts=2,
        usage_rate_limit_org_attempts=100,
        usage_rate_limit_window_seconds=60,
    )

    payload = harness.usage_payload()
    assert harness.signed_post(first_device, payload).status_code == 200
    assert harness.signed_post(first_device, payload).status_code == 200
    blocked_nonce = "blocked-device-rate-limit-nonce"
    limited = harness.signed_post(first_device, payload, nonce=blocked_nonce)
    assert limited.status_code == 429
    assert limited.json() == {"detail": "too many usage upload attempts"}
    assert int(limited.headers["Retry-After"]) >= 1
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(DeviceNonce)
            .where(DeviceNonce.device_id == first_device.id)
        ) == 2
        assert session.scalar(
            select(func.count())
            .select_from(DeviceNonce)
            .where(DeviceNonce.nonce == blocked_nonce)
        ) == 0

    harness.app.state.settings = replace(
        harness.app.state.settings,
        usage_rate_limit_device_attempts=100,
        usage_rate_limit_org_attempts=2,
    )
    # Existing events are shared across every process and device in the same
    # organization, so a second device cannot bypass the organization bucket.
    organization_limited = harness.signed_post(second_device, payload)
    assert organization_limited.status_code == 429
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(DeviceNonce)
            .join(Device, Device.id == DeviceNonce.device_id)
            .where(Device.org_id == harness.users["a_admin"].org_id)
        ) == 2


def test_login_rate_limit_key_storage_is_bounded() -> None:
    limiter = LoginRateLimiter(
        attempts=100, ip_attempts=100, window_seconds=60, max_keys=4
    )
    for index in range(20):
        limiter.consume(f"account:{index}", f"ip:{index}")
    assert len(limiter._events) <= 4


def test_chunked_request_body_is_bounded_before_endpoint_parsing(harness) -> None:
    def oversized_chunks():
        yield b"x" * (1024 * 1024)
        yield b"y" * (1024 * 1024)
        yield b"z"

    response = harness.client.post(
        "/api/v1/usage/daily",
        content=oversized_chunks(),
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 413
    assert response.headers["x-content-type-options"] == "nosniff"
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]


def test_retention_cli_is_dry_run_by_default_and_org_scoped(harness) -> None:
    assert harness.client.patch(
        "/api/v1/organization",
        headers=harness.auth("a_admin"),
        json={"retention_days": 60},
    ).status_code == 200
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    payload["buckets"][0]["date"] = (
        datetime.now(timezone.utc).date() - timedelta(days=40)
    ).isoformat()
    assert harness.signed_post(device, payload).status_code == 200
    # Tightening the policy makes the previously accepted row purge-eligible.
    assert harness.client.patch(
        "/api/v1/organization",
        headers=harness.auth("a_admin"),
        json={"retention_days": 30},
    ).status_code == 200

    preview = purge_retention(harness.app.state.settings, apply=False)
    assert preview["mode"] == "dry-run"
    assert preview["organizations"]["alpha"]["matched_rows"] == 1
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 1

    applied = purge_retention(harness.app.state.settings, apply=True)
    assert applied["organizations"]["alpha"]["deleted_rows"] == 1
    assert applied["organizations"]["bravo"]["deleted_rows"] == 0
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 0
        organization = session.scalar(
            select(Organization).where(Organization.slug == "alpha")
        )
        assert organization is not None and organization.ledger_version == 2

    # A later force sync of a locally retained bucket cannot evade the policy.
    replay = harness.signed_post(device, payload)
    assert replay.status_code == 200
    assert replay.json() == {
        "created": 0,
        "updated": 0,
        "unchanged": 1,
        "ledger_version": 2,
    }
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 0


def test_empty_dashboard_and_maximum_tokens_with_128_character_model(harness) -> None:
    empty = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    )
    assert empty.status_code == 200
    assert empty.json()["rows"] == []
    assert empty.json()["totals"] == {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
        "total_tokens": 0,
        "priced_costs_microunits": {},
        "unpriced_rows": 0,
    }

    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    longest_model = "m" * 128
    payload = harness.usage_payload()
    payload["buckets"][0].update(
        {
            "model": longest_model,
            "input_tokens": TOKEN_MAX,
            "output_tokens": TOKEN_MAX,
            "cache_read_tokens": TOKEN_MAX,
            "cache_write_tokens": TOKEN_MAX,
        }
    )
    accepted = harness.signed_post(device, payload)
    assert accepted.status_code == 200
    dashboard = harness.client.get(
        "/api/v1/dashboard",
        headers=harness.auth("a_admin"),
        params={"model": longest_model},
    )
    assert dashboard.status_code == 200
    assert dashboard.json()["rows"][0]["model"] == longest_model
    assert dashboard.json()["rows"][0]["input_tokens"] == TOKEN_MAX
    assert dashboard.json()["totals"]["total_tokens"] == TOKEN_MAX * 4

    too_long = harness.usage_payload()
    too_long["buckets"][0]["model"] = "m" * 129
    assert harness.signed_post(device, too_long).status_code == 422
