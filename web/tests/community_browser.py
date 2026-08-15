"""Headless browser regression for anonymous community and secure join pages."""

from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import re
import struct
import time
from threading import Thread
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright


VALID_CODE = "Abcd_0123456789-abcdefghijklmnop"
SECOND_VALID_CODE = "Zyxw_9876543210-ponmlkjihgfedcba"
BATCH_INVITATION = "Batch_0123456789-abcdefghijklmnop"
PERSONAL_DEVICE_CODE = "Personal_0123456789-abcdefghijklmnop"
ARTIFACT_DIR = Path(os.environ.get("TOKENFLEET_BROWSER_ARTIFACTS", "/tmp"))
ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
WEB_ROOT = Path(__file__).resolve().parents[1]


class CommunityStaticHandler(SimpleHTTPRequestHandler):
    """Serve static assets and return index.html for anonymous SPA deep links."""

    pricing_delay_seconds = 0
    batch_claims = []

    def send_json(self, payload, delay=0):
        if delay:
            time.sleep(delay)
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/api/v1/me":
            self.send_json({"id": "admin-1", "display_name": "管理员", "role": "admin"})
            return
        if path == "/api/v1/organization":
            self.send_json({
                "id": "org-1", "name": "测试社群",
                "default_timezone": "Asia/Shanghai", "retention_days": 365,
            })
            return
        if path == "/api/v1/devices":
            self.send_json([])
            return
        if path == "/api/v1/dashboard":
            self.send_json({"rows": []})
            return
        if path == "/api/v1/users":
            self.send_json([
                {"id": "admin-1", "display_name": "管理员", "role": "admin"},
                {"id": "member-1", "display_name": "成员", "role": "member", "status": "active"},
            ])
            return
        if path == "/api/v1/pricing":
            self.send_json(
                {"items": []}, delay=type(self).pricing_delay_seconds
            )
            return
        if path in {"/join", "/install"} or re.fullmatch(r"/join/batch(?:/[^/?#]+)?", path) or re.fullmatch(
            r"/(?:rank|community)(?:/p/[A-Za-z0-9_-]{1,128})?", path
        ):
            self.path = "/index.html"
        super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path != "/api/v1/public/invitation-batches/claim":
            self.send_error(404)
            return
        content_length = int(self.headers.get("Content-Length", "0"))
        assert 0 < content_length <= 4096
        payload = json.loads(self.rfile.read(content_length))
        type(self).batch_claims.append({
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "payload": payload,
        })
        body = json.dumps({
            "nickname": payload.get("display_name", "浏览器成员"),
            "enrollment_token": PERSONAL_DEVICE_CODE,
            "expires_at": "2026-08-10T13:00:00Z",
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


@contextmanager
def browser_base():
    configured = os.environ.get("TOKENFLEET_BROWSER_BASE", "").rstrip("/")
    if configured:
        yield configured
        return
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0),
        partial(CommunityStaticHandler, directory=str(WEB_ROOT)),
    )
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def assert_no_horizontal_overflow(page):
    overflow = page.evaluate(
        """() => ({
          viewport: document.documentElement.clientWidth,
          body: document.body.scrollWidth,
          html: document.documentElement.scrollWidth,
        })"""
    )
    assert overflow["body"] <= overflow["viewport"] + 1, overflow
    assert overflow["html"] <= overflow["viewport"] + 1, overflow


def assert_accessible_controls(page):
    controls = page.locator('button, a, input:not([type="hidden"]), select')
    for index in range(controls.count()):
        control = controls.nth(index)
        assert control.evaluate(
            """el => Boolean(
              el.getAttribute('aria-label') ||
              el.getAttribute('title') ||
              el.textContent.trim() ||
              el.labels?.[0]?.textContent.trim() ||
              el.getAttribute('placeholder')
            )"""
        ), control.evaluate("el => el.outerHTML")


def png_dimensions(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", data[16:24])


def main():
    CommunityStaticHandler.batch_claims = []
    with browser_base() as base, sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        context = browser.new_context(accept_downloads=True)
        page = context.new_page()
        errors = []
        console_messages = []
        resource_status = {}
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("console", lambda message: console_messages.append(message.text))
        page.on(
            "response",
            lambda response: resource_status.__setitem__(
                urlparse(response.url).path, response.status
            ),
        )

        page.set_viewport_size({"width": 1440, "height": 900})
        page.goto(f"{base}/?demo=1#/rank", wait_until="networkidle")
        page.get_by_role("link", name="安装与参与", exact=True).click()
        page.locator(".install-contact").wait_for()
        assert page.url.endswith("#/install")

        for width in (390, 820, 1440):
            page.set_viewport_size({"width": width, "height": 900})
            page.goto(f"{base}/?demo=1#/rank", wait_until="networkidle")
            page.locator(".community-rank-row").first.wait_for()
            assert page.locator(".community-rank-row").count() == 12
            assert page.locator(".community-model-summary").count() == 12
            assert page.get_by_text("主力工具", exact=True).count() == 12
            assert page.get_by_text("主力模型", exact=True).count() == 12
            assert page.get_by_text("共 2 个工具", exact=False).count() == 12
            assert page.get_by_text("共 2 个模型", exact=False).count() == 12
            first_summary = page.locator(".community-model-summary").first.inner_text()
            assert first_summary.index("主力工具") < first_summary.index("主力模型")
            assert "900719" not in page.locator(".community-rank-row").nth(1).inner_text()
            assert page.get_by_text("未定价", exact=True).count() >= 1
            assert page.get_by_text("演示·这是一个专门验证窄屏截断", exact=False).count() == 1
            assert page.get_by_text("演示数据 · 不是真实排名或真实成员数据", exact=True).count() == 1
            assert page.locator('input[name="tool"], input[name="model"]').count() == 0
            assert page.get_by_role("link", name="CC Switch", exact=True).count() == 1
            assert page.get_by_role("link", name="kimi-k2", exact=True).count() == 1
            assert page.get_by_role("link", name="全部工具（3）", exact=True).count() == 1
            assert page.get_by_role("link", name="全部模型（6）", exact=True).count() == 1
            assert page.get_by_role("button", name="应用筛选").count() == 0
            assert page.get_by_role("link", name="安装与参与", exact=True).count() == 1
            assert page.get_by_text("未跨时区重新归日", exact=False).count() == 1
            if width == 1440:
                headline = page.locator(".community-hero h1")
                metrics = headline.evaluate(
                    """element => ({
                        height: element.getBoundingClientRect().height,
                        lineHeight: Number.parseFloat(getComputedStyle(element).lineHeight),
                    })"""
                )
                assert metrics["height"] < metrics["lineHeight"] * 1.5, metrics
            assert_no_horizontal_overflow(page)
            assert_accessible_controls(page)
            page.screenshot(path=str(ARTIFACT_DIR / f"tokenfleet-rank-{width}.png"), full_page=True)

            page.keyboard.press("Tab")
            focused = page.evaluate("document.activeElement?.tagName")
            assert focused in {"A", "BUTTON", "INPUT", "SELECT", "MAIN"}, focused

        for width in (390, 820, 1440):
            page.set_viewport_size({"width": width, "height": 900})
            page.goto(f"{base}/?demo=1#/install", wait_until="networkidle")
            page.locator(".install-contact").wait_for()
            assert page.get_by_role("heading", name="安装只是第一步， 领取邀请码才算加入。").count() == 1
            assert page.get_by_text("只下载安装不会自动加入", exact=False).count() == 1
            assert page.get_by_text("没有邀请码，安装后仍无法加入社群。", exact=True).count() == 1
            assert page.get_by_text("诗奥", exact=False).count() == 0
            assert page.get_by_text("奥哥", exact=False).count() == 0
            assert page.get_by_role("img", name="扫码添加微信领取邀请码二维码", exact=True).count() == 1
            qr_layout = page.locator(".install-qr-frame").evaluate(
                """frame => {
                  const image = frame.querySelector('img');
                  const outer = frame.getBoundingClientRect();
                  const inner = image.getBoundingClientRect();
                  return {
                    square: Math.abs(outer.width - outer.height),
                    intrinsicSquare: image.naturalWidth === image.naturalHeight,
                    intrinsicWidth: image.naturalWidth,
                    contained: Math.abs(inner.width - frame.clientWidth) <= 1
                      && Math.abs(inner.height - frame.clientHeight) <= 1,
                  };
                }"""
            )
            assert qr_layout["square"] <= 1, qr_layout
            assert qr_layout["intrinsicSquare"], qr_layout
            assert qr_layout["intrinsicWidth"] == 432, qr_layout
            assert qr_layout["contained"], qr_layout
            assert_no_horizontal_overflow(page)
            assert_accessible_controls(page)
            page.screenshot(path=str(ARTIFACT_DIR / f"tokenfleet-install-{width}.png"), full_page=True)

        document_response = page.goto(f"{base}/install?demo=1", wait_until="networkidle")
        assert document_response.status == 200
        page.locator(".install-contact").wait_for()
        assert resource_status.get("/tokenfleet-contact-wechat-qr.jpg") == 200

        # The anonymous board is shareable, but must label itself as the board;
        # only a disclosed member profile may render a personal ranking card.
        page.goto(f"{base}/?demo=1#/rank", wait_until="networkidle")
        share_hint = page.locator(".community-share-hint")
        share_hint.wait_for()
        assert page.locator('[data-community-action="share-leaderboard"]').count() == 1
        assert share_hint.inner_text() == "可分享当前筛选口径的公开排行榜；成员页的“分享排名”才会展示该成员的个人成绩。"
        page.locator('[data-community-action="share-leaderboard"]').click()
        board_preview = page.locator(".community-poster-modal canvas")
        board_preview.wait_for()
        assert board_preview.evaluate("canvas => [canvas.width, canvas.height]") == [1200, 1600]
        assert page.get_by_role("heading", name="当前 Token 排行榜", exact=True).count() == 1
        page.get_by_role("button", name="关闭", exact=True).click()
        assert page.locator(".community-poster-modal").count() == 0

        # The server fixture has nested totals for distributions; these must not normalize to zero.
        page.goto(f"{base}/?demo=1#/rank/p/demo-1?period=7d", wait_until="networkidle")
        page.locator(".community-detail-grid").wait_for()
        assert page.locator(".community-distribution").count() == 2
        assert page.locator(".community-distribution em").first.inner_text() not in {"0", "—"}
        assert page.locator(".community-trend svg").count() == 1
        first_observation = page.locator(".community-trend .chart-observation").first
        first_observation.focus()
        page.wait_for_timeout(180)
        assert first_observation.locator(".chart-tooltip").evaluate(
            "element => getComputedStyle(element).opacity"
        ) == "1"
        assert_no_horizontal_overflow(page)

        # Root-absolute assets keep real SPA deep links working after a hard refresh.
        resource_status.clear()
        document_response = page.goto(
            f"{base}/rank/p/demo-1?demo=1", wait_until="networkidle"
        )
        assert document_response.status == 200
        page.locator(".community-detail-grid").wait_for()
        page.reload(wait_until="networkidle")
        page.locator(".community-detail-grid").wait_for()
        asset_status = page.evaluate(
            """async () => Object.fromEntries(await Promise.all(
              ['/styles.css', '/app.js'].map(async path => [
                path,
                (await fetch(path, {cache: 'no-store'})).status,
              ])
            ))"""
        )
        assert asset_status == {"/styles.css": 200, "/app.js": 200}
        assert page.get_by_role("link", name="管理员后台").evaluate("link => link.href") == f"{base}/"
        assert page.get_by_text("演示数据 · 不是真实排名或真实成员数据", exact=True).count() == 1

        # A public profile outside the leaderboard API limit is appended to its share poster.
        page.goto(
            f"{base}/?demo=1#/rank/p/outside-100?period=30d&metric=norm&tool=CC+Switch&model=kimi-k2",
            wait_until="networkidle",
        )
        page.get_by_text("Top 100 之外", exact=False).wait_for()
        page.locator('[data-community-action="share"]').click()
        preview = page.locator(".community-poster-modal canvas")
        save_button = page.get_by_role("button", name="保存图片", exact=True)
        preview.wait_for(state="visible")
        assert preview.evaluate("canvas => [canvas.width, canvas.height]") == [1200, 1600]
        preview_layout = preview.evaluate("""canvas => {
          const overlay = canvas.closest('.community-poster-modal');
          const section = overlay.querySelector('section');
          const frame = canvas.parentElement;
          const footer = overlay.querySelector('footer');
          const canvasRect = canvas.getBoundingClientRect();
          const sectionRect = section.getBoundingClientRect();
          const frameRect = frame.getBoundingClientRect();
          const footerRect = footer.getBoundingClientRect();
          return {
            canvasWidth: canvasRect.width,
            canvasHeight: canvasRect.height,
            frameWidth: frameRect.width,
            frameHeight: frameRect.height,
            sectionTop: sectionRect.top,
            sectionBottom: sectionRect.bottom,
            footerTop: footerRect.top,
            frameBottom: frameRect.bottom,
            viewportHeight: window.innerHeight,
          };
        }""")
        assert preview_layout["canvasWidth"] <= preview_layout["frameWidth"] + 1
        assert preview_layout["canvasHeight"] <= preview_layout["frameHeight"] + 1
        assert preview_layout["sectionTop"] >= -1
        assert preview_layout["sectionBottom"] <= preview_layout["viewportHeight"] + 1
        assert preview_layout["footerTop"] >= preview_layout["frameBottom"] - 1
        assert save_button.is_enabled() is True
        context.grant_permissions(["clipboard-write"], origin=base)
        page.get_by_role("button", name="复制图片", exact=True).click()
        page.get_by_text("排名图片已复制，可直接粘贴到聊天工具", exact=True).wait_for()
        assert page.get_by_role("button", name="关闭", exact=True).count() == 1
        with page.expect_download() as download_info:
            save_button.click()
        download = download_info.value
        poster_path = str(ARTIFACT_DIR / "tokenfleet-community-poster.png")
        download.save_as(poster_path)
        assert png_dimensions(poster_path) == (1200, 1600)
        page.get_by_role("button", name="关闭", exact=True).click()
        assert page.locator(".community-poster-modal").count() == 0

        # Empty state is deliberate and still keyboard-accessible.
        page.goto(f"{base}/?demo=1&scenario=empty#/rank", wait_until="networkidle")
        page.get_by_text("这个筛选下还没有参与者", exact=True).wait_for()
        assert_no_horizontal_overflow(page)

        # The secret is removed before the join DOM appears, never persisted, and never rendered.
        requested_urls = []
        page.on("request", lambda request: requested_urls.append(request.url))
        page.goto(f"{base}/index.html?view=join#code={VALID_CODE}", wait_until="networkidle")
        page.get_by_text("一次性连接码已安全载入", exact=True).wait_for()
        assert page.url == f"{base}/index.html?view=join"
        assert VALID_CODE not in page.content()
        assert all(VALID_CODE not in url for url in requested_urls)
        assert page.evaluate(
            """secret => !Object.values(localStorage).concat(Object.values(sessionStorage)).some(
              value => String(value).includes(secret)
            )""",
            VALID_CODE,
        )
        page.screenshot(path=str(ARTIFACT_DIR / "tokenfleet-join.png"), full_page=True)
        assert VALID_CODE not in page.content()

        # A second invite in the same tab is captured on hashchange, replaces the
        # consumed first code, and is scrubbed before the join UI handles input.
        context.grant_permissions(
            ["clipboard-read", "clipboard-write"], origin=base
        )
        page.evaluate(
            "secret => { location.href = `${location.pathname}${location.search}#code=${secret}`; }",
            SECOND_VALID_CODE,
        )
        page.wait_for_function("() => location.hash === ''")
        assert page.url == f"{base}/index.html?view=join"
        page.get_by_text("一次性连接码已安全载入", exact=True).wait_for()
        page.locator('[data-community-action="copy-join-code"]').click()
        assert page.evaluate("navigator.clipboard.readText()") == SECOND_VALID_CODE
        page.evaluate("navigator.clipboard.writeText('')")
        assert VALID_CODE not in page.content()
        assert SECOND_VALID_CODE not in page.content()
        assert all(
            secret not in url
            for secret in (VALID_CODE, SECOND_VALID_CODE)
            for url in requested_urls
        )
        assert all(
            secret not in message
            for secret in (VALID_CODE, SECOND_VALID_CODE)
            for message in console_messages
        )
        assert page.evaluate(
            """secrets => !Object.values(localStorage).concat(Object.values(sessionStorage)).some(
              value => secrets.some(secret => String(value).includes(secret))
            )""",
            [VALID_CODE, SECOND_VALID_CODE],
        )
        history_entries = context.new_cdp_session(page).send(
            "Page.getNavigationHistory"
        )["entries"]
        assert all(
            secret not in entry["url"]
            for secret in (VALID_CODE, SECOND_VALID_CODE)
            for entry in history_entries
        )

        # pagehide clears the in-memory copy even when the document remains alive.
        page.evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide'))")
        page.locator('[data-community-action="copy-join-code"]').click()
        assert page.evaluate("navigator.clipboard.readText()") == ""

        # A query token is refused and scrubbed rather than treated as a connection code.
        page.goto(f"{base}/index.html?view=join&code={VALID_CODE}", wait_until="networkidle")
        page.get_by_text("链接里没有有效连接码", exact=True).wait_for()
        assert "code=" not in page.url
        assert VALID_CODE not in page.content()
        assert page.locator('[data-community-action="copy-join-code"]').is_disabled()

        # /join is independently addressable; the fragment is scrubbed before assets render.
        page.goto(f"{base}/join?demo=1#code={VALID_CODE}", wait_until="networkidle")
        page.get_by_text("一次性连接码已安全载入", exact=True).wait_for()
        assert page.url == f"{base}/join?demo=1"
        assert VALID_CODE not in page.content()
        assert page.get_by_text("演示数据 · 不是真实排名或真实成员数据", exact=True).count() == 1

        # Join-to-rank uses a direct path so /join never shadows the app route.
        assert page.locator('a[href="/rank?demo=1"]').count() == 2
        page.get_by_role("link", name="先看看匿名社群榜").click()
        page.locator(".community-rank-row").first.wait_for()
        assert page.url == f"{base}/rank?demo=1"
        page.reload(wait_until="networkidle")
        page.locator(".community-rank-row").first.wait_for()
        assert page.url == f"{base}/rank?demo=1"

        # A shared batch invitation is accepted only from the fragment. It is
        # scrubbed before rendering and the claim uses an anonymous POST body.
        context.grant_permissions(
            ["clipboard-read", "clipboard-write"], origin=base
        )
        batch_requested_urls = []
        page.on("request", lambda request: batch_requested_urls.append(request.url))
        for width in (390, 820, 1440):
            page.set_viewport_size({"width": width, "height": 900})
            page.goto(
                f"{base}/join/batch#invite={BATCH_INVITATION}",
                wait_until="networkidle",
            )
            page.get_by_text("社群邀请已安全载入", exact=True).wait_for()
            assert page.url == f"{base}/join/batch"
            assert BATCH_INVITATION not in page.content()
            assert_no_horizontal_overflow(page)
            assert_accessible_controls(page)
            page.screenshot(
                path=str(ARTIFACT_DIR / f"tokenfleet-batch-{width}.png"),
                full_page=True,
            )

        assert all(BATCH_INVITATION not in url for url in batch_requested_urls)
        assert all(BATCH_INVITATION not in message for message in console_messages)
        assert page.evaluate(
            """secret => !Object.values(localStorage).concat(Object.values(sessionStorage)).some(
              value => String(value).includes(secret)
            )""",
            BATCH_INVITATION,
        )
        batch_history = context.new_cdp_session(page).send(
            "Page.getNavigationHistory"
        )["entries"]
        assert all(BATCH_INVITATION not in entry["url"] for entry in batch_history)

        batch_form = page.locator('[data-community-action="claim-batch"]')
        batch_form.locator('input[name="display_name"]').fill("浏览器成员")
        batch_form.locator('input[name="public_profile_enabled"]').check()
        batch_form.get_by_role("button", name="确认昵称并领取设备码").click()
        page.get_by_text("浏览器成员，你的设备码已经生成", exact=True).wait_for()
        page.screenshot(
            path=str(ARTIFACT_DIR / "tokenfleet-batch-success.png"),
            full_page=True,
        )
        assert len(CommunityStaticHandler.batch_claims) == 1
        claim = CommunityStaticHandler.batch_claims[0]
        assert claim["path"] == "/api/v1/public/invitation-batches/claim"
        assert claim["authorization"] is None
        assert claim["payload"] == {
            "invitation_token": BATCH_INVITATION,
            "display_name": "浏览器成员",
            "public_profile_enabled": True,
        }
        assert BATCH_INVITATION not in page.content()
        assert PERSONAL_DEVICE_CODE not in page.content()
        assert page.evaluate(
            """secrets => !Object.values(localStorage).concat(Object.values(sessionStorage)).some(
              value => secrets.some(secret => String(value).includes(secret))
            )""",
            [BATCH_INVITATION, PERSONAL_DEVICE_CODE],
        )
        page.evaluate("navigator.clipboard.writeText('')")
        page.get_by_role("button", name="复制个人设备码").click()
        assert page.evaluate("navigator.clipboard.readText()") == PERSONAL_DEVICE_CODE
        page.evaluate("navigator.clipboard.writeText('')")
        page.evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide'))")
        page.get_by_role("button", name="复制个人设备码").click()
        assert page.evaluate("navigator.clipboard.readText()") == ""

        # Query/path batch tokens are erased but never accepted as invitations.
        for refused_url in (
            f"{base}/join/batch?invite={BATCH_INVITATION}",
            f"{base}/join/batch/{BATCH_INVITATION}",
        ):
            page.goto(refused_url, wait_until="networkidle")
            page.get_by_text("这个批次链接当前不可用", exact=True).wait_for()
            assert page.url == f"{base}/join/batch"
            assert BATCH_INVITATION not in page.content()
            assert page.get_by_role("button", name="确认昵称并领取设备码").is_disabled()

        # Admin creates one shared batch link without ever rendering its raw token.
        page.goto(f"{base}/?demo=1#/people", wait_until="networkidle")
        page.get_by_role("button", name="创建自助批次（单批最多 50）").click()
        batch_dialog = page.locator("#batch-dialog")
        assert batch_dialog.locator('input[name="capacity"]').input_value() == "50"
        assert batch_dialog.locator('select[name="expires_in_hours"]').input_value() == "24"
        batch_dialog.get_by_role("button", name="生成批次链接").click()
        batch_link_dialog = page.locator("dialog.token-dialog")
        batch_link_dialog.wait_for()
        assert "demo_batch" not in batch_link_dialog.inner_text()
        batch_link_dialog.get_by_role("button", name="复制本批次自助接入链接").click()
        copied_batch_link = page.evaluate("navigator.clipboard.readText()")
        assert copied_batch_link.startswith(f"{base}/join/batch#invite=")
        assert "demo_batch_7Yp4" in copied_batch_link
        batch_link_dialog.get_by_role("button", name="关闭").click()

        # Admin first-use flow asks only for nickname and defaults public participation off.
        page.get_by_role("button", name="单独新建参赛者").click()
        dialog = page.locator("#member-dialog")
        assert dialog.locator('input[name="display_name"]').count() == 1
        assert dialog.locator('input[name="email"], input[name="password"]').count() == 0
        public_checkbox = dialog.locator('input[name="public_profile_enabled"]')
        assert not public_checkbox.is_checked()
        expiry_values = dialog.locator('select[name="expires_in_minutes"] option').evaluate_all(
            "options => options.map(option => Number(option.value))"
        )
        assert max(expiry_values) <= 1440
        dialog.locator('input[name="display_name"]').fill("重复昵称")
        dialog.get_by_role("button", name="创建并生成链接").click()
        one_time = page.locator("dialog.token-dialog")
        one_time.wait_for()
        assert "demo_once" not in one_time.inner_text()
        assert "N1s7" not in one_time.inner_text()
        assert one_time.get_by_role("button", name="复制连接码").count() == 1
        one_time.get_by_role("button", name="关闭").click()

        # Public switches expose proper state and remain unavailable for disabled members.
        page.locator('[role="switch"]:not([disabled])').first.wait_for()
        switch = page.locator('[role="switch"]:not([disabled])').first
        before = switch.get_attribute("aria-checked")
        switch.click()
        page.locator('[role="switch"]:not([disabled])').first.wait_for()
        after = page.locator('[role="switch"]:not([disabled])').first.get_attribute("aria-checked")
        assert before != after

        # Cost charts never turn unpriced or cross-currency microunits into a fake zero/comparable line.
        page.goto(
            f"{base}/?demo=1#/rank/p/mixed-cost?metric=cost",
            wait_until="networkidle",
        )
        page.get_by_text("费用趋势暂不可比", exact=True).wait_for()
        assert page.locator(".community-trend polyline, .community-trend circle").count() == 0
        assert page.locator(".community-distribution .is-unpriced").count() >= 1
        assert page.locator('.community-distribution b[style*="width"]').count() == 0
        page.goto(
            f"{base}/?demo=1#/rank/p/mixed-currency?metric=cost",
            wait_until="networkidle",
        )
        page.get_by_text("日费用包含多种币种", exact=False).wait_for()
        assert page.locator(".community-trend polyline, .community-trend circle").count() == 0
        assert page.locator(".community-distribution .is-not-comparable").count() >= 1
        assert page.locator('.community-distribution b[style*="width"]').count() == 0

        # Public -> admin: an old slow leaderboard response cannot overwrite overview.
        page.goto(
            f"{base}/?demo=1&scenario=slow-public#/overview",
            wait_until="networkidle",
        )
        page.evaluate("location.hash = '#/rank'")
        page.locator(".community-loading").wait_for()
        page.wait_for_timeout(50)
        page.evaluate("location.hash = '#/overview'")
        page.get_by_role("heading", name="总览", exact=True).wait_for()
        page.wait_for_timeout(350)
        assert page.get_by_role("heading", name="总览", exact=True).count() == 1
        assert page.locator(".community-board").count() == 0

        # Public -> public: the first slow board cannot overwrite the later profile.
        page.evaluate("location.hash = '#/rank'")
        page.locator(".community-loading").wait_for()
        page.wait_for_timeout(50)
        page.evaluate("location.hash = '#/rank/p/demo-1'")
        page.locator(".community-profile-hero").wait_for()
        page.wait_for_timeout(350)
        assert page.locator(".community-profile-hero").count() == 1
        assert page.locator(".community-board").count() == 0

        # A slow profile response is also inert after returning to admin overview.
        page.goto(
            f"{base}/?demo=1&scenario=slow-profile#/overview",
            wait_until="networkidle",
        )
        page.evaluate("location.hash = '#/rank/p/demo-1'")
        page.locator(".community-loading").wait_for()
        page.wait_for_timeout(50)
        page.evaluate("location.hash = '#/overview'")
        page.get_by_role("heading", name="总览", exact=True).wait_for()
        page.wait_for_timeout(350)
        assert page.locator(".community-profile-hero, .community-board").count() == 0

        # Admin -> public: delayed pricing cannot repaint over the public board.
        page.goto(
            f"{base}/?demo=1&scenario=slow-admin#/overview",
            wait_until="networkidle",
        )
        page.evaluate("location.hash = '#/costs'")
        page.get_by_role("heading", name="成本", exact=True).wait_for()
        page.wait_for_timeout(50)
        page.evaluate("location.hash = '#/rank'")
        page.locator(".community-board").wait_for()
        page.wait_for_timeout(350)
        assert page.locator(".community-board").count() == 1
        assert page.locator(".cost-ledger").count() == 0

        # In-progress poster generation cannot open a modal or download after route disposal.
        page.goto(
            f"{base}/?demo=1&scenario=slow-share#/rank/p/demo-1",
            wait_until="networkidle",
        )
        share = page.locator('[data-community-action="share"]')
        assert share.count() == 1
        stale_downloads = []
        page.on("download", lambda download: stale_downloads.append(download.suggested_filename))
        share.click()
        page.wait_for_timeout(50)
        page.evaluate("location.hash = '#/overview'")
        page.get_by_role("heading", name="总览", exact=True).wait_for()
        page.wait_for_timeout(350)
        assert stale_downloads == []
        assert page.locator(".community-poster-modal").count() == 0
        assert page.locator(".community-toast, .community-board").count() == 0

        # A delayed enrollment mutation cannot append its one-time secret dialog to /rank.
        page.goto(
            f"{base}/?demo=1&scenario=slow-enrollment#/people",
            wait_until="networkidle",
        )
        page.get_by_role("button", name="给已有成员补发设备码").click()
        enrollment = page.locator("#enrollment-dialog")
        assert "不会重复创建成员" in enrollment.inner_text()
        assert "不占自助批次名额" in enrollment.inner_text()
        assert "旧码会立即失效" in enrollment.inner_text()
        assert "已使用码及其审计记录不会改变" in enrollment.inner_text()
        option_values = enrollment.locator('select[name="user_id"] option').evaluate_all(
            "options => options.map(option => option.value).filter(Boolean)"
        )
        assert "u-demo-admin" not in option_values
        enrollment.locator('select[name="user_id"]').select_option(index=1)
        enrollment.get_by_role(
            "button", name="确认补发 60 分钟设备码"
        ).click()
        page.wait_for_timeout(50)
        page.evaluate("location.hash = '#/rank'")
        page.locator(".community-board").wait_for()
        page.wait_for_timeout(350)
        assert page.locator("dialog.token-dialog").count() == 0
        assert "demo_once" not in page.content()
        assert "N1s7" not in page.content()

        # Logout invalidates a real pending admin load before rendering login in-place.
        page.goto(f"{base}/", wait_until="domcontentloaded")
        page.evaluate("sessionStorage.setItem('tokenfleet.apiKey', 'race-admin-session')")
        page.goto(f"{base}/?admin-race=1#/overview", wait_until="networkidle")
        page.get_by_role("heading", name="总览", exact=True).wait_for()
        CommunityStaticHandler.pricing_delay_seconds = 0.3
        try:
            page.evaluate("location.hash = '#/costs'")
            page.wait_for_timeout(100)
            assert page.locator(".page-header h1").inner_text() == "成本", {
                "url": page.url,
                "body": page.locator("body").inner_text()[:500],
            }
            page.wait_for_timeout(50)
            page.get_by_role("button", name="退出", exact=True).click()
            page.get_by_role("heading", name="进入社群管理后台", exact=True).wait_for()
            page.wait_for_timeout(350)
            assert page.get_by_role("heading", name="进入社群管理后台", exact=True).count() == 1
            assert page.locator(".cost-ledger").count() == 0
        finally:
            CommunityStaticHandler.pricing_delay_seconds = 0

        assert not errors, errors
        context.close()
        browser.close()


if __name__ == "__main__":
    main()
