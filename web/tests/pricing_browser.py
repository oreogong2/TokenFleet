"""Browser check for partial pricing, gated cost ranking, and narrow screens."""
from functools import partial
import json
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright
from community_browser import ARTIFACT_DIR, assert_no_horizontal_overflow, browser_base


TOTALS = {
    "input_tokens": "700", "output_tokens": "100", "cache_read_tokens": "100",
    "cache_write_tokens": "100", "norm_tokens": "800", "total_tokens": "1000",
    "estimated_cost_microunits": None, "cost_currency": None,
    "unpriced": True, "mixed_currency": False,
    "priced_tokens": "30", "priced_costs_microunits": {"USD": "190000"},
}


def fixture(route, request=None, *, partial_cost_ranking=False):
    parsed = urlparse(route.request.url)
    params = parse_qs(parsed.query)
    metric = params.get("metric", ["tokens"])[0]
    period = params.get("period", ["today"])[0]
    if parsed.path.endswith("/capabilities"):
        body = {"tools": ["Codex"], "models": ["known", "unknown"], "partial": False}
    else:
        entry = {
            "public_id": "partial-member", "nickname": "部分计价示例", "rank": None if metric == "cost" else 1,
            "metric_value": None if metric == "cost" else "1000",
            "primary_tool": "Codex", "primary_tool_tokens": "1000", "tool_count": 1,
            "primary_model": "unknown", "primary_model_tokens": "970", "model_count": 2,
            "totals": TOTALS,
        }
        full_entry = {
            **entry, "public_id": "fully-priced", "nickname": "完整计价示例",
            "rank": 1, "metric_value": "300000",
            "totals": {**TOTALS, "estimated_cost_microunits": "300000", "cost_currency": "USD",
                       "unpriced": False, "priced_tokens": "1000",
                       "priced_costs_microunits": {"USD": "300000"}},
        }
        unpriced_entry = {
            **entry, "public_id": "unpriced-member", "nickname": "全部未定价示例",
            "rank": 3, "metric_value": "0",
            "totals": {**TOTALS, "priced_tokens": "0", "priced_costs_microunits": {}},
        }
        enabled = partial_cost_ranking and metric == "cost"
        if enabled:
            entry = {**entry, "rank": 2, "metric_value": "190000"}
        if parsed.path.endswith("/priced-leaderboard"):
            body = {"entries": [unpriced_entry, entry, full_entry] if enabled else [entry],
                    "period": period, "metric": metric,
                    "available_tools": ["Codex"], "available_models": ["known", "unknown"]}
        elif "/priced-members/" in parsed.path:
            body = {**entry, "period": period, "metric": metric,
                    "tool_distribution": [{"name": "Codex", "totals": TOTALS}],
                    "model_distribution": [{"name": "known + unknown", "totals": TOTALS}],
                    "daily_trend": [{"date": "2026-09-07", "totals": TOTALS}]}
        else:
            route.fulfill(status=404, content_type="application/json", body='{"detail":"not found"}')
            return
    route.fulfill(status=200, content_type="application/json", body=json.dumps(body))


def main():
    with browser_base() as base, sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.route("**/api/v1/public/**", fixture)
        for width in (1440, 390):
            page.set_viewport_size({"width": width, "height": 1000})
            page.goto(f"{base}/rank", wait_until="networkidle")
            row = page.locator(".community-rank-row")
            assert "已计价部分 US$0.19 · 部分模型无公开价 · 覆盖 3%" in row.inner_text()
            assert row.locator(".community-primary small").evaluate("el => el.scrollHeight <= el.clientHeight")
            assert_no_horizontal_overflow(page)
            page.screenshot(path=str(ARTIFACT_DIR / f"pricing-rank-{width}.png"), full_page=True)
            row.get_by_role("link", name="部分计价示例").click()
            page.wait_for_load_state("networkidle")
            assert "已计价部分 US$0.19 · 部分模型无公开价 · 覆盖 3%" in page.locator(".community-extra-totals").inner_text()
            assert_no_horizontal_overflow(page)
            page.screenshot(path=str(ARTIFACT_DIR / f"pricing-profile-{width}.png"), full_page=True)
            page.goto(f"{base}/rank/p/partial-member?metric=cost", wait_until="networkidle")
            assert page.locator(".community-profile-rank").inner_text() == "未上榜"
            assert "已计价部分" in page.locator(".community-extra-totals").inner_text()
            assert page.locator(".community-trend polyline").count() == 0
            assert_no_horizontal_overflow(page)
            page.screenshot(path=str(ARTIFACT_DIR / f"pricing-cost-{width}.png"), full_page=True)
        page.unroute("**/api/v1/public/**", fixture)
        page.route("**/api/v1/public/**", partial(fixture, partial_cost_ranking=True))
        for width in (1440, 390):
            page.set_viewport_size({"width": width, "height": 1000})
            page.goto(f"{base}/rank?metric=cost", wait_until="networkidle")
            rows = page.locator(".community-rank-row")
            assert rows.count() == 3
            assert [row.locator(".community-person strong").inner_text() for row in rows.all()] == [
                "完整计价示例", "部分计价示例", "全部未定价示例",
            ]
            assert [row.locator(".community-rank b").inner_text() for row in rows.all()] == ["01", "02", "03"]
            assert "US$0.30" in rows.nth(0).inner_text()
            assert "已计价部分 US$0.19" in rows.nth(1).inner_text()
            assert "已计价部分为 0 · 覆盖 0%" in rows.nth(2).inner_text()
            assert "费用榜只比较完整计价" not in page.locator(".community-privacy").inner_text()
            assert_no_horizontal_overflow(page)
            page.screenshot(path=str(ARTIFACT_DIR / f"pricing-enabled-rank-{width}.png"), full_page=True)
            rows.nth(1).get_by_role("link", name="部分计价示例").click()
            page.wait_for_load_state("networkidle")
            assert page.locator(".community-profile-rank").inner_text() == "#2"
            assert "已计价部分 US$0.19" in page.locator(".community-extra-totals").inner_text()
            assert_no_horizontal_overflow(page)
        assert not errors, errors
        browser.close()
    print("PASS: partial prices, coverage, cost ranking disabled/enabled, desktop/mobile layouts")


if __name__ == "__main__":
    main()
