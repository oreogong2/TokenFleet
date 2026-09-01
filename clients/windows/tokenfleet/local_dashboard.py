from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable

from .client import TokenFleetClient
from .collectors import experimental_scan_paths, import_cursor_csv, remove_cursor_import
from .constants import ACCOUNTING_TIMEZONE, LOCAL_DASHBOARD_HOST, LOCAL_DASHBOARD_PORT
from .credential import CredentialStore
from .paths import ClientPaths, default_source_home
from .settings import SettingsStore
from .state import atomic_write

MAX_CURSOR_CSV_BYTES = 10 * 1024 * 1024
RANK_CACHE_SECONDS = 5 * 60
ACTION_TOKEN_HEADER = "X-TokenFleet-Token"
HEALTH_CHALLENGE_HEADER = "X-TokenFleet-Health-Challenge"
_ACTION_TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{43,128}")
_RANK_CACHE_LOCK = threading.Lock()


def dashboard_url(action_token: str | None = None) -> str:
    base = f"http://{LOCAL_DASHBOARD_HOST}:{LOCAL_DASHBOARD_PORT}/"
    return f"{base}#{action_token}" if action_token else base


def ensure_action_token(paths: ClientPaths) -> str:
    try:
        existing = paths.dashboard_token.read_text(encoding="ascii").strip()
    except FileNotFoundError:
        existing = ""
    except (OSError, UnicodeError) as exc:
        raise RuntimeError("TokenFleet local action token is unreadable") from exc
    if existing:
        if _ACTION_TOKEN_PATTERN.fullmatch(existing) is None:
            raise RuntimeError("TokenFleet local action token is invalid")
        return existing
    token = secrets.token_urlsafe(32)
    try:
        paths.dashboard_token.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(paths.dashboard_token, f"{token}\n".encode("ascii"))
    except RuntimeError as exc:
        raise RuntimeError("TokenFleet local action token could not be created") from exc
    return token


def _bucket_total(bucket: dict[str, Any]) -> int:
    return sum(
        int(bucket[field])
        for field in (
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
        )
    )


def _period_summary(buckets: list[dict[str, Any]], days: set[str]) -> dict[str, Any]:
    selected = [bucket for bucket in buckets if bucket["date"] in days]
    tools: dict[str, int] = {}
    models: dict[str, int] = {}
    for bucket in selected:
        total = _bucket_total(bucket)
        tools[bucket["tool"]] = tools.get(bucket["tool"], 0) + total
        models[bucket["model"]] = models.get(bucket["model"], 0) + total
    return {
        "total_tokens": sum(map(_bucket_total, selected)),
        "tools": dict(sorted(tools.items(), key=lambda item: (-item[1], item[0]))),
        "models": dict(sorted(models.items(), key=lambda item: (-item[1], item[0]))),
    }


def _rank_for_dashboard(
    paths: ClientPaths, client: TokenFleetClient
) -> tuple[dict[str, Any] | None, str | None]:
    if not paths.credential.is_file():
        return None, None
    with _RANK_CACHE_LOCK:
        now = time.time()
        try:
            cached = json.loads(paths.rank_cache.read_text(encoding="utf-8"))
            if (
                isinstance(cached, dict)
                and type(cached.get("cached_at")) in (int, float)
                and now - float(cached["cached_at"]) < RANK_CACHE_SECONDS
                and isinstance(cached.get("rank"), dict)
            ):
                return cached["rank"], None
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            pass
        try:
            value = client.community_rank()
            rank = {
                "rank": value["rank"],
                "total_entries": value["total_entries"],
                "metric_value": value["metric_value"],
                "primary_tool": value["primary_tool"],
                "primary_model": value["primary_model"],
            }
            paths.rank_cache.parent.mkdir(parents=True, exist_ok=True)
            atomic_write(
                paths.rank_cache,
                json.dumps(
                    {"cached_at": now, "rank": rank},
                    ensure_ascii=True,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8"),
            )
            return rank, None
        except RuntimeError:
            return None, "暂时无法读取社群名次"


def dashboard_data(paths: ClientPaths, client: TokenFleetClient) -> dict[str, Any]:
    settings = SettingsStore(paths.settings).load()
    collection = client.preview(history_days=180)
    # The accounting timezone is fixed at UTC+8; converting from the instant
    # prevents the Windows system timezone from changing TokenFleet day keys.
    today = datetime.now(timezone.utc).astimezone(timezone(timedelta(hours=8))).date()
    today_key = today.isoformat()
    week_start = today - timedelta(days=today.weekday())
    week_days = {(week_start + timedelta(days=offset)).isoformat() for offset in range(7)}
    rank, rank_error = _rank_for_dashboard(paths, client)
    return {
        "timezone": ACCOUNTING_TIMEZONE,
        "today": _period_summary(collection.buckets, {today_key}),
        "week": _period_summary(collection.buckets, week_days),
        "rank": rank,
        "rank_error": rank_error,
        "experimental": {
            "enabled": settings.experimental_sources_enabled,
            "sources": collection.diagnostics.source_status,
            "scan_paths": experimental_scan_paths(default_source_home()),
        },
        "cursor": {
            "imported": paths.cursor_usage.is_file(),
            "records": collection.diagnostics.exact_records.get("Cursor", 0),
        },
        "privacy": "只从本机记录中提取结构化 usage 并展示日聚合；只披露固定扫描根目录，不保存、展示或上传 prompt、回复、代码、具体记录路径或设备凭据。",
    }


def _client_for_paths(paths: ClientPaths) -> TokenFleetClient:
    from .installation import CommunityInstallationConfigStore
    from .state import StateStore

    config = CommunityInstallationConfigStore(
        paths.community_config, paths.community_digest
    ).load()
    return TokenFleetClient(
        credential_store=CredentialStore(paths.credential),
        state_store=StateStore(paths.state),
        settings_store=SettingsStore(paths.settings),
        cursor_archive=paths.cursor_usage,
        source_home=default_source_home(),
        community_origin=config.community_server,
    )


class _ExclusiveThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def server_bind(self) -> None:
        if os.name == "nt":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def dashboard_handler_class(
    paths: ClientPaths,
    *,
    port: int = LOCAL_DASHBOARD_PORT,
    client_factory: Callable[[ClientPaths], TokenFleetClient] = _client_for_paths,
    action_token: str,
) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "TokenFleetLocal/1"
        timeout = 10

        def log_message(self, _format: str, *_args: Any) -> None:
            return

        def _send_json(self, status: int, value: Any) -> None:
            payload = json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(payload)

        def _send_asset(self, name: str, content_type: str) -> None:
            path = paths.web_root / name
            try:
                payload = path.read_bytes()
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(payload)

        def _authorized_action(self) -> bool:
            expected_origin = f"http://{LOCAL_DASHBOARD_HOST}:{port}"
            return (
                self.headers.get("Origin") == expected_origin
                and self.headers.get("X-TokenFleet-Action") == "1"
                and secrets.compare_digest(
                    self.headers.get(ACTION_TOKEN_HEADER, ""), action_token
                )
            )

        def _valid_host(self) -> bool:
            return self.headers.get("Host") == f"{LOCAL_DASHBOARD_HOST}:{port}"

        def do_GET(self) -> None:  # noqa: N802
            if not self._valid_host():
                self._send_json(421, {"error": "本机页面 Host 无效"})
                return
            if self.path == "/health":
                challenge = self.headers.get(HEALTH_CHALLENGE_HEADER, "")
                if re.fullmatch(r"[A-Za-z0-9_-]{32,128}", challenge) is None:
                    self._send_json(403, {"error": "本机服务挑战无效"})
                    return
                proof = hmac.new(
                    action_token.encode("ascii"),
                    challenge.encode("ascii"),
                    hashlib.sha256,
                ).hexdigest()
                self._send_json(200, {"ok": True, "proof": proof})
            elif self.path == "/api/data":
                try:
                    self._send_json(200, dashboard_data(paths, client_factory(paths)))
                except RuntimeError:
                    self._send_json(503, {"error": "本机统计暂时不可用"})
            elif self.path in ("/", "/index.html"):
                self._send_asset("index.html", "text/html; charset=utf-8")
            elif self.path == "/app.js":
                self._send_asset("app.js", "text/javascript; charset=utf-8")
            elif self.path == "/styles.css":
                self._send_asset("styles.css", "text/css; charset=utf-8")
            else:
                self.send_error(404)

        def do_POST(self) -> None:  # noqa: N802
            if not self._valid_host():
                self._send_json(421, {"error": "本机页面 Host 无效"})
                return
            if not self._authorized_action():
                self._send_json(403, {"error": "授权已失效，请从桌面快捷方式重新打开"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self._send_json(400, {"error": "请求长度无效"})
                return
            if length < 0:
                self._send_json(400, {"error": "请求长度无效"})
                return
            if self.path == "/api/settings/experimental":
                if length > 1024:
                    self._send_json(413, {"error": "请求过大"})
                    return
                try:
                    value = json.loads(self.rfile.read(length))
                except (UnicodeError, json.JSONDecodeError):
                    self._send_json(400, {"error": "请求格式无效"})
                    return
                if not isinstance(value, dict) or set(value) != {"enabled"} or type(value["enabled"]) is not bool:
                    self._send_json(400, {"error": "请求字段无效"})
                    return
                try:
                    SettingsStore(paths.settings).set_experimental_sources(value["enabled"])
                except RuntimeError:
                    self._send_json(500, {"error": "实验来源开关无法保存"})
                    return
                self._send_json(200, {"enabled": value["enabled"]})
                return
            if self.path == "/api/cursor/import":
                if length <= 0 or length > MAX_CURSOR_CSV_BYTES:
                    self._send_json(413, {"error": "Cursor CSV 必须小于 10 MiB"})
                    return
                payload = self.rfile.read(length)
                temporary_name: str | None = None
                try:
                    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as handle:
                        temporary_name = handle.name
                        handle.write(payload)
                    summary = import_cursor_csv(Path(temporary_name), paths.cursor_usage)
                    self._send_json(200, summary)
                except RuntimeError as exc:
                    self._send_json(400, {"error": str(exc)})
                finally:
                    if temporary_name:
                        try:
                            Path(temporary_name).unlink(missing_ok=True)
                        except OSError:
                            pass
                return
            self.send_error(404)

        def do_DELETE(self) -> None:  # noqa: N802
            if not self._valid_host():
                self._send_json(421, {"error": "本机页面 Host 无效"})
                return
            if self.path != "/api/cursor/import":
                self.send_error(404)
                return
            if not self._authorized_action():
                self._send_json(403, {"error": "授权已失效，请从桌面快捷方式重新打开"})
                return
            try:
                removed = remove_cursor_import(paths.cursor_usage)
            except RuntimeError as exc:
                self._send_json(500, {"error": str(exc)})
                return
            self._send_json(200, {"removed": removed})

    return Handler


def create_dashboard_server(
    paths: ClientPaths,
    *,
    host: str = LOCAL_DASHBOARD_HOST,
    port: int = LOCAL_DASHBOARD_PORT,
    client_factory: Callable[[ClientPaths], TokenFleetClient] = _client_for_paths,
) -> ThreadingHTTPServer:
    if host != LOCAL_DASHBOARD_HOST:
        raise RuntimeError("TokenFleet local page may only bind to 127.0.0.1")
    handler = dashboard_handler_class(
        paths,
        port=port,
        client_factory=client_factory,
        action_token=ensure_action_token(paths),
    )
    return _ExclusiveThreadingHTTPServer((host, port), handler)


def serve_dashboard(paths: ClientPaths) -> None:
    server = create_dashboard_server(paths)
    pid_path = paths.data / "local-dashboard.pid"
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(pid_path, f"{os.getpid()}\n".encode("ascii"))
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        try:
            pid_path.unlink(missing_ok=True)
        except OSError:
            pass


def _is_dashboard_running(action_token: str) -> bool:
    challenge = secrets.token_urlsafe(24)
    request = urllib.request.Request(
        f"http://{LOCAL_DASHBOARD_HOST}:{LOCAL_DASHBOARD_PORT}/health",
        headers={HEALTH_CHALLENGE_HEADER: challenge},
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=0.4,
        ) as response:
            value = json.loads(response.read(4096))
            expected = hmac.new(
                action_token.encode("ascii"),
                challenge.encode("ascii"),
                hashlib.sha256,
            ).hexdigest()
            return response.status == 200 and value == {"ok": True, "proof": expected}
    except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError):
        return False


def ensure_dashboard_running(entrypoint: Path, paths: ClientPaths) -> None:
    action_token = ensure_action_token(paths)
    if _is_dashboard_running(action_token):
        return
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        subprocess.Popen(
            [sys.executable, os.fspath(entrypoint), "_serve"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=flags,
            close_fds=True,
        )
    except OSError as exc:
        raise RuntimeError("TokenFleet local page could not start") from exc
    for _ in range(40):
        if _is_dashboard_running(action_token):
            return
        time.sleep(0.1)
    raise RuntimeError("TokenFleet local page could not start")


def open_dashboard(entrypoint: Path, paths: ClientPaths) -> None:
    ensure_dashboard_running(entrypoint, paths)
    if not webbrowser.open(dashboard_url(ensure_action_token(paths)), new=2):
        raise RuntimeError("系统未能打开默认浏览器")
