#!/usr/bin/env python3
"""Fail closed when TokenFleet's published and built version identities diverge."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def one_match(pattern: str, text: str, label: str) -> str:
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    require(len(matches) == 1, f"{label}: expected exactly one match, found {len(matches)}")
    return matches[0]


def load_expected(root: Path) -> tuple[str, str]:
    raw = json.loads(read_text(root / "config" / "release_identity.json"))
    release = raw.get("release_version")
    collector = raw.get("collector_version")
    require(isinstance(release, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", release) is not None,
            "release_identity.json has an invalid release_version")
    require(isinstance(collector, str) and re.fullmatch(r"\d+\.\d+\.\d+", collector) is not None,
            "release_identity.json has an invalid collector_version")
    return release, collector


def verify_sources(root: Path) -> tuple[str, str]:
    release, collector = load_expected(root)
    expected_tag = f"v{release}"
    display_release = release.split("-", 1)[1] if "-" in release else release

    changelog_versions = re.findall(
        r"^##\s+(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s+-\s+\d{4}-\d{2}-\d{2}\s*$",
        read_text(root / "CHANGELOG.md"),
        flags=re.MULTILINE,
    )
    require(bool(changelog_versions), "CHANGELOG does not contain a release heading")
    changelog_version = changelog_versions[0]
    require(changelog_version == release,
            f"CHANGELOG first release {changelog_version!r} != configured release {release!r}")

    release_copy = (
        (
            "README.md",
            r"当前发布版本是\s+([^（\n]+)（tag `([^`]+)`）",
        ),
        (
            "docs/INSTALL.md",
            r"^状态：当前发布版本为\s+([^（\n]+)（tag `([^`]+)`）",
        ),
    )
    for relative, pattern in release_copy:
        matches = re.findall(pattern, read_text(root / relative), flags=re.MULTILINE)
        require(len(matches) == 1,
                f"{relative}: expected exactly one current-release marker, found {len(matches)}")
        actual_display, actual_tag = matches[0]
        require(actual_display.strip() == display_release,
                f"{relative} display release {actual_display.strip()!r} != {display_release!r}")
        require(actual_tag == expected_tag,
                f"{relative} current tag {actual_tag!r} != {expected_tag!r}")

    shell_pattern = r'^VERSION="\$\{TOKENFLEET_VERSION:-(.+)\}"$'
    for relative in ("script/install_from_source.sh", "script/build_swiftui_and_run.sh"):
        actual = one_match(shell_pattern, read_text(root / relative), relative)
        require(actual == release, f"{relative} default {actual!r} != {release!r}")

    swift_protocol = read_text(
        root / "TokenStepSwift" / "Sources" / "TokenStepSwift" / "Services" / "TeamSyncProtocol.swift"
    )
    actual_collector = one_match(
        r'^\s*static let collectorVersion = "([^"]+)"\s*$',
        swift_protocol,
        "TeamSync collector version",
    )
    require(actual_collector == collector,
            f"collector version {actual_collector!r} != configured {collector!r}")

    runtime_ui_files = (
        "TokenStepSwift/Sources/TokenStepSwift/Support/MainWindowPresenter.swift",
        "TokenStepSwift/Sources/TokenStepSwift/Support/SettingsWindowPresenter.swift",
        "TokenStepSwift/Sources/TokenStepSwift/Views/SettingsView.swift",
        "TokenStepSwift/Sources/TokenStepSwift/Views/ScreenshotCaptureViews.swift",
    )
    for relative in runtime_ui_files:
        content = read_text(root / relative)
        require(re.search(r"TokenFleet beta\.\d+", content) is None,
                f"{relative} contains a hard-coded user-visible beta label")
        require("UpdateService.currentVersion" in content,
                f"{relative} does not derive its release label from UpdateService.currentVersion")

    web_source = read_text(root / "web" / "community-app.js")
    require("随机设备 ID、平台、App／采集器版本、时区和统计完整性" in web_source,
            "install privacy copy does not disclose minimum synchronization metadata")
    require("邮箱或设备详情" not in web_source,
            "install privacy copy still overclaims that no device metadata is uploaded")

    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        actual_tag = os.environ.get("GITHUB_REF_NAME", "")
        require(actual_tag == expected_tag,
                f"Git tag {actual_tag!r} != configured release tag {expected_tag!r}")

    return release, collector


def verify_app_bundle(app_bundle: Path, release: str) -> None:
    plist_path = app_bundle / "Contents" / "Info.plist"
    require(plist_path.is_file(), f"built App Info.plist not found: {plist_path}")
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    actual_release = plist.get("TokenFleetReleaseVersion")
    require(actual_release == release,
            f"built App release {actual_release!r} != configured release {release!r}")
    expected_bundle = release.split("-", 1)[0].split("+", 1)[0]
    actual_bundle = plist.get("CFBundleShortVersionString")
    require(actual_bundle == expected_bundle,
            f"built App bundle version {actual_bundle!r} != {expected_bundle!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-bundle", type=Path)
    args = parser.parse_args()
    try:
        release, collector = verify_sources(ROOT)
        if args.app_bundle is not None:
            verify_app_bundle(args.app_bundle.resolve(), release)
    except (OSError, ValueError, json.JSONDecodeError, VerificationError) as error:
        print(f"release identity verification failed: {error}", file=sys.stderr)
        return 1
    print(f"release identity verified: app={release}, collector={collector}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
