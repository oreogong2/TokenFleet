from __future__ import annotations

from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import func, select

from app import api as api_module
from app.models import DailyUsage, Device, Organization


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _as_tombstone(payload: dict[str, object]) -> dict[str, object]:
    bucket = payload["buckets"][0]
    bucket.update(
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


def test_idempotent_overwrite_completeness_and_stale_guard(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=2)
    payload = harness.usage_payload(generated_at=_iso(base_time))
    payload["buckets"][0]["completeness"] = "fallback_estimate"

    first = harness.signed_post(device, payload)
    assert first.status_code == 200, first.text
    assert first.json() == {"created": 1, "updated": 0, "unchanged": 0, "ledger_version": 1}

    same = harness.signed_post(device, payload)
    assert same.status_code == 200
    assert same.json() == {"created": 0, "updated": 0, "unchanged": 1, "ledger_version": 1}

    exact = harness.usage_payload(generated_at=_iso(base_time + timedelta(minutes=1)))
    exact["buckets"][0]["input_tokens"] = 999
    exact["buckets"][0]["completeness"] = "exact"
    updated = harness.signed_post(device, exact)
    assert updated.status_code == 200, updated.text
    assert updated.json() == {"created": 0, "updated": 1, "unchanged": 0, "ledger_version": 2}

    stale = harness.usage_payload(generated_at=_iso(base_time - timedelta(minutes=1)))
    stale["buckets"][0]["input_tokens"] = 1
    ignored = harness.signed_post(device, stale)
    assert ignored.status_code == 200
    assert ignored.json() == {"created": 0, "updated": 0, "unchanged": 1, "ledger_version": 2}

    with harness.session_factory() as session:
        rows = list(session.scalars(select(DailyUsage)))
        assert len(rows) == 1
        assert rows[0].input_tokens == 999
        assert rows[0].completeness == "exact"


def test_completeness_quality_is_monotonic_and_dominates_snapshot_time(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=6)

    def upload(*, offset: int, completeness: str, input_tokens: int):
        payload = harness.usage_payload(
            generated_at=_iso(base_time + timedelta(minutes=offset))
        )
        payload["buckets"][0]["completeness"] = completeness
        payload["buckets"][0]["input_tokens"] = input_tokens
        return harness.signed_post(device, payload)

    fallback = upload(
        offset=5, completeness="fallback_estimate", input_tokens=100
    )
    assert fallback.json() == {
        "created": 1,
        "updated": 0,
        "unchanged": 0,
        "ledger_version": 1,
    }

    # A higher-quality snapshot wins even if its generated_at is older. This
    # makes final quality deterministic when offline reports arrive out of order.
    legacy = upload(offset=4, completeness="legacy_marginal", input_tokens=200)
    assert legacy.json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "ledger_version": 2,
    }

    later_fallback = upload(
        offset=6, completeness="fallback_estimate", input_tokens=300
    )
    assert later_fallback.json() == {
        "created": 0,
        "updated": 0,
        "unchanged": 1,
        "ledger_version": 2,
    }

    exact = upload(offset=3, completeness="exact", input_tokens=400)
    assert exact.json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "ledger_version": 3,
    }

    for completeness in ("legacy_marginal", "fallback_estimate"):
        downgrade = upload(
            offset=6,
            completeness=completeness,
            input_tokens=500,
        )
        assert downgrade.json() == {
            "created": 0,
            "updated": 0,
            "unchanged": 1,
            "ledger_version": 3,
        }

    with harness.session_factory() as session:
        row = session.scalar(
            select(DailyUsage).where(DailyUsage.device_id == device.id)
        )
        assert row is not None
        assert row.completeness == "exact"
        assert row.input_tokens == 400
        assert _utc_for_test(row.reported_generated_at) == base_time + timedelta(
            minutes=3
        )


def test_tombstone_marker_hides_usage_and_only_newer_exact_can_resurrect(
    harness,
) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=5)
    active = harness.usage_payload(generated_at=_iso(base_time))
    assert harness.signed_post(device, active).json() == {
        "created": 1,
        "updated": 0,
        "unchanged": 0,
        "ledger_version": 1,
    }

    # At an equal version the tombstone wins deterministically.
    tombstone = _as_tombstone(
        harness.usage_payload(generated_at=_iso(base_time))
    )
    assert harness.signed_post(device, tombstone).json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "ledger_version": 2,
    }
    hidden = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_member")
    )
    assert hidden.status_code == 200
    assert hidden.json()["rows"] == []
    assert hidden.json()["totals"]["total_tokens"] == 0
    assert hidden.json()["totals"]["priced_costs_microunits"] == {}

    for generated_at, completeness in (
        (base_time - timedelta(seconds=1), "exact"),
        (base_time, "exact"),
        (base_time + timedelta(seconds=1), "fallback_estimate"),
    ):
        rejected_resurrection = harness.usage_payload(
            generated_at=_iso(generated_at)
        )
        rejected_resurrection["buckets"][0]["completeness"] = completeness
        assert harness.signed_post(device, rejected_resurrection).json() == {
            "created": 0,
            "updated": 0,
            "unchanged": 1,
            "ledger_version": 2,
        }

    resurrection = harness.usage_payload(
        generated_at=_iso(base_time + timedelta(seconds=2))
    )
    resurrection["buckets"][0]["input_tokens"] = 321
    assert harness.signed_post(device, resurrection).json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "ledger_version": 3,
    }
    visible = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_member")
    ).json()
    assert len(visible["rows"]) == 1
    assert visible["totals"]["input_tokens"] == 321
    with harness.session_factory() as session:
        row = session.scalar(
            select(DailyUsage).where(DailyUsage.device_id == device.id)
        )
        assert row is not None and not row.is_deleted
        assert row.input_tokens == 321


def test_first_and_newer_tombstones_persist_hidden_versions(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=5)
    first_marker = _as_tombstone(
        harness.usage_payload(generated_at=_iso(base_time))
    )
    assert harness.signed_post(device, first_marker).json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "ledger_version": 1,
    }
    assert harness.signed_post(device, first_marker).json() == {
        "created": 0,
        "updated": 0,
        "unchanged": 1,
        "ledger_version": 1,
    }

    newer_marker = _as_tombstone(
        harness.usage_payload(generated_at=_iso(base_time + timedelta(seconds=1)))
    )
    assert harness.signed_post(device, newer_marker).json() == {
        "created": 0,
        "updated": 1,
        "unchanged": 0,
        "ledger_version": 2,
    }
    with harness.session_factory() as session:
        rows = list(
            session.scalars(
                select(DailyUsage).where(DailyUsage.device_id == device.id)
            )
        )
        assert len(rows) == 1
        assert rows[0].is_deleted
        assert _utc_for_test(rows[0].reported_generated_at) == base_time + timedelta(
            seconds=1
        )
    assert harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()["rows"] == []


def test_older_tombstone_cannot_delete_newer_active_snapshot(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=5)
    active = harness.usage_payload(
        generated_at=_iso(base_time + timedelta(seconds=1))
    )
    assert harness.signed_post(device, active).status_code == 200
    stale_tombstone = _as_tombstone(
        harness.usage_payload(generated_at=_iso(base_time))
    )
    assert harness.signed_post(device, stale_tombstone).json() == {
        "created": 0,
        "updated": 0,
        "unchanged": 1,
        "ledger_version": 1,
    }
    dashboard = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_member")
    ).json()
    assert dashboard["totals"]["input_tokens"] == 120


def test_ingest_retention_cutoff_ignores_older_dates_and_accepts_boundary(
    harness,
) -> None:
    assert harness.client.patch(
        "/api/v1/organization",
        headers=harness.auth("a_admin"),
        json={"default_timezone": "Asia/Shanghai", "retention_days": 30},
    ).status_code == 200
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    local_today = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    cutoff = local_today - timedelta(days=30)
    template = harness.usage_payload()["buckets"][0]
    expired = dict(template, date=(cutoff - timedelta(days=1)).isoformat())
    boundary = dict(template, date=cutoff.isoformat(), model="retention-boundary")
    response = harness.signed_post(
        device,
        harness.usage_payload(buckets=[expired, boundary]),
    )
    assert response.status_code == 200
    assert response.json() == {
        "created": 1,
        "updated": 0,
        "unchanged": 1,
        "ledger_version": 1,
    }
    with harness.session_factory() as session:
        rows = list(
            session.scalars(
                select(DailyUsage).where(DailyUsage.device_id == device.id)
            )
        )
        assert len(rows) == 1
        assert rows[0].usage_date == cutoff


def _utc_for_test(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


@pytest.mark.parametrize(
    ("organization_timezone", "fixed_now", "expected_today"),
    [
        (
            "Asia/Shanghai",
            datetime(2026, 8, 9, 16, 30, tzinfo=timezone.utc),
            date(2026, 8, 10),
        ),
        (
            "Asia/Singapore",
            datetime(2026, 8, 9, 16, 30, tzinfo=timezone.utc),
            date(2026, 8, 10),
        ),
        (
            "America/Los_Angeles",
            datetime(2026, 8, 9, 6, 30, tzinfo=timezone.utc),
            date(2026, 8, 8),
        ),
    ],
)
def test_dashboard_default_range_uses_organization_calendar_today(
    harness,
    monkeypatch,
    organization_timezone: str,
    fixed_now: datetime,
    expected_today: date,
) -> None:
    updated = harness.client.patch(
        "/api/v1/organization",
        headers=harness.auth("a_admin"),
        json={"default_timezone": organization_timezone},
    )
    assert updated.status_code == 200

    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    boundary_dates = [
        expected_today - timedelta(days=30),
        expected_today - timedelta(days=29),
        expected_today,
        expected_today + timedelta(days=1),
    ]
    buckets = []
    for index, usage_date in enumerate(boundary_dates, start=1):
        bucket = dict(harness.usage_payload()["buckets"][0])
        bucket.update(
            {
                "date": usage_date.isoformat(),
                "timezone": organization_timezone,
                "model": f"timezone-default-{index}",
                "input_tokens": index,
            }
        )
        buckets.append(bucket)
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    monkeypatch.setattr(api_module, "utcnow", lambda: fixed_now)
    default_range = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    )
    assert default_range.status_code == 200
    assert [row["date"] for row in default_range.json()["rows"]] == [
        boundary_dates[1].isoformat(),
        boundary_dates[2].isoformat(),
    ]
    assert default_range.json()["organization_timezone"] == organization_timezone

    explicit_range = harness.client.get(
        "/api/v1/dashboard",
        headers=harness.auth("a_admin"),
        params={
            "start_date": boundary_dates[0].isoformat(),
            "end_date": boundary_dates[3].isoformat(),
        },
    )
    assert explicit_range.status_code == 200
    assert [row["date"] for row in explicit_range.json()["rows"]] == [
        usage_date.isoformat() for usage_date in boundary_dates
    ]


def test_multiple_devices_are_distinct_and_sum_in_dashboard(harness) -> None:
    first_device = harness.enroll(admin_name="a_admin", user_name="a_member")
    second_device = harness.enroll(admin_name="a_admin", user_name="a_member")
    first_payload = harness.usage_payload()
    second_payload = harness.usage_payload()
    second_payload["buckets"][0]["input_tokens"] = 300

    assert harness.signed_post(first_device, first_payload).status_code == 200
    assert harness.signed_post(second_device, second_payload).status_code == 200

    response = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("a_member")
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["rows"]) == 2
    assert {row["device_id"] for row in body["rows"]} == {
        first_device.id,
        second_device.id,
    }
    assert body["totals"]["input_tokens"] == 420

    filtered = harness.client.get(
        "/api/v1/dashboard/usage",
        headers=harness.auth("a_member"),
        params={"device_id": second_device.id, "tool": "Codex", "model": "gpt-5"},
    )
    assert filtered.status_code == 200
    assert filtered.json()["totals"]["input_tokens"] == 300


@pytest.mark.parametrize("device_count", [1, 2, 4])
def test_one_two_and_four_devices_sum_without_collapsing_identity(
    harness, device_count: int
) -> None:
    devices = [
        harness.enroll(admin_name="a_admin", user_name="a_member")
        for _ in range(device_count)
    ]
    expected_input = 0
    for index, device in enumerate(devices, start=1):
        payload = harness.usage_payload()
        payload["buckets"][0]["input_tokens"] = index * 100
        expected_input += index * 100
        assert harness.signed_post(device, payload).status_code == 200

    response = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("a_member")
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["rows"]) == device_count
    assert {row["device_id"] for row in body["rows"]} == {
        device.id for device in devices
    }
    assert body["totals"]["input_tokens"] == expected_input


def test_source_and_timezone_are_dimensions_and_filters(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    today = datetime.now(timezone.utc).date().isoformat()
    payload = harness.usage_payload(
        buckets=[
            {
                "date": today,
                "timezone": "Asia/Shanghai",
                "tool": "Codex",
                "model": "gpt-5",
                "source": "local",
                "input_tokens": 10,
                "output_tokens": 1,
                "cache_read_tokens": 0,
                "cache_write_tokens": 0,
                "completeness": "exact",
            },
            {
                "date": today,
                "timezone": "America/Los_Angeles",
                "tool": "Codex",
                "model": "gpt-5",
                "source": "cc-switch",
                "input_tokens": 20,
                "output_tokens": 2,
                "cache_read_tokens": 0,
                "cache_write_tokens": 0,
                "completeness": "exact",
            },
        ]
    )
    assert harness.signed_post(device, payload).status_code == 200
    all_rows = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("a_member")
    ).json()
    assert all_rows["totals"]["input_tokens"] == 30
    assert all_rows["timezone_warning"] is not None

    filtered = harness.client.get(
        "/api/v1/dashboard/usage",
        headers=harness.auth("a_member"),
        params={"timezone": "America/Los_Angeles", "source": "cc-switch"},
    )
    assert filtered.status_code == 200
    assert filtered.json()["totals"]["input_tokens"] == 20

    reverse_range = harness.client.get(
        "/api/v1/dashboard/usage",
        headers=harness.auth("a_member"),
        params={"start_date": "2026-08-10", "end_date": "2026-08-09"},
    )
    assert reverse_range.status_code == 422
    bad_timezone = harness.client.get(
        "/api/v1/dashboard/usage",
        headers=harness.auth("a_member"),
        params={"timezone": "Mars/Olympus"},
    )
    assert bad_timezone.status_code == 422


def test_failed_batch_is_atomic_and_unknown_fields_are_rejected(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    today = datetime.now(timezone.utc).date().isoformat()
    valid_bucket = harness.usage_payload()["buckets"][0]
    invalid_bucket = dict(valid_bucket)
    invalid_bucket["date"] = today
    invalid_bucket["model"] = "other"
    invalid_bucket["input_tokens"] = True
    payload = harness.usage_payload(buckets=[valid_bucket, invalid_bucket])
    rejected = harness.signed_post(device, payload)
    assert rejected.status_code == 422
    assert '"input":true' not in rejected.text.lower()

    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 0

    unknown_top = harness.usage_payload()
    unknown_top["prompt"] = "must never be accepted or echoed"
    response = harness.signed_post(device, unknown_top)
    assert response.status_code == 422
    assert "must never be accepted" not in response.text

    unknown_bucket = harness.usage_payload()
    unknown_bucket["buckets"][0]["project_path"] = "/private/source"
    response = harness.signed_post(device, unknown_bucket)
    assert response.status_code == 422
    assert "/private/source" not in response.text


def test_device_row_quota_counts_tombstones_but_allows_existing_keys(
    harness,
) -> None:
    harness.app.state.settings = replace(
        harness.app.state.settings,
        usage_max_rows_per_device=2,
        usage_max_rows_per_org=10,
    )
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=2)
    active_bucket = dict(harness.usage_payload()["buckets"][0])
    active_bucket["model"] = "quota-active"
    first = harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[active_bucket], generated_at=_iso(base_time)
        ),
    )
    assert first.status_code == 200
    assert first.json()["created"] == 1

    marker_bucket = dict(active_bucket)
    marker_bucket.update(
        {
            "model": "quota-marker",
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "completeness": "exact",
            "deleted": True,
        }
    )
    first_marker = harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[marker_bucket],
            generated_at=_iso(base_time + timedelta(seconds=1)),
        ),
    )
    assert first_marker.status_code == 200
    assert first_marker.json()["updated"] == 1
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.device_id == device.id)
        ) == 2

    update_bucket = dict(active_bucket)
    update_bucket["input_tokens"] = 321
    update_payload = harness.usage_payload(
        buckets=[update_bucket],
        generated_at=_iso(base_time + timedelta(seconds=2)),
    )
    updated = harness.signed_post(device, update_payload)
    assert updated.status_code == 200
    assert updated.json()["updated"] == 1
    idempotent = harness.signed_post(device, update_payload)
    assert idempotent.status_code == 200
    assert idempotent.json()["unchanged"] == 1

    existing_marker = dict(update_bucket)
    existing_marker.update(
        {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "completeness": "exact",
            "deleted": True,
        }
    )
    deleted = harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[existing_marker],
            generated_at=_iso(base_time + timedelta(seconds=3)),
        ),
    )
    assert deleted.status_code == 200
    assert deleted.json()["updated"] == 1

    with harness.session_factory() as session:
        organization = session.scalar(
            select(Organization).where(
                Organization.id == harness.users["a_admin"].org_id
            )
        )
        stored_device = session.scalar(select(Device).where(Device.id == device.id))
        assert organization is not None
        assert stored_device is not None
        before_ledger = organization.ledger_version
        before_last_success = stored_device.last_successful_sync_at

    resurrection = dict(update_bucket)
    resurrection["input_tokens"] = 999
    new_bucket = dict(active_bucket)
    new_bucket.update({"model": "quota-new", "input_tokens": 777})
    rejected = harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[resurrection, new_bucket],
            generated_at=_iso(base_time + timedelta(seconds=4)),
        ),
    )
    assert rejected.status_code == 422
    assert rejected.json()["detail"] == {
        "code": "usage_row_quota_exceeded",
        "scope": "device",
        "message": (
            "the report would add natural keys beyond the configured device "
            "usage-row quota"
        ),
    }

    with harness.session_factory() as session:
        rows = list(
            session.scalars(
                select(DailyUsage)
                .where(DailyUsage.device_id == device.id)
                .order_by(DailyUsage.model)
            )
        )
        assert [row.model for row in rows] == ["quota-active", "quota-marker"]
        assert rows[0].is_deleted
        assert rows[0].input_tokens == 0
        organization = session.scalar(
            select(Organization).where(
                Organization.id == harness.users["a_admin"].org_id
            )
        )
        stored_device = session.scalar(select(Device).where(Device.id == device.id))
        assert organization is not None and organization.ledger_version == before_ledger
        assert stored_device is not None
        assert stored_device.last_successful_sync_at == before_last_success

    another_marker = dict(marker_bucket)
    another_marker["model"] = "quota-new-marker"
    marker_rejected = harness.signed_post(
        device,
        harness.usage_payload(
            buckets=[another_marker],
            generated_at=_iso(base_time + timedelta(seconds=5)),
        ),
    )
    assert marker_rejected.status_code == 422
    assert marker_rejected.json()["detail"]["scope"] == "device"
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.device_id == device.id)
        ) == 2


def test_organization_row_quota_is_shared_across_devices(harness) -> None:
    harness.app.state.settings = replace(
        harness.app.state.settings,
        usage_max_rows_per_device=10,
        usage_max_rows_per_org=2,
    )
    first_device = harness.enroll(admin_name="a_admin", user_name="a_member")
    second_device = harness.enroll(admin_name="a_admin", user_name="a_other")
    base_time = datetime.now(timezone.utc) - timedelta(minutes=1)

    first_payload = harness.usage_payload(generated_at=_iso(base_time))
    first_payload["buckets"][0]["model"] = "org-quota-first"
    second_payload = harness.usage_payload(
        generated_at=_iso(base_time + timedelta(seconds=1))
    )
    second_payload["buckets"][0]["model"] = "org-quota-second"
    assert harness.signed_post(first_device, first_payload).status_code == 200
    assert harness.signed_post(second_device, second_payload).status_code == 200

    existing_update = harness.usage_payload(
        generated_at=_iso(base_time + timedelta(seconds=2))
    )
    existing_update["buckets"][0].update(
        {"model": "org-quota-first", "input_tokens": 500}
    )
    assert harness.signed_post(first_device, existing_update).status_code == 200

    new_row = harness.usage_payload(
        generated_at=_iso(base_time + timedelta(seconds=3))
    )
    new_row["buckets"][0]["model"] = "org-quota-third"
    rejected = harness.signed_post(second_device, new_row)
    assert rejected.status_code == 422
    assert rejected.json()["detail"]["code"] == "usage_row_quota_exceeded"
    assert rejected.json()["detail"]["scope"] == "organization"
    with harness.session_factory() as session:
        assert session.scalar(
            select(func.count())
            .select_from(DailyUsage)
            .where(DailyUsage.org_id == harness.users["a_admin"].org_id)
        ) == 2


def test_duplicate_natural_key_after_trimming_is_rejected(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    first = harness.usage_payload()["buckets"][0]
    second = dict(first)
    second["tool"] = " Codex "
    second["completeness"] = "fallback_estimate"
    response = harness.signed_post(device, harness.usage_payload(buckets=[first, second]))
    assert response.status_code == 422


def test_ledger_version_is_scoped_to_organization(harness) -> None:
    device_a = harness.enroll(admin_name="a_admin", user_name="a_member")
    device_b = harness.enroll(admin_name="b_admin", user_name="b_member")
    assert harness.signed_post(device_a, harness.usage_payload()).json()["ledger_version"] == 1
    assert harness.signed_post(device_b, harness.usage_payload()).json()["ledger_version"] == 1
    with harness.session_factory() as session:
        versions = {
            organization.slug: organization.ledger_version
            for organization in session.scalars(select(Organization))
        }
    assert versions == {"alpha": 1, "bravo": 1}


def test_same_generated_at_with_different_snapshot_is_conflict(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    generated_at = _iso(datetime.now(timezone.utc) - timedelta(minutes=1))
    first = harness.usage_payload(generated_at=generated_at)
    assert harness.signed_post(device, first).status_code == 200

    divergent = harness.usage_payload(generated_at=generated_at)
    divergent["buckets"][0]["input_tokens"] = 999
    conflict = harness.signed_post(device, divergent)
    assert conflict.status_code == 409
    with harness.session_factory() as session:
        row = session.scalar(select(DailyUsage).where(DailyUsage.device_id == device.id))
        organization = session.scalar(
            select(Organization).where(Organization.id == harness.users["a_admin"].org_id)
        )
        assert row is not None and row.input_tokens == 120
        assert organization is not None and organization.ledger_version == 1


def test_successful_sync_updates_device_collector_metadata(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload(collector_version="0.3.0")
    assert harness.signed_post(device, payload).status_code == 200
    devices = harness.client.get(
        "/api/v1/devices", headers=harness.auth("a_member")
    ).json()
    assert devices[0]["collector_version"] == "0.3.0"
    assert devices[0]["app_version"] == "0.2.0"
    assert devices[0]["last_successful_sync_at"] is not None


def test_dst_transition_date_ranges_preserve_every_local_day(harness) -> None:
    # Keep both prior-year transitions inside this test organization's policy;
    # ingest correctly ignores buckets outside retention before query logic runs.
    assert harness.client.patch(
        "/api/v1/organization",
        headers=harness.auth("a_admin"),
        json={"retention_days": 730},
    ).status_code == 200
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    transition_year = datetime.now(timezone.utc).year - 1

    march_first = date(transition_year, 3, 1)
    first_march_sunday = march_first + timedelta(
        days=(6 - march_first.weekday()) % 7
    )
    spring_forward = first_march_sunday + timedelta(days=7)
    november_first = date(transition_year, 11, 1)
    fall_back = november_first + timedelta(
        days=(6 - november_first.weekday()) % 7
    )
    local_dates = [
        spring_forward - timedelta(days=1),
        spring_forward,
        spring_forward + timedelta(days=1),
        fall_back - timedelta(days=1),
        fall_back,
        fall_back + timedelta(days=1),
    ]
    buckets = []
    for index, local_date in enumerate(local_dates, start=1):
        buckets.append(
            {
                "date": local_date.isoformat(),
                "timezone": "America/Los_Angeles",
                "tool": "Codex",
                "model": "dst-boundary-model",
                "source": "local",
                "input_tokens": index,
                "output_tokens": 0,
                "cache_read_tokens": 0,
                "cache_write_tokens": 0,
                "completeness": "exact",
            }
        )
    assert harness.signed_post(
        device, harness.usage_payload(buckets=buckets)
    ).status_code == 200

    for transition in (spring_forward, fall_back):
        response = harness.client.get(
            "/api/v1/dashboard",
            headers=harness.auth("a_member"),
            params={
                "start_date": (transition - timedelta(days=1)).isoformat(),
                "end_date": (transition + timedelta(days=1)).isoformat(),
                "timezone": "America/Los_Angeles",
            },
        )
        assert response.status_code == 200
        assert [row["date"] for row in response.json()["rows"]] == [
            (transition - timedelta(days=1)).isoformat(),
            transition.isoformat(),
            (transition + timedelta(days=1)).isoformat(),
        ]
        assert response.json()["mixed_timezones"] is False

    entire_range = harness.client.get(
        "/api/v1/dashboard",
        headers=harness.auth("a_member"),
        params={
            "start_date": local_dates[0].isoformat(),
            "end_date": local_dates[-1].isoformat(),
            "timezone": "America/Los_Angeles",
        },
    )
    assert entire_range.status_code == 200
    assert len(entire_range.json()["rows"]) == 6
    assert entire_range.json()["totals"]["input_tokens"] == sum(range(1, 7))
