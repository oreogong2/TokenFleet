#!/usr/bin/env python3
"""Fail-closed checks for a GitHub public-source ZIP."""

from __future__ import annotations

import argparse
from pathlib import PurePosixPath
import unicodedata
from zipfile import BadZipFile, ZipFile


MAX_MEMBER_BYTES = 25 * 1024 * 1024
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
UTF8_FLAG = 0x800


def fail(message: str) -> None:
    raise SystemExit(f"TokenFleet public archive verification failed: {message}")


def forbidden_filename(path: PurePosixPath) -> bool:
    name = path.name.lower()
    if name == ".env.example":
        return False
    if name == ".env" or name.startswith(".env."):
        return True
    return path.suffix.lower() in {
        ".db",
        ".key",
        ".mobileprovision",
        ".p12",
        ".p8",
        ".pem",
        ".sqlite",
        ".sqlite3",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    args = parser.parse_args()

    forbidden_bytes = (
        b"oreo" + b"gong2" + b"@" + b"gmail.com",
        b"/Users/" + b"oreo",
        b"47" + b".97" + b".20" + b".13",
        b"BEGIN " + b"PRIVATE KEY",
        b"BEGIN RSA " + b"PRIVATE KEY",
        b"BEGIN EC " + b"PRIVATE KEY",
        b"BEGIN OPENSSH " + b"PRIVATE KEY",
    )

    try:
        with ZipFile(args.archive) as archive:
            if archive.testzip() is not None:
                fail("CRC validation failed")
            entries = archive.infolist()
            if not entries:
                fail("archive is empty")
            if sum(entry.file_size for entry in entries) > MAX_ARCHIVE_BYTES:
                fail("uncompressed archive exceeds 100 MiB")

            roots: set[str] = set()
            normalized_names: set[str] = set()
            for entry in entries:
                name = entry.filename
                if "\\" in name or name.startswith("/") or "\x00" in name:
                    fail("archive contains an unsafe path")
                path = PurePosixPath(name)
                if not path.parts or any(part in {"", ".", ".."} for part in path.parts):
                    fail("archive contains an unsafe path component")
                roots.add(path.parts[0])
                normalized = unicodedata.normalize("NFC", name)
                if normalized in normalized_names:
                    fail("archive contains duplicate Unicode-normalized paths")
                normalized_names.add(normalized)
                if any(ord(character) > 127 for character in name) and not (
                    entry.flag_bits & UTF8_FLAG
                ):
                    fail(f"non-ASCII filename lacks the ZIP UTF-8 flag: {name}")
                if entry.file_size > MAX_MEMBER_BYTES:
                    fail(f"archive member exceeds 25 MiB: {name}")
                relative = PurePosixPath(*path.parts[1:])
                if not entry.is_dir() and forbidden_filename(relative):
                    fail(f"credential or database filename entered archive: {relative}")
                if entry.is_dir():
                    continue
                payload = archive.read(entry)
                if any(marker in payload for marker in forbidden_bytes):
                    fail(f"personal marker or private-key header entered archive: {relative}")

            if len(roots) != 1 or not next(iter(roots)).startswith("TokenFleet-"):
                fail("archive must have one TokenFleet-* root directory")
    except (BadZipFile, OSError) as exc:
        fail(str(exc))

    print("PASS: public archive paths, UTF-8 filenames, and privacy markers")


if __name__ == "__main__":
    main()
