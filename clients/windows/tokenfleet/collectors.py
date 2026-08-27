from __future__ import annotations

import json
import os
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

from .constants import (
    ACCOUNTING_TIMEZONE,
    MAX_RELEVANT_LINE_BYTES,
    MAX_SOURCE_FILES,
    MAX_TOKEN_VALUE,
)
from .protocol import ProtocolError, validate_bucket

SHANGHAI = timezone(timedelta(hours=8), name=ACCOUNTING_TIMEZONE)


@dataclass(frozen=True)
class UsageCounts:
    input_total: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0

    @property
    def total(self) -> int:
        return self.input_total + self.output

    @property
    def exact(self) -> bool:
        return (
            all(
                type(value) is int and 0 <= value <= MAX_TOKEN_VALUE
                for value in (
                    self.input_total,
                    self.output,
                    self.cache_read,
                    self.cache_write,
                )
            )
            and self.cache_read + self.cache_write <= self.input_total
        )

    def bucket_components(self) -> tuple[int, int, int, int]:
        if not self.exact:
            raise ProtocolError("usage components are incomplete")
        return (
            self.input_total - self.cache_read - self.cache_write,
            self.output,
            self.cache_read,
            self.cache_write,
        )

    def subtract(self, earlier: "UsageCounts") -> "UsageCounts | None":
        values = (
            self.input_total - earlier.input_total,
            self.output - earlier.output,
            self.cache_read - earlier.cache_read,
            self.cache_write - earlier.cache_write,
        )
        if any(value < 0 for value in values):
            return None
        result = UsageCounts(*values)
        return result if result.exact else None


@dataclass(frozen=True)
class UsageRecord:
    day: str
    tool: str
    model: str
    counts: UsageCounts


@dataclass
class CollectionDiagnostics:
    source_files: dict[str, int] = field(
        default_factory=lambda: {"Codex": 0, "Claude Code": 0, "ZCode": 0}
    )
    exact_records: dict[str, int] = field(
        default_factory=lambda: {"Codex": 0, "Claude Code": 0, "ZCode": 0}
    )
    skipped_records: dict[str, int] = field(
        default_factory=lambda: {"Codex": 0, "Claude Code": 0, "ZCode": 0}
    )
    zcode_status: str = "missing_db"
    cc_switch_status: str = "unsupported_in_windows_v1"


@dataclass(frozen=True)
class CollectionResult:
    buckets: list[dict[str, Any]]
    diagnostics: CollectionDiagnostics

    @property
    def total_tokens(self) -> int:
        return sum(
            bucket["input_tokens"]
            + bucket["output_tokens"]
            + bucket["cache_read_tokens"]
            + bucket["cache_write_tokens"]
            for bucket in self.buckets
        )


@dataclass(frozen=True)
class CodexEvent:
    timestamp: datetime | None
    model: str
    cumulative_present: bool
    cumulative: UsageCounts | None
    cumulative_raw_total: int
    last: UsageCounts | None
    last_raw_total: int
    context_window: int


@dataclass(frozen=True)
class CodexScan:
    session_id: str
    created_at: datetime | None
    parent_session_id: str | None
    events: list[CodexEvent]


def collect_usage(home: Path, *, history_days: int = 366) -> CollectionResult:
    if not 1 <= history_days <= 366 * 5:
        raise ValueError("history_days must be between 1 and 1830")
    cutoff = datetime.now(timezone.utc) - timedelta(days=history_days + 2)
    diagnostics = CollectionDiagnostics()
    codex_paths = _jsonl_files(home / ".codex" / "sessions", cutoff)
    claude_paths = _jsonl_files(home / ".claude" / "projects", cutoff)
    if len(codex_paths) + len(claude_paths) > MAX_SOURCE_FILES:
        raise RuntimeError("too many local JSONL files to scan safely")
    diagnostics.source_files["Codex"] = len(codex_paths)
    diagnostics.source_files["Claude Code"] = len(claude_paths)

    codex_records, incomplete_codex_buckets = _collect_codex(codex_paths, diagnostics)
    claude_records, incomplete_claude_buckets = _collect_claude(
        claude_paths, diagnostics
    )
    zcode_records, incomplete_zcode_buckets = _collect_zcode(
        home / ".zcode" / "cli" / "db" / "db.sqlite", diagnostics
    )
    today = datetime.now(timezone.utc).astimezone(SHANGHAI).date()
    oldest = today - timedelta(days=history_days - 1)
    codex_records = [
        record for record in codex_records if _day_is_in_range(record.day, oldest, today)
    ]
    claude_records = [
        record for record in claude_records if _day_is_in_range(record.day, oldest, today)
    ]
    zcode_records = [
        record for record in zcode_records if _day_is_in_range(record.day, oldest, today)
    ]
    incomplete_codex_buckets = {
        key for key in incomplete_codex_buckets if _day_is_in_range(key[0], oldest, today)
    }
    incomplete_claude_buckets = {
        key
        for key in incomplete_claude_buckets
        if _day_is_in_range(key[0], oldest, today)
    }
    incomplete_zcode_buckets = {
        key for key in incomplete_zcode_buckets if _day_is_in_range(key[0], oldest, today)
    }
    buckets = _aggregate(
        codex_records + claude_records + zcode_records,
        excluded_keys=(
            incomplete_codex_buckets
            | incomplete_claude_buckets
            | incomplete_zcode_buckets
        ),
    )
    return CollectionResult(buckets=buckets, diagnostics=diagnostics)


def _day_is_in_range(value: str, oldest: date, newest: date) -> bool:
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        return False
    return oldest <= parsed <= newest


def _jsonl_files(root: Path, cutoff: datetime) -> list[Path]:
    if not root.is_dir():
        return []
    found: list[Path] = []
    for path in root.rglob("*.jsonl"):
        try:
            stat = path.stat()
        except OSError:
            continue
        modified = datetime.fromtimestamp(stat.st_mtime, timezone.utc)
        if path.is_file() and modified >= cutoff:
            found.append(path)
            if len(found) > MAX_SOURCE_FILES:
                break
    return sorted(found, key=lambda item: os.fspath(item).casefold())


def _json_lines(
    path: Path, *, matching_any: tuple[bytes, ...] = ()
) -> Iterable[dict[str, Any]]:
    try:
        with path.open("rb") as handle:
            for raw_line in handle:
                if len(raw_line) > MAX_RELEVANT_LINE_BYTES:
                    continue
                if matching_any and not any(marker in raw_line for marker in matching_any):
                    continue
                try:
                    value = json.loads(raw_line)
                except (UnicodeError, json.JSONDecodeError):
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc)


def _day(value: datetime | None) -> str | None:
    return value.astimezone(SHANGHAI).date().isoformat() if value else None


def _nonnegative_integer(value: Any) -> int:
    if type(value) is int:
        return max(0, value)
    if isinstance(value, float) and value.is_integer():
        return max(0, int(value))
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return 0


def _first_integer(raw: dict[str, Any], keys: tuple[str, ...]) -> int:
    for key in keys:
        if key in raw:
            return _nonnegative_integer(raw[key])
    return 0


def _normalize_codex(raw: Any) -> UsageCounts | None:
    if not isinstance(raw, dict):
        return None
    counts = UsageCounts(
        input_total=_first_integer(raw, ("input_tokens", "input")),
        output=_first_integer(raw, ("output_tokens", "output")),
        cache_read=_first_integer(
            raw, ("cached_input_tokens", "cache_read_input_tokens", "cached")
        ),
        cache_write=_first_integer(
            raw, ("cache_creation_input_tokens", "cache_write_input_tokens")
        ),
    )
    explicit_total = _first_integer(raw, ("total_tokens", "total"))
    if explicit_total and explicit_total != counts.total:
        return None
    return counts if counts.exact else None


def _raw_usage_total(raw: Any) -> int:
    if not isinstance(raw, dict):
        return 0
    explicit = _first_integer(raw, ("total_tokens", "total"))
    if explicit:
        return explicit
    return _first_integer(raw, ("input_tokens", "input")) + _first_integer(
        raw, ("output_tokens", "output")
    )


def _normalize_claude(raw: Any) -> UsageCounts | None:
    if not isinstance(raw, dict):
        return None
    raw_input = _first_integer(raw, ("input_tokens", "input"))
    cache_write = _first_integer(raw, ("cache_creation_input_tokens",))
    cache_read = _first_integer(
        raw, ("cache_read_input_tokens", "cached_input_tokens", "cached")
    )
    counts = UsageCounts(
        input_total=raw_input + cache_write + cache_read,
        output=_first_integer(raw, ("output_tokens", "output")),
        cache_read=cache_read,
        cache_write=cache_write,
    )
    return counts if counts.exact else None


def _model(value: Any) -> str:
    if not isinstance(value, str):
        return "unknown"
    trimmed = value.strip()
    if not trimmed or len(trimmed) > 128:
        return "unknown"
    if any(ord(character) < 32 or ord(character) == 127 for character in trimmed):
        return "unknown"
    return trimmed


def _parent_session_id(payload: dict[str, Any]) -> str | None:
    source = payload.get("source")
    if isinstance(source, dict):
        subagent = source.get("subagent")
        if isinstance(subagent, dict):
            thread_spawn = subagent.get("thread_spawn")
            if isinstance(thread_spawn, dict):
                parent = thread_spawn.get("parent_thread_id")
                if isinstance(parent, str) and parent.strip():
                    return parent.strip()
    for key in ("parent_thread_id", "forked_from_id"):
        parent = payload.get(key)
        if isinstance(parent, str) and parent.strip():
            return parent.strip()
    return None


def _scan_codex(path: Path) -> CodexScan:
    session_id: str | None = None
    created_at: datetime | None = None
    parent: str | None = None
    model = "unknown"
    events: list[CodexEvent] = []
    for obj in _json_lines(
        path,
        matching_any=(b'"session_meta"', b'"turn_context"', b'"token_count"'),
    ):
        kind = obj.get("type")
        payload = obj.get("payload")
        if not isinstance(payload, dict):
            payload = {}
        if kind == "session_meta" and session_id is None:
            candidate = payload.get("id")
            if isinstance(candidate, str) and candidate.strip():
                session_id = candidate.strip()
            created_at = _parse_time(obj.get("timestamp")) or _parse_time(
                payload.get("timestamp")
            )
            parent = _parent_session_id(payload)
        if kind == "turn_context":
            model = _model(payload.get("model", model))
        if kind != "event_msg" or payload.get("type") != "token_count":
            continue
        info = payload.get("info")
        if not isinstance(info, dict):
            continue
        cumulative_raw = info.get("total_token_usage")
        last_raw = info.get("last_token_usage")
        events.append(
            CodexEvent(
                timestamp=_parse_time(obj.get("timestamp")),
                model=model,
                cumulative_present="total_token_usage" in info,
                cumulative=_normalize_codex(cumulative_raw),
                cumulative_raw_total=_raw_usage_total(cumulative_raw),
                last=_normalize_codex(last_raw),
                last_raw_total=_raw_usage_total(last_raw),
                context_window=_nonnegative_integer(info.get("model_context_window")),
            )
        )
    if not session_id:
        try:
            session_id = str(uuid.UUID(path.stem))
        except ValueError:
            session_id = path.stem
    return CodexScan(session_id, created_at, parent, events)


def _collect_codex(
    paths: list[Path], diagnostics: CollectionDiagnostics
) -> tuple[list[UsageRecord], set[tuple[str, str, str]]]:
    scans_by_id: dict[str, CodexScan] = {}
    for path in paths:
        scan = _scan_codex(path)
        current = scans_by_id.get(scan.session_id)
        if current is None or len(scan.events) > len(current.events):
            scans_by_id[scan.session_id] = scan

    anchors: dict[str, list[tuple[datetime, UsageCounts]]] = {}
    for scan in scans_by_id.values():
        anchors[scan.session_id] = [
            (event.timestamp, event.cumulative)
            for event in scan.events
            if event.timestamp is not None
            and event.cumulative_present
            and event.cumulative is not None
            and event.cumulative.total > 0
        ]

    records: list[UsageRecord] = []
    incomplete_buckets: set[tuple[str, str, str]] = set()
    for scan in sorted(scans_by_id.values(), key=lambda value: value.session_id):
        parent_anchor: UsageCounts | None = None
        if scan.parent_session_id and scan.created_at:
            candidates = [
                pair
                for pair in anchors.get(scan.parent_session_id, [])
                if pair[0] <= scan.created_at
            ]
            if candidates:
                parent_anchor = max(candidates, key=lambda pair: pair[0])[1]
        scan_records, skipped, incomplete = _codex_records(scan, parent_anchor)
        records.extend(scan_records)
        incomplete_buckets.update(incomplete)
        diagnostics.exact_records["Codex"] += len(scan_records)
        diagnostics.skipped_records["Codex"] += skipped
    return records, incomplete_buckets


def _codex_records(
    scan: CodexScan, parent_anchor: UsageCounts | None
) -> tuple[list[UsageRecord], int, set[tuple[str, str, str]]]:
    records: list[UsageRecord] = []
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()

    def mark_incomplete(event: CodexEvent) -> None:
        day = _day(event.timestamp)
        if day is not None:
            incomplete.add((day, "Codex", event.model))

    has_cumulative = any(event.cumulative_present for event in scan.events)
    if not has_cumulative:
        seen: set[tuple[str, UsageCounts]] = set()
        for event in scan.events:
            day = _day(event.timestamp)
            if day is None or event.last is None or event.last.total <= 0:
                if event.last_raw_total > 0:
                    mark_incomplete(event)
                skipped += 1
                continue
            identity = (event.timestamp.isoformat() if event.timestamp else "", event.last)
            if identity in seen:
                continue
            seen.add(identity)
            records.append(UsageRecord(day, "Codex", event.model, event.last))
        return records, skipped, incomplete

    previous: UsageCounts | None = None
    start = 0
    if parent_anchor is not None:
        for index, event in enumerate(scan.events):
            if event.cumulative_present and event.cumulative == parent_anchor:
                previous = parent_anchor
                start = index + 1
                break
    for index in range(start, len(scan.events)):
        event = scan.events[index]
        current = event.cumulative
        day = _day(event.timestamp)
        if not event.cumulative_present:
            if event.last_raw_total > 0:
                mark_incomplete(event)
            skipped += 1
            continue
        if current is None:
            if not _is_raw_context_sentinel(event) and event.cumulative_raw_total > 0:
                mark_incomplete(event)
            skipped += 1
            continue
        if current.total <= 0 or day is None:
            skipped += 1
            continue
        if previous is not None and current.total == previous.total:
            continue
        is_reset = False
        if previous is not None and current.total < previous.total:
            if _is_context_sentinel(event):
                skipped += 1
                continue
            if event.last is not None and event.last.total == current.total:
                is_reset = True
            else:
                next_totals = [
                    following.cumulative.total
                    for following in scan.events[index + 1 :]
                    if following.cumulative_present
                    and following.cumulative is not None
                    and following.cumulative.total != current.total
                ]
                is_reset = bool(
                    next_totals
                    and next_totals[0] > current.total
                    and next_totals[0] < previous.total
                )
            if not is_reset:
                mark_incomplete(event)
                skipped += 1
                continue

        delta_total = current.total if previous is None or is_reset else current.total - previous.total
        counts: UsageCounts | None = None
        if event.last is not None and event.last.total == delta_total:
            counts = event.last
        else:
            counts = current if previous is None or is_reset else current.subtract(previous)
        previous = current
        if counts is None or counts.total != delta_total or not counts.exact:
            mark_incomplete(event)
            skipped += 1
            continue
        records.append(UsageRecord(day, "Codex", event.model, counts))
    return records, skipped, incomplete


def _is_context_sentinel(event: CodexEvent) -> bool:
    current = event.cumulative
    return bool(
        current is not None
        and current.input_total == 0
        and current.output == 0
        and current.cache_read == 0
        and current.cache_write == 0
        and (event.last is None or event.last.total == 0)
        and event.context_window > 0
        and current.total == event.context_window
    )


def _is_raw_context_sentinel(event: CodexEvent) -> bool:
    return bool(
        event.cumulative_raw_total > 0
        and event.cumulative_raw_total == event.context_window
        and event.last_raw_total == 0
    )


@dataclass(frozen=True)
class _ClaudeCandidate:
    record: UsageRecord
    timestamp: datetime
    has_stop_reason: bool
    line_number: int


def _collect_claude(
    paths: list[Path], diagnostics: CollectionDiagnostics
) -> tuple[list[UsageRecord], set[tuple[str, str, str]]]:
    responses: dict[str, _ClaudeCandidate] = {}
    incomplete_buckets: set[tuple[str, str, str]] = set()
    unresolved_days: set[str] = set()
    unresolved_models: set[str] = set()
    has_fully_unresolved_skip = False

    def mark_incomplete(message: Any, timestamp: datetime | None) -> None:
        nonlocal has_fully_unresolved_skip
        day = _day(timestamp)
        raw_model = message.get("model") if isinstance(message, dict) else None
        model = _model(raw_model)
        model_is_known = (
            isinstance(raw_model, str)
            and bool(raw_model.strip())
            and model == raw_model.strip()
        )
        if day is not None and model_is_known:
            incomplete_buckets.add((day, "Claude Code", model))
        elif day is not None:
            unresolved_days.add(day)
        elif model_is_known:
            unresolved_models.add(model)
        else:
            has_fully_unresolved_skip = True

    for path in paths:
        for line_number, obj in enumerate(
            _json_lines(path, matching_any=(b'"usage"', b'"assistant"')), start=1
        ):
            if obj.get("type") != "assistant":
                continue
            message = obj.get("message")
            timestamp = _parse_time(obj.get("timestamp"))
            if not isinstance(message, dict):
                diagnostics.skipped_records["Claude Code"] += 1
                mark_incomplete(message, timestamp)
                continue
            counts = _normalize_claude(message.get("usage"))
            day = _day(timestamp)
            if counts is None or counts.total <= 0 or timestamp is None or day is None:
                diagnostics.skipped_records["Claude Code"] += 1
                mark_incomplete(message, timestamp)
                continue
            response_id = message.get("id")
            request_id = next(
                (
                    value
                    for value in (
                        obj.get("requestId"),
                        obj.get("request_id"),
                        message.get("requestId"),
                        message.get("request_id"),
                    )
                    if isinstance(value, str) and value.strip()
                ),
                None,
            )
            object_uuid = obj.get("uuid")
            if isinstance(response_id, str) and response_id.strip():
                identity = f"response:{response_id.strip()}"
            elif request_id:
                identity = f"request:{request_id.strip()}"
            elif isinstance(object_uuid, str) and object_uuid.strip():
                identity = f"uuid:{object_uuid.strip()}"
            else:
                identity = f"line:{os.fspath(path)}:{line_number}"
            stop_reason = message.get("stop_reason")
            candidate = _ClaudeCandidate(
                UsageRecord(day, "Claude Code", _model(message.get("model")), counts),
                timestamp,
                isinstance(stop_reason, str) and bool(stop_reason.strip()),
                line_number,
            )
            existing = responses.get(identity)
            if existing is None or _prefer_claude(candidate, existing):
                responses[identity] = candidate
    records = [candidate.record for candidate in responses.values()]
    known_keys = {(record.day, record.tool, record.model) for record in records}
    if has_fully_unresolved_skip:
        incomplete_buckets.update(known_keys)
    else:
        incomplete_buckets.update(
            key
            for key in known_keys
            if key[0] in unresolved_days or key[2] in unresolved_models
        )
    diagnostics.exact_records["Claude Code"] = len(records)
    return records, incomplete_buckets


def _prefer_claude(candidate: _ClaudeCandidate, existing: _ClaudeCandidate) -> bool:
    if candidate.has_stop_reason != existing.has_stop_reason:
        return candidate.has_stop_reason
    if candidate.timestamp != existing.timestamp:
        return candidate.timestamp > existing.timestamp
    return candidate.line_number > existing.line_number


_ZCODE_REQUIRED_COLUMN_GROUPS: dict[str, tuple[str, ...]] = {
    "id": ("id",),
    "status": ("status",),
    "started_at": ("started_at",),
    "model": ("model_id",),
    "input": ("input_tokens",),
    "output": ("output_tokens",),
    "reasoning": ("reasoning_tokens",),
    "cache_read": ("cache_read_input_tokens", "cache_read_tokens"),
    "cache_write": (
        "cache_creation_input_tokens",
        "cache_creation_tokens",
        "cache_write_tokens",
    ),
}


def _collect_zcode(
    database: Path, diagnostics: CollectionDiagnostics
) -> tuple[list[UsageRecord], set[tuple[str, str, str]]]:
    """Read ZCode's dedicated usage table without opening session transcripts."""
    if not database.is_file():
        diagnostics.zcode_status = "missing_db"
        return [], set()
    diagnostics.source_files["ZCode"] = 1

    try:
        connection = sqlite3.connect(
            database.resolve().as_uri() + "?mode=ro",
            uri=True,
            timeout=2.0,
            isolation_level=None,
        )
    except (OSError, sqlite3.Error):
        diagnostics.zcode_status = "unreadable_db"
        return [], set()

    try:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA busy_timeout = 2000")
        columns = {
            str(row["name"])
            for row in connection.execute("PRAGMA table_info(model_usage)")
        }
        if not columns:
            diagnostics.zcode_status = "missing_table"
            return [], set()

        selected: dict[str, str] = {}
        for logical_name, candidates in _ZCODE_REQUIRED_COLUMN_GROUPS.items():
            actual = next((candidate for candidate in candidates if candidate in columns), None)
            if actual is None:
                diagnostics.zcode_status = "schema_mismatch"
                return [], set()
            selected[logical_name] = actual

        session_expression = "session_id" if "session_id" in columns else "''"
        computed_expression = (
            "COALESCE(computed_total_tokens, 0)"
            if "computed_total_tokens" in columns
            else "0"
        )
        provider_expression = (
            "COALESCE(provider_total_tokens, 0)"
            if "provider_total_tokens" in columns
            else "0"
        )
        query = f"""
            SELECT
                {selected['id']} AS request_id,
                {session_expression} AS session_id,
                {selected['started_at']} AS started_at,
                {selected['model']} AS model_id,
                COALESCE({selected['input']}, 0) AS input_tokens,
                COALESCE({selected['output']}, 0) AS output_tokens,
                COALESCE({selected['reasoning']}, 0) AS reasoning_tokens,
                COALESCE({selected['cache_read']}, 0) AS cache_read_tokens,
                COALESCE({selected['cache_write']}, 0) AS cache_write_tokens,
                {computed_expression} AS computed_total_tokens,
                {provider_expression} AS provider_total_tokens
            FROM model_usage
            WHERE {selected['status']} = 'completed'
            ORDER BY {selected['started_at']}, {selected['id']}
        """
        rows = connection.execute(query).fetchall()
    except sqlite3.Error:
        diagnostics.zcode_status = "query_failed"
        return [], set()
    finally:
        connection.close()

    records: list[UsageRecord] = []
    incomplete: set[tuple[str, str, str]] = set()
    for row in rows:
        timestamp = _parse_epoch_time(row["started_at"])
        day = _day(timestamp)
        model = _model(row["model_id"])
        raw_values = {
            name: _strict_nonnegative_integer(row[name])
            for name in (
                "input_tokens",
                "output_tokens",
                "reasoning_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "computed_total_tokens",
                "provider_total_tokens",
            )
        }
        known_bucket = (day, "ZCode", model) if day is not None else None
        if timestamp is None or any(value is None for value in raw_values.values()):
            diagnostics.skipped_records["ZCode"] += 1
            if known_bucket is not None:
                incomplete.add(known_bucket)
            continue

        input_total = raw_values["input_tokens"]
        output = raw_values["output_tokens"]
        cache_read = raw_values["cache_read_tokens"]
        cache_write = raw_values["cache_write_tokens"]
        assert input_total is not None
        assert output is not None
        assert cache_read is not None
        assert cache_write is not None
        counts = UsageCounts(input_total, output, cache_read, cache_write)
        reasoning = raw_values["reasoning_tokens"]
        assert reasoning is not None
        explicit_total = max(
            raw_values["computed_total_tokens"] or 0,
            raw_values["provider_total_tokens"] or 0,
        )
        if (
            not counts.exact
            or reasoning > output
            or (counts.total <= 0 and explicit_total > 0)
        ):
            diagnostics.skipped_records["ZCode"] += 1
            if known_bucket is not None:
                incomplete.add(known_bucket)
            continue
        if counts.total <= 0 or day is None:
            continue
        records.append(UsageRecord(day, "ZCode", model, counts))

    diagnostics.exact_records["ZCode"] = len(records)
    diagnostics.zcode_status = "ok" if records else "missing_valid_rows"
    return records, incomplete


def _strict_nonnegative_integer(value: Any) -> int | None:
    if type(value) is int:
        parsed = value
    elif isinstance(value, float) and value.is_integer():
        parsed = int(value)
    elif isinstance(value, str) and value.isdigit():
        parsed = int(value)
    else:
        return None
    return parsed if 0 <= parsed <= MAX_TOKEN_VALUE else None


def _parse_epoch_time(value: Any) -> datetime | None:
    if type(value) not in (int, float) or isinstance(value, bool):
        if not isinstance(value, str):
            return None
        try:
            number = float(value)
        except ValueError:
            return None
    else:
        number = float(value)
    if not number.is_integer() or number <= 0:
        return None
    magnitude = abs(number)
    if magnitude >= 100_000_000_000_000_000:
        number /= 1_000_000_000
    elif magnitude >= 100_000_000_000_000:
        number /= 1_000_000
    elif magnitude >= 100_000_000_000:
        number /= 1_000
    try:
        return datetime.fromtimestamp(number, timezone.utc)
    except (OSError, OverflowError, ValueError):
        return None


def _aggregate(
    records: Iterable[UsageRecord],
    *,
    excluded_keys: set[tuple[str, str, str]] | None = None,
) -> list[dict[str, Any]]:
    excluded_keys = excluded_keys or set()
    totals: dict[tuple[str, str, str], list[int]] = {}
    for record in records:
        if not record.counts.exact:
            continue
        key = (record.day, record.tool, record.model)
        if key in excluded_keys:
            continue
        components = record.counts.bucket_components()
        accumulator = totals.setdefault(key, [0, 0, 0, 0])
        for index, value in enumerate(components):
            accumulator[index] += value
            if accumulator[index] > MAX_TOKEN_VALUE:
                raise RuntimeError("local token total exceeds the protocol limit")
    buckets: list[dict[str, Any]] = []
    for (day, tool, model), values in sorted(totals.items()):
        bucket = {
            "date": day,
            "timezone": ACCOUNTING_TIMEZONE,
            "tool": tool,
            "model": model,
            "source": "local",
            "input_tokens": values[0],
            "output_tokens": values[1],
            "cache_read_tokens": values[2],
            "cache_write_tokens": values[3],
            "completeness": "exact",
        }
        buckets.append(validate_bucket(bucket))
    return buckets
