#!/usr/bin/env python3
"""Verify the fresh single-admin/empty-ledger Web state at 390 px."""

from __future__ import annotations

import json
import os

from playwright.sync_api import Page, sync_playwright


BASE_URL = os.getenv("TOKENFLEET_LIVE_BASE_URL", "http://127.0.0.1:4311").rstrip("/")
ORG_SLUG = os.getenv("TOKENFLEET_E2E_ORG", "dev-team")
ADMIN_EMAIL = os.getenv("TOKENFLEET_E2E_ADMIN", "admin@example.com")
ADMIN_PASSWORD = os.getenv("TOKENFLEET_E2E_PASSWORD")


def wait_for_heading(page: Page, name: str) -> None:
    page.get_by_role("heading", name=name, exact=True).wait_for()


def assert_no_horizontal_overflow(page: Page, route: str) -> None:
    widths = page.evaluate(
        """() => ({
          document: document.documentElement.scrollWidth,
          viewport: document.documentElement.clientWidth,
        })"""
    )
    if widths["document"] > widths["viewport"] + 1:
        raise AssertionError(f"390px {route} horizontal overflow: {widths}")


def open_route(page: Page, route: str, heading: str) -> None:
    page.goto(f"{BASE_URL}/#/{route}")
    wait_for_heading(page, heading)
    page.locator(".skeleton-grid").wait_for(state="detached")
    page.locator(".page-body").wait_for()
    assert_no_horizontal_overflow(page, route)


def main() -> None:
    if not ADMIN_PASSWORD:
        raise SystemExit("set TOKENFLEET_E2E_PASSWORD; it is never printed")

    console_errors: list[str] = []
    page_errors: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 390, "height": 844})
        page.on(
            "console",
            lambda message: console_errors.append(message.text)
            if message.type == "error"
            else None,
        )
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        try:
            page.goto(BASE_URL)
            wait_for_heading(page, "进入社群管理后台")
            page.locator("#org-slug").fill(ORG_SLUG)
            page.locator("#email").fill(ADMIN_EMAIL)
            page.locator("#password").fill(ADMIN_PASSWORD)
            page.get_by_role("button", name="验证并进入").click()

            wait_for_heading(page, "总览")
            page.locator(".metric-grid").wait_for()
            overview_text = page.locator(".page-body").inner_text()
            assert "这个范围还没有用量" in overview_text
            assert "暂无已登记设备" in overview_text
            assert_no_horizontal_overflow(page, "overview")

            open_route(page, "people", "成员")
            assert page.locator("tbody tr").count() == 1
            assert "1\n名已登记成员" in page.locator(".section-count").inner_text()

            open_route(page, "devices", "设备")
            assert "尚未登记设备" in page.locator(".page-body").inner_text()

            open_route(page, "history", "历史明细")
            assert "这个范围还没有上报记录" in page.locator(".page-body").inner_text()

            open_route(page, "breakdown", "工具与模型")
            assert page.locator(".empty-inline").count() == 2

            open_route(page, "costs", "成本")
            page.locator(".cost-ledger").wait_for()
            assert "还没有配置价格版本" in page.locator(".page-body").inner_text()
        finally:
            browser.close()

    if console_errors or page_errors:
        raise AssertionError(
            json.dumps(
                {"console_errors": console_errors, "page_errors": page_errors},
                ensure_ascii=False,
            )
        )
    print(
        json.dumps(
            {
                "status": "ok",
                "viewport_width": 390,
                "members": 1,
                "devices": 0,
                "usage_rows": 0,
                "routes_checked": 6,
                "horizontal_overflow_routes": 0,
                "console_errors": 0,
                "page_errors": 0,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
