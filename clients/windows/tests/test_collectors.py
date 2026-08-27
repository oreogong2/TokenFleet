from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tokenfleet.collectors import collect_usage


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
    with sqlite3.connect(path) as connection:
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


class CollectorTests(unittest.TestCase):
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
                     100, 30, 7, 10, 40, NULL, 137),
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

            result = collect_usage(home)

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

    def test_zcode_collector_reads_committed_rows_while_wal_database_is_open(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            create_zcode_database(database, "")
            with sqlite3.connect(database) as writer:
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
                        105,
                        105,
                    ),
                )
                writer.commit()

                result = collect_usage(home)

            self.assertEqual(result.diagnostics.zcode_status, "ok")
            self.assertEqual(result.total_tokens, 100)
            self.assertEqual(result.buckets[0]["model"], "GLM-5.3-Flash")

    def test_zcode_schema_mismatch_and_inexact_rows_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            database = home / ".zcode" / "cli" / "db" / "db.sqlite"
            database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE model_usage (id TEXT, status TEXT)")

            mismatch = collect_usage(home)
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

            inexact = collect_usage(home)
            self.assertEqual(inexact.buckets, [])
            self.assertEqual(inexact.diagnostics.zcode_status, "ok")
            self.assertEqual(inexact.diagnostics.exact_records["ZCode"], 1)
            self.assertEqual(inexact.diagnostics.skipped_records["ZCode"], 1)

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


if __name__ == "__main__":
    unittest.main()
