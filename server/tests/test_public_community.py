from __future__ import annotations

import json
from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import event, func, select, text
from sqlalchemy.exc import IntegrityError

from app.models import DailyUsage, Device, EnrollmentToken, PriceVersion, User, utcnow
from app.middleware import parse_trusted_proxy_cidrs
from app.rate_limit import PublicReadRateLimiter
from app.schemas import PublicUsageTotals, TOKEN_MAX, UsageTotals
from app.security import opaque_token_hash


SERVER_ROOT = Path(__file__).resolve().parents[1]


def _enable_alpha_public_board(harness) -> None:
    harness.app.state.settings = replace(
        harness.app.state.settings,
        public_org_slug="alpha",
    )


def _create_participant(
    harness,
    *,
    admin_name: str = "a_admin",
    display_name: str = "公开昵称",
    public_profile_enabled: bool = True,
    expires_in_minutes: int | None = None,
):
    payload = {
        "display_name": display_name,
        "public_profile_enabled": public_profile_enabled,
    }
    if expires_in_minutes is not None:
        payload["expires_in_minutes"] = expires_in_minutes
    response = harness.client.post(
        "/api/v1/admin/participants",
        headers=harness.auth(admin_name),
        json=payload,
    )
    assert response.status_code == 201
    assert response.headers["cache-control"] == "no-store"
    return response.json()


def _enroll_participant(harness, created):
    response = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": created["enrollment_token"],
            "device_public_id": str(uuid4()),
            "platform": "test",
            "app_version": "1.0.0",
            "collector_version": "1.0.0",
        },
    )
    assert response.status_code == 201
    assert response.headers["cache-control"] == "no-store"
    body = response.json()
    return SimpleNamespace(
        id=body["device_id"],
        public_id=body["device_public_id"],
        secret=body["device_secret"],
        user_id=created["participant"]["id"],
    )


def _price_payload(
    *,
    model: str,
    tool: str = "Codex",
    currency: str = "USD",
    public_estimate: bool,
) -> dict[str, object]:
    return {
        "tool": tool,
        "model": model,
        "currency": currency,
        "public_estimate": public_estimate,
        "input_per_million": "1",
        "output_per_million": "2",
        "cache_read_per_million": "3",
        "cache_write_per_million": "4",
        "effective_from": (date.today() - timedelta(days=365)).isoformat(),
    }


def _create_price(harness, **kwargs):
    response = harness.client.post(
        "/api/v1/prices",
        headers=harness.auth(kwargs.pop("admin_name", "a_admin")),
        json=_price_payload(**kwargs),
    )
    assert response.status_code == 201
    return response.json()


def _bucket(
    harness,
    *,
    usage_date: date | None = None,
    tool: str = "Codex",
    model: str = "public-model",
    input_tokens: int = 10,
    output_tokens: int = 20,
    cache_read_tokens: int = 100,
    cache_write_tokens: int = 200,
    completeness: str = "exact",
    deleted: bool = False,
) -> dict[str, object]:
    value = dict(harness.usage_payload()["buckets"][0])
    value.update(
        {
            "date": (
                usage_date or datetime.now(ZoneInfo("Asia/Shanghai")).date()
            ).isoformat(),
            "tool": tool,
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cache_read_tokens": cache_read_tokens,
            "cache_write_tokens": cache_write_tokens,
            "completeness": completeness,
            "deleted": deleted,
        }
    )
    return value


def _all_keys(value) -> set[str]:
    if isinstance(value, dict):
        result = set(value)
        for item in value.values():
            result.update(_all_keys(item))
        return result
    if isinstance(value, list):
        result: set[str] = set()
        for item in value:
            result.update(_all_keys(item))
        return result
    return set()


def test_public_totals_schema_excludes_private_bucket_cardinality() -> None:
    assert "unpriced_rows" not in PublicUsageTotals.model_fields
    assert "unpriced_rows" in UsageTotals.model_fields


def test_admin_creates_non_login_participant_and_one_time_enrollment(harness) -> None:
    before = utcnow()
    created = _create_participant(
        harness,
        display_name="  参赛者甲  ",
        public_profile_enabled=False,
    )
    after = utcnow()
    participant = created["participant"]
    expires_at = datetime.fromisoformat(created["expires_at"].replace("Z", "+00:00"))

    assert participant["email"] is None
    assert participant["can_login"] is False
    assert participant["display_name"] == "参赛者甲"
    assert participant["role"] == "member"
    assert participant["public_profile_enabled"] is False
    UUID(participant["public_id"])
    assert before + timedelta(minutes=59, seconds=55) < expires_at
    assert expires_at < after + timedelta(minutes=60, seconds=5)
    assert "join" not in created
    assert "url" not in created

    raw_token = created["enrollment_token"]
    with harness.session_factory() as session:
        user = session.scalar(select(User).where(User.id == participant["id"]))
        token = session.scalar(
            select(EnrollmentToken).where(EnrollmentToken.user_id == participant["id"])
        )
        assert user is not None and user.email is None and user.password_hash is None
        assert token is not None
        assert token.token_hash == opaque_token_hash(raw_token)
        assert token.token_hash != raw_token

    device = _enroll_participant(harness, created)
    reused = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": raw_token,
            "device_public_id": str(uuid4()),
            "platform": "test",
            "app_version": "1.0.0",
            "collector_version": "1.0.0",
        },
    )
    assert reused.status_code == 400
    assert reused.headers["cache-control"] == "no-store"
    assert device.user_id == participant["id"]


def test_fifty_member_beta_cohort_enrolls_uploads_and_appears_once(harness) -> None:
    _enable_alpha_public_board(harness)
    public_ids: set[str] = set()
    device_ids: set[str] = set()

    for index in range(50):
        created = _create_participant(
            harness,
            display_name=f"Beta 成员 {index + 1:02d}",
            public_profile_enabled=True,
        )
        device = _enroll_participant(harness, created)
        uploaded = harness.signed_post(
            device,
            harness.usage_payload(
                buckets=[
                    _bucket(
                        harness,
                        model="beta-capacity-model",
                        input_tokens=index + 1,
                        output_tokens=1,
                        cache_read_tokens=0,
                        cache_write_tokens=0,
                    )
                ]
            ),
        )
        assert uploaded.status_code == 200, uploaded.text
        public_ids.add(created["participant"]["public_id"])
        device_ids.add(device.id)

    board = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"period": "today", "metric": "tokens", "limit": 100},
    )
    assert board.status_code == 200, board.text
    payload = board.json()
    assert payload["total_entries"] == 50
    assert len(payload["entries"]) == 50
    assert {entry["public_id"] for entry in payload["entries"]} == public_ids
    assert all(identifier not in board.text for identifier in device_ids)


@pytest.mark.parametrize(
    ("expires_in_minutes", "expected_status"),
    [(0, 422), (1, 201), (60, 201), (1_440, 201), (1_441, 422)],
)
def test_participant_enrollment_expiry_boundaries(
    harness, expires_in_minutes: int, expected_status: int
) -> None:
    response = harness.client.post(
        "/api/v1/admin/participants",
        headers=harness.auth("a_admin"),
        json={
            "display_name": f"时限-{expires_in_minutes}",
            "public_profile_enabled": False,
            "expires_in_minutes": expires_in_minutes,
        },
    )
    assert response.status_code == expected_status
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize(
    ("expires_in_minutes", "expected_status"),
    [(1_440, 201), (1_441, 422), (10_080, 422)],
)
def test_additional_device_enrollment_never_exceeds_twenty_four_hours(
    harness, expires_in_minutes: int, expected_status: int
) -> None:
    response = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={
            "user_id": harness.users["a_member"].id,
            "expires_in_minutes": expires_in_minutes,
        },
    )
    assert response.status_code == expected_status
    assert response.headers["cache-control"] == "no-store"


def test_disabled_participant_and_admin_role_cannot_enroll(harness) -> None:
    created = _create_participant(harness, public_profile_enabled=True)
    participant_id = created["participant"]["id"]
    disabled = harness.client.patch(
        f"/api/v1/users/{participant_id}",
        headers=harness.auth("a_admin"),
        json={"is_active": False},
    )
    assert disabled.status_code == 200
    assert disabled.json()["public_profile_enabled"] is False
    denied = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": created["enrollment_token"],
            "device_public_id": str(uuid4()),
            "platform": "test",
            "app_version": "1.0.0",
            "collector_version": "1.0.0",
        },
    )
    assert denied.status_code == 403

    cannot_issue = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={"user_id": harness.users["a_admin"].id, "expires_in_minutes": 60},
    )
    assert cannot_issue.status_code == 404

    # Defense in depth: even a legacy/manually inserted token targeting an
    # administrator cannot be exchanged for a device credential.
    synthetic_token = "not-a-real-secret-token-for-role-boundary"
    with harness.session_factory() as session:
        session.add(
            EnrollmentToken(
                org_id=harness.users["a_admin"].org_id,
                user_id=harness.users["a_admin"].id,
                created_by_user_id=harness.users["a_admin"].id,
                token_hash=opaque_token_hash(synthetic_token),
                expires_at=utcnow() + timedelta(minutes=5),
            )
        )
        session.commit()
    role_denied = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            "enrollment_token": synthetic_token,
            "device_public_id": str(uuid4()),
            "platform": "test",
            "app_version": "1.0.0",
            "collector_version": "1.0.0",
        },
    )
    assert role_denied.status_code == 403
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(Device)
            .where(Device.user_id == harness.users["a_admin"].id)
        ) == 0


def test_public_projection_exact_only_norm_cost_and_privacy_contract(harness) -> None:
    _enable_alpha_public_board(harness)
    public_price = _create_price(
        harness, model="public-model", public_estimate=True
    )
    private_price = _create_price(
        harness,
        tool="Claude",
        model="private-model",
        public_estimate=False,
    )
    created = _create_participant(harness, display_name="甲", public_profile_enabled=True)
    device = _enroll_participant(harness, created)
    buckets = [
        _bucket(harness, model="public-model"),
        _bucket(
            harness,
            tool="Claude",
            model="private-model",
            input_tokens=7,
            output_tokens=3,
            cache_read_tokens=0,
            cache_write_tokens=0,
        ),
        _bucket(
            harness,
            model="estimate-must-not-leak",
            input_tokens=999,
            output_tokens=999,
            cache_read_tokens=999,
            cache_write_tokens=999,
            completeness="fallback_estimate",
        ),
        _bucket(
            harness,
            model="deleted-must-not-leak",
            input_tokens=0,
            output_tokens=0,
            cache_read_tokens=0,
            cache_write_tokens=0,
            deleted=True,
        ),
    ]
    uploaded = harness.signed_post(device, harness.usage_payload(buckets=buckets))
    assert uploaded.status_code == 200

    leaderboard = harness.client.get("/api/v1/public/leaderboard")
    assert leaderboard.status_code == 200
    assert leaderboard.headers["cache-control"] == (
        "public, max-age=15, s-maxage=15"
    )
    payload = leaderboard.json()
    assert payload["metric_definition"] == (
        "input_tokens + output_tokens + cache_read_tokens + cache_write_tokens"
    )
    assert payload["mixed_timezones"] is False
    assert payload["timezone_warning"] is None
    assert payload["total_entries"] == 1
    assert payload["available_tools"] == ["Claude", "Codex"]
    assert payload["available_models"] == ["private-model", "public-model"]
    entry = payload["entries"][0]
    assert entry["nickname"] == "甲"
    assert entry["metric_value"] == "340"
    assert entry["primary_tool"] == "Codex"
    assert entry["primary_tool_tokens"] == "330"
    assert entry["tool_count"] == 2
    assert entry["primary_model"] == "public-model"
    assert entry["primary_model_tokens"] == "330"
    assert entry["model_count"] == 2
    assert entry["totals"] == {
        "input_tokens": "17",
        "output_tokens": "23",
        "cache_read_tokens": "100",
        "cache_write_tokens": "200",
        "norm_tokens": "40",
        "total_tokens": "340",
        "estimated_cost_microunits": None,
        "cost_currency": None,
        "unpriced": True,
        "mixed_currency": False,
    }

    norm = harness.client.get(
        "/api/v1/public/leaderboard", params={"metric": "norm"}
    ).json()
    assert norm["metric_definition"] == "input_tokens + output_tokens"
    assert norm["entries"][0]["metric_value"] == "40"

    priced_only = harness.client.get(
        f"/api/v1/public/members/{entry['public_id']}",
        params={"metric": "cost", "model": "public-model"},
    )
    assert priced_only.status_code == 200
    detail = priced_only.json()
    assert detail["rank"] == 1
    assert detail["metric_value"] == "1150"
    assert detail["metric_currency"] == "USD"
    assert detail["totals"]["estimated_cost_microunits"] == "1150"
    assert detail["totals"]["unpriced"] is False
    assert [item["name"] for item in detail["tool_distribution"]] == ["Codex"]
    assert [item["name"] for item in detail["model_distribution"]] == [
        "public-model"
    ]
    assert len(detail["daily_trend"]) == 1

    forbidden_keys = {
        "email",
        "org_id",
        "org_slug",
        "user_id",
        "device_id",
        "device_public_id",
        "devices",
        "ip",
        "source",
        "session",
        "message",
        "hour",
        "city",
        "unpriced_rows",
    }
    assert not (_all_keys(payload) | _all_keys(detail)) & forbidden_keys
    serialized = json.dumps({"leaderboard": payload, "detail": detail})
    assert harness.users["a_admin"].email not in serialized
    assert harness.users["a_member"].id not in serialized
    assert device.id not in serialized
    assert harness.users["a_admin"].org_id not in serialized

    # An explicit admin action can publish the already-frozen standard estimate;
    # no price rates themselves cross the public response boundary.
    made_public = harness.client.patch(
        f"/api/v1/prices/{private_price['id']}",
        headers=harness.auth("a_admin"),
        json={"public_estimate": True},
    )
    assert made_public.status_code == 200
    cost = harness.client.get(
        "/api/v1/public/leaderboard", params={"metric": "cost"}
    ).json()
    assert cost["entries"][0]["metric_value"] == "1163"
    assert cost["entries"][0]["totals"]["unpriced"] is False
    assert public_price["public_estimate"] is True


def test_authenticated_device_reads_only_its_public_rank_context(harness) -> None:
    _enable_alpha_public_board(harness)
    first = _create_participant(harness, display_name="领航员")
    first_device = _enroll_participant(harness, first)
    first_upload = harness.signed_post(
        first_device,
        harness.usage_payload(
            buckets=[
                _bucket(
                    harness,
                    model="community-rank",
                    input_tokens=600,
                    output_tokens=400,
                    cache_read_tokens=0,
                    cache_write_tokens=0,
                )
            ]
        ),
    )
    assert first_upload.status_code == 200

    second = _create_participant(harness, display_name="奥哥")
    second_device = _enroll_participant(harness, second)
    second_upload = harness.signed_post(
        second_device,
        harness.usage_payload(
            buckets=[
                _bucket(
                    harness,
                    model="community-rank",
                    input_tokens=200,
                    output_tokens=100,
                    cache_read_tokens=0,
                    cache_write_tokens=0,
                )
            ]
        ),
    )
    assert second_upload.status_code == 200

    response = harness.signed_get(
        second_device,
        "/api/v1/devices/me/community-rank",
    )
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "public_id": second["participant"]["public_id"],
        "nickname": "奥哥",
        "public_profile_enabled": True,
        "period": "today",
        "metric": "tokens",
        "rank": 2,
        "total_entries": 2,
        "metric_value": "300",
        "primary_tool": "Codex",
        "primary_model": "community-rank",
        "totals": {
            "input_tokens": "200",
            "output_tokens": "100",
            "cache_read_tokens": "0",
            "cache_write_tokens": "0",
            "norm_tokens": "300",
            "total_tokens": "300",
            "estimated_cost_microunits": None,
            "cost_currency": None,
            "unpriced": True,
            "mixed_currency": False,
        },
    }
    assert harness.client.get(
        "/api/v1/devices/me/community-rank"
    ).status_code == 401


def test_device_rank_context_does_not_rank_private_profile(harness) -> None:
    _enable_alpha_public_board(harness)
    private = _create_participant(
        harness,
        display_name="不公开昵称",
        public_profile_enabled=False,
    )
    device = _enroll_participant(harness, private)
    response = harness.signed_get(
        device,
        "/api/v1/devices/me/community-rank",
    )
    assert response.status_code == 200
    assert response.json() == {
        "public_id": private["participant"]["public_id"],
        "nickname": None,
        "public_profile_enabled": False,
        "period": "today",
        "metric": "tokens",
        "rank": None,
        "total_entries": 0,
        "metric_value": None,
        "primary_tool": None,
        "primary_model": None,
        "totals": None,
    }


def test_device_rank_context_includes_own_public_summary_beyond_top_ten(harness) -> None:
    _enable_alpha_public_board(harness)
    target = _create_participant(harness, display_name="榜外本人")
    target_device = _enroll_participant(harness, target)
    assert harness.signed_post(
        target_device,
        harness.usage_payload(
            buckets=[
                _bucket(
                    harness,
                    tool="Codex",
                    model="own-model",
                    input_tokens=20,
                    output_tokens=10,
                    cache_read_tokens=5,
                    cache_write_tokens=0,
                )
            ]
        ),
    ).status_code == 200

    for index in range(11):
        participant = _create_participant(harness, display_name=f"领先成员{index + 1}")
        device = _enroll_participant(harness, participant)
        assert harness.signed_post(
            device,
            harness.usage_payload(
                buckets=[
                    _bucket(
                        harness,
                        tool="Claude Code",
                        model="leader-model",
                        input_tokens=1_000 + index,
                        output_tokens=500,
                        cache_read_tokens=0,
                        cache_write_tokens=0,
                    )
                ]
            ),
        ).status_code == 200

    response = harness.signed_get(
        target_device,
        "/api/v1/devices/me/community-rank",
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["rank"] == 12
    assert payload["total_entries"] == 12
    assert payload["metric_value"] == "35"
    assert payload["primary_tool"] == "Codex"
    assert payload["primary_model"] == "own-model"
    assert payload["totals"]["total_tokens"] == "35"


def test_public_periods_filters_and_daily_trend(harness) -> None:
    _enable_alpha_public_board(harness)
    created = _create_participant(harness, public_profile_enabled=True)
    device = _enroll_participant(harness, created)
    local_today = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    offsets = (0, 1, 2, 6, 29, 89, 90)
    buckets = [
        _bucket(
            harness,
            usage_date=local_today - timedelta(days=offset),
            tool="Codex",
            model="period-model",
            input_tokens=1,
            output_tokens=0,
            cache_read_tokens=0,
            cache_write_tokens=0,
        )
        for offset in offsets
    ]
    # A second filtered dimension on today proves tool/model predicates apply
    # before every aggregate and trend calculation.
    buckets.append(
        _bucket(
            harness,
            usage_date=local_today,
            tool="Claude",
            model="other-model",
            input_tokens=50,
            output_tokens=0,
            cache_read_tokens=0,
            cache_write_tokens=0,
        )
    )
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    expected = {
        "today": 1,
        "yesterday": 1,
        "3d": 3,
        "7d": 4,
        "30d": 5,
        "90d": 6,
        "all": 7,
    }
    for period, total in expected.items():
        response = harness.client.get(
            "/api/v1/public/leaderboard",
            params={"period": period, "model": "period-model"},
        )
        assert response.status_code == 200
        assert response.json()["entries"][0]["metric_value"] == str(total)

    public_id = created["participant"]["public_id"]
    detail = harness.client.get(
        f"/api/v1/public/members/{public_id}",
        params={"period": "all", "tool": "Codex"},
    ).json()
    assert len(detail["daily_trend"]) == 7
    assert detail["totals"]["total_tokens"] == "7"
    today_other = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"tool": "Claude", "model": "other-model"},
    ).json()
    assert today_other["entries"][0]["metric_value"] == "50"


def test_public_daily_trend_is_limited_to_most_recent_100_days(harness) -> None:
    _enable_alpha_public_board(harness)
    created = _create_participant(harness, public_profile_enabled=True)
    device = _enroll_participant(harness, created)
    local_today = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    buckets = [
        _bucket(
            harness,
            usage_date=local_today - timedelta(days=offset),
            model="daily-limit-model",
            input_tokens=offset + 1,
            output_tokens=0,
            cache_read_tokens=0,
            cache_write_tokens=0,
        )
        for offset in range(101)
    ]
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    public_id = created["participant"]["public_id"]
    response = harness.client.get(
        f"/api/v1/public/members/{public_id}",
        params={"period": "all", "model": "daily-limit-model"},
    )
    assert response.status_code == 200
    trend = response.json()["daily_trend"]
    assert len(trend) == 100
    assert trend[0]["date"] == (local_today - timedelta(days=99)).isoformat()
    assert trend[-1]["date"] == local_today.isoformat()
    assert all(
        trend[index]["date"] < trend[index + 1]["date"]
        for index in range(len(trend) - 1)
    )


def test_public_mixed_timezones_expose_only_a_generic_warning(harness) -> None:
    _enable_alpha_public_board(harness)
    created = _create_participant(harness, public_profile_enabled=True)
    device = _enroll_participant(harness, created)
    local_today = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    buckets = [
        {
            **_bucket(
                harness,
                usage_date=local_today,
                model="mixed-timezone-model",
                input_tokens=10,
                output_tokens=0,
                cache_read_tokens=0,
                cache_write_tokens=0,
            ),
            "timezone": timezone_name,
        }
        for timezone_name in ("UTC", "America/New_York")
    ]
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    leaderboard = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"model": "mixed-timezone-model"},
    )
    assert leaderboard.status_code == 200
    payload = leaderboard.json()
    assert payload["timezone"] == "Asia/Shanghai"
    assert payload["mixed_timezones"] is True
    assert payload["timezone_warning"] == (
        "Daily usage uses device-local date buckets and has not been recalculated "
        "across time zones."
    )
    assert "America/New_York" not in leaderboard.text
    assert '"UTC"' not in leaderboard.text

    detail = harness.client.get(
        f"/api/v1/public/members/{created['participant']['public_id']}",
        params={"model": "mixed-timezone-model"},
    )
    assert detail.status_code == 200
    assert detail.json()["mixed_timezones"] is True
    assert detail.json()["timezone_warning"] == payload["timezone_warning"]


def test_visibility_disable_device_history_and_tenant_enumeration_boundaries(
    harness,
) -> None:
    _enable_alpha_public_board(harness)
    alpha = _create_participant(
        harness, display_name="Alpha Public", public_profile_enabled=True
    )
    alpha_device = _enroll_participant(harness, alpha)
    assert harness.signed_post(alpha_device, harness.usage_payload()).status_code == 200

    hidden = _create_participant(
        harness, display_name="Hidden", public_profile_enabled=False
    )
    hidden_device = _enroll_participant(harness, hidden)
    assert harness.signed_post(hidden_device, harness.usage_payload()).status_code == 200

    bravo = _create_participant(
        harness,
        admin_name="b_admin",
        display_name="Bravo Public",
        public_profile_enabled=True,
    )
    bravo_device = _enroll_participant(harness, bravo)
    assert harness.signed_post(bravo_device, harness.usage_payload()).status_code == 200

    first = harness.client.get("/api/v1/public/leaderboard").json()
    assert [entry["public_id"] for entry in first["entries"]] == [
        alpha["participant"]["public_id"]
    ]

    expected_404 = {"detail": "public profile not found"}
    for identifier in (
        hidden["participant"]["public_id"],
        bravo["participant"]["public_id"],
        str(uuid4()),
        "not-a-uuid",
        alpha["participant"]["public_id"].upper(),
    ):
        response = harness.client.get(f"/api/v1/public/members/{identifier}")
        assert response.status_code == 404
        assert response.json() == expected_404

    participant_id = alpha["participant"]["id"]
    hidden_update = harness.client.patch(
        f"/api/v1/users/{participant_id}",
        headers=harness.auth("a_admin"),
        json={"public_profile_enabled": False},
    )
    assert hidden_update.status_code == 200
    assert harness.client.get(
        f"/api/v1/public/members/{alpha['participant']['public_id']}"
    ).status_code == 404

    republished = harness.client.patch(
        f"/api/v1/users/{participant_id}",
        headers=harness.auth("a_admin"),
        json={"public_profile_enabled": True},
    )
    assert republished.status_code == 200
    disabled = harness.client.patch(
        f"/api/v1/users/{participant_id}",
        headers=harness.auth("a_admin"),
        json={"is_active": False},
    )
    assert disabled.status_code == 200
    assert disabled.json()["public_profile_enabled"] is False
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.user_id == participant_id)
        ) == 1

    # Re-enabling human/device access alone cannot silently republish history.
    assert harness.client.patch(
        f"/api/v1/users/{participant_id}",
        headers=harness.auth("a_admin"),
        json={"is_active": True},
    ).json()["public_profile_enabled"] is False
    assert harness.client.patch(
        f"/api/v1/users/{participant_id}",
        headers=harness.auth("a_admin"),
        json={"public_profile_enabled": True},
    ).status_code == 200

    # Device disable prevents future uploads but does not erase an explicitly
    # visible member's existing exact history.
    assert harness.client.post(
        f"/api/v1/devices/{alpha_device.id}/disable",
        headers=harness.auth("a_admin"),
    ).status_code == 200
    visible_history = harness.client.get("/api/v1/public/leaderboard").json()
    assert [entry["public_id"] for entry in visible_history["entries"]] == [
        alpha["participant"]["public_id"]
    ]


def test_public_bigint_decimal_strings_and_stable_nickname_tie_sort(harness) -> None:
    _enable_alpha_public_board(harness)
    participants = [
        _create_participant(
            harness, display_name=f"同分-{index}", public_profile_enabled=True
        )
        for index in range(2)
    ]
    for index, participant in enumerate(participants):
        device = _enroll_participant(harness, participant)
        buckets = [
            _bucket(
                harness,
                model=f"extreme-{index}-{suffix}",
                input_tokens=TOKEN_MAX,
                output_tokens=TOKEN_MAX,
                cache_read_tokens=TOKEN_MAX,
                cache_write_tokens=TOKEN_MAX,
            )
            for suffix in ("a", "b")
        ]
        assert harness.signed_post(
            device, harness.usage_payload(buckets=buckets)
        ).status_code == 200

    expected_ids = [
        participant["participant"]["public_id"] for participant in participants
    ]
    first = harness.client.get(
        "/api/v1/public/leaderboard", params={"metric": "norm"}
    ).json()
    second = harness.client.get(
        "/api/v1/public/leaderboard", params={"metric": "norm"}
    ).json()
    assert first == second
    assert [entry["public_id"] for entry in first["entries"]] == expected_ids
    assert [entry["rank"] for entry in first["entries"]] == [1, 2]
    for entry in first["entries"]:
        assert entry["metric_value"] == str(TOKEN_MAX * 4)
        assert entry["totals"]["norm_tokens"] == str(TOKEN_MAX * 4)
        assert entry["totals"]["total_tokens"] == str(TOKEN_MAX * 8)
        assert isinstance(entry["totals"]["total_tokens"], str)

    # Every member remains visible for a cost view, but unknown costs are never
    # ranked as zero.
    cost = harness.client.get(
        "/api/v1/public/leaderboard", params={"metric": "cost"}
    ).json()
    assert [entry["rank"] for entry in cost["entries"]] == [None, None]
    assert [entry["metric_value"] for entry in cost["entries"]] == [None, None]
    assert [entry["totals"]["unpriced"] for entry in cost["entries"]] == [True, True]
    assert "unpriced_rows" not in _all_keys(cost)
    unpriced_detail = harness.client.get(
        f"/api/v1/public/members/{cost['entries'][0]['public_id']}",
        params={"metric": "cost"},
    ).json()
    assert unpriced_detail["rank"] is None


def test_public_sqlite_aggregate_exceeds_signed_int64(harness) -> None:
    _enable_alpha_public_board(harness)
    participant = _create_participant(
        harness,
        display_name="超大整数",
        public_profile_enabled=True,
    )
    device = _enroll_participant(harness, participant)
    bucket_count = 257
    buckets = [
        _bucket(
            harness,
            model=f"sqlite-int64-{index:03d}",
            input_tokens=TOKEN_MAX,
            output_tokens=TOKEN_MAX,
            cache_read_tokens=TOKEN_MAX,
            cache_write_tokens=TOKEN_MAX,
        )
        for index in range(bucket_count)
    ]
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    response = harness.client.get("/api/v1/public/leaderboard")
    assert response.status_code == 200
    expected_total = TOKEN_MAX * 4 * bucket_count
    assert expected_total > 2**63
    entry = response.json()["entries"][0]
    assert entry["metric_value"] == str(expected_total)
    assert entry["totals"]["total_tokens"] == str(expected_total)


def test_public_input_limits_rate_limit_and_no_anonymous_upload(harness) -> None:
    _enable_alpha_public_board(harness)
    for params in (
        {"period": "2d"},
        {"metric": "unknown"},
        {"tool": " "},
        {"model": "m" * 129},
        {"limit": 0},
        {"limit": 101},
    ):
        assert harness.client.get(
            "/api/v1/public/leaderboard", params=params
        ).status_code == 422

    unsigned = harness.client.post(
        "/api/v1/usage/daily", json=harness.usage_payload()
    )
    assert unsigned.status_code == 401

    harness.app.state.public_rate_limiter = PublicReadRateLimiter(
        attempts=2,
        window_seconds=60,
        max_keys=8,
    )
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    with TestClient(harness.app, client=("10.20.30.40", 50_000)) as proxy_client:
        forwarded_headers = {"X-Forwarded-For": "198.51.100.25"}
        assert proxy_client.get(
            "/api/v1/public/leaderboard", headers=forwarded_headers
        ).status_code == 200
        assert proxy_client.get(
            "/api/v1/public/leaderboard", headers=forwarded_headers
        ).status_code == 200
        limited = proxy_client.get(
            "/api/v1/public/leaderboard", headers=forwarded_headers
        )
    assert limited.status_code == 429
    assert limited.json() == {"detail": "too many public leaderboard requests"}
    assert int(limited.headers["retry-after"]) >= 1
    assert limited.headers["cache-control"] == "no-store"

    limiter = PublicReadRateLimiter(attempts=100, window_seconds=60, max_keys=4)
    for index in range(20):
        limiter.consume(f"ip:{index}")
    assert len(limiter._events) <= 4


@pytest.mark.parametrize(
    "forwarded_for",
    [
        "bogus, 198.51.100.25",
        "unknown, 198.51.100.25",
        "198.51.100.25:443",
        ", ".join(["198.51.100.25"] * 33),
    ],
)
def test_configured_proxy_malformed_xff_is_rejected_before_public_projection(
    harness,
    forwarded_for: str,
) -> None:
    _enable_alpha_public_board(harness)
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = PublicReadRateLimiter(
        attempts=2,
        window_seconds=60,
        max_keys=8,
    )
    harness.app.state.public_rate_limiter = limiter
    headers = {"X-Forwarded-For": forwarded_for}
    with TestClient(
        harness.app,
        client=("10.20.30.40", 50_000),
    ) as proxy_client:
        for _ in range(3):
            rejected = proxy_client.get(
                "/api/v1/public/leaderboard", headers=headers
            )
            assert rejected.status_code == 400
            assert rejected.json() == {"detail": "invalid client network identity"}
            assert rejected.headers["cache-control"] == "no-store"
    assert limiter._events == {}


def test_public_projection_rejects_uds_without_verifiable_network_identity(
    harness,
) -> None:
    _enable_alpha_public_board(harness)
    harness.app.state.trusted_proxy_networks = parse_trusted_proxy_cidrs(
        "10.0.0.0/8"
    )
    harness.app.state.trusted_proxy_hops = 1
    limiter = PublicReadRateLimiter(
        attempts=2,
        window_seconds=60,
        max_keys=8,
    )
    harness.app.state.public_rate_limiter = limiter
    with TestClient(harness.app, client=None) as uds_client:
        response = uds_client.get(
            "/api/v1/public/leaderboard",
            headers={"X-Forwarded-For": "198.51.100.25"},
        )
    assert response.status_code == 400
    assert response.json() == {"detail": "invalid client network identity"}
    assert response.headers["cache-control"] == "no-store"
    assert limiter._events == {}


def test_public_scan_limit_applies_before_caller_controlled_filters(harness) -> None:
    _enable_alpha_public_board(harness)
    participant = _create_participant(harness, public_profile_enabled=True)
    device = _enroll_participant(harness, participant)
    assert harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[
                _bucket(harness, model="scan-a"),
                _bucket(harness, model="scan-b"),
            ]
        ),
    ).status_code == 200
    harness.app.state.settings = replace(
        harness.app.state.settings,
        public_max_scan_rows=1,
    )
    broad = harness.client.get("/api/v1/public/leaderboard")
    assert broad.status_code == 503
    assert broad.headers["cache-control"] == "no-store"
    assert broad.json() == {
        "detail": {
            "code": "public_projection_scan_limit_exceeded",
            "message": (
                "public projection is temporarily unavailable for this period; "
                "use a shorter period"
            ),
        }
    }
    narrowed = harness.client.get(
        "/api/v1/public/leaderboard", params={"model": "scan-a"}
    )
    assert narrowed.status_code == 503
    assert narrowed.json() == broad.json()
    missing_label = harness.client.get(
        "/api/v1/public/leaderboard", params={"model": "does-not-exist"}
    )
    assert missing_label.status_code == 503
    assert missing_label.json() == broad.json()
    detail_over_limit = harness.client.get(
        f"/api/v1/public/members/{participant['participant']['public_id']}",
        params={"model": "scan-a"},
    )
    assert detail_over_limit.status_code == 503
    assert detail_over_limit.json() == broad.json()

    # Once the complete unfiltered candidate scope fits, caller filters execute
    # normally and cannot turn an unbounded scan into a false zero-row result.
    harness.app.state.settings = replace(
        harness.app.state.settings,
        public_max_scan_rows=2,
    )
    bounded = harness.client.get(
        "/api/v1/public/leaderboard", params={"model": "scan-a"}
    )
    assert bounded.status_code == 200
    assert bounded.json()["entries"][0]["totals"]["total_tokens"] == "330"


def test_public_projection_groups_in_sql_and_caches_by_ledger_version(
    harness,
) -> None:
    _enable_alpha_public_board(harness)
    participant = _create_participant(
        harness,
        display_name="聚合前昵称",
        public_profile_enabled=True,
    )
    device = _enroll_participant(harness, participant)
    local_today = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    buckets = [
        _bucket(
            harness,
            usage_date=local_today - timedelta(days=offset),
            model="grouped-model",
            input_tokens=offset + 1,
            output_tokens=1,
            cache_read_tokens=0,
            cache_write_tokens=0,
        )
        for offset in range(40)
    ]
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    statements: list[str] = []

    def capture_statement(
        _connection,
        _cursor,
        statement,
        _parameters,
        _context,
        _executemany,
    ) -> None:
        statements.append(statement)

    event.listen(
        harness.app.state.engine,
        "before_cursor_execute",
        capture_statement,
    )
    try:
        leaderboard_url = (
            "/api/v1/public/leaderboard?period=all&model=grouped-model"
        )
        first = harness.client.get(leaderboard_url)
        assert first.status_code == 200
        assert first.headers["cache-control"] == (
            "public, max-age=15, s-maxage=15"
        )
        assert first.json()["entries"][0]["totals"]["total_tokens"] == str(
            sum(range(1, 41)) + 40
        )
        first_daily_queries = [
            statement
            for statement in statements
            if "daily_usage" in statement.lower()
        ]
        # One bounded scan count, two DISTINCT label queries, and one grouped
        # member aggregate: row count changes do not increase query count.
        assert len(first_daily_queries) == 4
        assert sum("group by" in item.lower() for item in first_daily_queries) == 1

        statements.clear()
        second = harness.client.get(leaderboard_url)
        assert second.json() == first.json()
        assert not [
            statement
            for statement in statements
            if "daily_usage" in statement.lower()
        ]

        public_id = participant["participant"]["public_id"]
        detail_url = (
            f"/api/v1/public/members/{public_id}"
            "?period=all&model=grouped-model"
        )
        statements.clear()
        detail = harness.client.get(detail_url)
        assert detail.status_code == 200
        detail_daily_queries = [
            statement
            for statement in statements
            if "daily_usage" in statement.lower()
        ]
        # Scan count + member rank + tool/model/day grouped projections.
        assert len(detail_daily_queries) == 5
        assert sum("group by" in item.lower() for item in detail_daily_queries) == 4

        statements.clear()
        assert harness.client.get(detail_url).json() == detail.json()
        assert not [
            statement
            for statement in statements
            if "daily_usage" in statement.lower()
        ]

        renamed = harness.client.patch(
            f"/api/v1/users/{participant['participant']['id']}",
            headers=harness.auth("a_admin"),
            json={"display_name": "聚合后昵称"},
        )
        assert renamed.status_code == 200
        statements.clear()
        refreshed = harness.client.get(leaderboard_url)
        assert refreshed.json()["entries"][0]["nickname"] == "聚合后昵称"
        assert len(
            [
                statement
                for statement in statements
                if "daily_usage" in statement.lower()
            ]
        ) == 4
    finally:
        event.remove(
            harness.app.state.engine,
            "before_cursor_execute",
            capture_statement,
        )


@pytest.mark.parametrize("member_count", [100, 200])
def test_public_leaderboard_scales_to_one_hundred_and_two_hundred_members(
    harness, member_count: int
) -> None:
    _enable_alpha_public_board(harness)
    org_id = harness.users["a_admin"].org_id
    usage_date = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    with harness.session_factory() as session:
        users = [
            User(
                org_id=org_id,
                email=None,
                password_hash=None,
                display_name=f"容量榜-{member_count}-{position:03d}",
                public_profile_enabled=True,
            )
            for position in range(1, member_count + 1)
        ]
        session.add_all(users)
        session.flush()
        devices = [
            Device(
                org_id=org_id,
                user_id=user.id,
                device_public_id=str(uuid4()),
                platform="test",
                app_version="0.1.0-beta.8",
                collector_version="0.1.0-beta.8",
                signing_key="0" * 64,
            )
            for user in users
        ]
        session.add_all(devices)
        session.flush()
        session.add_all(
            DailyUsage(
                org_id=org_id,
                user_id=user.id,
                device_id=device.id,
                usage_date=usage_date,
                timezone="Asia/Shanghai",
                tool="Codex" if position % 2 else "Claude Code",
                model=f"scale-model-{position % 4}",
                source="local",
                completeness="exact",
                input_tokens=position,
                output_tokens=0,
                cache_read_tokens=0,
                cache_write_tokens=0,
                report_schema_version=1,
                collector_version="0.1.0-beta.8",
                reported_generated_at=utcnow(),
            )
            for position, (user, device) in enumerate(
                zip(users, devices, strict=True), start=1
            )
        )
        session.commit()

    response = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"period": "today", "metric": "tokens", "limit": 100},
    )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["total_entries"] == member_count
    assert len(payload["entries"]) == min(member_count, 100)
    assert [entry["rank"] for entry in payload["entries"]] == list(
        range(1, min(member_count, 100) + 1)
    )
    assert payload["entries"][0]["metric_value"] == str(member_count)
    assert payload["entries"][0]["primary_tool"] in {"Codex", "Claude Code"}
    assert payload["entries"][0]["primary_model"].startswith("scale-model-")
    assert set(payload["available_tools"]) == {"Codex", "Claude Code"}
    assert len(payload["available_models"]) == 4


def test_public_member_detail_rank_is_exact_beyond_leaderboard_limit(harness) -> None:
    _enable_alpha_public_board(harness)
    org_id = harness.users["a_admin"].org_id
    usage_date = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    with harness.session_factory() as session:
        users = [
            User(
                org_id=org_id,
                email=None,
                password_hash=None,
                display_name=f"排名-{position:03d}",
                public_profile_enabled=True,
            )
            for position in range(1, 102)
        ]
        session.add_all(users)
        session.flush()
        devices = [
            Device(
                org_id=org_id,
                user_id=user.id,
                device_public_id=str(uuid4()),
                platform="test",
                app_version="1.0.0",
                collector_version="1.0.0",
                signing_key="0" * 64,
            )
            for user in users
        ]
        session.add_all(devices)
        session.flush()
        session.add_all(
            DailyUsage(
                org_id=org_id,
                user_id=user.id,
                device_id=device.id,
                usage_date=usage_date,
                timezone="Asia/Shanghai",
                tool="Codex",
                model="rank-model",
                source="local",
                completeness="exact",
                input_tokens=102 - position,
                output_tokens=0,
                cache_read_tokens=0,
                cache_write_tokens=0,
                report_schema_version=1,
                collector_version="1.0.0",
                reported_generated_at=utcnow(),
            )
            for position, (user, device) in enumerate(
                zip(users, devices, strict=True), start=1
            )
        )
        session.commit()
        last_public_id = users[-1].public_id

    leaderboard = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"model": "rank-model", "limit": 100},
    ).json()
    assert leaderboard["total_entries"] == 101
    assert len(leaderboard["entries"]) == 100
    assert last_public_id not in {
        entry["public_id"] for entry in leaderboard["entries"]
    }

    detail = harness.client.get(
        f"/api/v1/public/members/{last_public_id}",
        params={"model": "rank-model"},
    )
    assert detail.status_code == 200
    assert detail.json()["rank"] == 101
    assert detail.json()["metric_value"] == "1"

    no_usage = _create_participant(
        harness,
        display_name="暂无用量",
        public_profile_enabled=True,
    )
    empty_detail = harness.client.get(
        f"/api/v1/public/members/{no_usage['participant']['public_id']}",
        params={"model": "rank-model"},
    )
    assert empty_detail.status_code == 200
    assert empty_detail.json()["rank"] is None


def test_public_today_uses_organization_calendar_across_utc_boundary(
    harness, monkeypatch
) -> None:
    from app import public_projection

    _enable_alpha_public_board(harness)
    fixed_now = datetime(2026, 8, 9, 16, 30, tzinfo=timezone.utc)
    monkeypatch.setattr(public_projection, "utcnow", lambda: fixed_now)
    participant = _create_participant(harness, public_profile_enabled=True)
    device = _enroll_participant(harness, participant)
    assert harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[
                _bucket(
                    harness,
                    usage_date=date(2026, 8, 10),
                    model="calendar-model",
                    input_tokens=10,
                    output_tokens=0,
                    cache_read_tokens=0,
                    cache_write_tokens=0,
                ),
                _bucket(
                    harness,
                    usage_date=date(2026, 8, 9),
                    model="calendar-model",
                    input_tokens=20,
                    output_tokens=0,
                    cache_read_tokens=0,
                    cache_write_tokens=0,
                ),
            ]
        ),
    ).status_code == 200
    today = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"period": "today", "model": "calendar-model"},
    ).json()
    yesterday = harness.client.get(
        "/api/v1/public/leaderboard",
        params={"period": "yesterday", "model": "calendar-model"},
    ).json()
    assert today["start_date"] == "2026-08-10"
    assert today["entries"][0]["metric_value"] == "10"
    assert yesterday["start_date"] == "2026-08-09"
    assert yesterday["entries"][0]["metric_value"] == "20"


def test_public_visibility_requires_member_and_safe_nickname(harness) -> None:
    member_path = f"/api/v1/users/{harness.users['a_member'].id}"
    missing_name = harness.client.patch(
        member_path,
        headers=harness.auth("a_admin"),
        json={"public_profile_enabled": True},
    )
    assert missing_name.status_code == 409
    enabled = harness.client.patch(
        member_path,
        headers=harness.auth("a_admin"),
        json={"display_name": "成员昵称", "public_profile_enabled": True},
    )
    assert enabled.status_code == 200
    unsafe = harness.client.patch(
        member_path,
        headers=harness.auth("a_admin"),
        json={"display_name": "bad\nname"},
    )
    assert unsafe.status_code == 422
    admin_public = harness.client.patch(
        f"/api/v1/users/{harness.users['a_admin'].id}",
        headers=harness.auth("a_admin"),
        json={"display_name": "Admin", "public_profile_enabled": True},
    )
    assert admin_public.status_code == 409


def test_price_public_estimate_is_explicit_and_sensitive_posts_are_no_store(
    harness,
) -> None:
    missing_flag = _price_payload(
        model="explicit-flag", public_estimate=False
    )
    missing_flag.pop("public_estimate")
    assert harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=missing_flag,
    ).status_code == 422
    private = _create_price(
        harness,
        model="explicit-private",
        public_estimate=False,
    )
    assert private["public_estimate"] is False

    login = harness.client.post(
        "/api/v1/auth/token",
        json={
            "org_slug": "alpha",
            "email": harness.users["a_admin"].email,
            "password": "correct-horse-battery-staple",
        },
    )
    assert login.status_code == 200
    assert login.headers["cache-control"] == "no-store"

    for path in ("/api/v1/me", "/api/v1/users", "/api/v1/dashboard"):
        authenticated_get = harness.client.get(
            path,
            headers=harness.auth("a_admin"),
        )
        assert authenticated_get.status_code == 200
        assert authenticated_get.headers["cache-control"] == "no-store"


def test_cost_metric_rejects_cross_currency_comparison(harness) -> None:
    _enable_alpha_public_board(harness)
    for index, currency in enumerate(("USD", "EUR")):
        model = f"currency-{currency.lower()}"
        _create_price(
            harness,
            model=model,
            currency=currency,
            public_estimate=True,
        )
        participant = _create_participant(
            harness,
            display_name=f"Currency {index}",
            public_profile_enabled=True,
        )
        device = _enroll_participant(harness, participant)
        assert harness.signed_post(
            device,
            harness.usage_payload(
                buckets=[
                    _bucket(
                        harness,
                        model=model,
                        cache_read_tokens=0,
                        cache_write_tokens=0,
                    )
                ]
            ),
        ).status_code == 200
    statements: list[str] = []

    def capture_statement(
        _connection,
        _cursor,
        statement,
        _parameters,
        _context,
        _executemany,
    ) -> None:
        statements.append(statement)

    event.listen(
        harness.app.state.engine,
        "before_cursor_execute",
        capture_statement,
    )
    try:
        response = harness.client.get(
            "/api/v1/public/leaderboard", params={"metric": "cost"}
        )
    finally:
        event.remove(
            harness.app.state.engine,
            "before_cursor_execute",
            capture_statement,
        )
    assert response.status_code == 422
    assert response.json() == {
        "detail": (
            "metric=cost requires one currency across all fully priced "
            "matching members"
        )
    }
    daily_queries = [
        statement.lower()
        for statement in statements
        if "daily_usage" in statement.lower()
    ]
    assert any("count(distinct(daily_usage.cost_currency))" in statement for statement in daily_queries)
    assert not any("tokenfleet_exact_integer_sum" in statement for statement in daily_queries)


def test_public_configuration_fails_closed(harness) -> None:
    not_configured = harness.client.get("/api/v1/public/leaderboard")
    assert not_configured.status_code == 404
    assert not_configured.json() == {"detail": "public leaderboard not found"}
    assert harness.client.get("/readyz").status_code == 200
    harness.app.state.settings = replace(
        harness.app.state.settings,
        public_org_slug="missing-org",
    )
    missing = harness.client.get("/api/v1/public/leaderboard")
    assert missing.status_code == 404
    assert missing.json() == {"detail": "public leaderboard not found"}
    ready = harness.client.get("/readyz")
    assert ready.status_code == 200
    assert ready.json() == {"status": "ready"}


def test_sqlite_migration_backfills_safe_defaults_and_allows_null_login_pair(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "public-migration.db"
    database_url = f"sqlite:///{database_path}"
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    config.attributes["database_url"] = database_url
    command.upgrade(config, "bb8d4e1a2f73")

    from sqlalchemy import create_engine, inspect

    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO organizations "
                "(id, slug, name, default_timezone, retention_days, ledger_version, created_at) "
                "VALUES ('org', 'legacy', 'Legacy', 'UTC', 395, 0, :now)"
            ),
            {"now": datetime.now(timezone.utc)},
        )
        connection.execute(
            text(
                "INSERT INTO users "
                "(id, org_id, email, display_name, password_hash, role, is_active, created_at) "
                "VALUES ('user', 'org', 'legacy@example.com', 'Legacy', 'hash', "
                "'MEMBER', 1, :now)"
            ),
            {"now": datetime.now(timezone.utc)},
        )
        connection.execute(
            text(
                "INSERT INTO price_versions "
                "(id, org_id, tool, model, currency, input_per_million, "
                "output_per_million, cache_read_per_million, cache_write_per_million, "
                "effective_from, created_by_user_id, created_at) VALUES "
                "('price', 'org', 'Codex', 'legacy-model', 'USD', 1, 1, 1, 1, "
                "'2026-01-01', 'user', :now)"
            ),
            {"now": datetime.now(timezone.utc)},
        )
    engine.dispose()

    command.upgrade(config, "head")
    engine = create_engine(database_url)
    usage_indexes = {item["name"] for item in inspect(engine).get_indexes("daily_usage")}
    assert {
        "ix_usage_public_org_tool_date",
        "ix_usage_public_org_model_date",
    } <= usage_indexes
    with engine.begin() as connection:
        migrated = connection.execute(
            text(
                "SELECT public_id, public_profile_enabled FROM users WHERE id='user'"
            )
        ).one()
        UUID(migrated.public_id)
        assert migrated.public_profile_enabled == 0
        assert connection.scalar(
            text("SELECT public_estimate FROM price_versions WHERE id='price'")
        ) == 0

        participant_public_id = str(uuid4())
        connection.execute(
            text(
                "INSERT INTO users "
                "(id, org_id, email, display_name, password_hash, public_id, "
                "public_profile_enabled, role, is_active, created_at) VALUES "
                "('participant', 'org', NULL, 'Participant', NULL, :public_id, "
                "0, 'MEMBER', 1, :now)"
            ),
            {
                "public_id": participant_public_id,
                "now": datetime.now(timezone.utc),
            },
        )
        with pytest.raises(IntegrityError):
            connection.execute(
                text(
                    "INSERT INTO users "
                    "(id, org_id, email, display_name, password_hash, public_id, "
                    "public_profile_enabled, role, is_active, created_at) VALUES "
                    "('broken', 'org', NULL, 'Broken', 'hash', :public_id, "
                    "0, 'MEMBER', 1, :now)"
                ),
                {
                    "public_id": str(uuid4()),
                    "now": datetime.now(timezone.utc),
                },
            )
    engine.dispose()


def test_sqlite_public_migration_downgrades_without_participants(
    tmp_path: Path,
) -> None:
    from sqlalchemy import create_engine, inspect

    database_path = tmp_path / "public-downgrade-empty.db"
    database_url = f"sqlite:///{database_path}"
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    config.attributes["database_url"] = database_url
    command.upgrade(config, "head")
    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO organizations "
                "(id, slug, name, default_timezone, retention_days, ledger_version, created_at) "
                "VALUES ('org', 'downgrade', 'Downgrade', 'UTC', 395, 0, :now)"
            ),
            {"now": datetime.now(timezone.utc)},
        )
        connection.execute(
            text(
                "INSERT INTO users "
                "(id, org_id, email, display_name, password_hash, public_id, "
                "public_profile_enabled, role, is_active, created_at) VALUES "
                "('admin', 'org', 'admin@example.com', 'Admin', 'hash', :public_id, "
                "0, 'ADMIN', 1, :now)"
            ),
            {"public_id": str(uuid4()), "now": datetime.now(timezone.utc)},
        )
        connection.execute(
            text(
                "INSERT INTO price_versions "
                "(id, org_id, tool, model, currency, public_estimate, "
                "input_per_million, output_per_million, cache_read_per_million, "
                "cache_write_per_million, effective_from, created_by_user_id, created_at) "
                "VALUES ('price', 'org', 'Codex', 'model', 'USD', 0, 1, 1, 1, 1, "
                "'2026-01-01', 'admin', :now)"
            ),
            {"now": datetime.now(timezone.utc)},
        )
    engine.dispose()

    command.downgrade(config, "bb8d4e1a2f73")
    engine = create_engine(database_url)
    assert "public_id" not in {
        column["name"] for column in inspect(engine).get_columns("users")
    }
    assert "public_estimate" not in {
        column["name"] for column in inspect(engine).get_columns("price_versions")
    }
    assert not {
        "ix_usage_public_org_tool_date",
        "ix_usage_public_org_model_date",
    } & {item["name"] for item in inspect(engine).get_indexes("daily_usage")}
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "bb8d4e1a2f73"
        )
        assert connection.scalar(text("SELECT count(*) FROM users")) == 1
        assert connection.scalar(text("SELECT count(*) FROM price_versions")) == 1
    engine.dispose()


def test_sqlite_public_migration_refuses_destructive_participant_downgrade(
    tmp_path: Path,
) -> None:
    from sqlalchemy import create_engine, inspect

    database_path = tmp_path / "public-downgrade-participant.db"
    database_url = f"sqlite:///{database_path}"
    config = Config(str(SERVER_ROOT / "alembic.ini"))
    config.attributes["database_url"] = database_url
    command.upgrade(config, "head")
    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO organizations "
                "(id, slug, name, default_timezone, retention_days, ledger_version, created_at) "
                "VALUES ('org', 'safe-refusal', 'Safe', 'UTC', 395, 0, :now)"
            ),
            {"now": datetime.now(timezone.utc)},
        )
        connection.execute(
            text(
                "INSERT INTO users "
                "(id, org_id, email, display_name, password_hash, public_id, "
                "public_profile_enabled, role, is_active, created_at) VALUES "
                "('participant', 'org', NULL, 'Participant', NULL, :public_id, "
                "0, 'MEMBER', 1, :now)"
            ),
            {"public_id": str(uuid4()), "now": datetime.now(timezone.utc)},
        )
    engine.dispose()

    with pytest.raises(
        RuntimeError,
        match="cannot downgrade invitation batches while participants or batches exist",
    ):
        command.downgrade(config, "bb8d4e1a2f73")
    engine = create_engine(database_url)
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "c7b4e2a91d35"
        )
        assert connection.scalar(
            text("SELECT count(*) FROM users WHERE email IS NULL")
        ) == 1
    assert {
        "ix_usage_public_org_tool_date",
        "ix_usage_public_org_model_date",
    } <= {item["name"] for item in inspect(engine).get_indexes("daily_usage")}
    assert "invitation_batches" in inspect(engine).get_table_names()
    assert "uq_user_org_normalized_display_name" in {
        item["name"] for item in inspect(engine).get_indexes("users")
    }
    engine.dispose()
