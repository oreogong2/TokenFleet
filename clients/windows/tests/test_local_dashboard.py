from __future__ import annotations

import io
import hashlib
import hmac
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from tokenfleet.collectors import CollectionDiagnostics, CollectionResult
from tokenfleet.local_dashboard import (
    ACTION_TOKEN_HEADER,
    HEALTH_CHALLENGE_HEADER,
    MAX_CURSOR_CSV_BYTES,
    dashboard_data,
    dashboard_handler_class,
    dashboard_url,
    ensure_action_token,
)


class _OpenBytesIO(io.BytesIO):
    def close(self) -> None:
        self.flush()


class _RequestSocket:
    def __init__(self, raw_request: bytes) -> None:
        self.input = _OpenBytesIO(raw_request)
        self.output = _OpenBytesIO()

    def makefile(self, mode: str, _buffering: int = -1) -> _OpenBytesIO:
        return self.input if "r" in mode else self.output

    def sendall(self, payload: bytes) -> None:
        self.output.write(payload)

    def settimeout(self, _timeout: float) -> None:
        return


def _request(handler: type, raw_request: bytes) -> tuple[int, bytes]:
    connection = _RequestSocket(raw_request)
    handler(connection, ("127.0.0.1", 43210), SimpleNamespace())
    response = connection.output.getvalue()
    status = int(response.split(b"\r\n", 1)[0].split()[1])
    return status, response


class LocalDashboardTests(unittest.TestCase):
    def test_dashboard_summarizes_today_week_tool_model_and_rank(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            credential = root / "credential.dpapi"
            credential.write_bytes(b"existence-marker-only")
            paths = SimpleNamespace(
                settings=root / "settings.json",
                credential=credential,
                cursor_usage=root / "cursor-usage.json",
                rank_cache=root / "community-rank-cache.json",
            )
            today = (
                datetime.now(timezone.utc)
                .astimezone(timezone(timedelta(hours=8)))
                .date()
                .isoformat()
            )
            collection = CollectionResult(
                buckets=[
                    {
                        "date": today,
                        "timezone": "Asia/Shanghai",
                        "tool": "Codex",
                        "model": "gpt-5",
                        "source": "local",
                        "input_tokens": 10,
                        "output_tokens": 5,
                        "cache_read_tokens": 3,
                        "cache_write_tokens": 2,
                        "completeness": "exact",
                    }
                ],
                diagnostics=CollectionDiagnostics(),
            )
            client = mock.Mock()
            client.preview.return_value = collection
            client.community_rank.return_value = {
                "rank": 137,
                "total_entries": 200,
                "metric_value": "20",
                "primary_tool": "Codex",
                "primary_model": "gpt-5",
            }

            value = dashboard_data(paths, client)

            client.preview.assert_called_once_with(history_days=180)
            self.assertEqual(value["today"]["total_tokens"], 20)
            self.assertEqual(value["week"]["tools"], {"Codex": 20})
            self.assertEqual(value["week"]["models"], {"gpt-5": 20})
            self.assertEqual(value["rank"]["rank"], 137)
            self.assertTrue(value["experimental"]["enabled"])

            second = dashboard_data(paths, client)
            self.assertEqual(second["rank"]["rank"], 137)
            client.community_rank.assert_called_once_with()

    def test_dashboard_week_excludes_last_week_and_sorts_multi_bucket_totals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = SimpleNamespace(
                settings=root / "settings.json",
                credential=root / "missing-credential.dpapi",
                cursor_usage=root / "cursor-usage.json",
                rank_cache=root / "community-rank-cache.json",
            )
            today = datetime.now(timezone.utc).astimezone(
                timezone(timedelta(hours=8))
            ).date()
            monday = today - timedelta(days=today.weekday())
            previous_week = monday - timedelta(days=1)

            def bucket(day, tool, model, total):  # type: ignore[no-untyped-def]
                return {
                    "date": day.isoformat(),
                    "timezone": "Asia/Shanghai",
                    "tool": tool,
                    "model": model,
                    "source": "local",
                    "input_tokens": total,
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "completeness": "exact",
                }

            client = mock.Mock()
            client.preview.return_value = CollectionResult(
                [
                    bucket(today, "Codex", "gpt-small", 10),
                    bucket(today, "Claude Code", "claude", 30),
                    bucket(monday, "Codex", "gpt-large", 40),
                    bucket(previous_week, "Old", "old", 999),
                ],
                CollectionDiagnostics(),
            )

            value = dashboard_data(paths, client)

            self.assertEqual(value["today"]["total_tokens"], 40)
            self.assertEqual(value["week"]["total_tokens"], 80)
            self.assertEqual(
                list(value["week"]["tools"]), ["Codex", "Claude Code"]
            )
            self.assertEqual(
                list(value["week"]["models"]),
                ["gpt-large", "claude", "gpt-small"],
            )
            self.assertNotIn("Old", value["week"]["tools"])

    def test_action_token_is_persisted_and_only_injected_in_url_fragment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = SimpleNamespace(
                dashboard_token=root / "data" / "local-dashboard.token"
            )
            first = ensure_action_token(paths)
            second = ensure_action_token(paths)

            self.assertEqual(first, second)
            self.assertEqual(paths.dashboard_token.read_text(encoding="ascii").strip(), first)
            self.assertEqual(dashboard_url(first).split("#", 1)[1], first)
            self.assertNotIn(first, dashboard_url().split("#", 1)[0])

    def test_request_handler_rejects_wrong_host_origin_and_action_token(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            web_root = root / "web"
            web_root.mkdir()
            for name in ("index.html", "app.js", "styles.css"):
                (web_root / name).write_text(name, encoding="utf-8")
            paths = SimpleNamespace(
                settings=root / "settings.json",
                cursor_usage=root / "cursor-usage.json",
                web_root=web_root,
            )
            token = "T" * 43
            handler = dashboard_handler_class(
                paths,
                port=8765,
                client_factory=mock.Mock(),
                action_token=token,
            )

            wrong_host, _ = _request(
                handler,
                b"GET /health HTTP/1.1\r\nHost: attacker.invalid\r\n\r\n",
            )
            challenge = "C" * 32
            health_status, health_response = _request(
                handler,
                b"GET /health HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n"
                + f"{HEALTH_CHALLENGE_HEADER}: {challenge}\r\n\r\n".encode("ascii"),
            )
            body = b'{"enabled":true}'
            wrong_origin, _ = _request(
                handler,
                b"POST /api/settings/experimental HTTP/1.1\r\n"
                b"Host: 127.0.0.1:8765\r\n"
                b"Origin: http://attacker.invalid\r\n"
                b"X-TokenFleet-Action: 1\r\n"
                + f"{ACTION_TOKEN_HEADER}: {token}\r\n".encode("ascii")
                + f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
                + body,
            )
            wrong_token, wrong_token_response = _request(
                handler,
                b"POST /api/settings/experimental HTTP/1.1\r\n"
                b"Host: 127.0.0.1:8765\r\n"
                b"Origin: http://127.0.0.1:8765\r\n"
                b"X-TokenFleet-Action: 1\r\n"
                + f"{ACTION_TOKEN_HEADER}: wrong\r\n".encode("ascii")
                + f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
                + body,
            )
            authorized, _ = _request(
                handler,
                b"POST /api/settings/experimental HTTP/1.1\r\n"
                b"Host: 127.0.0.1:8765\r\n"
                b"Origin: http://127.0.0.1:8765\r\n"
                b"X-TokenFleet-Action: 1\r\n"
                + f"{ACTION_TOKEN_HEADER}: {token}\r\n".encode("ascii")
                + f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
                + body,
            )

            self.assertEqual(wrong_host, 421)
            self.assertEqual(health_status, 200)
            health = __import__("json").loads(
                health_response.split(b"\r\n\r\n", 1)[1]
            )
            self.assertEqual(
                health["proof"],
                hmac.new(
                    token.encode("ascii"),
                    challenge.encode("ascii"),
                    hashlib.sha256,
                ).hexdigest(),
            )
            self.assertEqual(wrong_origin, 403)
            self.assertEqual(wrong_token, 403)
            self.assertIn(
                "请从桌面快捷方式重新打开",
                wrong_token_response.split(b"\r\n\r\n", 1)[1].decode("utf-8"),
            )
            self.assertEqual(authorized, 200)

    def test_cursor_upload_over_10_mib_is_rejected_before_body_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            web_root = root / "web"
            web_root.mkdir()
            paths = SimpleNamespace(
                settings=root / "settings.json",
                cursor_usage=root / "cursor-usage.json",
                web_root=web_root,
            )
            token = "T" * 43
            handler = dashboard_handler_class(
                paths,
                port=8765,
                client_factory=mock.Mock(),
                action_token=token,
            )

            status, _ = _request(
                handler,
                b"POST /api/cursor/import HTTP/1.1\r\n"
                b"Host: 127.0.0.1:8765\r\n"
                b"Origin: http://127.0.0.1:8765\r\n"
                b"X-TokenFleet-Action: 1\r\n"
                + f"{ACTION_TOKEN_HEADER}: {token}\r\n".encode("ascii")
                + f"Content-Length: {MAX_CURSOR_CSV_BYTES + 1}\r\n\r\n".encode("ascii"),
            )

            self.assertEqual(handler.timeout, 10)
            self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
