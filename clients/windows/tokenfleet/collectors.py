from __future__ import annotations

import json
import os
import sqlite3
import uuid
import csv
import hashlib
import io
import math
import unicodedata
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

try:
    import zstandard
except ImportError:  # pragma: no cover - exercised by the missing-decoder fixture
    zstandard = None  # type: ignore[assignment]

from .constants import (
    ACCOUNTING_TIMEZONE,
    MAX_RELEVANT_LINE_BYTES,
    MAX_SOURCE_FILES,
    MAX_TOKEN_VALUE,
)
from .protocol import ProtocolError, validate_bucket

SHANGHAI = timezone(timedelta(hours=8), name=ACCOUNTING_TIMEZONE)

SWITCHED_EXPERIMENTAL_SOURCE_NAMES = (
    "Hermes Agent",
    "WorkBuddy",
    "CodeBuddy",
    "Qoder",
    "Kimi",
    "OpenCode",
    "Grok",
    "Qwen Code",
    "Cline",
    "Copilot CLI",
    "Copilot OTel",
    "Antigravity",
    "Droid",
    "dsh",
    "Pi",
    "OpenClaw",
)

EXPERIMENTAL_SOURCE_NAMES = (
    "ZCode",
    *SWITCHED_EXPERIMENTAL_SOURCE_NAMES,
    "Cursor",
)


def experimental_scan_paths(home: Path) -> dict[str, list[str]]:
    """Return the disclosed Windows scan roots without touching the filesystem."""
    appdata = Path(os.environ.get("APPDATA", home / "AppData" / "Roaming"))
    localappdata = Path(os.environ.get("LOCALAPPDATA", home / "AppData" / "Local"))
    cline_data = _environment_path("CLINE_DATA_DIR") or (
        (_environment_path("CLINE_DIR") / "data")
        if _environment_path("CLINE_DIR")
        else home / ".cline" / "data"
    )
    copilot_home = _environment_path("COPILOT_HOME") or home / ".copilot"
    dsh_home = _environment_path("DSH_HOME") or home / ".dsh"
    pi_root = _environment_path("PI_CODING_AGENT_SESSION_DIR")
    if pi_root is None:
        configured_pi = _environment_path("PI_CODING_AGENT_DIR")
        pi_root = configured_pi / "sessions" if configured_pi else home / ".pi" / "agent" / "sessions"
    openclaw = _environment_path("OPENCLAW_HOME") or _environment_path("OPENCLAW_STATE_DIR") or home / ".openclaw"
    grok = _environment_path("TOKENTRACKER_GROK_HOME") or _environment_path("GROK_HOME") or home / ".grok"
    qwen = _environment_path("QWEN_RUNTIME_DIR") or _environment_path("QWEN_HOME") or home / ".qwen"
    opencode = _environment_path("OPENCODE_DATA_DIR") or localappdata / "opencode"
    cursor_archive = localappdata / "TokenFleet" / "data" / "cursor-usage.json"
    ide_names = ("Code", "Code - Insiders", "Cursor", "CodeBuddy", "Windsurf", "VSCodium", "Trae", "Trae CN")
    cline_legacy = [
        appdata / ide / "User" / "globalStorage" / extension
        for ide in ide_names
        for extension in ("saoudrizwan.claude-dev", "cline.cline")
    ]
    all_paths = {
        "ZCode": [os.fspath(home / ".zcode" / "cli" / "db" / "db.sqlite")],
        "Hermes Agent": [os.fspath(home / ".hermes" / "state.db")],
        "WorkBuddy": [
            os.fspath(home / ".workbuddy" / "projects"),
            os.fspath(appdata / "WorkBuddyExtension"),
        ],
        "CodeBuddy": [os.fspath(home / ".codebuddy" / "projects"), os.fspath(home / ".codebuddy" / "sessions")],
        "Qoder": [os.fspath(home / ".qoder" / "projects")],
        "Kimi": [os.fspath(home / ".kimi-code" / "sessions")],
        "OpenCode": list(
            dict.fromkeys(
                (
                    os.fspath(opencode),
                    os.fspath(home / ".local" / "share" / "opencode"),
                )
            )
        ),
        "Grok": [os.fspath(grok / "sessions")],
        "Qwen Code": [os.fspath(qwen / "usage")],
        "Cursor": [os.fspath(cursor_archive)],
        "Cline": [os.fspath(cline_data), *(os.fspath(path) for path in cline_legacy)],
        "Copilot CLI": [os.fspath(copilot_home / "session-store.db")],
        "Copilot OTel": [
            *([os.fspath(_environment_path("COPILOT_OTEL_FILE_EXPORTER_PATH"))] if _environment_path("COPILOT_OTEL_FILE_EXPORTER_PATH") else []),
            os.fspath(copilot_home / "otel"),
            os.fspath(localappdata / "GitHub Copilot" / "otel"),
            os.fspath(appdata / "GitHub Copilot" / "otel"),
        ],
        "Antigravity": [os.fspath(home / ".gemini" / name / "brain") for name in ("antigravity", "antigravity-cli", "antigravity-ide")],
        "Droid": [os.fspath(home / ".factory" / "projects")],
        "dsh": [os.fspath(dsh_home / "sessions")],
        "Pi": [os.fspath(pi_root)],
        "OpenClaw": [os.fspath(openclaw)],
    }
    return {name: all_paths[name] for name in SWITCHED_EXPERIMENTAL_SOURCE_NAMES}


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
    timestamp: datetime | None = None
    request_id: str | None = None
    session_id: str | None = None
    source_path: str | None = None
    line_number: int | None = None
    data_source: str | None = None


@dataclass
class CollectionDiagnostics:
    source_files: dict[str, int] = field(
        default_factory=lambda: {
            name: 0 for name in ("Codex", "Claude Code", *EXPERIMENTAL_SOURCE_NAMES)
        }
    )
    exact_records: dict[str, int] = field(
        default_factory=lambda: {
            name: 0 for name in ("Codex", "Claude Code", *EXPERIMENTAL_SOURCE_NAMES)
        }
    )
    skipped_records: dict[str, int] = field(
        default_factory=lambda: {
            name: 0 for name in ("Codex", "Claude Code", *EXPERIMENTAL_SOURCE_NAMES)
        }
    )
    source_status: dict[str, str] = field(
        default_factory=lambda: {name: "disabled" for name in EXPERIMENTAL_SOURCE_NAMES}
    )
    experimental_sources_enabled: bool = False
    scan_paths: dict[str, list[str]] = field(default_factory=dict)
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


@dataclass
class _SourceResult:
    records: list[UsageRecord]
    status: str
    files: int = 0
    skipped: int = 0
    incomplete_buckets: set[tuple[str, str, str]] = field(default_factory=set)


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


def collect_usage(
    home: Path,
    *,
    history_days: int = 366,
    include_experimental: bool = False,
    cursor_archive: Path | None = None,
) -> CollectionResult:
    if not 1 <= history_days <= 366 * 5:
        raise ValueError("history_days must be between 1 and 1830")
    cutoff = datetime.now(timezone.utc) - timedelta(days=history_days + 2)
    diagnostics = CollectionDiagnostics()
    diagnostics.experimental_sources_enabled = include_experimental
    diagnostics.scan_paths = experimental_scan_paths(home) if include_experimental else {}
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
    diagnostics.source_status["ZCode"] = diagnostics.zcode_status
    cursor_path = cursor_archive or (
        Path(os.environ.get("LOCALAPPDATA", home / "AppData" / "Local"))
        / "TokenFleet"
        / "data"
        / "cursor-usage.json"
    )
    cursor_result = _collect_cursor(cursor_path)
    _record_source_result(diagnostics, "Cursor", cursor_result)
    cursor_records = list(cursor_result.records)
    incomplete_cursor_buckets = set(cursor_result.incomplete_buckets)
    experimental_records: list[UsageRecord] = []
    incomplete_experimental_buckets: set[tuple[str, str, str]] = set()
    if include_experimental:
        source_cutoff = datetime.now(timezone.utc) - timedelta(
            days=min(history_days, 180) + 2
        )
        paths = _resolved_experimental_paths(home, cursor_archive=cursor_archive)
        source_results = (
            ("Hermes Agent", _collect_hermes(paths["hermes"])),
            ("WorkBuddy", _collect_workbuddy(paths["workbuddy"], source_cutoff)),
            (
                "CodeBuddy",
                _collect_claude_shaped(
                    "CodeBuddy", paths["codebuddy"], source_cutoff
                ),
            ),
            (
                "Qoder",
                _collect_claude_shaped("Qoder", paths["qoder"], source_cutoff),
            ),
            ("Kimi", _collect_kimi(paths["kimi"], source_cutoff)),
            ("OpenCode", _collect_opencode(paths["opencode"])),
            ("Grok", _collect_grok(paths["grok"], source_cutoff)),
            ("Qwen Code", _collect_qwen(paths["qwen"], source_cutoff)),
            ("Cline", _collect_cline_usage(paths["cline"], source_cutoff)),
        )
        for name, source_result in source_results:
            _record_source_result(
                diagnostics,
                name,
                source_result,
                incomplete_experimental_buckets,
            )
            experimental_records.extend(source_result.records)

        copilot_store = _collect_copilot_store(paths["copilot_store"])
        copilot_otel = _collect_copilot_otel(paths["copilot_otel"], source_cutoff)
        _prefer_copilot_session_store(copilot_store, copilot_otel)
        for name, source_result in (
            ("Copilot CLI", copilot_store),
            ("Copilot OTel", copilot_otel),
            (
                "Antigravity",
                _collect_result_usage_jsonl(
                    "Antigravity",
                    paths["antigravity"],
                    source_cutoff,
                    accepted_names={"transcript.jsonl"},
                    usage_keys=("usage", "usageMetadata"),
                    input_includes_cached=True,
                ),
            ),
            (
                "Droid",
                _collect_result_usage_jsonl(
                    "Droid",
                    paths["droid"],
                    source_cutoff,
                    accepted_names={"session.jsonl"},
                    usage_keys=("tokenUsage",),
                    input_includes_cached=False,
                ),
            ),
            ("dsh", _collect_dsh(paths["dsh"], source_cutoff)),
            ("Pi", _collect_pi(paths["pi"], source_cutoff)),
            ("OpenClaw", _collect_openclaw(paths["openclaw"], source_cutoff)),
        ):
            _record_source_result(
                diagnostics,
                name,
                source_result,
                incomplete_experimental_buckets,
            )
            experimental_records.extend(source_result.records)
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
    cursor_records = [
        record for record in cursor_records if _day_is_in_range(record.day, oldest, today)
    ]
    experimental_oldest = today - timedelta(days=min(history_days, 180) - 1)
    experimental_records = [
        record
        for record in experimental_records
        if _day_is_in_range(record.day, experimental_oldest, today)
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
        key
        for key in incomplete_zcode_buckets
        if _day_is_in_range(key[0], oldest, today)
    }
    incomplete_cursor_buckets = {
        key
        for key in incomplete_cursor_buckets
        if _day_is_in_range(key[0], oldest, today)
    }
    incomplete_experimental_buckets = {
        key
        for key in incomplete_experimental_buckets
        if _day_is_in_range(key[0], experimental_oldest, today)
    }
    buckets = _aggregate(
        codex_records
        + claude_records
        + zcode_records
        + cursor_records
        + experimental_records,
        excluded_keys=(
            incomplete_codex_buckets
            | incomplete_claude_buckets
            | incomplete_zcode_buckets
            | incomplete_cursor_buckets
            | incomplete_experimental_buckets
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
            relative_parts = path.relative_to(root).parts
        except ValueError:
            relative_parts = path.parts
        if any(part.startswith(".") for part in relative_parts[:-1]):
            continue
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
    raw = value if isinstance(value, str) else "unknown"
    safe = "".join(
        " "
        if character == "\x1f" or unicodedata.category(character) in ("Cc", "Cf")
        else character
        for character in raw.strip()
    )
    collapsed = " ".join(safe.split()) or "unknown"
    limited = collapsed[:128].strip()
    return limited or "unknown"


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
        cursor = connection.cursor()
        try:
            cursor.execute("PRAGMA query_only = ON")
            cursor.execute("PRAGMA busy_timeout = 2000")
            cursor.execute("PRAGMA table_info(model_usage)")
            columns = {str(row["name"]) for row in cursor.fetchall()}
            if not columns:
                diagnostics.zcode_status = "missing_table"
                return [], set()

            selected: dict[str, str] = {}
            for logical_name, candidates in _ZCODE_REQUIRED_COLUMN_GROUPS.items():
                actual = next(
                    (candidate for candidate in candidates if candidate in columns), None
                )
                if actual is None:
                    diagnostics.zcode_status = "schema_mismatch"
                    return [], set()
                selected[logical_name] = actual

            session_expression = "session_id" if "session_id" in columns else "NULL"
            reasoning_expression = (
                "COALESCE(reasoning_tokens, 0)" if "reasoning_tokens" in columns else "0"
            )
            cache_read_column = next(
                (
                    candidate
                    for candidate in ("cache_read_input_tokens", "cache_read_tokens")
                    if candidate in columns
                ),
                None,
            )
            cache_write_column = next(
                (
                    candidate
                    for candidate in (
                        "cache_creation_input_tokens",
                        "cache_creation_tokens",
                        "cache_write_tokens",
                    )
                    if candidate in columns
                ),
                None,
            )
            cache_read_expression = (
                f"COALESCE({cache_read_column}, 0)" if cache_read_column else "0"
            )
            cache_write_expression = (
                f"COALESCE({cache_write_column}, 0)" if cache_write_column else "0"
            )
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
                    {reasoning_expression} AS reasoning_tokens,
                    {cache_read_expression} AS cache_read_tokens,
                    {cache_write_expression} AS cache_write_tokens,
                    {computed_expression} AS computed_total_tokens,
                    {provider_expression} AS provider_total_tokens
                FROM model_usage
                WHERE {selected['status']} = 'completed'
                ORDER BY {selected['started_at']}, {selected['id']}
            """
            cursor.execute(query)
            rows = [dict(row) for row in cursor.fetchall()]
        finally:
            cursor.close()
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
        explicit_totals = (
            raw_values["computed_total_tokens"] or 0,
            raw_values["provider_total_tokens"] or 0,
        )
        if (
            not counts.exact
            or reasoning > output
            or any(
                explicit_total > 0 and explicit_total != counts.total
                for explicit_total in explicit_totals
            )
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
    if not math.isfinite(number) or number <= 0:
        return None
    number = float(int(number))
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


def _environment_path(name: str) -> Path | None:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    return Path(os.path.expandvars(raw)).expanduser()


def _resolved_experimental_paths(
    home: Path, *, cursor_archive: Path | None
) -> dict[str, Any]:
    appdata = Path(os.environ.get("APPDATA", home / "AppData" / "Roaming"))
    localappdata = Path(os.environ.get("LOCALAPPDATA", home / "AppData" / "Local"))
    cline_data = _environment_path("CLINE_DATA_DIR")
    if cline_data is None:
        cline_home = _environment_path("CLINE_DIR")
        cline_data = cline_home / "data" if cline_home else home / ".cline" / "data"
    ide_names = (
        "Code",
        "Code - Insiders",
        "Cursor",
        "CodeBuddy",
        "Windsurf",
        "VSCodium",
        "Trae",
        "Trae CN",
    )
    cline_roots = [cline_data]
    cline_roots.extend(
        appdata / ide / "User" / "globalStorage" / extension
        for ide in ide_names
        for extension in ("saoudrizwan.claude-dev", "cline.cline")
    )
    copilot_home = _environment_path("COPILOT_HOME") or home / ".copilot"
    otel_roots: list[Path] = []
    configured_otel = _environment_path("COPILOT_OTEL_FILE_EXPORTER_PATH")
    if configured_otel:
        otel_roots.append(configured_otel)
    otel_roots.extend(
        (
            copilot_home / "otel",
            localappdata / "GitHub Copilot" / "otel",
            appdata / "GitHub Copilot" / "otel",
        )
    )
    dsh_home = _environment_path("DSH_HOME") or home / ".dsh"
    pi_root = _environment_path("PI_CODING_AGENT_SESSION_DIR")
    if pi_root is None:
        pi_home = _environment_path("PI_CODING_AGENT_DIR")
        pi_root = pi_home / "sessions" if pi_home else home / ".pi" / "agent" / "sessions"
    openclaw = (
        _environment_path("OPENCLAW_HOME")
        or _environment_path("OPENCLAW_STATE_DIR")
        or home / ".openclaw"
    )
    grok = (
        _environment_path("TOKENTRACKER_GROK_HOME")
        or _environment_path("GROK_HOME")
        or home / ".grok"
    )
    qwen = (
        _environment_path("QWEN_RUNTIME_DIR")
        or _environment_path("QWEN_HOME")
        or home / ".qwen"
    )
    opencode_roots = [
        _environment_path("OPENCODE_DATA_DIR") or localappdata / "opencode",
        home / ".local" / "share" / "opencode",
    ]
    return {
        "zcode": home / ".zcode" / "cli" / "db" / "db.sqlite",
        "hermes": home / ".hermes" / "state.db",
        "workbuddy": [home / ".workbuddy" / "projects", appdata / "WorkBuddyExtension"],
        "codebuddy": [home / ".codebuddy" / "projects", home / ".codebuddy" / "sessions"],
        "qoder": [home / ".qoder" / "projects"],
        "kimi": home / ".kimi-code",
        "opencode": opencode_roots,
        "grok": grok,
        "qwen": qwen,
        "cursor": cursor_archive or localappdata / "TokenFleet" / "data" / "cursor-usage.json",
        "cline": cline_roots,
        "copilot_store": copilot_home / "session-store.db",
        "copilot_otel": otel_roots,
        "antigravity": [home / ".gemini" / name / "brain" for name in ("antigravity", "antigravity-cli", "antigravity-ide")],
        "droid": [home / ".factory" / "projects"],
        "dsh": dsh_home / "sessions",
        "pi": pi_root,
        "openclaw": [openclaw],
    }


def _record_source_result(
    diagnostics: CollectionDiagnostics,
    name: str,
    result: _SourceResult,
    incomplete_buckets: set[tuple[str, str, str]] | None = None,
) -> None:
    diagnostics.source_status[name] = result.status
    diagnostics.source_files[name] = result.files
    diagnostics.exact_records[name] = len(result.records)
    diagnostics.skipped_records[name] = result.skipped
    if incomplete_buckets is not None:
        incomplete_buckets.update(result.incomplete_buckets)


def _mark_incomplete_bucket(
    incomplete_buckets: set[tuple[str, str, str]],
    timestamp: datetime | None,
    tool: str,
    model: Any,
) -> None:
    day = _day(timestamp)
    if day is not None:
        incomplete_buckets.add((day, tool, _model(model)))


def _read_only_rows(database: Path, table: str) -> tuple[set[str], list[dict[str, Any]]] | None:
    if not database.is_file():
        return None
    try:
        connection = sqlite3.connect(
            database.resolve().as_uri() + "?mode=ro",
            uri=True,
            timeout=2.0,
            isolation_level=None,
        )
        connection.row_factory = sqlite3.Row
        cursor = connection.cursor()
        cursor.execute("PRAGMA query_only = ON")
        cursor.execute("PRAGMA busy_timeout = 2000")
        cursor.execute(f"PRAGMA table_info('{table}')")
        columns = {str(row["name"]) for row in cursor.fetchall()}
        if not columns:
            return set(), []
        cursor.execute(f'SELECT * FROM "{table}"')
        rows = [dict(row) for row in cursor.fetchall()]
        return columns, rows
    except (OSError, sqlite3.Error):
        return None
    finally:
        try:
            connection.close()
        except (UnboundLocalError, sqlite3.Error):
            pass


def _canonical_counts(
    *,
    raw_input: int,
    output: int,
    cache_write: int = 0,
    cache_read: int = 0,
    reasoning: int = 0,
    input_includes_cached: bool,
    explicit_total: int = 0,
    explicit_total_authoritative: bool = False,
) -> UsageCounts | None:
    raw_input = max(0, raw_input)
    output = max(0, output)
    cache_write = max(0, cache_write)
    cache_read = max(0, cache_read)
    reasoning = max(0, reasoning)
    input_total = raw_input if input_includes_cached else raw_input + cache_write + cache_read
    counts = UsageCounts(input_total, output, cache_read, cache_write)
    if not counts.exact or reasoning > output:
        return None
    if explicit_total_authoritative and explicit_total > 0 and explicit_total != counts.total:
        return None
    return counts


def _nonempty(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    if type(value) in (int, float):
        return str(value)
    return None


def _first_string(*values: Any) -> str | None:
    return next((text for value in values if (text := _nonempty(value))), None)


def _temporal(value: Any) -> datetime | None:
    if isinstance(value, str):
        return _parse_time(value) or _parse_epoch_time(value)
    return _parse_epoch_time(value)


def _usage_temporal_info(obj: dict[str, Any]) -> datetime | None:
    for key in ("timestamp", "created_at", "createdAt", "time", "event_time", "date"):
        if key in obj and (parsed := _temporal(obj[key])) is not None:
            return parsed
    for key in ("message", "result", "data"):
        nested = obj.get(key)
        if isinstance(nested, dict) and (parsed := _usage_temporal_info(nested)) is not None:
            return parsed
    return None


def _first_nested(obj: dict[str, Any], keys: tuple[str, ...]) -> dict[str, Any] | None:
    for key in keys:
        value = obj.get(key)
        if isinstance(value, dict):
            return value
    for value in obj.values():
        if isinstance(value, dict) and (found := _first_nested(value, keys)) is not None:
            return found
    return None


def _portable_usage(raw: dict[str, Any], *, input_includes_cached: bool) -> UsageCounts | None:
    raw_input = _first_integer(
        raw,
        ("input_tokens", "inputTokens", "prompt_tokens", "promptTokens", "promptTokenCount", "input"),
    )
    raw_output = _first_integer(
        raw,
        ("output_tokens", "outputTokens", "completion_tokens", "completionTokens", "candidatesTokenCount", "output"),
    )
    cache_read = _first_integer(
        raw,
        (
            "cache_read_input_tokens",
            "cacheReadInputTokens",
            "cacheReadTokens",
            "cache_read_tokens",
            "cached_input_tokens",
            "cachedContentTokenCount",
            "prompt_cache_hit_tokens",
        ),
    )
    cache_write = _first_integer(
        raw,
        (
            "cache_creation_input_tokens",
            "cacheCreationInputTokens",
            "cacheCreationTokens",
            "cache_creation_tokens",
            "cache_write_input_tokens",
            "cacheWriteTokens",
            "cache_write_tokens",
            "prompt_cache_write_tokens",
        ),
    )
    reasoning = _first_integer(
        raw,
        ("reasoning_output_tokens", "reasoningTokens", "reasoning_tokens", "thinkingTokens", "thinking_tokens", "thoughtsTokenCount"),
    )
    explicit_total = _first_integer(raw, ("total_tokens", "totalTokens", "totalTokenCount", "total"))
    output = raw_output + reasoning if "thoughtsTokenCount" in raw else raw_output
    counts = _canonical_counts(
        raw_input=raw_input,
        output=output,
        cache_write=cache_write,
        cache_read=cache_read,
        reasoning=reasoning,
        input_includes_cached=input_includes_cached,
        explicit_total=explicit_total,
        explicit_total_authoritative=explicit_total > 0,
    )
    return counts


def _source_status(discovered: bool, files: int, records: list[UsageRecord]) -> str:
    if not discovered:
        return "missing"
    if files == 0:
        return "discovered_no_usage"
    return "ok" if records else "missing_valid_rows"


def _collect_hermes(database: Path) -> _SourceResult:
    if not database.exists():
        return _SourceResult([], "missing_db")
    result = _read_only_rows(database, "sessions")
    if result is None:
        return _SourceResult([], "schema_unreadable", 1)
    columns, rows = result
    if not columns:
        return _SourceResult([], "missing_table", 1)
    if not {"id", "started_at", "input_tokens", "output_tokens"}.issubset(columns):
        return _SourceResult([], "schema_mismatch", 1)
    records: list[UsageRecord] = []
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for row in rows:
        timestamp = _temporal(row.get("started_at"))
        if timestamp is None:
            skipped += 1
            continue
        reasoning = _nonnegative_integer(row.get("reasoning_tokens"))
        output = _nonnegative_integer(row.get("output_tokens"))
        counts = _canonical_counts(
            raw_input=_nonnegative_integer(row.get("input_tokens")),
            output=output,
            cache_read=_nonnegative_integer(row.get("cache_read_tokens")),
            cache_write=_nonnegative_integer(row.get("cache_write_tokens")),
            reasoning=reasoning,
            input_includes_cached=False,
        )
        if counts is None or counts.total <= 0:
            if output + reasoning + _nonnegative_integer(row.get("input_tokens")) > 0:
                skipped += 1
                _mark_incomplete_bucket(
                    incomplete, timestamp, "Hermes Agent", row.get("model")
                )
            continue
        records.append(
            UsageRecord(
                _day(timestamp) or "",
                "Hermes Agent",
                _model(row.get("model")),
                counts,
                timestamp,
                _nonempty(row.get("id")),
                _nonempty(row.get("id")),
                os.fspath(database),
                data_source=_nonempty(row.get("source")),
            )
        )
    return _SourceResult(
        records, "ok" if records else "missing_valid_rows", 1, skipped, incomplete
    )


def _workbuddy_usage(obj: dict[str, Any], *, input_includes_cached: bool = True) -> UsageCounts | None:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    provider = obj.get("providerData") if isinstance(obj.get("providerData"), dict) else {}
    usage = obj.get("usage")
    if not isinstance(usage, dict):
        usage = message.get("usage")
    if not isinstance(usage, dict):
        usage = provider.get("rawUsage")
    if not isinstance(usage, dict):
        usage = provider.get("usage")
    if not isinstance(usage, dict):
        return None
    raw_input = _first_integer(usage, ("input_tokens", "inputTokens", "prompt_tokens"))
    output = _first_integer(usage, ("output_tokens", "outputTokens", "completion_tokens"))
    prompt_details = usage.get("prompt_tokens_details") if isinstance(usage.get("prompt_tokens_details"), dict) else {}
    completion_details = usage.get("completion_tokens_details") if isinstance(usage.get("completion_tokens_details"), dict) else {}
    cache_read = max(
        _nonnegative_integer(usage.get("cache_read_input_tokens")),
        _nonnegative_integer(usage.get("cached_tokens")),
        _nonnegative_integer(usage.get("prompt_cache_hit_tokens")),
        _nonnegative_integer(prompt_details.get("cached_tokens")),
    )
    cache_write = _first_integer(
        usage,
        ("cache_creation_input_tokens", "cacheCreationInputTokens", "prompt_cache_write_tokens"),
    )
    reasoning = max(
        _nonnegative_integer(usage.get("reasoning_tokens")),
        _nonnegative_integer(usage.get("completion_thinking_tokens")),
        _nonnegative_integer(completion_details.get("reasoning_tokens")),
    )
    explicit_total = _first_integer(usage, ("total_tokens", "totalTokens"))
    if explicit_total > 0 and explicit_total == raw_input + output:
        resolved_inclusive = True
    elif explicit_total > 0 and explicit_total == raw_input + cache_write + cache_read + output:
        resolved_inclusive = False
    else:
        resolved_inclusive = input_includes_cached
    return _canonical_counts(
        raw_input=raw_input,
        output=output,
        cache_write=cache_write,
        cache_read=cache_read,
        reasoning=reasoning,
        input_includes_cached=resolved_inclusive,
        explicit_total=explicit_total,
        explicit_total_authoritative=True,
    )


def _collect_workbuddy(roots: list[Path], cutoff: datetime) -> _SourceResult:
    discovered = [root for root in roots if root.exists()]
    files = sorted({path for root in discovered for path in _jsonl_files(root, cutoff)})
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b'"usage"', b'"rawUsage"')), start=1):
            timestamp = _usage_temporal_info(obj)
            provider = obj.get("providerData") if isinstance(obj.get("providerData"), dict) else {}
            raw_model = _first_string(
                provider.get("requestModelId"),
                provider.get("requestModelName"),
                provider.get("model"),
                obj.get("model"),
            )
            usage = _workbuddy_usage(obj)
            if timestamp is None or usage is None or usage.total <= 0:
                skipped += 1
                if usage is None:
                    _mark_incomplete_bucket(incomplete, timestamp, "WorkBuddy", raw_model)
                continue
            session_id = _first_string(obj.get("sessionId"), path.stem)
            request_id = _first_string(
                provider.get("messageId"),
                provider.get("conversationRequestId"),
                obj.get("uuid"),
                obj.get("id"),
            )
            identity = f"{session_id or 'unknown'}|{request_id}" if request_id else f"{path}:{line_number}"
            if identity in seen:
                continue
            seen.add(identity)
            records.append(
                UsageRecord(
                    _day(timestamp) or "",
                    "WorkBuddy",
                    _model(raw_model),
                    usage,
                    timestamp,
                    request_id,
                    session_id,
                    os.fspath(path),
                    line_number,
                )
            )
    return _SourceResult(
        records,
        _source_status(bool(discovered), len(files), records),
        len(files),
        skipped,
        incomplete,
    )


def _collect_claude_shaped(tool: str, roots: list[Path], cutoff: datetime) -> _SourceResult:
    discovered = [root for root in roots if root.exists()]
    files = sorted({path for root in discovered for path in _jsonl_files(root, cutoff)})
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b'"usage"', b'"rawUsage"')), start=1):
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            role = _first_string(message.get("role"), obj.get("role"))
            event_type = _first_string(obj.get("type")) or ""
            if role != "assistant" and event_type not in ("assistant", "assistant_message"):
                continue
            # Qoder session summaries and other cumulative status rows are not
            # per-request usage and must never enter the immutable daily ledger.
            lower_type = event_type.lower()
            if (
                ("session" in lower_type and "summary" in lower_type)
                or obj.get("cumulative") is True
                or obj.get("isCumulative") is True
                or obj.get("is_cumulative") is True
            ):
                skipped += 1
                continue
            timestamp = _usage_temporal_info(obj)
            provider = obj.get("providerData") if isinstance(obj.get("providerData"), dict) else {}
            raw_model = _first_string(
                message.get("model"),
                obj.get("model"),
                obj.get("modelId"),
                provider.get("model"),
                provider.get("requestModelId"),
                provider.get("requestModelName"),
            )
            usage = _workbuddy_usage(obj, input_includes_cached=False)
            if timestamp is None or usage is None or usage.total <= 0:
                skipped += 1
                if usage is None:
                    _mark_incomplete_bucket(incomplete, timestamp, tool, raw_model)
                continue
            session_id = _first_string(obj.get("sessionId"), obj.get("session_id"), message.get("sessionId"), path.stem) or path.stem
            request_id = _first_string(
                obj.get("requestId"),
                obj.get("request_id"),
                obj.get("uuid"),
                obj.get("id"),
                message.get("id"),
                provider.get("messageId"),
                provider.get("conversationRequestId"),
            )
            identity = f"{session_id}|{request_id}" if request_id else f"{path}:{line_number}"
            if identity in seen:
                continue
            seen.add(identity)
            records.append(
                UsageRecord(
                    _day(timestamp) or "",
                    tool,
                    _model(raw_model),
                    usage,
                    timestamp,
                    request_id,
                    session_id,
                    os.fspath(path),
                    line_number,
                    "local_transcript",
                )
            )
    return _SourceResult(
        records,
        _source_status(bool(discovered), len(files), records),
        len(files),
        skipped,
        incomplete,
    )


def _kimi_usage(raw: dict[str, Any]) -> UsageCounts | None:
    if "inputOther" in raw:
        return _canonical_counts(
            raw_input=_nonnegative_integer(raw.get("inputOther")),
            output=_nonnegative_integer(raw.get("output")),
            cache_write=_nonnegative_integer(raw.get("inputCacheCreation")),
            cache_read=_nonnegative_integer(raw.get("inputCacheRead")),
            input_includes_cached=False,
        )
    raw_input = _nonnegative_integer(raw.get("input_tokens"))
    direct_cache = "cache_read_input_tokens" in raw
    details = raw.get("input_tokens_details") if isinstance(raw.get("input_tokens_details"), dict) else {}
    cache_read = (
        _nonnegative_integer(raw.get("cache_read_input_tokens"))
        if direct_cache
        else _nonnegative_integer(details.get("cached_tokens"))
    )
    fresh_input = raw_input if direct_cache else max(0, raw_input - cache_read)
    return _canonical_counts(
        raw_input=fresh_input,
        output=_nonnegative_integer(raw.get("output_tokens")),
        cache_write=_nonnegative_integer(raw.get("cache_creation_input_tokens")),
        cache_read=cache_read,
        input_includes_cached=False,
    )


def _collect_kimi(root: Path, cutoff: datetime) -> _SourceResult:
    if not root.exists():
        return _SourceResult([], "missing")
    files = [path for path in _jsonl_files(root / "sessions", cutoff) if path.name == "wire.jsonl"]
    fallback_model = "kimi-for-coding"
    try:
        for line in (root / "config.toml").read_text(encoding="utf-8").splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() == "default_model":
                fallback_model = (value.strip().strip("\"'").split("/")[-1].strip() or fallback_model)
                break
    except (OSError, UnicodeError):
        pass
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        file_model = fallback_model
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b'"config.update"', b'"step.end"')), start=1):
            if obj.get("type") == "config.update":
                alias = _nonempty(obj.get("modelAlias"))
                if alias:
                    file_model = alias.split("/")[-1]
                continue
            event = obj.get("event") if obj.get("type") == "context.append_loop_event" else obj
            if not isinstance(event, dict) or event.get("type") != "step.end" or not isinstance(event.get("usage"), dict):
                continue
            timestamp = _temporal(obj.get("time")) or _temporal(event.get("time"))
            raw_model = _first_string(event.get("model"), obj.get("model"), file_model) or file_model
            usage = _kimi_usage(event["usage"])
            if timestamp is None or usage is None or usage.total <= 0:
                skipped += 1
                if usage is None:
                    _mark_incomplete_bucket(incomplete, timestamp, "Kimi", raw_model.split("/")[-1])
                continue
            event_id = _nonempty(event.get("uuid"))
            identity = f"id:{event_id}" if event_id else f"line:{path}:{line_number}"
            if identity in seen:
                continue
            seen.add(identity)
            records.append(
                UsageRecord(
                    _day(timestamp) or "",
                    "Kimi",
                    _model(raw_model.split("/")[-1]),
                    usage,
                    timestamp,
                    event_id,
                    path.parents[2].name if len(path.parents) > 2 else path.parent.name,
                    os.fspath(path),
                    line_number,
                )
            )
    return _SourceResult(
        records, _source_status(True, len(files), records), len(files), skipped, incomplete
    )


def _opencode_databases(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if not root.is_dir():
        return []
    return sorted(
        (
            path
            for path in root.iterdir()
            if path.is_file()
            and path.stem.lower().startswith("opencode")
            and path.suffix.lower() in (".db", ".sqlite", ".sqlite3")
        ),
        key=lambda path: os.fspath(path).casefold(),
    )


def _collect_opencode(roots: list[Path]) -> _SourceResult:
    discovered = [root for root in roots if root.exists()]
    if not discovered:
        return _SourceResult([], "missing")
    databases = sorted({database for root in discovered for database in _opencode_databases(root)})
    if not databases:
        return _SourceResult([], "missing_db")
    by_identity: dict[str, UsageRecord] = {}
    valid_layouts = 0
    failed_queries = 0
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for database in databases:
        for table in ("message", "session_message"):
            result = _read_only_rows(database, table)
            if result is None:
                failed_queries += 1
                continue
            columns, rows = result
            if not {"data", "id", "session_id"}.issubset(columns):
                continue
            valid_layouts += 1
            for row_index, row in enumerate(rows, start=1):
                try:
                    data = json.loads(row.get("data") or "")
                except (TypeError, json.JSONDecodeError):
                    continue
                if not isinstance(data, dict):
                    continue
                role = row.get("type") if table == "session_message" and "type" in columns else data.get("role")
                if role != "assistant":
                    continue
                tokens = data.get("tokens") if isinstance(data.get("tokens"), dict) else {}
                cache = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
                reasoning = _nonnegative_integer(tokens.get("reasoning"))
                time_object = data.get("time") if isinstance(data.get("time"), dict) else {}
                timestamp = _temporal(time_object.get("completed")) or _temporal(time_object.get("created")) or _temporal(row.get("time_updated"))
                model_object = data.get("model") if isinstance(data.get("model"), dict) else {}
                raw_model = _first_string(data.get("modelID"), data.get("model") if isinstance(data.get("model"), str) else None, model_object.get("id"), data.get("modelId"))
                counts = _canonical_counts(
                    raw_input=_nonnegative_integer(tokens.get("input")),
                    output=_nonnegative_integer(tokens.get("output")) + reasoning,
                    cache_read=_nonnegative_integer(cache.get("read")),
                    cache_write=_nonnegative_integer(cache.get("write")),
                    reasoning=reasoning,
                    input_includes_cached=False,
                )
                if counts is None or counts.total <= 0 or timestamp is None:
                    skipped += 1
                    if counts is None:
                        _mark_incomplete_bucket(incomplete, timestamp, "OpenCode", raw_model)
                    continue
                message_id = _nonempty(row.get("id"))
                session_id = _nonempty(row.get("session_id"))
                identity = "|".join(filter(None, (session_id, message_id))) or f"{database}|{table}|{row_index}"
                record = UsageRecord(
                    _day(timestamp) or "",
                    "OpenCode",
                    _model(raw_model),
                    counts,
                    timestamp,
                    message_id,
                    session_id,
                    os.fspath(database),
                    data_source=table,
                )
                existing = by_identity.get(identity)
                if existing is None or (
                    (record.timestamp or datetime.min.replace(tzinfo=timezone.utc), record.counts.total)
                    > (existing.timestamp or datetime.min.replace(tzinfo=timezone.utc), existing.counts.total)
                ):
                    by_identity[identity] = record
    records = sorted(
        by_identity.values(),
        key=lambda record: (record.timestamp or datetime.min.replace(tzinfo=timezone.utc), record.session_id or "", record.request_id or ""),
    )
    if records:
        status = "ok"
    elif valid_layouts == 0:
        status = "schema_unreadable" if failed_queries else "schema_mismatch"
    elif failed_queries >= valid_layouts:
        status = "query_failed"
    else:
        status = "missing_valid_rows"
    return _SourceResult(records, status, len(databases), skipped, incomplete)


def _grok_model(value: Any) -> str:
    model = _model(value)
    lower = model.lower()
    if "build-free" in lower or lower.endswith("-free") or "free-tier" in lower:
        return "grok-build-free"
    if lower in ("grok-4.5-build", "grok-4-5-build"):
        return "grok-4.5-build"
    return model


def _grok_usage(raw: dict[str, Any]) -> UsageCounts | None:
    camel_case = "inputTokens" in raw
    raw_input = _first_integer(raw, ("inputTokens", "input_tokens"))
    cache_read = _first_integer(raw, ("cachedReadTokens", "cacheReadInputTokens", "cache_read_input_tokens", "cached_input_tokens"))
    cache_write = _first_integer(raw, ("cacheCreationTokens", "cachedWriteTokens", "cacheWriteInputTokens", "cache_creation_input_tokens"))
    output = _first_integer(raw, ("outputTokens", "output_tokens"))
    reasoning = _first_integer(raw, ("reasoningTokens", "reasoning_output_tokens"))
    fresh_input = max(0, raw_input - cache_read - cache_write) if camel_case else raw_input
    total = _first_integer(raw, ("totalTokens", "total_tokens"))
    return _canonical_counts(
        raw_input=fresh_input,
        output=output,
        cache_read=cache_read,
        cache_write=cache_write,
        reasoning=min(output, reasoning),
        input_includes_cached=False,
        explicit_total=total,
        explicit_total_authoritative=True,
    )


def _collect_grok(root: Path, cutoff: datetime) -> _SourceResult:
    if not root.exists():
        return _SourceResult([], "missing")
    files = [path for path in _jsonl_files(root / "sessions", cutoff) if path.name == "updates.jsonl"]
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        session_id = _nonempty(path.parent.name)
        fallback_model = "grok-build"
        try:
            signals = json.loads((path.parent / "signals.json").read_text(encoding="utf-8"))
            if isinstance(signals, dict):
                models_used = signals.get("modelsUsed") if isinstance(signals.get("modelsUsed"), list) else []
                fallback_model = _first_string(signals.get("primaryModelId"), *(models_used[:1]), signals.get("model"), fallback_model) or fallback_model
        except (OSError, UnicodeError, json.JSONDecodeError):
            pass
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b'"turn_completed"', b'"usage"')), start=1):
            params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
            update = params.get("update") if isinstance(params.get("update"), dict) else {}
            usage = update.get("usage")
            if update.get("sessionUpdate") != "turn_completed" or not isinstance(usage, dict):
                continue
            metadata = params.get("_meta") if isinstance(params.get("_meta"), dict) else obj.get("_meta") if isinstance(obj.get("_meta"), dict) else {}
            timestamp = _temporal(_first_string(metadata.get("agentTimestampMs"), metadata.get("timestampMs"), obj.get("timestamp_ms"), obj.get("timestamp"), obj.get("time")))
            if timestamp is None:
                skipped += 1
                continue
            event_id = _first_string(metadata.get("eventId"), obj.get("eventId"), obj.get("id"), update.get("prompt_id"), f"line-{line_number}") or f"line-{line_number}"
            model_usage = usage.get("modelUsage") if isinstance(usage.get("modelUsage"), dict) else None
            candidates = sorted(model_usage.items()) if model_usage else [(fallback_model, usage)]
            for raw_model, usage_object in candidates:
                if not isinstance(usage_object, dict):
                    continue
                model = _grok_model(raw_model)
                counts = _grok_usage(usage_object)
                if counts is None or counts.total <= 0:
                    skipped += 1
                    if counts is None:
                        _mark_incomplete_bucket(incomplete, timestamp, "Grok", model)
                    continue
                identity = f"{session_id or 'unknown'}|{event_id}|{model}"
                if identity in seen:
                    continue
                seen.add(identity)
                records.append(
                    UsageRecord(
                        _day(timestamp) or "",
                        "Grok",
                        model,
                        counts,
                        timestamp,
                        event_id,
                        session_id,
                        os.fspath(path),
                        line_number,
                    )
                )
    return _SourceResult(
        records, _source_status(True, len(files), records), len(files), skipped, incomplete
    )


def _collect_qwen(root: Path, cutoff: datetime) -> _SourceResult:
    if not root.exists():
        return _SourceResult([], "missing")
    files = [path for path in _jsonl_files(root / "usage", cutoff) if path.name.startswith("token-usage-")]
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b'"schemaVersion"', b'"inputTokens"')), start=1):
            event_id = _nonempty(obj.get("id"))
            if _nonnegative_integer(obj.get("schemaVersion")) != 1 or not event_id or event_id in seen:
                continue
            timestamp_text = _nonempty(obj.get("timestamp"))
            timestamp = _parse_time(timestamp_text) if timestamp_text else None
            local_day = _nonempty(obj.get("localDate"))
            if local_day is not None:
                try:
                    datetime.strptime(local_day, "%Y-%m-%d")
                except ValueError:
                    local_day = None
            day = _day(timestamp) if timestamp else local_day
            thoughts = _nonnegative_integer(obj.get("thoughtsTokens"))
            model = _model(obj.get("model"))
            counts = _canonical_counts(
                raw_input=_nonnegative_integer(obj.get("inputTokens")),
                output=_nonnegative_integer(obj.get("outputTokens")) + thoughts,
                cache_read=_nonnegative_integer(obj.get("cachedTokens")),
                reasoning=thoughts,
                input_includes_cached=True,
                explicit_total=_nonnegative_integer(obj.get("totalTokens")),
                explicit_total_authoritative=True,
            )
            if not day or counts is None or counts.total <= 0:
                skipped += 1
                if counts is None and day:
                    incomplete.add((day, "Qwen Code", model))
                continue
            seen.add(event_id)
            records.append(
                UsageRecord(
                    day,
                    "Qwen Code",
                    model,
                    counts,
                    timestamp,
                    event_id,
                    _nonempty(obj.get("sessionId")),
                    os.fspath(path),
                    line_number,
                    _nonempty(obj.get("source")),
                )
            )
    return _SourceResult(
        records, _source_status(True, len(files), records), len(files), skipped, incomplete
    )


def _parse_cursor_time(value: str) -> datetime | None:
    parsed = _parse_time(value)
    if parsed:
        return parsed
    try:
        local = datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=SHANGHAI)
    except ValueError:
        return None
    return local.astimezone(timezone.utc)


def _cursor_dedupe_key(record: dict[str, Any]) -> str:
    values = (
        record.get("timestamp", ""),
        record.get("kind", ""),
        record.get("model", ""),
        "1" if record.get("max_mode") else "0",
        record.get("input_tokens", 0),
        record.get("cache_write_tokens", 0),
        record.get("cache_read_tokens", 0),
        record.get("output_tokens", 0),
        record.get("reported_total_tokens", 0),
        record.get("cost_usd", 0),
    )
    return "\x1f".join(map(str, values))


def _collect_cursor(archive_path: Path) -> _SourceResult:
    if not archive_path.is_file():
        return _SourceResult([], "missing_import")
    try:
        archive = json.loads(archive_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        return _SourceResult([], "unreadable_import", 1)
    except json.JSONDecodeError:
        return _SourceResult([], "schema_mismatch", 1)
    if not isinstance(archive, dict) or archive.get("schema_version") != 1 or not isinstance(archive.get("records"), list):
        return _SourceResult([], "schema_mismatch", 1)
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for raw in archive["records"]:
        if not isinstance(raw, dict):
            skipped += 1
            continue
        key = _cursor_dedupe_key(raw)
        timestamp = _parse_cursor_time(str(raw.get("timestamp", "")))
        if key in seen or timestamp is None:
            skipped += 1
            continue
        seen.add(key)
        model = _model(raw.get("model"))
        counts = _canonical_counts(
            raw_input=_nonnegative_integer(raw.get("input_tokens")),
            output=_nonnegative_integer(raw.get("output_tokens")),
            cache_write=_nonnegative_integer(raw.get("cache_write_tokens")),
            cache_read=_nonnegative_integer(raw.get("cache_read_tokens")),
            input_includes_cached=False,
        )
        if counts is None or counts.total <= 0:
            skipped += 1
            if counts is None:
                _mark_incomplete_bucket(incomplete, timestamp, "Cursor", model)
            continue
        records.append(
            UsageRecord(
                _day(timestamp) or "",
                "Cursor",
                model,
                counts,
                timestamp,
                "cursor-csv:" + hashlib.sha256(key.encode("utf-8")).hexdigest(),
                source_path=os.fspath(archive_path),
                data_source="cursor_usage_csv",
            )
        )
    return _SourceResult(
        records, "ok" if records else "missing_valid_rows", 1, skipped, incomplete
    )


def import_cursor_csv(source_path: Path, archive_path: Path) -> dict[str, int]:
    try:
        text = source_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise RuntimeError("Cursor CSV 不是可读的 UTF-8 文件") from exc
    try:
        rows = list(csv.reader(io.StringIO(text), strict=True))
    except csv.Error as exc:
        raise RuntimeError("Cursor CSV 格式无效") from exc
    if len(rows) < 2:
        raise RuntimeError("没有找到可用的 Cursor usage 记录")
    header = [name.replace("\ufeff", "").strip() for name in rows[0]]
    indexes = {name: index for index, name in enumerate(header)}
    required = (
        "Date",
        "Model",
        "Input (w/ Cache Write)",
        "Input (w/o Cache Write)",
        "Cache Read",
        "Output Tokens",
        "Total Tokens",
        "Cost",
    )
    if not all(name in indexes for name in required):
        raise RuntimeError("Cursor CSV 表头不受支持")

    def field(row: list[str], name: str) -> str:
        index = indexes.get(name)
        return row[index].strip() if index is not None and index < len(row) else ""

    def integer(value: str) -> int:
        try:
            return max(0, int(value.replace(",", "")))
        except ValueError:
            return 0

    def decimal(value: str) -> float:
        try:
            return max(0.0, float(value.replace("$", "").replace(",", "")))
        except ValueError:
            return 0.0

    imported: list[dict[str, Any]] = []
    for row in rows[1:]:
        timestamp = field(row, "Date")
        model = field(row, "Model")
        if not timestamp or not model or _parse_cursor_time(timestamp) is None:
            continue
        with_write = integer(field(row, "Input (w/ Cache Write)"))
        without_write = integer(field(row, "Input (w/o Cache Write)"))
        cache_read = integer(field(row, "Cache Read"))
        output = integer(field(row, "Output Tokens"))
        reported_total = integer(field(row, "Total Tokens"))
        exact_total = without_write + max(0, with_write - without_write) + cache_read + output
        if max(exact_total, reported_total) <= 0:
            continue
        imported.append(
            {
                "timestamp": timestamp,
                "kind": field(row, "Kind") or "unknown",
                "model": model,
                "max_mode": field(row, "Max Mode").lower() == "yes",
                "input_tokens": without_write,
                "cache_write_tokens": max(0, with_write - without_write),
                "cache_read_tokens": cache_read,
                "output_tokens": output,
                "reported_total_tokens": reported_total,
                "cost_usd": decimal(field(row, "Cost")),
            }
        )
    if not imported:
        raise RuntimeError("没有找到可用的 Cursor usage 记录")
    existing: list[dict[str, Any]] = []
    if archive_path.exists():
        try:
            archive = json.loads(archive_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("已有 Cursor 导入归档无法读取") from exc
        if not isinstance(archive, dict) or archive.get("schema_version") != 1 or not isinstance(archive.get("records"), list):
            raise RuntimeError("已有 Cursor 导入归档版本不受支持")
        existing = [record for record in archive["records"] if isinstance(record, dict)]
    merged = {_cursor_dedupe_key(record): record for record in existing}
    previous_count = len(merged)
    for record in imported:
        merged[_cursor_dedupe_key(record)] = record
    records = sorted(merged.values(), key=lambda record: (str(record.get("timestamp", "")), _cursor_dedupe_key(record)))
    payload = json.dumps(
        {
            "schema_version": 1,
            "imported_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "records": records,
        },
        ensure_ascii=False,
        sort_keys=True,
        indent=2,
    ).encode("utf-8")
    temporary = archive_path.with_name(f".{archive_path.name}.{uuid.uuid4().hex}.tmp")
    try:
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_bytes(payload)
        os.replace(temporary, archive_path)
    except OSError as exc:
        raise RuntimeError("Cursor 导入归档无法保存") from exc
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
    return {
        "imported_records": len(imported),
        "added_records": len(records) - previous_count,
        "total_records": len(records),
    }


def remove_cursor_import(archive_path: Path) -> bool:
    existed = archive_path.exists()
    try:
        archive_path.unlink(missing_ok=True)
    except OSError as exc:
        raise RuntimeError("Cursor 导入归档无法删除") from exc
    return existed


def _cline_files(roots: list[Path], cutoff: datetime) -> list[Path]:
    files: set[Path] = set()
    for root in roots:
        if root.is_file() and (root.name == "ui_messages.json" or root.name.endswith(".messages.json")):
            files.add(root)
        elif root.is_dir():
            for path in root.rglob("*"):
                if not path.is_file() or (path.name != "ui_messages.json" and not path.name.endswith(".messages.json")):
                    continue
                try:
                    if datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) >= cutoff:
                        files.add(path)
                except OSError:
                    continue
    return sorted(files, key=lambda path: os.fspath(path).casefold())


def _collect_cline_usage(roots: list[Path], cutoff: datetime) -> _SourceResult:
    files = _cline_files(roots, cutoff)
    discovered = any(root.exists() for root in roots)
    records: list[UsageRecord] = []
    seen: set[str] = set()
    current_session_ids: set[str] = set()
    current_archives: list[tuple[Path, dict[str, Any]]] = []
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        if not path.name.endswith(".messages.json"):
            continue
        try:
            archive = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            skipped += 1
            continue
        if isinstance(archive, dict) and archive.get("version") == 1 and _nonempty(archive.get("sessionId")):
            current_session_ids.add(str(archive["sessionId"]))
            current_archives.append((path, archive))
    for path, archive in current_archives:
        session_id = str(archive["sessionId"])
        messages = archive.get("messages") if isinstance(archive.get("messages"), list) else []
        for message in messages:
            if not isinstance(message, dict) or message.get("role") != "assistant" or not isinstance(message.get("metrics"), dict):
                continue
            metrics = message["metrics"]
            required = ("inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens")
            if not all(key in metrics for key in required):
                skipped += 1
                continue
            timestamp = _temporal(message.get("ts"))
            model_info = message.get("modelInfo") if isinstance(message.get("modelInfo"), dict) else {}
            model = _nonempty(model_info.get("id"))
            request_id = _nonempty(message.get("id"))
            if timestamp is None or not model or not request_id:
                skipped += 1
                continue
            identity = f"current:{session_id}:{request_id}"
            if identity in seen:
                continue
            seen.add(identity)
            counts = _canonical_counts(
                raw_input=_nonnegative_integer(metrics.get("inputTokens")),
                output=_nonnegative_integer(metrics.get("outputTokens")),
                cache_read=_nonnegative_integer(metrics.get("cacheReadTokens")),
                cache_write=_nonnegative_integer(metrics.get("cacheWriteTokens")),
                input_includes_cached=True,
            )
            if counts and counts.total > 0:
                records.append(UsageRecord(_day(timestamp) or "", "Cline", _model(model), counts, timestamp, identity, session_id, os.fspath(path), data_source="cline_messages_v1"))
            elif counts is None:
                skipped += 1
                _mark_incomplete_bucket(incomplete, timestamp, "Cline", model)
    for path in files:
        if path.name != "ui_messages.json":
            continue
        task_id = path.parent.name
        if task_id in current_session_ids:
            continue
        try:
            messages = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            skipped += 1
            continue
        if not isinstance(messages, list):
            continue
        for index, message in enumerate(messages):
            if not isinstance(message, dict) or message.get("type") != "say" or message.get("say") not in ("api_req_started", "deleted_api_reqs", "subagent_usage", "api_req_deleted"):
                continue
            try:
                payload = json.loads(message.get("text") or "")
            except (TypeError, json.JSONDecodeError):
                continue
            if not isinstance(payload, dict):
                continue
            if message.get("say") == "api_req_started":
                for candidate in messages[index + 1 :]:
                    if not isinstance(candidate, dict):
                        continue
                    if candidate.get("type") == "say" and candidate.get("say") == "api_req_started":
                        break
                    if candidate.get("type") == "say" and candidate.get("say") == "api_req_finished":
                        try:
                            finished = json.loads(candidate.get("text") or "")
                        except (TypeError, json.JSONDecodeError):
                            finished = None
                        if isinstance(finished, dict):
                            payload.update(finished)
                        break
            timestamp = _temporal(message.get("ts"))
            counts = _canonical_counts(
                raw_input=_nonnegative_integer(payload.get("tokensIn")),
                output=_nonnegative_integer(payload.get("tokensOut")),
                cache_read=_nonnegative_integer(payload.get("cacheReads")),
                cache_write=_nonnegative_integer(payload.get("cacheWrites")),
                input_includes_cached=False,
            )
            if timestamp is None or counts is None or counts.total <= 0:
                skipped += 1
                if counts is None:
                    _mark_incomplete_bucket(
                        incomplete,
                        timestamp,
                        "Cline",
                        _first_string(payload.get("model"), payload.get("modelId")),
                    )
                continue
            identity = f"legacy:{task_id}:{message.get('ts')}:{message.get('say')}"
            if identity in seen:
                continue
            seen.add(identity)
            records.append(
                UsageRecord(
                    _day(timestamp) or "",
                    "Cline",
                    _model(_first_string(payload.get("model"), payload.get("modelId"))),
                    counts,
                    timestamp,
                    identity,
                    task_id,
                    os.fspath(path),
                    index + 1,
                    "cline_ui_messages",
                )
            )
    return _SourceResult(
        records,
        _source_status(discovered, len(files), records),
        len(files),
        skipped,
        incomplete,
    )


def _copilot_token_details(raw: Any) -> tuple[int, int, int, int] | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        rows = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(rows, list):
        return None
    totals = {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0}
    recognized = 0
    for row in rows:
        if not isinstance(row, dict) or row.get("tokenType") not in totals:
            continue
        totals[str(row["tokenType"])] += _nonnegative_integer(row.get("tokenCount"))
        recognized += 1
    if not recognized:
        return None
    return totals["input"], totals["cache_read"], totals["cache_write"], totals["output"]


def _collect_copilot_store(database: Path) -> _SourceResult:
    if not database.exists():
        return _SourceResult([], "missing_db")
    result = _read_only_rows(database, "assistant_usage_events")
    if result is None:
        return _SourceResult([], "schema_unreadable", 1)
    columns, rows = result
    if not columns:
        return _SourceResult([], "missing_table", 1)
    required = {"id", "session_id", "model", "input_tokens", "output_tokens", "created_at"}
    if not required.issubset(columns):
        return _SourceResult([], "schema_mismatch", 1)
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for row in rows:
        row_id = _nonempty(row.get("id"))
        timestamp = _parse_time(row.get("created_at"))
        if not row_id or row_id in seen or timestamp is None:
            skipped += 1
            continue
        seen.add(row_id)
        raw_input = _nonnegative_integer(row.get("input_tokens"))
        raw_output = _nonnegative_integer(row.get("output_tokens"))
        declared_read = min(_nonnegative_integer(row.get("cache_read_tokens")), raw_input)
        declared_write = min(
            _nonnegative_integer(row.get("cache_write_tokens")),
            max(0, raw_input - declared_read),
        )
        details = _copilot_token_details(row.get("token_details_json"))
        details_consistent = bool(
            details
            and details[0] + details[1] + details[2] == raw_input
            and details[3] == raw_output
        )
        cache_read = details[1] if details_consistent and details else declared_read
        cache_write = details[2] if details_consistent and details else declared_write
        counts = _canonical_counts(
            raw_input=raw_input,
            output=raw_output,
            cache_read=cache_read,
            cache_write=cache_write,
            reasoning=min(_nonnegative_integer(row.get("reasoning_tokens")), raw_output),
            input_includes_cached=True,
        )
        if counts is None or counts.total <= 0:
            skipped += 1
            if counts is None:
                _mark_incomplete_bucket(
                    incomplete, timestamp, "Copilot CLI", row.get("model")
                )
            continue
        records.append(
            UsageRecord(
                _day(timestamp) or "",
                "Copilot CLI",
                _model(row.get("model")),
                counts,
                timestamp,
                f"copilot-store:{row_id}",
                _nonempty(row.get("session_id")),
                os.fspath(database),
                data_source="copilot_session_store",
            )
        )
    return _SourceResult(
        records, "ok" if records else "missing_valid_rows", 1, skipped, incomplete
    )


def _otel_scalar(value: Any) -> Any:
    if not isinstance(value, dict):
        return value
    for key in ("stringValue", "intValue", "doubleValue", "boolValue", "string_value", "int_value"):
        if key in value:
            return value[key]
    return value


def _otel_attributes(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return {str(key): _otel_scalar(item) for key, item in value.items()}
    if not isinstance(value, list):
        return {}
    result: dict[str, Any] = {}
    for row in value:
        if isinstance(row, dict) and (key := _nonempty(row.get("key"))):
            result[key] = _otel_scalar(row.get("value"))
    return result


def _otel_envelopes(obj: dict[str, Any], inherited: dict[str, Any] | None = None) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    attributes = dict(inherited or {})
    resource = obj.get("resource")
    if isinstance(resource, dict):
        attributes.update(_otel_attributes(resource.get("attributes")))
    results: list[tuple[dict[str, Any], dict[str, Any]]] = []
    if "name" in obj or "spanName" in obj:
        span_attributes = dict(attributes)
        span_attributes.update(_otel_attributes(obj.get("attributes")))
        results.append((obj, span_attributes))
    for key, value in obj.items():
        if key in ("attributes", "resource"):
            continue
        if isinstance(value, dict):
            results.extend(_otel_envelopes(value, attributes))
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    results.extend(_otel_envelopes(item, attributes))
    return results


def _otel_time(span: dict[str, Any]) -> datetime | None:
    for key in ("startTimeUnixNano", "start_time_unix_nano"):
        raw = _nonempty(span.get(key))
        if raw:
            try:
                return datetime.fromtimestamp(float(raw) / 1_000_000_000, timezone.utc)
            except (OSError, OverflowError, ValueError):
                pass
    for key in ("startTime", "start_time"):
        pair = span.get(key)
        if isinstance(pair, list) and pair:
            try:
                epoch = float(pair[0]) + (float(pair[1]) / 1_000_000_000 if len(pair) > 1 else 0)
                return datetime.fromtimestamp(epoch, timezone.utc)
            except (OSError, OverflowError, TypeError, ValueError):
                pass
    return _usage_temporal_info(span)


def _collect_copilot_otel(roots: list[Path], cutoff: datetime) -> _SourceResult:
    discovered = [root for root in roots if root.exists()]
    files = sorted({path for root in discovered for path in _usage_log_files(root, cutoff)})
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b"gen_ai.usage", b"attributes")), start=1):
            for span, attributes in _otel_envelopes(obj):
                operation = (_first_string(attributes.get("gen_ai.operation.name"), span.get("name"), span.get("spanName")) or "").lower()
                if operation != "chat" and not operation.endswith(" chat"):
                    continue
                counts = _canonical_counts(
                    raw_input=_first_integer(attributes, ("gen_ai.usage.input_tokens",)),
                    output=_first_integer(attributes, ("gen_ai.usage.output_tokens",)),
                    cache_read=_first_integer(attributes, ("gen_ai.usage.cache_read.input_tokens", "gen_ai.usage.cache_read_input_tokens")),
                    cache_write=_first_integer(attributes, ("gen_ai.usage.cache_creation.input_tokens", "gen_ai.usage.cache_creation_input_tokens")),
                    reasoning=_first_integer(attributes, ("gen_ai.usage.reasoning.output_tokens", "gen_ai.usage.reasoning_tokens")),
                    input_includes_cached=True,
                )
                timestamp = _otel_time(span)
                service = (_first_string(attributes.get("service.name"), attributes.get("gen_ai.system"), attributes.get("gen_ai.provider.name")) or "").lower()
                tool = "Copilot Chat" if "chat" in service or "vscode" in service else "Copilot CLI"
                raw_model = _first_string(attributes.get("gen_ai.response.model"), attributes.get("gen_ai.request.model"))
                if counts is None or counts.total <= 0 or timestamp is None:
                    skipped += 1
                    if counts is None:
                        _mark_incomplete_bucket(incomplete, timestamp, tool, raw_model)
                    continue
                trace_id = _first_string(span.get("traceId"), span.get("trace_id"))
                span_id = _first_string(span.get("spanId"), span.get("span_id"))
                identity = "|".join(filter(None, (trace_id, span_id))) or f"{path}:{line_number}:{len(records)}"
                if identity in seen:
                    continue
                seen.add(identity)
                explicit_session = _first_string(attributes.get("gen_ai.conversation.id"), attributes.get("session.id"))
                records.append(
                    UsageRecord(
                        _day(timestamp) or "",
                        tool,
                        _model(raw_model),
                        counts,
                        timestamp,
                        _first_string(attributes.get("gen_ai.request.id"), attributes.get("gen_ai.response.id"), span_id),
                        explicit_session or trace_id,
                        os.fspath(path),
                        line_number,
                        "copilot_otel_chat_span" if explicit_session else "copilot_otel_chat_span_trace_session_fallback",
                    )
                )
    return _SourceResult(
        records,
        _source_status(bool(discovered), len(files), records),
        len(files),
        skipped,
        incomplete,
    )


def _prefer_copilot_session_store(store: _SourceResult, otel: _SourceResult) -> None:
    if not store.records:
        return
    by_session: dict[str, list[datetime]] = {}
    for record in store.records:
        if record.session_id and record.timestamp:
            by_session.setdefault(record.session_id, []).append(record.timestamp)
    covered = {
        session: (min(timestamps), max(timestamps))
        for session, timestamps in by_session.items()
    }
    covered_days = {record.day for record in store.records}
    retained: list[UsageRecord] = []
    removed = 0
    for record in otel.records:
        should_remove = False
        if record.tool == "Copilot CLI":
            window = covered.get(record.session_id or "")
            if window and record.timestamp and window[0] <= record.timestamp <= window[1]:
                should_remove = True
            elif (
                record.data_source == "copilot_otel_chat_span_trace_session_fallback"
                and record.day in covered_days
            ):
                should_remove = True
        if should_remove:
            removed += 1
        else:
            retained.append(record)
    if removed:
        otel.records = retained
        otel.skipped += removed
        if not retained:
            otel.status = "deduped_by_session_store"


def _collect_result_usage_jsonl(
    tool: str,
    roots: list[Path],
    cutoff: datetime,
    *,
    accepted_names: set[str],
    usage_keys: tuple[str, ...],
    input_includes_cached: bool,
) -> _SourceResult:
    discovered = [root for root in roots if root.exists()]
    files = sorted(
        {
            path
            for root in discovered
            for path in _usage_log_files(root, cutoff)
            if not accepted_names or path.name in accepted_names
        }
    )
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped = 0
    incomplete: set[tuple[str, str, str]] = set()
    markers = tuple(f'"{key}"'.encode("utf-8") for key in usage_keys)
    for path in files:
        for line_number, obj in enumerate(_json_lines(path, matching_any=markers), start=1):
            event_type = (_first_string(obj.get("type"), obj.get("event")) or "").lower()
            if not any(term in event_type for term in ("result", "complete", "assistant_message", "response")) and event_type != "assistant":
                # This drops Antigravity statusline values and Droid's
                # cumulative TokenUsageUpdate events.
                continue
            usage_object = _first_nested(obj, usage_keys)
            timestamp = _usage_temporal_info(obj)
            if not usage_object or timestamp is None:
                skipped += 1
                continue
            result = obj.get("result") if isinstance(obj.get("result"), dict) else {}
            raw_model = _first_string(
                obj.get("model"),
                obj.get("modelId"),
                result.get("model"),
                usage_object.get("model"),
            )
            counts = _portable_usage(usage_object, input_includes_cached=input_includes_cached)
            if counts is None or counts.total <= 0:
                skipped += 1
                if counts is None:
                    _mark_incomplete_bucket(incomplete, timestamp, tool, raw_model)
                continue
            request_id = _first_string(obj.get("requestId"), obj.get("request_id"), obj.get("id"), obj.get("uuid"), result.get("id"))
            session_id = _first_string(obj.get("sessionId"), obj.get("session_id"), result.get("sessionId"), path.stem) or path.stem
            identity = f"{session_id}|{request_id}" if request_id else f"{path}:{line_number}"
            if identity in seen:
                continue
            seen.add(identity)
            records.append(
                UsageRecord(
                    _day(timestamp) or "",
                    tool,
                    _model(raw_model),
                    counts,
                    timestamp,
                    request_id,
                    session_id,
                    os.fspath(path),
                    line_number,
                    "local_transcript_result",
                )
            )
    return _SourceResult(
        records,
        _source_status(bool(discovered), len(files), records),
        len(files),
        skipped,
        incomplete,
    )


def _usage_log_files(root: Path, cutoff: datetime) -> list[Path]:
    if root.is_file():
        try:
            return [root] if datetime.fromtimestamp(root.stat().st_mtime, timezone.utc) >= cutoff else []
        except OSError:
            return []
    if not root.is_dir():
        return []
    files: list[Path] = []
    for path in root.rglob("*.jsonl"):
        try:
            if path.is_file() and datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) >= cutoff:
                files.append(path)
        except OSError:
            continue
    return sorted(files, key=lambda path: os.fspath(path).casefold())


def _compressed_dsh_files(root: Path, cutoff: datetime) -> list[Path]:
    if not root.is_dir():
        return []
    files: list[Path] = []
    for path in root.rglob("*.jsonl.zstd"):
        try:
            if path.is_file() and datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) >= cutoff:
                files.append(path)
        except OSError:
            continue
    return sorted(files, key=lambda path: os.fspath(path).casefold())


def _dsh_text(path: Path) -> str | None:
    try:
        if path.suffix == ".zstd":
            if zstandard is None:
                return None
            with path.open("rb") as compressed:
                with zstandard.ZstdDecompressor().stream_reader(compressed) as reader:
                    data = reader.read()
        else:
            data = path.read_bytes()
        return data.decode("utf-8")
    except (OSError, UnicodeError, zstandard.ZstdError if zstandard else OSError):
        return None


def _collect_dsh(root: Path, cutoff: datetime) -> _SourceResult:
    if not root.exists():
        return _SourceResult([], "missing")
    compressed = _compressed_dsh_files(root, cutoff)
    all_plaintext = _usage_log_files(root, cutoff)
    plaintext_paths = {path.resolve() for path in all_plaintext}
    authoritative_plaintext = {path.with_suffix("").resolve() for path in compressed}
    plaintext = (
        [path for path in all_plaintext if path.resolve() not in authoritative_plaintext]
        if zstandard is not None
        else all_plaintext
    )
    files = compressed + plaintext
    records: list[UsageRecord] = []
    seen: set[str] = set()
    skipped_compressed = 0
    uncovered_without_decoder = 0
    incomplete: set[tuple[str, str, str]] = set()

    def append_record(record: UsageRecord) -> None:
        fallback = f"{record.source_path or 'unknown'}:{record.line_number or 0}"
        identity = f"{record.session_id or 'unknown'}|{record.request_id or fallback}"
        if identity not in seen:
            seen.add(identity)
            records.append(record)

    for path in files:
        if path.suffix == ".zstd" and zstandard is None:
            skipped_compressed += 1
            if path.with_suffix("").resolve() not in plaintext_paths:
                uncovered_without_decoder += 1
            continue
        text = _dsh_text(path)
        if text is None:
            if path.suffix == ".zstd":
                skipped_compressed += 1
            continue
        provider = ""
        model = "unknown"
        current_step = ""
        step_has_chunk = False
        pending_message: UsageRecord | None = None
        pending_chunk: UsageRecord | None = None
        for line_number, line in enumerate(text.splitlines(), start=1):
            try:
                obj = json.loads(line)
            except (UnicodeError, json.JSONDecodeError):
                continue
            if not isinstance(obj, dict):
                continue
            event_type = _nonempty(obj.get("type")) or ""
            payload = obj.get("data") if isinstance(obj.get("data"), dict) else obj
            if event_type == "request/header":
                header = payload.get("header") if isinstance(payload.get("header"), dict) else payload
                config = header.get("config") if isinstance(header.get("config"), dict) else header
                provider = _nonempty(config.get("provider")) or provider
                model = _model(_first_string(config.get("model"), model))
                continue
            if event_type == "step/start":
                if pending_chunk or pending_message:
                    append_record(pending_chunk or pending_message)  # type: ignore[arg-type]
                pending_message = None
                pending_chunk = None
                current_step = _first_string(payload.get("id"), payload.get("stepId"), obj.get("seq"), f"step-{line_number}") or f"step-{line_number}"
                step_has_chunk = False
                continue
            if event_type == "step/end":
                if pending_chunk or pending_message:
                    append_record(pending_chunk or pending_message)  # type: ignore[arg-type]
                pending_message = None
                pending_chunk = None
                step_has_chunk = False
                continue
            usage_object: dict[str, Any] | None = None
            is_chunk = False
            if event_type == "assistant/chunk":
                chunk = payload.get("chunk") if isinstance(payload.get("chunk"), dict) else payload
                if chunk.get("type") == "usage":
                    usage_object = chunk.get("usage") if isinstance(chunk.get("usage"), dict) else chunk
                    is_chunk = True
            elif event_type == "assistant/message" and not step_has_chunk:
                usage_object = payload.get("usage") if isinstance(payload.get("usage"), dict) else None
            if usage_object is None:
                continue
            counts = _portable_usage(usage_object, input_includes_cached=False)
            timestamp = _usage_temporal_info(obj)
            if counts is None or counts.total <= 0 or timestamp is None:
                if counts is None:
                    _mark_incomplete_bucket(incomplete, timestamp, "dsh", model)
                continue
            event_id = _first_string(obj.get("seq"), payload.get("id"), f"{current_step}:{line_number}") or f"{current_step}:{line_number}"
            record = UsageRecord(
                _day(timestamp) or "",
                "dsh",
                model,
                counts,
                timestamp,
                event_id,
                path.parent.name,
                os.fspath(path),
                line_number,
                "dsh_session" if not provider else f"dsh_session:{provider}",
            )
            if is_chunk:
                step_has_chunk = True
                pending_message = None
                pending_chunk = record
            else:
                pending_message = record
        if pending_chunk or pending_message:
            append_record(pending_chunk or pending_message)  # type: ignore[arg-type]
    if uncovered_without_decoder and not records:
        status = "missing_decoder"
    elif uncovered_without_decoder:
        status = "partial_missing_decoder"
    elif not files:
        status = "discovered_no_usage"
    elif records:
        status = "ok"
    else:
        status = "missing_valid_rows"
    return _SourceResult(records, status, len(files), skipped_compressed, incomplete)


def _pi_like_record(
    obj: dict[str, Any],
    *,
    tool: str,
    data_source: str,
    source_path: Path,
    line_number: int,
    session_id: str,
    fallback_id: str,
    incomplete_buckets: set[tuple[str, str, str]],
) -> tuple[str, UsageRecord] | None:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else None
    if obj.get("type") != "message" or not message or message.get("role") != "assistant" or not isinstance(message.get("usage"), dict):
        return None
    raw = message["usage"]
    input_tokens = _nonnegative_integer(raw.get("input"))
    output = _nonnegative_integer(raw.get("output"))
    cache_read = _nonnegative_integer(raw.get("cacheRead"))
    cache_write = _nonnegative_integer(raw.get("cacheWrite"))
    reasoning = _nonnegative_integer(raw.get("reasoningTokens"))
    total = _nonnegative_integer(raw.get("totalTokens"))
    base_total = input_tokens + output + cache_read + cache_write
    reasoning_additional = reasoning > 0 and (total == 0 or total >= base_total + reasoning)
    normalized_output = output + (reasoning if reasoning_additional else 0)
    timestamp = _temporal(message.get("timestamp")) or _temporal(obj.get("timestamp"))
    model = _model(message.get("model"))
    counts = _canonical_counts(
        raw_input=input_tokens,
        output=normalized_output,
        cache_read=cache_read,
        cache_write=cache_write,
        reasoning=min(reasoning, normalized_output),
        input_includes_cached=False,
        explicit_total=total,
        explicit_total_authoritative=total > 0,
    )
    if counts is None or counts.total <= 0 or timestamp is None:
        if counts is None:
            _mark_incomplete_bucket(incomplete_buckets, timestamp, tool, model)
        return None
    entry_id = _nonempty(obj.get("id")) or fallback_id
    identity = f"{session_id}:{entry_id}"
    return (
        identity,
        UsageRecord(
            _day(timestamp) or "",
            tool,
            model,
            counts,
            timestamp,
            entry_id,
            session_id,
            os.fspath(source_path),
            line_number,
            data_source,
        ),
    )


def _collect_pi_jsonl(
    files: list[Path], *, tool: str, data_source: str, seen: set[str]
) -> tuple[list[UsageRecord], int, set[tuple[str, str, str]]]:
    records: list[UsageRecord] = []
    raw_records = 0
    incomplete: set[tuple[str, str, str]] = set()
    for path in files:
        session_id = path.name.split(".jsonl", 1)[0]
        for line_number, obj in enumerate(_json_lines(path, matching_any=(b'"type":"session"', b'"type": "session"', b'"usage"')), start=1):
            if obj.get("type") == "session" and (header_id := _nonempty(obj.get("id"))):
                session_id = header_id
                continue
            result = _pi_like_record(
                obj,
                tool=tool,
                data_source=data_source,
                source_path=path,
                line_number=line_number,
                session_id=session_id,
                fallback_id=f"file:{path}:{line_number}",
                incomplete_buckets=incomplete,
            )
            if result is None:
                continue
            raw_records += 1
            identity, record = result
            if identity not in seen:
                seen.add(identity)
                records.append(record)
    return records, raw_records, incomplete


def _collect_pi(root: Path, cutoff: datetime) -> _SourceResult:
    exists = root.exists()
    files = _jsonl_files(root, cutoff)
    records, raw, incomplete = _collect_pi_jsonl(
        files, tool="Pi", data_source="pi_session_jsonl", seen=set()
    )
    return _SourceResult(
        records,
        _source_status(exists, len(files), records),
        len(files),
        max(0, raw - len(records)),
        incomplete,
    )


def _named_files(roots: list[Path], cutoff: datetime | None, predicate: Any) -> list[Path]:
    files: set[Path] = set()
    for root in roots:
        candidates = [root] if root.is_file() else root.rglob("*") if root.is_dir() else []
        for path in candidates:
            try:
                if not path.is_file() or not predicate(path):
                    continue
                if cutoff and datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < cutoff:
                    continue
                files.add(path)
            except OSError:
                continue
    return sorted(files, key=lambda path: os.fspath(path).casefold())


def _collect_openclaw(roots: list[Path], cutoff: datetime) -> _SourceResult:
    discovered = [root for root in roots if root.exists()]
    databases = _named_files(roots, None, lambda path: path.name == "openclaw-agent.sqlite")
    transcripts = _named_files(
        roots,
        cutoff,
        lambda path: (
            path.name.endswith(".jsonl")
            or ".jsonl.reset." in path.name
            or ".jsonl.deleted." in path.name
        )
        and ("sessions" in path.parts or "session-sqlite-import-archive" in path.parts),
    )
    records: list[UsageRecord] = []
    seen: set[str] = set()
    readable_databases = 0
    raw_records = 0
    incomplete: set[tuple[str, str, str]] = set()
    for database in databases:
        result = _read_only_rows(database, "transcript_events")
        if result is None:
            continue
        columns, rows = result
        if not {"session_id", "seq", "event_json", "created_at"}.issubset(columns):
            continue
        readable_databases += 1
        for row in rows:
            timestamp = _temporal(row.get("created_at"))
            if timestamp and timestamp < cutoff:
                continue
            try:
                obj = json.loads(row.get("event_json") or "")
            except (TypeError, json.JSONDecodeError):
                continue
            if not isinstance(obj, dict):
                continue
            session_id = _nonempty(row.get("session_id")) or "unknown"
            sequence = _nonnegative_integer(row.get("seq"))
            parsed = _pi_like_record(
                obj,
                tool="OpenClaw",
                data_source="openclaw_transcript_sqlite",
                source_path=database,
                line_number=sequence,
                session_id=session_id,
                fallback_id=f"sqlite:{session_id}:{sequence}",
                incomplete_buckets=incomplete,
            )
            if parsed:
                raw_records += 1
                identity, record = parsed
                if identity not in seen:
                    seen.add(identity)
                    records.append(record)
    jsonl_records, jsonl_raw, jsonl_incomplete = _collect_pi_jsonl(
        transcripts,
        tool="OpenClaw",
        data_source="openclaw_transcript_jsonl",
        seen=seen,
    )
    records.extend(jsonl_records)
    raw_records += jsonl_raw
    incomplete.update(jsonl_incomplete)
    if not discovered:
        status = "missing"
    elif not databases and not transcripts:
        status = "discovered_no_usage"
    elif databases and not readable_databases and not transcripts:
        status = "schema_mismatch"
    elif records:
        status = "ok"
    else:
        status = "missing_valid_rows"
    return _SourceResult(
        records,
        status,
        len(databases) + len(transcripts),
        max(0, raw_records - len(records)),
        incomplete,
    )


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
