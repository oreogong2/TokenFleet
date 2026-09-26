"""Browser check for partial pricing, frozen ranking, and narrow screens."""
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


def fixture(route):
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
        if parsed.path.endswith("/priced-leaderboard"):
            body = {"entries": [entry], "period": period, "metric": metric,
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
        assert not errors, errors
        browser.close()
    print("PASS: partial prices, coverage, non-comparable cost rank, desktop/mobile layouts")


if __name__ == "__main__":
    main()
