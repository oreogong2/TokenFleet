from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import tokenfleet.collectors as collectors_module
from tokenfleet.collectors import (
    collect_usage,
    experimental_scan_paths,
    import_cursor_csv,
    remove_cursor_import,
)
from tokenfleet.local_dashboard import create_dashboard_server
from tokenfleet.paths import ClientPaths


def write_jsonl(path: Path, values: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(value, separators=(",", ":")) + "\n" for value in values),
        encoding="utf-8",
    )


def codex_usage(input_tokens: int, output_tokens: int, cached: int) -> dict:
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cached_input_tokens": cached,
        "total_tokens": input_tokens + output_tokens,
    }


def create_zcode_database(path: Path, rows_sql: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as connection:
        connection.executescript(
            f"""
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
                provider_total_tokens INTEGER,
                computed_total_tokens INTEGER NOT NULL DEFAULT 0
            );
            {rows_sql}
            """
        )


def _bucket_total(bucket: dict) -> int:
    return sum(
        bucket[field]
        for field in (
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
        )
    )


def _otel_span(
    trace_id: str,
    span_id: str,
    timestamp: str,
    *,
    session: str | None = None,
    service: str = "github-copilot",
) -> dict:
    attributes = {
        "gen_ai.operation.name": "chat",
        "gen_ai.request.model": "gpt-5",
        "gen_ai.usage.input_tokens": 100,
        "gen_ai.usage.output_tokens": 20,
        "gen_ai.usage.cache_read.input_tokens": 80,
    }
    if session:
        attributes["gen_ai.conversation.id"] = session
    return {
        "resource": {"attributes": {"service.name": service}},
        "name": "chat",
        "traceId": trace_id,
        "spanId": span_id,
        "timestamp": timestamp,
        "attributes": attributes,
    }


def _dsh_lines(input_tokens: int, output_tokens: int, cache_read: int, cache_write: int) -> list[dict]:
    return [
        {"type": "request/header", "data": {"config": {"provider": "deepseek", "model": "deepseek-v3"}}},
        {"type": "step/start", "timestamp": "2026-08-25T00:00:00Z", "data": {"id": "step-1"}},
        {
            "type": "assistant/message",
            "timestamp": "2026-08-25T00:00:01Z",
            "data": {"id": "message-1", "usage": {"input": 999, "output": 999}},
        },
        {
            "type": "assistant/chunk",
            "timestamp": "2026-08-25T00:00:02Z",
            "seq": "event-1",
            "data": {
                "chunk": {
                    "type": "usage",
                    "usage": {
                        "input": input_tokens,
                        "output": output_tokens,
                        "cacheReadTokens": cache_read,
                        "cacheWriteTokens": cache_write,
                    },
                }
            },
        },
        {"type": "step/end", "timestamp": "2026-08-25T00:00:03Z"},
    ]


def _pi_message(entry_id: str, _session_id: str, model: str) -> dict:
    return {
        "type": "message",
        "id": entry_id,
        "timestamp": "2026-08-25T00:00:00Z",
        "message": {
            "role": "assistant",
            "model": model,
            "usage": {
                "input": 10,
                "output": 5,
                "cacheRead": 3,
                "cacheWrite": 2,
                "totalTokens": 20,
            },
        },
    }


class CollectorTests(unittest.TestCase):
    def test_cursor_csv_import_is_bom_safe_idempotent_and_deletable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "cursor.csv"
            archive = root / "data" / "cursor-usage.json"
            source.write_text(
                "\ufeffDate,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost\n"
                "2026-08-25,Included,cursor-model,No,12,10,3,5,20,$0.10\n",
                encoding="utf-8",
            )

            first = import_cursor_csv(source, archive)
            second = import_cursor_csv(source, archive)

            self.assertEqual(first, {"imported_records": 1, "added_records": 1, "total_records": 1})
            self.assertEqual(second, {"imported_records": 1, "added_records": 0, "total_records": 1})
            result = collect_usage(
                root,
                include_experimental=True,
                cursor_archive=archive,
            )
            cursor = next(bucket for bucket in result.buckets if bucket["tool"] == "Cursor")
            self.assertEqual(_bucket_total(cursor), 20)
            self.assertTrue(remove_cursor_import(archive))
            self.assertFalse(archive.exists())
            with mock.patch.object(
                collectors_module.os,
                "replace",
                side_effect=OSError("fixture write failure"),
            ):
                with self.assertRaisesRegex(RuntimeError, "无法保存"):
                    import_cursor_csv(source, archive)

    def test_experimental_switch_off_does_not_resolve_or_scan_any_experimental_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            with mock.patch.object(
                collectors_module,
                "_resolved_experimental_paths",
                side_effect=AssertionError("experimental paths must not be resolved"),
            ):
                result = collect_usage(home, include_experimental=False)

            self.assertFalse(result.diagnostics.experimental_sources_enabled)
            self.assertEqual(result.diagnostics.scan_paths, {})
            self.assertTrue(
                all(
                    status == "disabled"
                    for name, status in result.diagnostics.source_status.items()
                    if name not in ("ZCode", "Cursor")
                )
            )
            self.assertEqual(result.diagnostics.source_status["ZCode"], "missing_db")
            self.assertEqual(result.diagnostics.source_status["Cursor"], "missing_import")
            self.assertEqual(result.buckets, [])

    def test_zcode_stays_enabled_and_cursor_import_stays_user_driven_when_switch_is_off(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            create_zcode_database(
                database,
                """
                INSERT INTO model_usage (
                    id, session_id, provider_id, model_id, status, started_at,
                    input_tokens, output_tokens, reasoning_tokens,
                    cache_creation_input_tokens, cache_read_input_tokens,
                    provider_total_tokens, computed_total_tokens
                ) VALUES ('z1', 's1', 'p1', 'glm', 'completed',
                    1787616000000, 10, 5, 0, 0, 0, 15, 15);
                """,
            )
            archive = home / "cursor-usage.json"
            archive.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "records": [
                            {
                                "timestamp": "2026-08-25",
                                "kind": "Included",
                                "model": "cursor-model",
                                "max_mode": False,
                                "input_tokens": 10,
                                "cache_write_tokens": 0,
                                "cache_read_tokens": 0,
                                "output_tokens": 5,
                                "reported_total_tokens": 15,
                                "cost_usd": 0,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            result = collect_usage(
                home, include_experimental=False, cursor_archive=archive
            )

            self.assertEqual({bucket["tool"] for bucket in result.buckets}, {"ZCode", "Cursor"})
            self.assertEqual(result.diagnostics.source_status["ZCode"], "ok")
            self.assertEqual(result.diagnostics.source_status["Cursor"], "ok")

    def test_experimental_sources_are_capped_at_180_days_and_paths_are_disclosed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            recent = datetime.now(timezone.utc) - timedelta(days=30)
            old = datetime.now(timezone.utc) - timedelta(days=181)
            cursor_archive = home / "cursor-usage.json"
            cursor_archive.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "records": [
                            {
                                "timestamp": old.date().isoformat(),
                                "kind": "Included",
                                "model": "cursor-old",
                                "max_mode": False,
                                "input_tokens": 10,
                                "cache_write_tokens": 0,
                                "cache_read_tokens": 0,
                                "output_tokens": 5,
                                "reported_total_tokens": 15,
                                "cost_usd": 0,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            write_jsonl(
                home / ".qwen" / "usage" / "token-usage-window.jsonl",
                [
                    {
                        "schemaVersion": 1,
                        "id": "recent",
                        "timestamp": recent.isoformat(),
                        "model": "qwen-window",
                        "inputTokens": 10,
                        "outputTokens": 5,
                        "totalTokens": 15,
                    },
                    {
                        "schemaVersion": 1,
                        "id": "old",
                        "timestamp": old.isoformat(),
                        "model": "qwen-window",
                        "inputTokens": 1000,
                        "outputTokens": 500,
                        "totalTokens": 1500,
                    },
                ],
            )

            result = collect_usage(
                home,
                history_days=366,
                include_experimental=True,
                cursor_archive=cursor_archive,
            )

            qwen = [bucket for bucket in result.buckets if bucket["tool"] == "Qwen Code"]
            self.assertEqual(sum(map(_bucket_total, qwen)), 15)
            cursor = [bucket for bucket in result.buckets if bucket["tool"] == "Cursor"]
            self.assertEqual(sum(map(_bucket_total, cursor)), 15)
            disclosed = experimental_scan_paths(home)
            self.assertIn(
                os.fspath(home / ".local" / "share" / "opencode"),
                disclosed["OpenCode"],
            )

    def test_collects_zcode_0165_model_usage_without_opening_transcripts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "用户 Profile #1"
            home.mkdir()
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            create_zcode_database(
                database,
                """
                INSERT INTO model_usage (
                    id, session_id, provider_id, model_id, status, started_at,
                    input_tokens, output_tokens, reasoning_tokens,
                    cache_creation_input_tokens, cache_read_input_tokens,
                    provider_total_tokens, computed_total_tokens
                ) VALUES
                    ('request-ok', 'session-1', 'builtin:bigmodel-coding-plan',
                     'GLM-5.3', 'completed', 1787616000000,
                     100, 30, 7, 10, 40, NULL, 130),
                    ('request-error', 'session-1', 'builtin:bigmodel-coding-plan',
                     'GLM-5.3', 'error', 1787616060000,
                     999, 999, 0, 0, 0, 1998, 1998),
                    ('request-zero', 'session-1', 'builtin:bigmodel-coding-plan',
                     'GLM-5.3-Flash', 'completed', 1787616120000,
                     0, 0, 0, 0, 0, 0, 0);
                """,
            )
            transcript = (
                home
                / ".zcode"
                / "cli"
                / "agents"
                / "sess-private"
                / "agent-private"
                / "transcript.jsonl"
            )
            transcript.parent.mkdir(parents=True)
            transcript.write_text("private conversation content", encoding="utf-8")

            result = collect_usage(home, include_experimental=True)

            self.assertEqual(result.diagnostics.zcode_status, "ok")
            self.assertEqual(result.diagnostics.source_files["ZCode"], 1)
            self.assertEqual(result.diagnostics.exact_records["ZCode"], 1)
            self.assertEqual(result.diagnostics.skipped_records["ZCode"], 0)
            self.assertEqual(len(result.buckets), 1)
            self.assertEqual(
                result.buckets[0],
                {
                    "date": "2026-08-25",
                    "timezone": "Asia/Shanghai",
                    "tool": "ZCode",
                    "model": "GLM-5.3",
                    "source": "local",
                    "input_tokens": 50,
                    "output_tokens": 30,
                    "cache_read_tokens": 40,
                    "cache_write_tokens": 10,
                    "completeness": "exact",
                },
            )
            self.assertEqual(result.total_tokens, 130)

    def test_zcode_collector_rejects_ambiguous_reasoning_totals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            create_zcode_database(
                database,
                """
                INSERT INTO model_usage (
                    id, session_id, provider_id, model_id, status, started_at,
                    input_tokens, output_tokens, reasoning_tokens,
                    cache_creation_input_tokens, cache_read_input_tokens,
                    provider_total_tokens, computed_total_tokens
                ) VALUES
                    ('ambiguous-reasoning', 'session-1',
                     'builtin:bigmodel-coding-plan', 'GLM-5.3', 'completed',
                     1787616000000, 100, 30, 7, 10, 40, 130, 137);
                """,
            )

            result = collect_usage(home, include_experimental=True)

            self.assertEqual(result.buckets, [])
            self.assertEqual(result.diagnostics.zcode_status, "missing_valid_rows")
            self.assertEqual(result.diagnostics.exact_records["ZCode"], 0)
            self.assertEqual(result.diagnostics.skipped_records["ZCode"], 1)

    def test_zcode_collector_reads_committed_rows_while_wal_database_is_open(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            create_zcode_database(database, "")
            with closing(sqlite3.connect(database)) as writer:
                writer.execute("PRAGMA journal_mode = WAL")
                writer.execute(
                    """
                    INSERT INTO model_usage (
                        id, session_id, provider_id, model_id, status, started_at,
                        input_tokens, output_tokens, reasoning_tokens,
                        cache_creation_input_tokens, cache_read_input_tokens,
                        provider_total_tokens, computed_total_tokens
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        "live-request",
                        "live-session",
                        "builtin:bigmodel-coding-plan",
                        "GLM-5.3-Flash",
                        "completed",
                        1787616000000,
                        80,
                        20,
                        5,
                        0,
                        30,
                        100,
                        100,
                    ),
                )
                writer.commit()

                result = collect_usage(home, include_experimental=True)

            self.assertEqual(result.diagnostics.zcode_status, "ok")
            self.assertEqual(result.total_tokens, 100)
            self.assertEqual(result.buckets[0]["model"], "GLM-5.3-Flash")

    def test_zcode_schema_mismatch_and_inexact_rows_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            database.parent.mkdir(parents=True)
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("CREATE TABLE model_usage (id TEXT, status TEXT)")

            mismatch = collect_usage(home, include_experimental=True)
            self.assertEqual(mismatch.buckets, [])
            self.assertEqual(mismatch.diagnostics.zcode_status, "schema_mismatch")

            database.unlink()
            create_zcode_database(
                database,
                """
                INSERT INTO model_usage (
                    id, session_id, provider_id, model_id, status, started_at,
                    input_tokens, output_tokens, reasoning_tokens,
                    cache_creation_input_tokens, cache_read_input_tokens,
                    provider_total_tokens, computed_total_tokens
                ) VALUES
                    ('valid', 'session-1', 'builtin:bigmodel-coding-plan',
                     'GLM-5.3', 'completed', 1787616000000,
                     100, 30, 0, 10, 40, 130, 130),
                    ('invalid-cache', 'session-1', 'builtin:bigmodel-coding-plan',
                     'GLM-5.3', 'completed', 1787616060000,
                     10, 5, 0, 0, 20, 35, 35);
                """,
            )

            inexact = collect_usage(home, include_experimental=True)
            self.assertEqual(inexact.buckets, [])
            self.assertEqual(inexact.diagnostics.zcode_status, "ok")
            self.assertEqual(inexact.diagnostics.exact_records["ZCode"], 1)
            self.assertEqual(inexact.diagnostics.skipped_records["ZCode"], 1)

    def test_zcode_accepts_legacy_schema_without_session_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            database.parent.mkdir(parents=True)
            with closing(sqlite3.connect(database)) as connection:
                connection.executescript(
                    """
                    CREATE TABLE model_usage (
                        id TEXT, status TEXT, started_at INTEGER, model_id TEXT,
                        input_tokens INTEGER, output_tokens INTEGER,
                        provider_total_tokens INTEGER, computed_total_tokens INTEGER
                    );
                    INSERT INTO model_usage VALUES
                        ('legacy', 'completed', 1787616000000, 'legacy-model',
                         10, 5, 15, 15);
                    """
                )

            result = collect_usage(home, include_experimental=False)

            self.assertEqual(result.diagnostics.zcode_status, "ok")
            self.assertEqual(result.total_tokens, 15)

    def test_qwen_bad_local_date_and_kimi_bad_config_encoding_do_not_abort_other_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".qwen" / "usage" / "token-usage-crash.jsonl",
                [
                    {
                        "schemaVersion": 1,
                        "id": "bad-date",
                        "localDate": "20260901",
                        "model": "qwen-model",
                        "inputTokens": 10,
                        "outputTokens": 5,
                        "totalTokens": 15,
                    },
                    {
                        "schemaVersion": 1,
                        "id": "good-date",
                        "timestamp": "2026-08-25T00:00:00Z",
                        "model": "qwen-model",
                        "inputTokens": 10,
                        "outputTokens": 5,
                        "totalTokens": 15,
                    },
                ],
            )
            kimi_root = home / ".kimi-code"
            (kimi_root / "config.toml").parent.mkdir(parents=True, exist_ok=True)
            (kimi_root / "config.toml").write_bytes(b"default_model = \xff\xfe")
            write_jsonl(
                kimi_root / "sessions" / "s1" / "2026" / "08" / "wire.jsonl",
                [
                    {
                        "type": "step.end",
                        "time": "2026-08-25T00:00:00Z",
                        "usage": {
                            "inputOther": 10,
                            "inputCacheRead": 3,
                            "inputCacheCreation": 2,
                            "output": 5,
                        },
                    }
                ],
            )

            result = collect_usage(home, include_experimental=True)

            by_tool = {bucket["tool"]: bucket for bucket in result.buckets}
            self.assertEqual(_bucket_total(by_tool["Qwen Code"]), 15)
            self.assertEqual(_bucket_total(by_tool["Kimi"]), 20)

    def test_float_epoch_and_model_cleaning_match_mac_character_rules(self) -> None:
        parsed = collectors_module._parse_epoch_time(1787616000.875)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed.timestamp(), 1787616000)
        self.assertEqual(collectors_module._model("a\x00b\u200dc"), "a b c")
        self.assertEqual(collectors_module._model("private\ue000model"), "private\ue000model")
        self.assertEqual(collectors_module._model(None), "unknown")

    def test_malformed_cursor_csv_is_reported_without_escaping_handler_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "bad.csv"
            source.write_text('Date,"unterminated\n', encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "CSV 格式无效"):
                import_cursor_csv(source, root / "archive.json")

    def test_experimental_total_conflict_withholds_the_whole_day_model_bucket(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".grok" / "sessions" / "g1" / "updates.jsonl",
                [
                    {
                        "params": {
                            "_meta": {
                                "eventId": "good",
                                "agentTimestampMs": 1787616000000,
                            },
                            "update": {
                                "sessionUpdate": "turn_completed",
                                "usage": {
                                    "modelUsage": {
                                        "grok-model": {
                                            "inputTokens": 10,
                                            "outputTokens": 5,
                                            "totalTokens": 15,
                                        }
                                    }
                                },
                            },
                        }
                    },
                    {
                        "params": {
                            "_meta": {
                                "eventId": "conflict",
                                "agentTimestampMs": 1787616060000,
                            },
                            "update": {
                                "sessionUpdate": "turn_completed",
                                "usage": {
                                    "modelUsage": {
                                        "grok-model": {
                                            "inputTokens": 10,
                                            "outputTokens": 5,
                                            "totalTokens": 999,
                                        }
                                    }
                                },
                            },
                        }
                    },
                ],
            )

            result = collect_usage(home, include_experimental=True)

            self.assertEqual(
                [bucket for bucket in result.buckets if bucket["tool"] == "Grok"],
                [],
            )
            self.assertEqual(result.diagnostics.exact_records["Grok"], 1)
            self.assertEqual(result.diagnostics.skipped_records["Grok"], 1)

    def test_grok_rejects_cumulative_or_context_total_without_exact_components(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".grok" / "sessions" / "g1" / "updates.jsonl",
                [
                    {
                        "params": {
                            "_meta": {
                                "eventId": "context-total",
                                "agentTimestampMs": 1787616000000,
                            },
                            "update": {
                                "sessionUpdate": "turn_completed",
                                "usage": {
                                    "totalTokens": 200_000,
                                    "contextTokensUsed": 200_000,
                                },
                            },
                        }
                    },
                    {
                        "params": {
                            "_meta": {
                                "eventId": "cumulative-total",
                                "agentTimestampMs": 1787616060000,
                            },
                            "update": {
                                "sessionUpdate": "turn_completed",
                                "usage": {
                                    "modelUsage": {
                                        "grok-model": {
                                            "totalTokens": 999_999,
                                            "cumulativeTokens": 999_999,
                                        }
                                    }
                                },
                            },
                        }
                    },
                ],
            )

            result = collect_usage(home, include_experimental=True)

            self.assertEqual(
                [bucket for bucket in result.buckets if bucket["tool"] == "Grok"],
                [],
            )
            self.assertEqual(result.diagnostics.exact_records["Grok"], 0)
            self.assertEqual(result.diagnostics.skipped_records["Grok"], 2)

    def test_collects_exact_codex_deltas_and_claude_deduplication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            codex = home / ".codex" / "sessions" / "2026" / "session.jsonl"
            write_jsonl(
                codex,
                [
                    {
                        "type": "session_meta",
                        "timestamp": "2026-08-08T17:00:00Z",
                        "payload": {"id": "session-one"},
                    },
                    {"type": "turn_context", "payload": {"model": "gpt-5"}},
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T17:30:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": codex_usage(100, 10, 20),
                                "last_token_usage": codex_usage(100, 10, 20),
                            },
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T17:40:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": codex_usage(150, 20, 30),
                                "last_token_usage": codex_usage(50, 10, 10),
                            },
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T17:41:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {"total_token_usage": codex_usage(150, 20, 30)},
                        },
                    },
                ],
            )
            claude = home / ".claude" / "projects" / "project" / "session.jsonl"
            write_jsonl(
                claude,
                [
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-08T18:00:00Z",
                        "message": {
                            "id": "msg-1",
                            "model": "claude-opus-4-1",
                            "usage": {"input_tokens": 4, "output_tokens": 2},
                            "stop_reason": None,
                        },
                    },
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-08T18:00:01Z",
                        "message": {
                            "id": "msg-1",
                            "model": "claude-opus-4-1",
                            "usage": {
                                "input_tokens": 10,
                                "output_tokens": 5,
                                "cache_read_input_tokens": 3,
                                "cache_creation_input_tokens": 2,
                            },
                            "stop_reason": "end_turn",
                        },
                    },
                ],
            )

            result = collect_usage(home)
            self.assertEqual(len(result.buckets), 2)
            by_tool = {bucket["tool"]: bucket for bucket in result.buckets}
            self.assertEqual(
                by_tool["Codex"],
                {
                    "date": "2026-08-09",
                    "timezone": "Asia/Shanghai",
                    "tool": "Codex",
                    "model": "gpt-5",
                    "source": "local",
                    "input_tokens": 120,
                    "output_tokens": 20,
                    "cache_read_tokens": 30,
                    "cache_write_tokens": 0,
                    "completeness": "exact",
                },
            )
            self.assertEqual(by_tool["Claude Code"]["input_tokens"], 10)
            self.assertEqual(by_tool["Claude Code"]["cache_read_tokens"], 3)
            self.assertEqual(by_tool["Claude Code"]["cache_write_tokens"], 2)
            self.assertEqual(by_tool["Claude Code"]["output_tokens"], 5)
            self.assertEqual(result.total_tokens, 190)
            self.assertEqual(result.diagnostics.cc_switch_status, "unsupported_in_windows_v1")

    def test_codex_fork_uses_parent_anchor_without_double_counting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            root = home / ".codex" / "sessions"
            inherited = codex_usage(100, 0, 0)
            write_jsonl(
                root / "parent.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": "2026-08-08T10:00:00Z",
                        "payload": {"id": "parent"},
                    },
                    {"type": "turn_context", "payload": {"model": "gpt-5"}},
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:10:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": inherited,
                                "last_token_usage": inherited,
                            },
                        },
                    },
                ],
            )
            write_jsonl(
                root / "child.jsonl",
                [
                    {
                        "type": "session_meta",
                        "timestamp": "2026-08-08T10:11:00Z",
                        "payload": {"id": "child", "parent_thread_id": "parent"},
                    },
                    {"type": "turn_context", "payload": {"model": "gpt-5"}},
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:11:01Z",
                        "payload": {
                            "type": "token_count",
                            "info": {"total_token_usage": inherited},
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:12:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": codex_usage(150, 0, 0),
                                "last_token_usage": codex_usage(50, 0, 0),
                            },
                        },
                    },
                ],
            )
            result = collect_usage(home)
            self.assertEqual(len(result.buckets), 1)
            self.assertEqual(result.total_tokens, 150)

    def test_incomplete_codex_breakdown_is_omitted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".codex" / "sessions" / "bad.jsonl",
                [
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:00:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 10,
                                    "output_tokens": 5,
                                    "total_tokens": 999,
                                }
                            },
                        },
                    }
                ],
            )
            result = collect_usage(home)
            self.assertEqual(result.buckets, [])
            self.assertGreater(result.diagnostics.skipped_records["Codex"], 0)

    def test_one_unknown_record_excludes_the_whole_exact_day_model_bucket(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".codex" / "sessions" / "partial.jsonl",
                [
                    {"type": "turn_context", "payload": {"model": "gpt-5"}},
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:00:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": codex_usage(10, 5, 0),
                                "last_token_usage": codex_usage(10, 5, 0),
                            },
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:01:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 20,
                                    "output_tokens": 10,
                                    "total_tokens": 999,
                                }
                            },
                        },
                    },
                ],
            )
            result = collect_usage(home)
            self.assertEqual(result.buckets, [])
            self.assertGreater(result.diagnostics.skipped_records["Codex"], 0)

    def test_incomplete_claude_records_withhold_the_exact_bucket(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".claude" / "projects" / "partial.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-08T10:00:00Z",
                        "message": {
                            "id": "complete",
                            "model": "claude-opus-4-1",
                            "usage": {"input_tokens": 100, "output_tokens": 50},
                            "stop_reason": "end_turn",
                        },
                    },
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-08T10:01:00Z",
                        "message": {
                            "id": "invalid-usage",
                            "model": "claude-opus-4-1",
                            "usage": "9999",
                        },
                    },
                    {
                        "type": "assistant",
                        "message": {
                            "id": "missing-timestamp",
                            "model": "claude-opus-4-1",
                            "usage": {"input_tokens": 10, "output_tokens": 5},
                        },
                    },
                ],
            )

            result = collect_usage(home)

            self.assertEqual(result.buckets, [])
            self.assertEqual(result.diagnostics.exact_records["Claude Code"], 1)
            self.assertEqual(result.diagnostics.skipped_records["Claude Code"], 2)

    def test_claude_assistant_without_usage_is_not_silently_filtered(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".claude" / "projects" / "missing-usage.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-08T10:00:00Z",
                        "message": {
                            "id": "complete",
                            "model": "claude-sonnet-4",
                            "usage": {"input_tokens": 40, "output_tokens": 20},
                        },
                    },
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-08T10:01:00Z",
                        "message": {
                            "id": "missing-usage",
                            "model": "claude-sonnet-4",
                            "content": [],
                        },
                    },
                ],
            )

            result = collect_usage(home)

            self.assertEqual(result.buckets, [])
            self.assertEqual(result.diagnostics.exact_records["Claude Code"], 1)
            self.assertEqual(result.diagnostics.skipped_records["Claude Code"], 1)

    def test_recently_modified_logs_do_not_upload_out_of_window_events(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            write_jsonl(
                home / ".claude" / "projects" / "old.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": "2020-01-01T00:00:00Z",
                        "message": {
                            "id": "old-response",
                            "model": "claude-old",
                            "usage": {"input_tokens": 10, "output_tokens": 5},
                            "stop_reason": "end_turn",
                        },
                    }
                ],
            )
            result = collect_usage(home, history_days=366)
            self.assertEqual(result.buckets, [])

    def test_codex_context_window_sentinel_does_not_poison_exact_bucket(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            zero = {
                "input_tokens": 0,
                "output_tokens": 0,
                "cached_input_tokens": 0,
                "total_tokens": 0,
            }
            sentinel = dict(zero, total_tokens=200_000)
            write_jsonl(
                home / ".codex" / "sessions" / "sentinel.jsonl",
                [
                    {"type": "turn_context", "payload": {"model": "gpt-5"}},
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:00:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": codex_usage(100, 0, 0),
                                "last_token_usage": codex_usage(100, 0, 0),
                            },
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:01:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": sentinel,
                                "last_token_usage": zero,
                                "model_context_window": 200_000,
                            },
                        },
                    },
                    {
                        "type": "event_msg",
                        "timestamp": "2026-08-08T10:02:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": codex_usage(150, 0, 0),
                                "last_token_usage": codex_usage(50, 0, 0),
                            },
                        },
                    },
                ],
            )
            result = collect_usage(home)
            self.assertEqual(result.total_tokens, 150)
            self.assertEqual(len(result.buckets), 1)

    def test_hermes_workbuddy_codebuddy_qoder_and_kimi_match_frozen_rules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            hermes = home / ".hermes" / "state.db"
            hermes.parent.mkdir(parents=True)
            with closing(sqlite3.connect(hermes)) as connection:
                connection.executescript(
                    """
                    CREATE TABLE sessions (
                        id TEXT, started_at INTEGER, model TEXT,
                        input_tokens INTEGER, output_tokens INTEGER,
                        cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                        reasoning_tokens INTEGER
                    );
                    INSERT INTO sessions VALUES
                        ('h1', 1787616000, 'hermes-model', 10, 5, 3, 2, 1);
                    """
                )
            write_jsonl(
                home / ".workbuddy" / "projects" / "p" / "session.jsonl",
                [
                    {
                        "type": "message",
                        "timestamp": 1787616000000,
                        "sessionId": "wb",
                        "providerData": {
                            "messageId": "same",
                            "requestModelId": "right-model",
                            "requestModelName": "wrong-model",
                            "rawUsage": {
                                "prompt_tokens": 100,
                                "completion_tokens": 20,
                                "total_tokens": 120,
                                "prompt_cache_hit_tokens": 80,
                            },
                        },
                    },
                    {
                        "type": "message",
                        "timestamp": 1787616000000,
                        "sessionId": "wb",
                        "providerData": {
                            "messageId": "same",
                            "requestModelId": "right-model",
                            "rawUsage": {"prompt_tokens": 999, "completion_tokens": 999},
                        },
                    },
                ],
            )
            write_jsonl(
                home / ".codebuddy" / "projects" / "p" / "session.jsonl",
                [
                    {
                        "type": "user",
                        "timestamp": "2026-08-25T00:00:00Z",
                        "message": {"role": "user", "usage": {"input_tokens": 999, "output_tokens": 999}},
                    },
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-25T00:01:00Z",
                        "message": {
                            "id": "cb1",
                            "role": "assistant",
                            "model": "claude-codebuddy",
                            "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 80, "total_tokens": 120},
                        },
                    },
                ],
            )
            write_jsonl(
                home / ".qoder" / "projects" / "p" / "session.jsonl",
                [
                    {
                        "type": "session_summary",
                        "role": "assistant",
                        "timestamp": "2026-08-25T00:00:00Z",
                        "usage": {"input_tokens": 999, "output_tokens": 999},
                    },
                    {
                        "type": "assistant",
                        "timestamp": "2026-08-25T00:02:00Z",
                        "session_id": "q1",
                        "message": {
                            "id": "q1-request",
                            "role": "assistant",
                            "model": "qwen3-coder",
                            "usage": {"input_tokens": 70, "output_tokens": 15, "cache_read_input_tokens": 50},
                        },
                    },
                ],
            )
            write_jsonl(
                home / ".kimi-code" / "sessions" / "s1" / "2026" / "08" / "wire.jsonl",
                [
                    {"type": "config.update", "modelAlias": "moonshot/kimi-k2"},
                    {
                        "type": "step.end",
                        "time": 1787616000000,
                        "uuid": "k1",
                        "usage": {"inputOther": 10, "inputCacheRead": 3, "inputCacheCreation": 2, "output": 5},
                    },
                ],
            )

            result = collect_usage(home, include_experimental=True)
            by_tool = {bucket["tool"]: bucket for bucket in result.buckets}

            self.assertEqual(_bucket_total(by_tool["Hermes Agent"]), 20)
            self.assertEqual(_bucket_total(by_tool["WorkBuddy"]), 120)
            self.assertEqual(by_tool["WorkBuddy"]["model"], "right-model")
            self.assertEqual(_bucket_total(by_tool["CodeBuddy"]), 120)
            self.assertEqual(_bucket_total(by_tool["Qoder"]), 135)
            self.assertEqual(_bucket_total(by_tool["Kimi"]), 20)
            self.assertEqual(result.diagnostics.exact_records["WorkBuddy"], 1)
            for source in ("Hermes Agent", "WorkBuddy", "CodeBuddy", "Qoder", "Kimi"):
                self.assertEqual(result.diagnostics.source_status[source], "ok")

    def test_opencode_grok_qwen_cursor_and_cline_cache_and_total_rules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            localappdata = home / "AppData" / "Local"
            opencode = localappdata / "opencode" / "opencode.db"
            opencode.parent.mkdir(parents=True)
            with closing(sqlite3.connect(opencode)) as connection:
                connection.execute("CREATE TABLE message (id TEXT, session_id TEXT, data TEXT)")
                connection.execute(
                    "INSERT INTO message VALUES (?, ?, ?)",
                    (
                        "m1",
                        "s1",
                        json.dumps(
                            {
                                "role": "assistant",
                                "time": {"created": 1787616000000},
                                "modelID": "opencode-model",
                                "tokens": {"input": 10, "output": 5, "reasoning": 1, "cache": {"read": 3, "write": 2}},
                            }
                        ),
                    ),
                )
                connection.commit()
            write_jsonl(
                home / ".grok" / "sessions" / "g1" / "updates.jsonl",
                [
                    {
                        "params": {
                            "_meta": {"agentTimestampMs": 1787616000000, "eventId": "g1"},
                            "update": {
                                "sessionUpdate": "turn_completed",
                                "usage": {
                                    "modelUsage": {
                                        "grok-4-5-build": {
                                            "inputTokens": 100,
                                            "cachedReadTokens": 80,
                                            "cacheCreationTokens": 5,
                                            "outputTokens": 20,
                                            "totalTokens": 120,
                                        }
                                    }
                                },
                            },
                        }
                    }
                ],
            )
            write_jsonl(
                home / ".qwen" / "usage" / "token-usage-1.jsonl",
                [
                    {
                        "schemaVersion": 1,
                        "id": "qw1",
                        "timestamp": "2026-08-25T00:00:00Z",
                        "model": "qwen3-coder",
                        "inputTokens": 100,
                        "outputTokens": 20,
                        "cachedTokens": 80,
                        "thoughtsTokens": 4,
                        "totalTokens": 124,
                    }
                ],
            )
            cursor_archive = home / "cursor-usage.json"
            cursor_archive.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "records": [
                            {
                                "timestamp": "2026-08-25",
                                "kind": "Included",
                                "model": "cursor-model",
                                "max_mode": False,
                                "input_tokens": 10,
                                "cache_write_tokens": 2,
                                "cache_read_tokens": 3,
                                "output_tokens": 5,
                                "reported_total_tokens": 20,
                                "cost_usd": 0.1,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            cline_archive = home / ".cline" / "data" / "tasks" / "c1.messages.json"
            cline_archive.parent.mkdir(parents=True)
            cline_archive.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "sessionId": "cline-session",
                        "messages": [
                            {
                                "id": "cline-1",
                                "role": "assistant",
                                "ts": 1787616000000,
                                "modelInfo": {"id": "cline-model"},
                                "metrics": {"inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 80, "cacheWriteTokens": 0},
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch.dict(os.environ, {"LOCALAPPDATA": os.fspath(localappdata)}):
                result = collect_usage(
                    home,
                    include_experimental=True,
                    cursor_archive=cursor_archive,
                )
            by_tool = {bucket["tool"]: bucket for bucket in result.buckets}

            self.assertEqual(_bucket_total(by_tool["OpenCode"]), 21)
            self.assertEqual(_bucket_total(by_tool["Grok"]), 120)
            self.assertEqual(by_tool["Grok"]["model"], "grok-4.5-build")
            self.assertEqual(_bucket_total(by_tool["Qwen Code"]), 124)
            self.assertEqual(_bucket_total(by_tool["Cursor"]), 20)
            self.assertEqual(_bucket_total(by_tool["Cline"]), 120)
            for source in ("OpenCode", "Grok", "Qwen Code", "Cursor", "Cline"):
                self.assertEqual(result.diagnostics.source_status[source], "ok")

    def test_copilot_preference_antigravity_and_droid_cumulative_barriers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            store = home / ".copilot" / "session-store.db"
            store.parent.mkdir(parents=True)
            with closing(sqlite3.connect(store)) as connection:
                connection.execute(
                    """CREATE TABLE assistant_usage_events (
                        id TEXT, session_id TEXT, model TEXT, input_tokens INTEGER,
                        output_tokens INTEGER, cache_read_tokens INTEGER,
                        cache_write_tokens INTEGER, reasoning_tokens INTEGER,
                        token_details_json TEXT, created_at TEXT
                    )"""
                )
                connection.executemany(
                    "INSERT INTO assistant_usage_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        ("a", "session-1", "gpt-5", 100, 20, 80, 0, 0, None, "2026-08-25T00:00:00Z"),
                        ("b", "session-1", "gpt-5", 50, 10, 30, 0, 0, None, "2026-08-25T02:00:00Z"),
                    ],
                )
                connection.commit()
            otel = home / ".copilot" / "otel" / "spans.jsonl"
            spans = [
                _otel_span("same-session", "same", "2026-08-25T01:00:00Z", session="session-1"),
                _otel_span("same-day-fallback", "fallback", "2026-08-25T03:00:00Z"),
                _otel_span("old-fallback", "old", "2026-08-24T03:00:00Z"),
                _otel_span("chat", "chat", "2026-08-25T03:00:00Z", service="copilot-chat"),
            ]
            write_jsonl(otel, spans)
            write_jsonl(
                home / ".gemini" / "antigravity" / "brain" / "x" / ".system_generated" / "logs" / "transcript.jsonl",
                [
                    {"type": "status", "timestamp": "2026-08-25T00:00:00Z", "usage": {"promptTokenCount": 999, "candidatesTokenCount": 999, "totalTokenCount": 1998}},
                    {"type": "result", "timestamp": "2026-08-25T00:01:00Z", "model": "gemini-thinking", "usageMetadata": {"promptTokenCount": 90, "candidatesTokenCount": 10, "thoughtsTokenCount": 4, "cachedContentTokenCount": 60, "totalTokenCount": 104}},
                ],
            )
            write_jsonl(
                home / ".factory" / "projects" / "d1" / "session.jsonl",
                [
                    {"type": "TokenUsageUpdate", "timestamp": "2026-08-25T00:00:00Z", "tokenUsage": {"inputTokens": 999, "outputTokens": 999}},
                    {"type": "result", "timestamp": "2026-08-25T00:01:00Z", "model": "droid-model", "tokenUsage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}},
                ],
            )

            result = collect_usage(home, include_experimental=True)
            totals = {}
            for bucket in result.buckets:
                totals[bucket["tool"]] = totals.get(bucket["tool"], 0) + _bucket_total(bucket)

            self.assertEqual(totals["Copilot CLI"], 300)
            self.assertEqual(totals["Copilot Chat"], 120)
            self.assertEqual(totals["Antigravity"], 104)
            self.assertEqual(totals["Droid"], 15)
            self.assertEqual(result.diagnostics.exact_records["Copilot OTel"], 2)

    def test_dsh_zstd_preference_partial_decoder_pi_and_openclaw_dedupe(self) -> None:
        if collectors_module.zstandard is None:
            self.skipTest("zstandard dependency is not installed")
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            dsh_root = home / ".dsh" / "sessions"
            twin_plain = dsh_root / "s1" / "session.jsonl"
            dsh_lines = _dsh_lines(10, 5, 3, 2)
            twin_plain.parent.mkdir(parents=True)
            twin_plain.write_text("\n".join(map(json.dumps, _dsh_lines(999, 999, 0, 0))) + "\n", encoding="utf-8")
            twin_compressed = twin_plain.with_suffix(twin_plain.suffix + ".zstd")
            twin_compressed.write_bytes(
                collectors_module.zstandard.ZstdCompressor().compress(
                    ("\n".join(map(json.dumps, dsh_lines)) + "\n").encode("utf-8")
                )
            )
            pi = home / ".pi" / "agent" / "sessions" / "pi.jsonl"
            write_jsonl(pi, [_pi_message("same", "pi-session", "pi-model")])
            openclaw = home / ".openclaw"
            database = openclaw / "openclaw-agent.sqlite"
            database.parent.mkdir(parents=True)
            openclaw_event = _pi_message("shared", "oc-session", "openclaw-model")
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER)")
                connection.execute(
                    "INSERT INTO transcript_events VALUES (?, ?, ?, ?)",
                    ("oc-session", 1, json.dumps(openclaw_event), 1787616000000),
                )
                connection.commit()
            transcript = openclaw / "agents" / "main" / "sessions" / "oc-session.jsonl"
            write_jsonl(transcript, [openclaw_event])

            result = collect_usage(home, include_experimental=True)
            totals = {bucket["tool"]: _bucket_total(bucket) for bucket in result.buckets}
            self.assertEqual(totals["dsh"], 20)
            self.assertEqual(totals["Pi"], 20)
            self.assertEqual(totals["OpenClaw"], 20)
            self.assertEqual(result.diagnostics.exact_records["OpenClaw"], 1)

            compressed_only = dsh_root / "s2" / "session.jsonl.zstd"
            compressed_only.parent.mkdir(parents=True)
            compressed_only.write_bytes(twin_compressed.read_bytes())
            with mock.patch.object(collectors_module, "zstandard", None):
                partial = collect_usage(home, include_experimental=True)
            self.assertEqual(partial.diagnostics.source_status["dsh"], "partial_missing_decoder")
            self.assertEqual(partial.diagnostics.exact_records["dsh"], 1)

    def test_dsh_reports_missing_decoder_for_uncovered_compressed_only_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "sessions"
            compressed = root / "s1" / "session.jsonl.zstd"
            compressed.parent.mkdir(parents=True)
            compressed.write_bytes(b"not-read-without-decoder")

            with mock.patch.object(collectors_module, "zstandard", None):
                result = collectors_module._collect_dsh(
                    root, datetime(2026, 1, 1, tzinfo=timezone.utc)
                )

            self.assertEqual(result.status, "missing_decoder")
            self.assertEqual(result.records, [])

    def test_dsh_keeps_latest_usage_chunk_per_step_across_multiple_steps(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            log = home / ".dsh" / "sessions" / "s1" / "session.jsonl"
            values = [
                {
                    "type": "request/header",
                    "data": {"config": {"model": "deepseek-v3"}},
                }
            ]
            for step, totals in (("one", (10, 20)), ("two", (30, 40))):
                values.append(
                    {
                        "type": "step/start",
                        "timestamp": "2026-08-25T00:00:00Z",
                        "data": {"id": step},
                    }
                )
                for offset, total in enumerate(totals):
                    values.append(
                        {
                            "type": "assistant/chunk",
                            "timestamp": f"2026-08-25T00:00:0{offset + 1}Z",
                            "seq": f"{step}-{offset}",
                            "data": {
                                "chunk": {
                                    "type": "usage",
                                    "usage": {"input": total, "output": 0},
                                }
                            },
                        }
                    )
                values.append(
                    {
                        "type": "step/end",
                        "timestamp": "2026-08-25T00:00:03Z",
                    }
                )
            write_jsonl(log, values)

            result = collect_usage(home, include_experimental=True)

            dsh = [bucket for bucket in result.buckets if bucket["tool"] == "dsh"]
            self.assertEqual(sum(map(_bucket_total, dsh)), 60)
            self.assertEqual(result.diagnostics.exact_records["dsh"], 2)

    def test_local_dashboard_server_refuses_non_loopback_binding(self) -> None:
        import tokenfleet.local_dashboard as dashboard_module

        self.assertFalse(dashboard_module._ExclusiveThreadingHTTPServer.allow_reuse_address)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with mock.patch.dict(os.environ, {"LOCALAPPDATA": os.fspath(root)}):
                paths = ClientPaths.default()
            with mock.patch("tokenfleet.local_dashboard._ExclusiveThreadingHTTPServer") as server_class:
                create_dashboard_server(paths, port=0)
                self.assertEqual(server_class.call_args.args[0][0], "127.0.0.1")
            with self.assertRaises(RuntimeError):
                create_dashboard_server(paths, host="0.0.0.0", port=0)


if __name__ == "__main__":
    unittest.main()
