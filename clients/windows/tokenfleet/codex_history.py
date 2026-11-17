"""Resolve only verified, immutable Codex history prefixes (never message content).

HistoryPosition.thread_id identifies a physical rollout, not the logical thread.
See openai/codex: protocol/src/protocol.rs and rollout/src/rollout_file_name.rs.
"""
from __future__ import annotations

import json
import io
import re
import uuid
import time
from pathlib import Path


class HistoryReadError(ValueError):
    pass


def strict_usage(raw):
    if not isinstance(raw, dict):
        return None
    keys = ('input_tokens', 'output_tokens', 'cached_input_tokens', 'total_tokens')
    if any(type(raw.get(k)) is not int or not 0 <= raw[k] <= 2**63-1 for k in keys):
        return None
    if raw['total_tokens'] != raw['input_tokens'] + raw['output_tokens'] or raw['cached_input_tokens'] > raw['input_tokens']:
        return None
    reasoning = raw.get('reasoning_output_tokens', 0)
    if type(reasoning) is not int or not 0 <= reasoning <= raw['output_tokens']:
        return None
    return raw


def ancestor_path(identifier, paths):
    candidates = {p.resolve() for p in paths if not p.is_symlink() and rollout_id(p) == identifier}
    candidates = {p for p in candidates if p.suffix != '.zst' or p.with_suffix('') not in candidates}
    return next(iter(candidates)) if len(candidates) == 1 else None


def source_lines(path):
    """Decode complete compressed sources; a truncated frame never succeeds."""
    if path.suffix != '.zst':
        with path.open('rb') as source:
            yield from source
        return
    try:
        import zstandard
        before = path.stat()
        decoder = zstandard.ZstdDecompressor(max_window_size=128 * 1024).decompressobj()
        pending = b''
        total = 0
        deadline = time.monotonic() + 30
        with path.open('rb') as source:
            while chunk := source.read(256):
                while chunk:
                    if decoder.eof:
                        decoder = zstandard.ZstdDecompressor(max_window_size=128 * 1024).decompressobj()
                    decoded = decoder.decompress(chunk)
                    chunk = decoder.unused_data if decoder.eof else b''
                    total += len(decoded)
                    if total > 8 * 1024**3 or time.monotonic() > deadline:
                        raise HistoryReadError('compressed history exceeds limits')
                    pending += decoded
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        if len(line) > 64 * 1024**2:
                            raise HistoryReadError('oversized compressed history line')
                        yield line + b'\n'
                    if len(pending) > 64 * 1024**2:
                        raise HistoryReadError('oversized compressed history line')
        after = path.stat()
        if not decoder.eof or pending or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise HistoryReadError('incomplete or changing compressed history')
    except (ImportError, OSError) as error:
        raise HistoryReadError('unreadable compressed history') from error
    except zstandard.ZstdError as error:
        raise HistoryReadError('invalid compressed history') from error


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
    path = ancestor_path(identifier, paths)
    if path is None:
        return None
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
                        return strict_usage(info["total_token_usage"])
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
