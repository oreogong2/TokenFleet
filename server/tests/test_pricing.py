from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select

from app.models import DailyUsage


def _price_payload(*, effective_from: str, input_rate: str = "2.0") -> dict[str, str]:
    return {
        "tool": "Codex",
        "model": "gpt-5",
        "currency": "USD",
        "public_estimate": False,
        "input_per_million": input_rate,
        "output_per_million": "10.0",
        "cache_read_per_million": "0.2",
        "cache_write_per_million": "2.5",
        "effective_from": effective_from,
    }


@pytest.mark.parametrize(
    ("field", "value"),
    [("tool", "Codex\u200bhidden"), ("model", "gpt\u202e-5")],
)
def test_price_labels_reject_unicode_format_characters(
    harness, field, value
) -> None:
    payload = _price_payload(
        effective_from=datetime.now(timezone.utc).date().isoformat()
    )
    payload[field] = value
    response = harness.client.post(
        "/api/v1/prices", headers=harness.auth("a_admin"), json=payload
    )
    assert response.status_code == 422
    assert value not in response.text


def test_versioned_cost_uses_all_atomic_fields_and_freezes_version(harness) -> None:
    today = datetime.now(timezone.utc).date()
    price = harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=_price_payload(effective_from=(today - timedelta(days=1)).isoformat()),
    )
    assert price.status_code == 201, price.text
    first_price_id = price.json()["id"]

    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    uploaded = harness.signed_post(device, payload)
    assert uploaded.status_code == 200, uploaded.text

    # 120*2 + 80*10 + 1000*.2 + 50*2.5 = 1365 micro-USD.
    dashboard = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("a_admin")
    ).json()
    assert dashboard["totals"]["priced_costs_microunits"] == {"USD": 1365}
    assert dashboard["totals"]["unpriced_rows"] == 0
    assert dashboard["rows"][0]["price_version_id"] == first_price_id

    later_price = harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=_price_payload(effective_from=today.isoformat(), input_rate="99"),
    )
    assert later_price.status_code == 201
    payload["generated_at"] = (
        datetime.now(timezone.utc) + timedelta(seconds=1)
    ).isoformat().replace("+00:00", "Z")
    payload["buckets"][0]["input_tokens"] = 121
    changed = harness.signed_post(device, payload)
    assert changed.status_code == 200
    assert changed.json()["updated"] == 1

    with harness.session_factory() as session:
        row = session.scalar(select(DailyUsage).where(DailyUsage.device_id == device.id))
        assert row is not None
        assert row.price_version_id == first_price_id
        assert row.cost_microunits == 1367


def test_unpriced_usage_is_not_reported_as_zero_cost(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    assert harness.signed_post(device, harness.usage_payload()).status_code == 200
    dashboard = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("a_member")
    ).json()
    assert dashboard["totals"]["priced_costs_microunits"] == {}
    assert dashboard["totals"]["unpriced_rows"] == 1
    assert dashboard["rows"][0]["cost_microunits"] is None


def test_tombstone_hides_cost_and_resurrection_reuses_frozen_price(harness) -> None:
    now = datetime.now(timezone.utc)
    price = harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=_price_payload(effective_from=now.date().isoformat()),
    )
    assert price.status_code == 201
    price_id = price.json()["id"]
    device = harness.enroll(admin_name="a_admin", user_name="a_member")

    active = harness.usage_payload(
        generated_at=(now - timedelta(seconds=3)).isoformat()
    )
    assert harness.signed_post(device, active).status_code == 200
    tombstone = harness.usage_payload(
        generated_at=(now - timedelta(seconds=2)).isoformat()
    )
    tombstone["buckets"][0].update(
        {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "deleted": True,
        }
    )
    assert harness.signed_post(device, tombstone).json()["updated"] == 1
    hidden = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert hidden["rows"] == []
    assert hidden["totals"]["priced_costs_microunits"] == {}
    assert hidden["totals"]["unpriced_rows"] == 0

    resurrection = harness.usage_payload(
        generated_at=(now - timedelta(seconds=1)).isoformat()
    )
    resurrection["buckets"][0]["input_tokens"] = 121
    assert harness.signed_post(device, resurrection).json()["updated"] == 1
    visible = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert visible["totals"]["priced_costs_microunits"] == {"USD": 1367}
    assert visible["rows"][0]["price_version_id"] == price_id


def test_tombstone_resurrection_does_not_reprice_unpriced_history(harness) -> None:
    now = datetime.now(timezone.utc)
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    active = harness.usage_payload(
        generated_at=(now - timedelta(seconds=3)).isoformat()
    )
    assert harness.signed_post(device, active).status_code == 200
    tombstone = harness.usage_payload(
        generated_at=(now - timedelta(seconds=2)).isoformat()
    )
    tombstone["buckets"][0].update(
        {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "deleted": True,
        }
    )
    assert harness.signed_post(device, tombstone).status_code == 200
    assert harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=_price_payload(effective_from=now.date().isoformat()),
    ).status_code == 201

    resurrection = harness.usage_payload(
        generated_at=(now - timedelta(seconds=1)).isoformat()
    )
    assert harness.signed_post(device, resurrection).status_code == 200
    dashboard = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert dashboard["totals"]["priced_costs_microunits"] == {}
    assert dashboard["totals"]["unpriced_rows"] == 1
    assert dashboard["rows"][0]["price_version_id"] is None


def test_price_and_cost_never_cross_tenants(harness) -> None:
    today = datetime.now(timezone.utc).date().isoformat()
    assert harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=_price_payload(effective_from=today),
    ).status_code == 201
    device_b = harness.enroll(admin_name="b_admin", user_name="b_member")
    assert harness.signed_post(device_b, harness.usage_payload()).status_code == 200
    dashboard_b = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("b_admin")
    ).json()
    assert dashboard_b["totals"]["unpriced_rows"] == 1
    assert dashboard_b["totals"]["priced_costs_microunits"] == {}


def test_cost_overflow_is_rejected_without_partial_usage_write(harness) -> None:
    today = datetime.now(timezone.utc).date().isoformat()
    price_payload = _price_payload(effective_from=today, input_rate="1025")
    price_payload.update(
        {
            "output_per_million": "0",
            "cache_read_per_million": "0",
            "cache_write_per_million": "0",
        }
    )
    assert harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=price_payload,
    ).status_code == 201
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    payload["buckets"][0]["input_tokens"] = 9_000_000_000_000_000
    response = harness.signed_post(device, payload)
    assert response.status_code == 422
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 0


def test_schema_maximum_price_and_all_maximum_counters_return_422_not_500(
    harness,
) -> None:
    today = datetime.now(timezone.utc).date().isoformat()
    maximum_rate = "999999999999.99999999"
    price_payload = _price_payload(effective_from=today, input_rate=maximum_rate)
    price_payload.update(
        {
            "output_per_million": maximum_rate,
            "cache_read_per_million": maximum_rate,
            "cache_write_per_million": maximum_rate,
        }
    )
    created_price = harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=price_payload,
    )
    assert created_price.status_code == 201, created_price.text

    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    extreme = harness.usage_payload()["buckets"][0]
    extreme.update(
        {
            "input_tokens": 9_000_000_000_000_000,
            "output_tokens": 9_000_000_000_000_000,
            "cache_read_tokens": 9_000_000_000_000_000,
            "cache_write_tokens": 9_000_000_000_000_000,
        }
    )
    # This row sorts first and proves a later cost error rolls back the batch.
    unpriced = dict(extreme, model="aaa-unpriced", input_tokens=1)
    response = harness.signed_post(
        device,
        harness.usage_payload(buckets=[unpriced, extreme]),
    )
    assert response.status_code == 422
    assert response.json() == {
        "detail": "derived cost exceeds the supported signed 64-bit range"
    }
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 0


def test_non_exact_bucket_is_unpriced_until_exact_replacement(harness) -> None:
    today = datetime.now(timezone.utc).date()
    assert harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_admin"),
        json=_price_payload(effective_from=today.isoformat()),
    ).status_code == 201
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    first_time = datetime.now(timezone.utc) - timedelta(minutes=1)
    fallback = harness.usage_payload(
        generated_at=first_time.isoformat().replace("+00:00", "Z")
    )
    fallback["buckets"][0]["completeness"] = "fallback_estimate"
    assert harness.signed_post(device, fallback).status_code == 200
    first_dashboard = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert first_dashboard["totals"]["unpriced_rows"] == 1
    assert first_dashboard["rows"][0]["cost_microunits"] is None

    exact = harness.usage_payload(
        generated_at=(first_time + timedelta(seconds=1))
        .isoformat()
        .replace("+00:00", "Z")
    )
    replacement = harness.signed_post(device, exact)
    assert replacement.status_code == 200
    assert replacement.json()["updated"] == 1
    exact_dashboard = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert exact_dashboard["totals"]["unpriced_rows"] == 0
    assert exact_dashboard["rows"][0]["cost_microunits"] == 1365
    assert exact_dashboard["rows"][0]["total_tokens"] == 1250
    assert exact_dashboard["totals"]["total_tokens"] == 1250

    later_fallback = harness.usage_payload(
        generated_at=(first_time + timedelta(seconds=2))
        .isoformat()
        .replace("+00:00", "Z")
    )
    later_fallback["buckets"][0]["completeness"] = "fallback_estimate"
    later_fallback["buckets"][0]["input_tokens"] = 1
    ignored = harness.signed_post(device, later_fallback)
    assert ignored.status_code == 200
    assert ignored.json()["updated"] == 0
    assert ignored.json()["unchanged"] == 1
    preserved = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert preserved["rows"][0]["completeness"] == "exact"
    assert preserved["rows"][0]["cost_microunits"] == 1365
    assert preserved["rows"][0]["total_tokens"] == 1250
