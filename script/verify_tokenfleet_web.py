#!/usr/bin/env python3
"""Real-browser regression for the dependency-free TokenFleet web console."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import Page, sync_playwright


BASE_URL = os.environ.get("TOKENFLEET_WEB_BASE_URL", "http://127.0.0.1:4310").rstrip("/")
REPO_ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = REPO_ROOT / "artifacts" / "web"


def assert_no_horizontal_overflow(page: Page, label: str) -> None:
    dimensions = page.evaluate(
        """() => {
          const originalX = window.scrollX;
          window.scrollTo(10000, window.scrollY);
          const reachableHorizontalScroll = window.scrollX;
          window.scrollTo(originalX, window.scrollY);
          return {
            documentWidth: document.documentElement.scrollWidth,
            viewportWidth: document.documentElement.clientWidth,
            bodyWidth: document.body.scrollWidth,
            reachableHorizontalScroll,
            scrollContainers: [...document.querySelectorAll('.table-scroll')].map((element) => {
              const rect = element.getBoundingClientRect();
              const style = getComputedStyle(element);
              return {
                left: Math.round(rect.left),
                right: Math.round(rect.right),
                width: Math.round(rect.width),
                clientWidth: element.clientWidth,
                scrollWidth: element.scrollWidth,
                overflowX: style.overflowX,
                contain: style.contain,
              };
            }),
            offenders: [...document.querySelectorAll('body *')]
              .filter((element) => !element.closest('.table-scroll'))
              .map((element) => {
                const rect = element.getBoundingClientRect();
                return {
                  tag: element.tagName,
                  className: String(element.className || '').slice(0, 100),
                  left: Math.round(rect.left),
                  right: Math.round(rect.right),
                  width: Math.round(rect.width),
                };
              })
              .filter((item) => item.right > document.documentElement.clientWidth + 1 || item.left < -1)
              .sort((a, b) => b.right - a.right)
              .slice(0, 12),
          };
        }"""
    )
    if dimensions["reachableHorizontalScroll"] > 1 or dimensions["offenders"]:
        raise AssertionError(f"{label} horizontal overflow: {dimensions}")


def wait_for_page(page: Page, heading: str) -> None:
    page.get_by_role("heading", name=heading, exact=True).wait_for()
    page.wait_for_timeout(80)


def verify_desktop(page: Page) -> dict[str, int]:
    page.goto(f"{BASE_URL}/?demo=1#/overview")
    page.wait_for_load_state("networkidle")
    wait_for_page(page, "总览")
    assert page.locator(".demo-banner").is_visible()
    assert "固定假数据" in page.locator(".demo-banner").inner_text()
    assert page.locator(".metric-card").count() == 4
    assert page.locator(".series-chart").count() == 1
    assert_no_horizontal_overflow(page, "overview desktop")
    page.screenshot(path=str(ARTIFACTS / "overview-desktop.png"), full_page=True)

    expected = {
        "成员": "成员",
        "设备": "设备",
        "历史明细": "历史明细",
        "工具与模型": "工具与模型",
        "成本": "成本",
        "设置与隐私": "设置与隐私",
    }
    for nav_name, heading in expected.items():
        page.get_by_role("link", name=nav_name, exact=True).click()
        wait_for_page(page, heading)
        assert_no_horizontal_overflow(page, f"{heading} desktop")

    page.get_by_role("link", name="历史明细", exact=True).click()
    wait_for_page(page, "历史明细")
    history_days = page.locator("details.history-day").count()
    assert history_days >= 20
    first_day = page.locator("details.history-day").first
    assert first_day.get_attribute("open") is not None
    first_text = first_day.inner_text()
    assert "Codex" in first_text and "Claude Code" in first_text
    assert "缓存读" in first_text and "缓存写" in first_text

    page.get_by_role("link", name="成员", exact=True).click()
    wait_for_page(page, "成员")
    page.get_by_role("button", name="单独新建参赛者").click()
    member_dialog = page.locator("#member-dialog")
    member_dialog.wait_for(state="visible")
    member_dialog.locator('input[name="display_name"]').fill("演示回归成员")
    member_dialog.get_by_role("button", name="创建并生成链接").click()
    page.get_by_text("参赛者已创建；请立即复制专属接入材料", exact=True).wait_for()
    assert page.locator("a.person-cell", has_text="演示回归成员").count() == 1
    token_dialog = page.locator("dialog.token-dialog")
    token_dialog.wait_for(state="visible")
    assert token_dialog.locator("code").inner_text() == "••••••••••••"
    assert "demo_once_" not in page.content()
    token_dialog.get_by_role("button", name="关闭").click()

    page.get_by_role("button", name="为已有成员创建设备码").click()
    dialog = page.locator("#enrollment-dialog")
    assert dialog.is_visible()
    dialog.locator('select[name="user_id"]').select_option(index=1)
    dialog.get_by_role("button", name="生成一次性连接码").click()
    token_dialog = page.locator("dialog.token-dialog")
    token_dialog.wait_for(state="visible")
    assert token_dialog.locator("code").inner_text() == "••••••••••••"
    assert "demo_once_" not in page.content()
    token_dialog.get_by_role("button", name="关闭").click()

    page.get_by_role("link", name="设备", exact=True).click()
    wait_for_page(page, "设备")
    first_disable = page.get_by_role("button", name="禁用设备").first
    page.once("dialog", lambda dialog: dialog.accept())
    first_disable.click()
    page.get_by_text("设备已禁用", exact=True).wait_for()
    assert page.get_by_text("已禁用", exact=True).count() >= 1

    page.get_by_role("link", name="设置与隐私", exact=True).click()
    wait_for_page(page, "设置与隐私")
    settings_text = page.locator(".page-body").inner_text()
    assert "不接收、不保存、也不转发" in settings_text
    assert page.locator('input[name*="webhook" i], input[name*="token" i], input[name*="secret" i]').count() == 0
    page.screenshot(path=str(ARTIFACTS / "settings-desktop.png"), full_page=True)

    return {
        "routes": len(expected) + 1,
        "history_days": history_days,
    }


def verify_responsive(page: Page, viewport: dict[str, int], label: str) -> None:
    page.set_viewport_size(viewport)
    page.goto(f"{BASE_URL}/?demo=1#/overview")
    page.wait_for_load_state("networkidle")
    wait_for_page(page, "总览")
    assert_no_horizontal_overflow(page, f"overview {label}")
    if viewport["width"] <= 820:
        nav_names = page.locator(".sidebar nav a").evaluate_all(
            "elements => elements.map((element) => element.getAttribute('aria-label') || element.getAttribute('title') || '')"
        )
        assert nav_names and all(name.strip() for name in nav_names), nav_names
    page.screenshot(path=str(ARTIFACTS / f"overview-{label}.png"), full_page=True)

    page.goto(f"{BASE_URL}/?demo=1#/history")
    page.wait_for_load_state("networkidle")
    wait_for_page(page, "历史明细")
    assert_no_horizontal_overflow(page, f"history {label}")

    page.goto(f"{BASE_URL}/?demo=1#/devices")
    page.wait_for_load_state("networkidle")
    wait_for_page(page, "设备")
    assert_no_horizontal_overflow(page, f"devices {label}")


def verify_login(page: Page) -> None:
    page.set_viewport_size({"width": 1280, "height": 850})
    page.goto(BASE_URL)
    page.wait_for_load_state("networkidle")
    page.get_by_role("heading", name="进入社群管理后台").wait_for()
    assert page.locator("#org-slug").is_visible()
    assert page.locator("#email").is_visible()
    secret = page.locator("#password")
    assert secret.get_attribute("type") == "password"
    page.get_by_role("button", name="显示或隐藏密码").click()
    assert secret.get_attribute("type") == "text"
    assert page.get_by_role("link", name="没有服务端？打开隔离演示模式").is_visible()
    assert_no_horizontal_overflow(page, "login")


def edge_payloads(mode: str) -> dict[str, object]:
    long_value = "超长模型-" + "x" * 118
    long_tool = "Claude Code Experimental Client " + "y" * 96
    display_name = "单成员" if mode == "empty" else "极端数据显示成员-" + "名" * 108
    user = {
        "id": "edge-user",
        "org_id": "edge-org",
        "email": "edge@example.com",
        "display_name": display_name,
        "role": "admin",
        "is_active": True,
    }
    participant = {
        "id": "edge-participant",
        "org_id": "edge-org",
        "email": None,
        "display_name": "边界参赛者",
        "role": "member",
        "is_active": True,
        "can_login": False,
        "public_id": "edge-public-participant",
        "public_profile_enabled": False,
    }
    organization = {
        "id": "edge-org",
        "slug": "edge-team",
        "name": "边界场景社群",
        "default_timezone": "America/Los_Angeles",
        "retention_days": 365,
        "ledger_version": 1,
    }
    if mode == "empty":
        rows: list[dict[str, object]] = []
        devices: list[dict[str, object]] = []
        totals = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "priced_costs_microunits": {},
            "unpriced_rows": 0,
        }
    else:
        devices = [
            {
                "id": "edge-device",
                "user_id": user["id"],
                "device_public_id": "123e4567-e89b-12d3-a456-426614174000",
                "platform": "macos",
                "app_version": "0.2.0-edge",
                "collector_version": "0.2.0-edge",
                "is_active": True,
                "last_successful_sync_at": "2026-08-09T03:00:00Z",
            }
        ]
        rows = [
            {
                "id": "edge-row",
                "date": "2026-08-09",
                "timezone": "America/Los_Angeles",
                "user_id": user["id"],
                "device_id": devices[0]["id"],
                "tool": long_tool,
                "model": long_value,
                "source": "local",
                "completeness": "exact",
                "input_tokens": 9_000_000_000_000_000,
                "output_tokens": 9_000_000_000_000_000,
                "cache_read_tokens": 9_000_000_000_000_000,
                "cache_write_tokens": 9_000_000_000_000_000,
                "cost_microunits": 9_000_000_000_000_000,
                "cost_currency": "USD",
            }
        ]
        totals = {
            "input_tokens": 9_000_000_000_000_000,
            "output_tokens": 9_000_000_000_000_000,
            "cache_read_tokens": 9_000_000_000_000_000,
            "cache_write_tokens": 9_000_000_000_000_000,
            "priced_costs_microunits": {"USD": 9_000_000_000_000_000},
            "unpriced_rows": 0,
        }
    return {
        "/api/v1/me": user,
        "/api/v1/organization": organization,
        "/api/v1/users": [user, participant],
        "/api/v1/devices": devices,
        "/api/v1/dashboard": {
            "rows": rows,
            "totals": totals,
            "organization_timezone": organization["default_timezone"],
            "timezone_warning": None,
        },
        "/api/v1/pricing": [],
        "long_model": long_value,
    }


def contrast_samples(page: Page) -> list[dict[str, object]]:
    return page.evaluate(
        """() => {
          const selectors = ['.page-header p', '.metric-card p', 'th', '.nav-item.active'];
          const parse = (value) => {
            const parts = String(value).match(/[\\d.]+/g)?.map(Number) || [];
            return [parts[0] || 0, parts[1] || 0, parts[2] || 0, parts[3] ?? 1];
          };
          const blend = (front, back) => [
            front[0] * front[3] + back[0] * (1 - front[3]),
            front[1] * front[3] + back[1] * (1 - front[3]),
            front[2] * front[3] + back[2] * (1 - front[3]),
            1,
          ];
          const background = (element) => {
            const layers = [];
            for (let node = element; node; node = node.parentElement) {
              layers.push(parse(getComputedStyle(node).backgroundColor));
            }
            let result = [255, 255, 255, 1];
            for (const layer of layers.reverse()) result = blend(layer, result);
            return result;
          };
          const luminance = (color) => {
            const channels = color.slice(0, 3).map((value) => {
              const normalized = value / 255;
              return normalized <= .03928
                ? normalized / 12.92
                : ((normalized + .055) / 1.055) ** 2.4;
            });
            return .2126 * channels[0] + .7152 * channels[1] + .0722 * channels[2];
          };
          return selectors.map((selector) => {
            const element = document.querySelector(selector);
            if (!element) return { selector, missing: true, pass: false };
            const style = getComputedStyle(element);
            const foreground = parse(style.color);
            const back = background(element);
            const light = Math.max(luminance(foreground), luminance(back));
            const dark = Math.min(luminance(foreground), luminance(back));
            const ratio = (light + .05) / (dark + .05);
            const fontSize = parseFloat(style.fontSize);
            const fontWeight = Number(style.fontWeight) || 400;
            const threshold = fontSize >= 24 || (fontSize >= 18.66 && fontWeight >= 700) ? 3 : 4.5;
            return { selector, ratio, threshold, pass: ratio >= threshold };
          });
        }"""
    )


def verify_mock_states(page: Page) -> dict[str, object]:
    scenario = {"mode": "empty"}
    seen_paths: list[str] = []
    mutation_counts = {"enrollment": 0}

    def handle_api(route) -> None:
        mode = scenario["mode"]
        path = urlparse(route.request.url).path
        seen_paths.append(path)
        if route.request.method == "POST" and path == "/api/v1/enrollment-tokens":
            mutation_counts["enrollment"] += 1
            route.fulfill(
                status=201,
                content_type="application/json",
                body=json.dumps(
                    {
                        "enrollment_token": "edge_once_only",
                        "expires_at": "2026-08-10T00:00:00Z",
                    }
                ),
            )
            return
        if mode == "service503":
            route.fulfill(
                status=503,
                content_type="application/json",
                body=json.dumps({"detail": "服务暂时不可用"}),
            )
            return
        if mode in {"expired401", "forbidden403"} and path == "/api/v1/me":
            status = 401 if mode == "expired401" else 403
            route.fulfill(
                status=status,
                content_type="application/json",
                body=json.dumps({"detail": "会话已过期" if status == 401 else "账号已禁用"}),
            )
            return
        if mode == "invalid_login" and path == "/api/v1/auth/token":
            route.fulfill(
                status=401,
                content_type="application/json",
                body=json.dumps({"detail": "账号或密码错误"}),
            )
            return
        payloads = edge_payloads("long" if mode == "long" else "empty")
        if path not in payloads:
            route.fulfill(
                status=404,
                content_type="application/json",
                body=json.dumps({"detail": "mock endpoint missing"}),
            )
            return
        route.fulfill(
            status=200,
            content_type="application/json",
            body=json.dumps(payloads[path], ensure_ascii=False),
        )

    page.route("**/api/v1/**", handle_api)
    page.add_init_script(
        """if (window.name !== 'tokenfleet-no-auto-key') {
          sessionStorage.setItem('tokenfleet.apiKey', 'edge-session-only');
        }"""
    )
    page.evaluate("sessionStorage.setItem('tokenfleet.apiKey', 'edge-session-only')")

    page.goto(f"{BASE_URL}/?edge=empty#/overview")
    page.wait_for_load_state("networkidle")
    wait_for_page(page, "总览")
    assert {
        "/api/v1/me",
        "/api/v1/organization",
        "/api/v1/dashboard",
        "/api/v1/devices",
        "/api/v1/users",
    } <= set(seen_paths), seen_paths
    page.get_by_text("单成员", exact=True).wait_for()
    page.goto(f"{BASE_URL}/#/devices")
    wait_for_page(page, "设备")
    assert "尚未登记设备" in page.locator(".page-body").inner_text()
    page.goto(f"{BASE_URL}/#/history")
    wait_for_page(page, "历史明细")
    assert "这个范围还没有上报记录" in page.locator(".page-body").inner_text()
    page.goto(f"{BASE_URL}/#/costs")
    wait_for_page(page, "成本")
    assert "还没有配置价格版本" in page.locator(".page-body").inner_text()
    page.goto(f"{BASE_URL}/#/people")
    wait_for_page(page, "成员")
    page.get_by_role("button", name="为已有成员创建设备码").click()
    enrollment_dialog = page.locator("#enrollment-dialog")
    enrollment_select = enrollment_dialog.locator('select[name="user_id"]')
    assert enrollment_select.locator('option[value="edge-user"]').count() == 0
    enrollment_select.select_option("edge-participant")
    enrollment_submit = enrollment_dialog.get_by_role("button", name="生成一次性连接码")
    enrollment_submit.evaluate("button => { button.click(); button.click(); }")
    page.locator("dialog.token-dialog").wait_for(state="visible")
    assert mutation_counts["enrollment"] == 1, mutation_counts
    page.locator("dialog.token-dialog").get_by_role("button", name="关闭").click()

    scenario["mode"] = "long"
    page.set_viewport_size({"width": 390, "height": 844})
    page.goto(f"{BASE_URL}/?edge=long#/overview")
    wait_for_page(page, "总览")
    page.get_by_text("极端数据显示成员", exact=False).first.wait_for()
    assert_no_horizontal_overflow(page, "edge overview mobile")
    page.goto(f"{BASE_URL}/#/breakdown")
    wait_for_page(page, "工具与模型")
    long_model = str(edge_payloads("long")["long_model"])
    assert page.locator(".distribution-row strong", has_text=long_model).count() == 1
    assert_no_horizontal_overflow(page, "long model breakdown mobile")
    page.goto(f"{BASE_URL}/#/history")
    wait_for_page(page, "历史明细")
    assert long_model in page.locator(".page-body").inner_text()
    assert_no_horizontal_overflow(page, "large token history mobile")

    page.set_viewport_size({"width": 1280, "height": 900})
    page.emulate_media(reduced_motion="reduce")
    page.goto(f"{BASE_URL}/#/overview")
    wait_for_page(page, "总览")
    reduced_duration = page.locator(".nav-item").first.evaluate(
        "element => getComputedStyle(element).transitionDuration"
    )
    reduced_seconds = [
        float(item[:-2]) / 1_000 if item.endswith("ms") else float(item[:-1])
        for item in reduced_duration.split(", ")
    ]
    assert max(reduced_seconds, default=0) <= 0.00002, reduced_duration
    unnamed = page.evaluate(
        """() => [...document.querySelectorAll('a,button,input,select,summary')]
          .filter((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && !element.disabled;
          })
          .filter((element) => {
            const label = element.getAttribute('aria-label')
              || element.getAttribute('title')
              || [...(element.labels || [])].map((item) => item.innerText).join(' ')
              || element.innerText
              || element.value;
            return !String(label || '').trim();
          })
          .map((element) => element.outerHTML.slice(0, 160))"""
    )
    assert unnamed == []
    skip = page.locator(".skip-link")
    page.evaluate("document.body.tabIndex = -1; document.body.focus()")
    page.keyboard.press("Tab")
    assert page.evaluate("document.activeElement?.classList.contains('skip-link')")
    # Reduced-motion disables transitions entirely, so the skip link must be
    # visible in the same frame it receives keyboard focus.
    skip_focus = skip.evaluate(
        """element => {
          const style = getComputedStyle(element);
          return {
            focused: element.matches(':focus'),
            focusVisible: element.matches(':focus-visible'),
            outlineStyle: style.outlineStyle,
            outlineWidth: parseFloat(style.outlineWidth),
            transform: style.transform,
            top: Math.round(element.getBoundingClientRect().top),
            stylesheetHrefs: [...document.styleSheets].map((sheet) => sheet.href),
            hasSkipFocusRule: [...document.styleSheets].some((sheet) =>
              [...sheet.cssRules].some((rule) => rule.cssText.includes('.skip-link:focus'))
            ),
          };
        }"""
    )
    assert skip_focus["focused"] and skip_focus["top"] >= 0, skip_focus
    assert skip_focus["outlineStyle"] != "none" and skip_focus["outlineWidth"] >= 2, skip_focus
    page.keyboard.press("Enter")
    page.wait_for_timeout(100)
    assert page.evaluate("document.activeElement?.id") == "main-content"
    contrast = contrast_samples(page)
    assert all(item["pass"] for item in contrast), contrast
    page.goto(f"{BASE_URL}/#/people")
    wait_for_page(page, "成员")
    open_member = page.get_by_role("button", name="单独新建参赛者")
    open_member.focus()
    page.keyboard.press("Enter")
    dialog = page.locator("#member-dialog")
    dialog.wait_for(state="visible")
    assert page.evaluate("document.activeElement?.closest('dialog')?.id") == "member-dialog"
    page.keyboard.press("Escape")
    dialog.wait_for(state="hidden")

    for mode, expected in (("expired401", "会话已过期"), ("forbidden403", "账号已禁用")):
        scenario["mode"] = mode
        page.goto(f"{BASE_URL}/?edge={mode}")
        page.get_by_role("heading", name="进入社群管理后台").wait_for()
        assert expected in page.locator(".inline-alert").inner_text()
        assert not page.evaluate("Boolean(sessionStorage.getItem('tokenfleet.apiKey'))")

    scenario["mode"] = "service503"
    page.goto(f"{BASE_URL}/?edge=service503")
    page.get_by_role("heading", name="进入社群管理后台").wait_for()
    assert "服务暂时不可用" in page.locator(".inline-alert").inner_text()
    assert page.evaluate("Boolean(sessionStorage.getItem('tokenfleet.apiKey'))")
    scenario["mode"] = "empty"
    page.reload()
    wait_for_page(page, "总览")

    scenario["mode"] = "invalid_login"
    page.evaluate(
        """() => {
          window.name = 'tokenfleet-no-auto-key';
          sessionStorage.clear();
        }"""
    )
    page.goto(f"{BASE_URL}/?edge=invalid-login")
    page.get_by_role("heading", name="进入社群管理后台").wait_for()
    page.locator("#org-slug").fill("edge-team")
    page.locator("#email").fill("edge@example.com")
    page.locator("#password").fill("wrong-password")
    page.get_by_role("button", name="验证并进入").click()
    assert "账号或密码错误" in page.locator(".inline-alert").inner_text()
    assert not page.evaluate("Boolean(sessionStorage.getItem('tokenfleet.apiKey'))")
    page.evaluate("window.name = ''")

    return {
        "data_scenarios": ["empty", "single", "long-model", "max-token"],
        "auth_states": [401, 403, 503, "invalid-login", "recovery"],
        "keyboard_focus": True,
        "reduced_motion": True,
        "contrast_samples": len(contrast),
    }


def main() -> None:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    console_errors: list[str] = []
    page_errors: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 1000})
        page.on(
            "console",
            lambda message: console_errors.append(message.text)
            if message.type == "error"
            else None,
        )
        page.on("pageerror", lambda error: page_errors.append(str(error)))

        try:
            result = verify_desktop(page)
            verify_responsive(page, {"width": 820, "height": 1000}, "tablet")
            verify_responsive(page, {"width": 390, "height": 844}, "mobile")
            verify_login(page)
            if console_errors or page_errors:
                raise AssertionError(
                    f"unexpected browser errors before failure-state checks: {console_errors!r} {page_errors!r}"
                )
            edge_result = verify_mock_states(page)
            expected_statuses = ("401 (Unauthorized)", "403 (Forbidden)", "503 (Service Unavailable)")
            unexpected_edge_errors = [
                message for message in console_errors if not any(status in message for status in expected_statuses)
            ]
            if unexpected_edge_errors or page_errors:
                raise AssertionError(
                    f"unexpected browser errors during failure-state checks: "
                    f"{unexpected_edge_errors!r} {page_errors!r}"
                )
            if not all(any(status in message for message in console_errors) for status in expected_statuses):
                raise AssertionError(f"not every expected HTTP failure was exercised: {console_errors!r}")
            edge_result["expected_http_failures"] = len(console_errors)
            console_errors.clear()
        except Exception:
            page.screenshot(path=str(ARTIFACTS / "failure.png"), full_page=True)
            print(
                json.dumps(
                    {
                        "console_errors": console_errors,
                        "page_errors": page_errors,
                        "body": page.locator("body").inner_text()[:2000],
                        "url": page.url,
                    },
                    ensure_ascii=False,
                    indent=2,
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
                indent=2,
            )
        )
    print(
        json.dumps(
            {
                "status": "ok",
                **result,
                **edge_result,
                "viewports": ["1440x1000", "820x1000", "390x844"],
                "console_errors": 0,
                "page_errors": 0,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
