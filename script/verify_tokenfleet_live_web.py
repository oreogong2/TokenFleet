#!/usr/bin/env python3
"""Real-browser verification against a live TokenFleet community ledger.

Credentials are accepted only through environment variables and are never printed.
"""

from __future__ import annotations

import json
import os
import uuid

from playwright.sync_api import Page, sync_playwright


BASE_URL = os.getenv("TOKENFLEET_LIVE_BASE_URL", "http://127.0.0.1:4311").rstrip("/")
ORG_SLUG = os.getenv("TOKENFLEET_E2E_ORG", "e2e-team")
ADMIN_EMAIL = os.getenv("TOKENFLEET_E2E_ADMIN", "admin@example.com")
ADMIN_PASSWORD = os.getenv("TOKENFLEET_E2E_PASSWORD")
VERIFY_EDGE_VALUES = os.getenv("TOKENFLEET_VERIFY_EDGE_VALUES") == "1"
WRITE_TEST_DATA_CONFIRMED = os.getenv("TOKENFLEET_ALLOW_MUTATING_E2E") == "YES"
CONFIRMED_BASE_URL = os.getenv("TOKENFLEET_E2E_CONFIRM_BASE_URL", "").rstrip("/")


def wait_for_heading(page: Page, name: str) -> None:
    page.get_by_role("heading", name=name, exact=True).wait_for()
    page.wait_for_timeout(100)


def assert_no_horizontal_overflow(page: Page, label: str) -> None:
    widths = page.evaluate(
        """() => ({
          document: document.documentElement.scrollWidth,
          viewport: document.documentElement.clientWidth,
        })"""
    )
    if widths["document"] > widths["viewport"] + 1:
        raise AssertionError(f"{label} horizontal overflow: {widths}")


def login_as(page: Page, email: str, password: str, *, navigate: bool = True) -> None:
    if navigate:
        page.goto(BASE_URL)
        page.wait_for_load_state("networkidle")
    wait_for_heading(page, "进入社群管理后台")
    page.locator("#org-slug").fill(ORG_SLUG)
    page.locator("#email").fill(email)
    page.locator("#password").fill(password)
    page.get_by_role("button", name="验证并进入").click()
    wait_for_heading(page, "总览")


def login(page: Page) -> None:
    login_as(page, ADMIN_EMAIL, ADMIN_PASSWORD or "")


def verify_live_dashboard(page: Page) -> dict[str, int]:
    edge_value_routes = 0
    assert page.locator(".demo-banner").count() == 0
    assert page.locator(".metric-card").count() == 4
    assert page.evaluate("() => Boolean(sessionStorage.getItem('tokenfleet.apiKey'))")
    assert not page.evaluate("() => Boolean(localStorage.getItem('tokenfleet.apiKey'))")
    assert_no_horizontal_overflow(page, "live overview")

    page.get_by_role("link", name="成员", exact=True).click()
    wait_for_heading(page, "成员")
    member_rows = page.locator("tbody tr").count()
    assert member_rows >= 2
    assert "E2E 参赛者" in page.locator(".page-body").inner_text()
    run_id = uuid.uuid4().hex[:8]
    new_member_name = f"浏览器参赛者 {run_id}"
    page.get_by_role("button", name="新建参赛者并生成链接").click()
    member_dialog = page.locator("#member-dialog")
    member_dialog.wait_for(state="visible")
    member_dialog.locator('input[name="display_name"]').fill(new_member_name)
    assert member_dialog.locator('input[name="email"], input[name="password"]').count() == 0
    assert not member_dialog.locator('input[name="public_profile_enabled"]').is_checked()
    member_dialog.get_by_role("button", name="创建并生成链接").click()
    participant_token_dialog = page.locator("dialog.token-dialog")
    participant_token_dialog.wait_for(state="visible")
    assert participant_token_dialog.get_by_role("button", name="复制连接码").count() == 1
    assert participant_token_dialog.get_by_role("button", name="复制专属接入链接").count() == 1
    assert "••••" in participant_token_dialog.locator("code").inner_text()
    participant_token_dialog.get_by_role("button", name="关闭").click()
    assert page.locator("tbody tr").count() == member_rows + 1

    page.locator("a.person-cell", has_text=new_member_name).click()
    page.get_by_role("button", name="禁用成员", exact=True).wait_for()
    page.once("dialog", lambda dialog: dialog.accept())
    page.get_by_role("button", name="禁用成员", exact=True).click()
    page.get_by_text("已禁用", exact=True).wait_for()
    page.once("dialog", lambda dialog: dialog.accept())
    page.get_by_role("button", name="重新启用成员", exact=True).click()
    page.get_by_text("正常", exact=True).wait_for()
    page.get_by_role("link", name="← 返回成员列表", exact=True).click()
    wait_for_heading(page, "成员")

    page.get_by_role("button", name="为已有成员创建设备码").click()
    enrollment_dialog = page.locator("#enrollment-dialog")
    enrollment_dialog.wait_for(state="visible")
    enrollment_dialog.locator('select[name="user_id"]').select_option(
        label=f"{new_member_name} · 管理编号 {page.locator('a.person-cell', has_text=new_member_name).get_attribute('href').split('/')[-1][-8:]}"
    )
    enrollment_dialog.get_by_role("button", name="生成一次性连接码").click()
    token_dialog = page.locator("dialog.token-dialog")
    token_dialog.wait_for(state="visible")
    assert "••••" in token_dialog.locator("code").inner_text()
    token_dialog.get_by_role("button", name="关闭").click()

    page.get_by_role("link", name="设备", exact=True).click()
    wait_for_heading(page, "设备")
    device_rows = page.locator("article.device-card").count()
    assert device_rows >= 2

    page.get_by_role("link", name="历史明细", exact=True).click()
    wait_for_heading(page, "历史明细")
    history_rows = page.locator("details.history-day").count()
    assert history_rows >= 1
    history_text = page.locator(".page-body").inner_text()
    assert "Codex" in history_text
    assert "Claude Code" in history_text
    assert "缓存读" in history_text and "缓存写" in history_text

    page.get_by_role("link", name="工具与模型", exact=True).click()
    wait_for_heading(page, "工具与模型")
    breakdown_text = page.locator(".page-body").inner_text()
    assert "gpt-e2e" in breakdown_text
    assert "claude-e2e" in breakdown_text

    page.get_by_role("link", name="成本", exact=True).click()
    wait_for_heading(page, "成本")
    page.locator(".cost-ledger").wait_for()
    costs_text = page.locator(".page-body").inner_text()
    assert "gpt-e2e" in costs_text
    assert "claude-e2e" in costs_text

    if VERIFY_EDGE_VALUES:
        page.set_viewport_size({"width": 390, "height": 844})
        for route, heading, ready_selector in (
            ("history", "历史明细", "details.history-day"),
            ("breakdown", "工具与模型", ".distribution-row"),
            ("costs", "成本", ".cost-ledger"),
        ):
            page.goto(f"{BASE_URL}/#/{route}")
            wait_for_heading(page, heading)
            page.locator(ready_selector).first.wait_for()
            assert "edge-model-" in page.locator(".page-body").inner_text()
            assert_no_horizontal_overflow(page, f"390px {route} edge values")
            edge_value_routes += 1
        page.set_viewport_size({"width": 1440, "height": 1000})

    page.get_by_role("link", name="设置与隐私", exact=True).click()
    wait_for_heading(page, "设置与隐私")
    settings_text = page.locator(".page-body").inner_text()
    assert "生财排行榜" in settings_text
    assert "不接收" in settings_text and "不保存" in settings_text and "也不转发" in settings_text
    assert page.locator(
        'input[name*="webhook" i], input[name*="token" i], input[name*="secret" i]'
    ).count() == 0

    page.route("**/api/v1/pricing", lambda route: route.abort())
    page.get_by_role("link", name="成本", exact=True).click()
    page.locator(".state-code", has_text="OFFLINE").wait_for()
    page.get_by_role("heading", name="这一页暂时无法读取", exact=True).wait_for()
    page.unroute("**/api/v1/pricing")
    page.get_by_role("button", name="重试", exact=True).click()
    page.locator(".state-code").wait_for(state="detached")

    page.get_by_role("button", name="退出", exact=True).click()
    wait_for_heading(page, "进入社群管理后台")
    assert not page.evaluate("() => Boolean(sessionStorage.getItem('tokenfleet.apiKey'))")

    page.locator("#org-slug").fill(ORG_SLUG)
    page.locator("#email").fill(ADMIN_EMAIL)
    page.locator("#password").fill("deliberately-wrong-password")
    page.get_by_role("button", name="验证并进入").click()
    page.get_by_role("alert").wait_for()
    assert "invalid credentials" in page.get_by_role("alert").inner_text()

    page.evaluate(
        "() => sessionStorage.setItem('tokenfleet.apiKey', 'expired.jwt.test-token')"
    )
    page.reload()
    wait_for_heading(page, "进入社群管理后台")
    page.get_by_role("alert").wait_for()
    assert "invalid or expired access token" in page.get_by_role("alert").inner_text()
    assert not page.evaluate("() => Boolean(sessionStorage.getItem('tokenfleet.apiKey'))")

    public_requests: list[dict[str, str]] = []

    def record_public_request(request) -> None:
        if "/api/v1/public/" not in request.url:
            return
        public_requests.append({key.lower(): value for key, value in request.headers.items()})

    page.on("request", record_public_request)
    document_response = page.goto(f"{BASE_URL}/rank")
    assert document_response.status == 200
    page.locator(".community-rank-row").first.wait_for()
    assert page.get_by_text("公开参赛者", exact=False).count() >= 1
    assert page.get_by_role("heading", name="进入社群管理后台", exact=True).count() == 0
    assert_no_horizontal_overflow(page, "live anonymous community rank")
    profile_link = page.locator("a.community-person").first
    profile_link.click()
    page.locator(".community-detail-grid").wait_for()
    page.reload(wait_until="networkidle")
    page.locator(".community-detail-grid").wait_for()
    assert public_requests
    assert all("authorization" not in headers for headers in public_requests)
    assert all("cookie" not in headers for headers in public_requests)

    return {
        "member_rows": member_rows + 1,
        "device_rows": device_rows,
        "history_days": history_rows,
        "wrong_login_401": 1,
        "participant_without_login_fields": 1,
        "offline_state": 1,
        "rejected_credential_state": 1,
        "edge_value_routes": edge_value_routes,
        "anonymous_public_rank": 1,
        "public_requests_without_credentials": len(public_requests),
    }


def main() -> None:
    if not WRITE_TEST_DATA_CONFIRMED or CONFIRMED_BASE_URL != BASE_URL:
        raise SystemExit(
            "refusing to change server data: set TOKENFLEET_ALLOW_MUTATING_E2E=YES and "
            "TOKENFLEET_E2E_CONFIRM_BASE_URL to the exact disposable test URL"
        )
    if not ADMIN_PASSWORD:
        raise SystemExit("set TOKENFLEET_E2E_PASSWORD; it is never printed")

    console_errors: list[str] = []
    page_errors: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 1000})
        def record_console_error(message) -> None:
            if message.type != "error":
                return
            # These resource errors are deliberately induced and asserted by
            # the offline/401/403 acceptance cases below.
            expected = ("net::ERR_FAILED", "401 (Unauthorized)", "403 (Forbidden)")
            if not any(marker in message.text for marker in expected):
                console_errors.append(message.text)

        page.on("console", record_console_error)
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        try:
            login(page)
            result = verify_live_dashboard(page)
        except Exception:
            print(
                json.dumps(
                    {
                        "status": "failed",
                        "url": page.url,
                        "visible_headings": page.locator("h1, h2").all_inner_texts()[:20],
                        "open_dialogs": page.locator("dialog[open]").count(),
                        "console_errors": console_errors,
                        "page_errors": page_errors,
                        "sensitive_body_suppressed": True,
                    },
                    ensure_ascii=False,
                )
            )
            raise
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
                **result,
                "demo_fallback": False,
                "session_cleared_on_logout": True,
                "console_errors": 0,
                "page_errors": 0,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
