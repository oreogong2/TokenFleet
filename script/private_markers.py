#!/usr/bin/env python3
"""Load maintainer-private export markers without publishing their values."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat


EXPECTED_PRIVATE_MARKERS = 3
PRIVATE_KEY_MARKERS = (
    b"BEGIN PRIVATE KEY",
    b"BEGIN RSA PRIVATE KEY",
    b"BEGIN EC PRIVATE KEY",
    b"BEGIN OPENSSH PRIVATE KEY",
)


class PrivateMarkerError(ValueError):
    pass


def load_private_markers(path_value: str | os.PathLike[str]) -> tuple[bytes, ...]:
    path = Path(path_value)
    if not path.is_absolute():
        raise PrivateMarkerError("private markers file must use an absolute path")
    if path.is_symlink() or not path.is_file():
        raise PrivateMarkerError("private markers file must be a regular non-symlink file")
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise PrivateMarkerError("private markers file permissions must not allow group/other access")
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise PrivateMarkerError("private markers file must be readable UTF-8") from exc
    lines = text.splitlines()
    if len(lines) != EXPECTED_PRIVATE_MARKERS or any(not line for line in lines):
        raise PrivateMarkerError(
            f"private markers file must contain exactly {EXPECTED_PRIVATE_MARKERS} non-empty lines"
        )
    if len(set(lines)) != len(lines):
        raise PrivateMarkerError("private markers must be unique")
    encoded = tuple(line.encode("utf-8") for line in lines)
    if any(len(marker) < 4 or len(marker) > 1024 or b"\x00" in marker for marker in encoded):
        raise PrivateMarkerError("private markers must be 4-1024 non-NUL UTF-8 bytes")
    return encoded


def scan_tree(root_value: str | os.PathLike[str], markers: tuple[bytes, ...]) -> Path | None:
    root = Path(root_value).resolve()
    if not root.is_dir():
        raise PrivateMarkerError("scan root must be a directory")
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            payload = path.read_bytes()
        except OSError as exc:
            raise PrivateMarkerError("export contains an unreadable file") from exc
        if any(marker in payload for marker in (*markers, *PRIVATE_KEY_MARKERS)):
            return path.relative_to(root)
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--markers-file", required=True)
    parser.add_argument("--scan-root", required=True)
    args = parser.parse_args()
    try:
        markers = load_private_markers(args.markers_file)
        matched_path = scan_tree(args.scan_root, markers)
    except PrivateMarkerError as exc:
        raise SystemExit(f"TokenFleet private marker check failed: {exc}") from exc
    if matched_path is not None:
        raise SystemExit(
            "TokenFleet private marker check failed: private marker entered export at "
            f"{matched_path}"
        )
    print("PASS: maintainer-private markers and private-key headers are absent")


if __name__ == "__main__":
    main()
