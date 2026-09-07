"""Partial estimates are opt-in; existing device/public contracts stay frozen."""
from pathlib import Path
import sys

from app.schemas import PublicUsageTotals
from .test_public_community import (
    _bucket, _create_participant, _create_price, _enable_alpha_public_board,
    _enroll_participant, _price_payload,
)


def _usage(harness, model, tokens):
    return _bucket(harness, model=model, input_tokens=tokens, output_tokens=0,
                   cache_read_tokens=0, cache_write_tokens=0)


def test_partial_public_cost_never_reprices_or_changes_v1_device_contract(harness):
    _enable_alpha_public_board(harness)
    public_price = _create_price(harness, model="priced", public_estimate=True)
    _create_price(harness, model="private-price", public_estimate=False)
    participant = _create_participant(harness, display_name="部分计价")
    device = _enroll_participant(harness, participant)
    buckets = [
        _bucket(harness, model="priced", input_tokens=100, output_tokens=20,
                cache_read_tokens=30, cache_write_tokens=40),
        _usage(harness, "unknown-price", 610),
        _usage(harness, "private-price", 200),
    ]
    uploaded = harness.signed_post(device, harness.usage_payload(buckets=buckets))
    assert uploaded.status_code == 200
    public_id = participant["participant"]["public_id"]
    for period in ("today", "7d", "all"):
        query = {"period": period}
        enriched = harness.client.get("/api/v1/public/priced-leaderboard", params=query)
        assert enriched.status_code == 200
        totals = enriched.json()["entries"][0]["totals"]
        assert totals["priced_tokens"] == "190"
        assert totals["total_tokens"] == "1000"
        assert totals["priced_costs_microunits"] == {"USD": "390"}
        assert totals["estimated_cost_microunits"] is None
        assert totals["unpriced"] is True
        # Exercise the shared cache in both endpoint orders: v1 must serialize
        # only its frozen fields, even after an enriched response is cached.
        old = harness.client.get("/api/v1/public/leaderboard", params=query).json()
        assert set(old["entries"][0]["totals"]) == set(PublicUsageTotals.model_fields)
        detail = harness.client.get(f"/api/v1/public/priced-members/{public_id}", params=query)
        assert detail.status_code == 200
        detail = detail.json()
        assert detail["totals"] == totals
        assert detail["tool_distribution"][0]["totals"] == totals
        assert detail["daily_trend"][0]["totals"] == totals
        models = {row["name"]: row["totals"] for row in detail["model_distribution"]}
        assert models["private-price"]["priced_costs_microunits"] == {}
        assert models["private-price"]["priced_tokens"] == "0"
        old_detail = harness.client.get(f"/api/v1/public/members/{public_id}", params=query).json()
        assert set(old_detail["totals"]) == set(PublicUsageTotals.model_fields)
        assert all(set(row["totals"]) == set(PublicUsageTotals.model_fields)
                   for row in old_detail["model_distribution"])
    filtered = harness.client.get("/api/v1/public/priced-leaderboard", params={"model": "priced"}).json()
    assert filtered["entries"][0]["totals"]["total_tokens"] == "190"
    assert filtered["entries"][0]["totals"]["unpriced"] is False
    cost_board = harness.client.get("/api/v1/public/priced-leaderboard", params={"metric": "cost"}).json()
    assert cost_board["entries"][0]["rank"] is None
    assert cost_board["entries"][0]["metric_value"] is None
    rank = harness.signed_get(device, "/api/v1/devices/me/community-rank")
    assert rank.status_code == 200
    assert set(rank.json()["totals"]) == set(PublicUsageTotals.model_fields)
    # Run the shipped Windows parser against the actual server response.
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "clients/windows"))
    try:
        from tokenfleet.client import TokenFleetClient
        assert TokenFleetClient._validate_community_rank(rank.json()) == rank.json()
    finally:
        sys.path.pop(0)
    repeated = harness.signed_post(device, harness.usage_payload(buckets=buckets))
    assert repeated.status_code == 200
    assert repeated.json()["unchanged"] == 3
    assert repeated.json()["created"] == repeated.json()["updated"] == 0
    hidden = harness.client.patch(f"/api/v1/prices/{public_price['id']}",
        headers=harness.auth("a_admin"), json={"public_estimate": False})
    assert hidden.status_code == 200
    after = harness.client.get("/api/v1/public/priced-leaderboard").json()["entries"][0]["totals"]
    assert after["total_tokens"] == "1000"
    assert after["priced_tokens"] == "0"
    assert after["priced_costs_microunits"] == {}


def test_zero_cost_is_priced_and_mixed_currencies_are_never_summed(harness):
    _enable_alpha_public_board(harness)
    payload = _price_payload(model="free", public_estimate=True)
    for key in ("input_per_million", "output_per_million", "cache_read_per_million", "cache_write_per_million"):
        payload[key] = "0"
    assert harness.client.post("/api/v1/prices", headers=harness.auth("a_admin"), json=payload).status_code == 201
    _create_price(harness, model="eur", currency="EUR", public_estimate=True)
    participant = _create_participant(harness)
    device = _enroll_participant(harness, participant)
    assert harness.signed_post(device, harness.usage_payload(buckets=[_usage(harness, "free", 100)])).status_code == 200
    free = harness.client.get("/api/v1/public/priced-leaderboard").json()["entries"][0]["totals"]
    assert free["priced_costs_microunits"] == {"USD": "0"}
    assert free["unpriced"] is False
    assert free["priced_tokens"] == "100"
    assert harness.signed_post(device, harness.usage_payload(buckets=[_usage(harness, "eur", 200)])).status_code == 200
    mixed = harness.client.get("/api/v1/public/priced-leaderboard").json()["entries"][0]["totals"]
    assert mixed["priced_costs_microunits"] == {"EUR": "200", "USD": "0"}
    assert mixed["priced_tokens"] == "300"
    assert mixed["mixed_currency"] is True
    assert mixed["estimated_cost_microunits"] is None


def test_enriched_endpoint_obeys_public_visibility_and_scan_limits(harness):
    _enable_alpha_public_board(harness)
    from dataclasses import replace
    participant = _create_participant(harness, public_profile_enabled=False)
    device = _enroll_participant(harness, participant)
    assert harness.signed_post(device, harness.usage_payload()).status_code == 200
    public_id = participant["participant"]["public_id"]
    assert harness.client.get("/api/v1/public/priced-leaderboard").json()["entries"] == []
    assert harness.client.get(f"/api/v1/public/priced-members/{public_id}").status_code == 404
    visible = _create_participant(harness, display_name="公开成员")
    visible_device = _enroll_participant(harness, visible)
    assert harness.signed_post(visible_device, harness.usage_payload(buckets=[_usage(harness, "one", 1), _usage(harness, "two", 2)])).status_code == 200
    harness.app.state.settings = replace(harness.app.state.settings, public_max_scan_rows=1)
    assert harness.client.get("/api/v1/public/priced-leaderboard").status_code == 503
