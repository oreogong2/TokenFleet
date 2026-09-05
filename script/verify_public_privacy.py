#!/usr/bin/env python3
"""Check the current public tree and new commit identities without echoing PII."""

from __future__ import annotations

import argparse
import ipaddress
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
PERSONAL_EMAIL = re.compile(
    r"(?i)(?<![\w.+-])[\w.+-]+@(?:gmail\.com|googlemail\.com|qq\.com|"
    r"163\.com|126\.com|outlook\.com|hotmail\.com|icloud\.com|yahoo\.com)\b"
)
HOME_PATH = re.compile(r"/(?:Users|home)/([A-Za-z0-9_.-]+)(?:/|\b)")
EXAMPLE_USERS = {"example", "user", "username", "your_user", "runner", "test", "shared", "ubuntu"}
IPV4 = re.compile(r"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])")
KEY_HEADER = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
PLACEHOLDER_DOMAINS = {"example.com", "example.org", "example.net"}


def content_issues(path: str, text: str) -> list[tuple[int, str]]:
    findings = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if PERSONAL_EMAIL.search(line):
            findings.append((line_number, "personal email"))
        if any(match.group(1).lower() not in EXAMPLE_USERS for match in HOME_PATH.finditer(line)):
            findings.append((line_number, "personal home path"))
        if KEY_HEADER.search(line):
            findings.append((line_number, "private-key header"))
        # Test networks and examples remain valid. Operational public addresses
        # belong in private deployment records, not public documentation.
        if path.endswith((".md", ".html", ".txt", ".rst")):
            for match in IPV4.finditer(line):
                try:
                    address = ipaddress.ip_address(match.group())
                except ValueError:
                    continue
                if address.is_global:
                    findings.append((line_number, "public IP in documentation"))
    return findings


def safe_commit_email(email: str) -> bool:
    local, separator, domain = email.lower().rpartition("@")
    if not separator or not local:
        return False
    return (
        domain == "users.noreply.github.com"
        or email.lower() == "noreply@github.com"
        or domain in PLACEHOLDER_DOMAINS
        or domain.endswith((".invalid", ".test"))
        or email.lower() == "noreply@tokenfleet.local"
    )


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args])


def check_tree(root: Path) -> list[str]:
    errors = []
    for raw_path in git(root, "ls-files", "-z").split(b"\0"):
        if not raw_path:
            continue
        relative = raw_path.decode("utf-8")
        path = root / relative
        if path.is_symlink():
            errors.append(f"{relative}: tracked symlink cannot be privacy-scanned")
            continue
        payload = path.read_bytes()
        if b"\0" in payload:
            continue
        for line, category in content_issues(relative, payload.decode("utf-8", "replace")):
            errors.append(f"{relative}:{line}: {category}")
    return errors


def check_commits(root: Path, base: str) -> list[str]:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", base) or set(base) == {"0"}:
        raise ValueError("base-ref must be a non-zero full commit SHA")
    git(root, "cat-file", "-e", base + "^{commit}")
    rows = git(root, "log", base + "..HEAD", "--format=%H%x00%ae%x00%ce").decode().splitlines()
    errors = []
    for row in rows:
        sha, author, committer = row.split("\0")
        for label, email in (("author", author), ("committer", committer)):
            if not safe_commit_email(email):
                errors.append(f"commit {sha[:12]}: use a noreply {label} email")
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-ref", help="Full base SHA; only newer commit identities are checked")
    args = parser.parse_args()
    try:
        errors = check_tree(ROOT)
        if args.base_ref:
            errors.extend(check_commits(ROOT, args.base_ref))
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit("Public privacy check could not complete") from exc
    if errors:
        print("Public privacy check failed (values withheld):")
        for error in errors:
            print("- " + error)
        raise SystemExit(1)
    print("PASS: public content privacy" + (" and new commit identities" if args.base_ref else ""))


if __name__ == "__main__":
    main()
