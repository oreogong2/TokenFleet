"""Resolve only verified, immutable Codex history prefixes (never message content).

HistoryPosition.thread_id identifies a physical rollout, not the logical thread.
See openai/codex: protocol/src/protocol.rs and rollout/src/rollout_file_name.rs.
"""
from __future__ import annotations

import json
import io
import re
import uuid
from pathlib import Path


def rollout_id(path: Path) -> str | None:
    match = re.fullmatch(r"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-fA-F-]{36})(?:_([0-9a-fA-F-]{36}))?\.jsonl(?:\.zst)?", path.name)
    if not match:
        return None
    try:
        uuid.UUID(match[1])
        return str(uuid.UUID(match[2] or match[1]))
    except ValueError:
        return None


def history_position(value):
    if not isinstance(value, dict):
        return None
    try:
        identifier = str(uuid.UUID(value["thread_id"]))
        ordinal, offset = value["end_ordinal_exclusive"], value["end_byte_offset"]
        if type(ordinal) is not int or type(offset) is not int or ordinal <= 0 or offset <= 0:
            return None
        return identifier, ordinal, offset
    except (KeyError, ValueError, TypeError, AttributeError):
        return None


def prefix_usage(position, paths: list[Path], visited=frozenset()):
    """Return the last raw cumulative vector in the exact prefix, or None.

    Refuse missing/ambiguous ancestors, partial lines, inconsistent ordinals,
    cycles and excessive scans. Never replace a missing baseline with a guess.
    """
    if position is None or position in visited or len(visited) >= 32:
        return None
    identifier, ordinal, offset = position
    candidates = {p.resolve() for p in paths if not p.is_symlink() and rollout_id(p) == identifier}
    # A plain file and its compressed copy are one source. Prefer the plain one.
    candidates = {p for p in candidates if p.suffix != '.zst' or p.with_suffix('') not in candidates}
    if len(candidates) != 1:
        return None
    path = candidates.pop()
    try:
        if path.suffix == '.zst':
            tail = _compressed_prefix_tail(path, offset)
            if tail is None:
                return None
            handle = io.BytesIO(tail)
            effective_offset = len(tail)
        else:
            handle = path.open('rb')
            effective_offset = offset
        with handle:
            if path.suffix != '.zst' and offset > path.stat().st_size:
                return None
            handle.seek(effective_offset - 1)
            if handle.read(1) != b"\n":
                return None
            # The position is an exclusive byte boundary. Read backwards to the
            # nearest token counter, without loading a long transcript into RAM.
            cursor, pending, scanned = effective_offset - 1, b"", 0
            expected = ordinal - 1
            while cursor or pending:
                if b"\n" not in pending and cursor:
                    length = min(cursor, 65536)
                    cursor -= length
                    handle.seek(cursor)
                    pending = handle.read(length) + pending
                    scanned += length
                    if scanned > 64 * 1024 * 1024 or (b"\n" not in pending and len(pending) > 2 * 1024 * 1024):
                        return None
                    continue
                if b"\n" in pending:
                    pending, line = pending.rsplit(b"\n", 1)
                else:
                    line, pending = pending, b""
                if len(line) > 2 * 1024 * 1024:
                    return None
                obj = json.loads(line)
                if type(obj.get("ordinal")) is not int or obj["ordinal"] != expected:
                    return None
                expected -= 1
                payload = obj.get("payload", {})
                if obj.get("type") == "event_msg" and payload.get("type") == "token_count":
                    info = payload.get("info")
                    if isinstance(info, dict) and "total_token_usage" in info:
                        return info["total_token_usage"]
                if obj.get("type") == "session_meta":
                    if "history_base" in payload:
                        return prefix_usage(history_position(payload["history_base"]), paths, visited | {position})
                    return {"input_tokens": 0, "output_tokens": 0, "cached_input_tokens": 0, "total_tokens": 0}
    except (OSError, ValueError, TypeError, AttributeError):
        return None
    return None


def _compressed_prefix_tail(path, offset):
    if offset > 8 * 1024**3:
        return None
    try:
        import zstandard
    except ImportError:
        return None
    try:
        before = path.stat()
        tail = bytearray()
        remaining = offset
        with path.open('rb') as source, zstandard.ZstdDecompressor(max_window_size=128 * 1024).stream_reader(source) as reader:
            while remaining:
                chunk = reader.read(min(remaining, 65536))
                if not chunk:
                    return None
                remaining -= len(chunk)
                tail.extend(chunk)
                if len(tail) > 64 * 1024**2:
                    del tail[:len(tail) - 64 * 1024**2]
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            return None
        return tail
    except (OSError, zstandard.ZstdError):
        return None
