#!/usr/bin/env bash
set -euo pipefail

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep (rg) is required" >&2
  exit 1
}
rg --version >/dev/null 2>&1 || {
  echo "ripgrep (rg) could not be executed" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_APP_BUNDLE="$ROOT_DIR/TokenStepSwift/dist/TokenFleet.app"
IDENTITY_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-desktop-identity.XXXXXX")"
BUILD_OUTPUT_ROOT="$(mktemp -d "$IDENTITY_WORK_DIR/.tokenfleet-build.XXXXXX")"
APP_BUNDLE="$BUILD_OUTPUT_ROOT/TokenFleet.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
TEST_BUNDLE_ID="com.lingdong.TokenFleet.Preflight"
TEST_UPDATE_URL="https://updates.example.invalid/tokenfleet/latest"
TEST_COMMUNITY_URL="https://community.example.invalid"
TEST_TEAM_ID="ABCDE12345"
TEST_VERSION="0.0.1-beta.1"
RELEASE_FIXTURE=""
VERSION_FIXTURE=""
ATOMIC_FIXTURE=""
COMPLETED=false

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  for directory in "$RELEASE_FIXTURE" "$VERSION_FIXTURE" "$ATOMIC_FIXTURE" "$IDENTITY_WORK_DIR"; do
    if [[ -n "$directory" && -d "$directory" ]]; then
      rm -rf "$directory"
    fi
  done
  [[ "$COMPLETED" == true || "$status" -ne 0 ]] || status=1
  exit "$status"
}
trap cleanup EXIT

bundle_fingerprint() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
if not root.exists() and not root.is_symlink():
    print("MISSING")
    raise SystemExit(0)
digest = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda item: str(item.relative_to(root))):
    relative = str(path.relative_to(root)).encode("utf-8")
    digest.update(relative + b"\0")
    if path.is_symlink():
        digest.update(b"L" + os.readlink(path).encode("utf-8") + b"\0")
    elif path.is_file():
        digest.update(b"F")
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    elif path.is_dir():
        digest.update(b"D")
print(digest.hexdigest())
PY
}

DIST_FINGERPRINT_BEFORE="$(bundle_fingerprint "$DIST_APP_BUNDLE")"

fail() {
  echo "TokenFleet desktop identity preflight failed: $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_source_has() {
  local file="$1"
  local pattern="$2"
  rg -q --fixed-strings -- "$pattern" "$file" || fail "$file is missing required identity: $pattern"
}

assert_source_lacks() {
  local file="$1"
  local pattern="$2"
  local status=0
  rg -q --fixed-strings -- "$pattern" "$file" || status=$?
  if [[ "$status" -eq 0 ]]; then
    fail "$file still contains forbidden cross-product behavior: $pattern"
  fi
  [[ "$status" -eq 1 ]] || fail "ripgrep failed while checking $file"
}

bash -n "$ROOT_DIR/script/build_swiftui_and_run.sh"
bash -n "$ROOT_DIR/script/package_release.sh"
/usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" \
  --verify-fixture "$ROOT_DIR/script/fixtures/community-origin-cases.tsv"

TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
TOKENFLEET_CREDENTIAL_BACKEND="file-login-v1" \
TOKENFLEET_EXTERNAL_SIGNING_STAGE="1" \
TOKENFLEET_VERSION="$TEST_VERSION" \
TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
  "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch

[[ -d "$APP_BUNDLE" ]] || fail "TokenFleet.app was not built"
[[ -x "$APP_BUNDLE/Contents/MacOS/TokenFleet" ]] || fail "TokenFleet executable is missing"
[[ -x "$APP_BUNDLE/Contents/Helpers/TokenFleetHelper" ]] || fail "TokenFleetHelper is missing"
[[ -f "$APP_BUNDLE/Contents/Resources/LICENSE.txt" ]] || fail "MIT LICENSE is missing from the bundle"
[[ -f "$APP_BUNDLE/Contents/Resources/NOTICE.txt" ]] || fail "NOTICE is missing from the bundle"

assert_equal "TokenFleet" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$INFO_PLIST")" "CFBundleName"
assert_equal "TokenFleet" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$INFO_PLIST")" "CFBundleDisplayName"
assert_equal "TokenFleet" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$INFO_PLIST")" "CFBundleExecutable"
assert_equal "$TEST_BUNDLE_ID" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INFO_PLIST")" "CFBundleIdentifier"
assert_equal "$TEST_UPDATE_URL" "$(/usr/libexec/PlistBuddy -c 'Print TokenFleetUpdateAPIURL' "$INFO_PLIST")" "TokenFleetUpdateAPIURL"
assert_equal "$TEST_COMMUNITY_URL" "$(/usr/libexec/PlistBuddy -c 'Print TokenFleetCommunityServerURL' "$INFO_PLIST")" "TokenFleetCommunityServerURL"
assert_equal "file-login-v1" "$(/usr/libexec/PlistBuddy -c 'Print TokenFleetCredentialBackend' "$INFO_PLIST")" "TokenFleetCredentialBackend"
assert_equal "$TEST_TEAM_ID" "$(/usr/libexec/PlistBuddy -c 'Print TokenFleetDeveloperTeamID' "$INFO_PLIST")" "TokenFleetDeveloperTeamID"
assert_equal "$TEST_VERSION" "$(/usr/libexec/PlistBuddy -c 'Print TokenFleetReleaseVersion' "$INFO_PLIST")" "TokenFleetReleaseVersion"
assert_equal "0.0.1" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST")" "CFBundleShortVersionString"

APP_PATHS="$ROOT_DIR/TokenStepSwift/Sources/TokenStepSwift/Support/AppPaths.swift"
AUTOSTART="$ROOT_DIR/TokenStepSwift/Sources/TokenStepSwift/Services/AutostartService.swift"
LIFECYCLE="$ROOT_DIR/TokenStepSwift/Sources/TokenStepSwift/Support/LifecycleLogger.swift"
SINGLE_INSTANCE="$ROOT_DIR/TokenStepSwift/Sources/TokenStepSwift/Support/SingleInstanceGuard.swift"
UPDATER="$ROOT_DIR/TokenStepSwift/Sources/TokenStepSwift/Services/UpdateService.swift"
HELPER="$ROOT_DIR/TokenStepSwift/Sources/TokenStepHelper/main.swift"
POPOVER_FOOTER="$ROOT_DIR/TokenStepSwift/Sources/TokenStepSwift/Views/Popover/PopoverFooterView.swift"
BUILD_SCRIPT="$ROOT_DIR/script/build_swiftui_and_run.sh"
RELEASE_SCRIPT="$ROOT_DIR/script/package_release.sh"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
SOURCE_INSTALLER="$ROOT_DIR/script/install_from_source.sh"
SOURCE_SIGNING="$ROOT_DIR/script/lib/tokenfleet_source_signing.sh"

assert_source_has "$APP_PATHS" 'appendingPathComponent("TokenFleet", isDirectory: true)'
assert_source_has "$APP_PATHS" 'TOKENFLEET_TEST_APP_SUPPORT_ROOT'
assert_source_lacks "$APP_PATHS" 'appendingPathComponent("TokenStep", isDirectory: true)'
assert_source_has "$AUTOSTART" 'com.lingdong.TokenFleet'
assert_source_lacks "$AUTOSTART" 'com.huangshu.TokenStep.login'
assert_source_has "$LIFECYCLE" '.reopenRequested'
assert_source_lacks "$LIFECYCLE" 'com.huangshu.TokenStep.reopenRequested'
assert_source_has "$SINGLE_INSTANCE" 'TokenFleet.lock'
assert_source_lacks "$SINGLE_INSTANCE" 'TokenStep.lock'
assert_source_has "$UPDATER" 'TokenFleetUpdateAPIURL'
assert_source_has "$UPDATER" 'TokenFleetDeveloperTeamID'
assert_source_has "$UPDATER" 'signingTeamIdentifier(appURL) == expectedTeamID'
assert_source_has "$UPDATER" 'TokenFleet.app'
assert_source_lacks "$UPDATER" '/Applications/TokenStep.app'
assert_source_lacks "$UPDATER" 'api.github.com/repos/Backtthefuture/TokenStep'
assert_source_has "$HELPER" '/Applications/TokenFleet.app'
assert_source_has "$HELPER" '"-x", "TokenFleet"'
assert_source_lacks "$HELPER" '/Applications/TokenStep.app'
assert_source_lacks "$HELPER" '"-x", "TokenStepSwift"'
assert_source_has "$POPOVER_FOOTER" 'appState.openCommunityLeaderboard('
assert_source_has "$POPOVER_FOOTER" '@Environment(\.isScreenshotRendering)'
assert_source_lacks "$BUILD_SCRIPT" 'pkill -f "TokenUsageMenu.py"'
assert_source_lacks "$BUILD_SCRIPT" 'pkill -x "TokenStepSwift"'
assert_source_lacks "$RELEASE_SCRIPT" 'rm -rf "$RELEASE_DIR"'
assert_source_has "$RELEASE_SCRIPT" 'mv -n "$ARTIFACT_STAGING" "$VERSION_RELEASE_DIR"'
assert_source_lacks "$RELEASE_SCRIPT" 'APPLE_APP_PASSWORD'
assert_source_lacks "$RELEASE_SCRIPT" '--password'
assert_source_has "$RELEASE_SCRIPT" 'TOKENFLEET_NOTARY_KEY_ID'
assert_source_has "$RELEASE_SCRIPT" 'TOKENFLEET_NOTARY_ISSUER'
assert_source_has "$RELEASE_SCRIPT" 'verify_bundle_contract "$APP_BUNDLE"'
assert_source_has "$RELEASE_SCRIPT" 'TOKENFLEET_CREDENTIAL_BACKEND="file-login-v1"'
assert_source_has "$RELEASE_WORKFLOW" 'TOKENFLEET_COMMUNITY_SERVER_URL: ${{ vars.TOKENFLEET_COMMUNITY_SERVER_URL }}'
assert_source_has "$SOURCE_INSTALLER" 'MODE="local-only"'
assert_source_has "$SOURCE_INSTALLER" 'The enrollment code is never handled by this script'
assert_source_has "$SOURCE_SIGNING" 'TOKENFLEET_SOURCE_BACKEND_ENABLED="file-login-v1"'
assert_source_has "$SOURCE_SIGNING" 'certificate leaf = H'
assert_source_has "$SOURCE_SIGNING" '-x \'
assert_source_lacks "$SOURCE_SIGNING" 'keychain-access-groups'
assert_source_lacks "$SOURCE_SIGNING" 'com.apple.application-identifier'
assert_source_lacks "$SOURCE_SIGNING" 'com.apple.developer.team-identifier'

# Explicit output overrides are limited to dedicated mktemp roots. A caller
# cannot redirect a build at the repository, /Applications, or another broad
# existing directory that may contain a previous installation.
if TOKENFLEET_APP_OUTPUT_ROOT="$ROOT_DIR" \
    TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "desktop build accepted an unsafe output root"
fi

# An update endpoint without a pinned Developer Team ID must stay disabled.
INFO_BEFORE="$(shasum -a 256 "$INFO_PLIST")"
if TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_TEAM_ID="" \
    TOKENFLEET_VERSION="$TEST_VERSION" \
    TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "build enabled updates without TOKENFLEET_TEAM_ID"
fi
assert_equal "$INFO_BEFORE" "$(shasum -a 256 "$INFO_PLIST")" "failed update build changed the existing bundle"

if TOKENFLEET_VERSION="../outside" \
    TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "desktop build accepted a path-like version"
fi
assert_equal "$INFO_BEFORE" "$(shasum -a 256 "$INFO_PLIST")" "malicious build version changed the existing bundle"

if TOKENFLEET_VERSION="$TEST_VERSION" \
    TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TOKENFLEET_UPDATE_API_URL='https://updates.example.invalid/latest?a=1&b=<unsafe>' \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
    TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "desktop build accepted XML-unsafe update metadata"
fi
assert_equal "$INFO_BEFORE" "$(shasum -a 256 "$INFO_PLIST")" "unsafe update metadata changed the existing bundle"

while IFS=$'\t' read -r fixture_mode fixture_expectation fixture_value; do
  [[ "$fixture_mode" == "production" && "$fixture_expectation" == "invalid" ]] || continue
  [[ "$fixture_value" != "<EMPTY>" ]] || continue
  invalid_community_url="$fixture_value"
  if TOKENFLEET_VERSION="$TEST_VERSION" \
      TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
      TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
      TOKENFLEET_COMMUNITY_SERVER_URL="$invalid_community_url" \
      TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
      TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
      "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
    fail "desktop build accepted unsafe community origin: $invalid_community_url"
  fi
done <"$ROOT_DIR/script/fixtures/community-origin-cases.tsv"
assert_equal "$INFO_BEFORE" "$(shasum -a 256 "$INFO_PLIST")" "unsafe community origin changed the existing bundle"

# A normal/ad-hoc build must never embed a sync origin without the stable
# external-signing stage marker.
if TOKENFLEET_VERSION="$TEST_VERSION" \
    TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_CREDENTIAL_BACKEND="disabled" \
    TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "ad-hoc build embedded a community origin"
fi
assert_equal "$INFO_BEFORE" "$(shasum -a 256 "$INFO_PLIST")" "rejected ad-hoc sync build changed the existing bundle"

# Public release must refuse a missing update endpoint before touching artifacts.
if CODE_SIGN_IDENTITY="preflight-placeholder" \
    TOKENFLEET_NOTARY_PROFILE="preflight-placeholder" \
    TOKENFLEET_UPDATE_API_URL="" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    "$RELEASE_SCRIPT" >/dev/null 2>&1; then
  fail "release packaging accepted a missing TOKENFLEET_UPDATE_API_URL"
fi

# Public release must also refuse a missing fixed community origin before
# signing, notarization, or artifact staging.
if CODE_SIGN_IDENTITY="preflight-placeholder" \
    TOKENFLEET_NOTARY_PROFILE="preflight-placeholder" \
    TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
    TOKENFLEET_COMMUNITY_SERVER_URL="" \
    "$RELEASE_SCRIPT" >/dev/null 2>&1; then
  fail "release packaging accepted a missing TOKENFLEET_COMMUNITY_SERVER_URL"
fi

# API-key notarization is all-or-nothing and must reject an incomplete triple
# before building or touching release artifacts.
if CODE_SIGN_IDENTITY="preflight-placeholder" \
    TOKENFLEET_NOTARY_KEY_ID="ABC123DEFG" \
    TOKENFLEET_NOTARY_ISSUER="00000000-0000-0000-0000-000000000000" \
    TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
    "$RELEASE_SCRIPT" >/dev/null 2>&1; then
  fail "release packaging accepted an incomplete App Store Connect API-key triple"
fi

# An existing version must fail closed without deleting that file or older rollback packages.
RELEASE_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-release-preflight.XXXXXX")"
touch "$RELEASE_FIXTURE/TokenFleet-previous.zip"
touch "$RELEASE_FIXTURE/TokenFleet-9.9.9.zip"
if CODE_SIGN_IDENTITY="preflight-placeholder" \
    TOKENFLEET_NOTARY_PROFILE="preflight-placeholder" \
    TOKENFLEET_RELEASE_DIR="$RELEASE_FIXTURE" \
    TOKENFLEET_VERSION="9.9.9" \
    TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
    "$RELEASE_SCRIPT" >/dev/null 2>&1; then
  fail "release packaging overwrote an existing version"
fi
[[ -f "$RELEASE_FIXTURE/TokenFleet-previous.zip" ]] || fail "release packaging deleted a rollback artifact"
[[ -f "$RELEASE_FIXTURE/TokenFleet-9.9.9.zip" ]] || fail "release packaging deleted the conflicting artifact"

# A malicious version must be rejected before it can escape RELEASE_DIR.
VERSION_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-version-preflight.XXXXXX")"
printf 'keep\n' >"$VERSION_FIXTURE/sentinel"
if CODE_SIGN_IDENTITY="preflight-placeholder" \
    TOKENFLEET_NOTARY_PROFILE="preflight-placeholder" \
    TOKENFLEET_RELEASE_DIR="$VERSION_FIXTURE/release" \
    TOKENFLEET_VERSION="../sentinel" \
    TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
    "$RELEASE_SCRIPT" >/dev/null 2>&1; then
  fail "release packaging accepted a path-like version"
fi
assert_equal "keep" "$(tr -d '\n' <"$VERSION_FIXTURE/sentinel")" "malicious version touched an external sentinel"
[[ ! -e "$VERSION_FIXTURE/release" ]] || fail "malicious version created the release directory"

# A packaging/signing failure must leave no public-looking partial artifacts.
ATOMIC_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-atomic-preflight.XXXXXX")"
touch "$ATOMIC_FIXTURE/TokenFleet-previous.zip"
if CODE_SIGN_IDENTITY="-" \
    TOKENFLEET_NOTARY_PROFILE="preflight-placeholder" \
    TOKENFLEET_RELEASE_DIR="$ATOMIC_FIXTURE" \
    TOKENFLEET_VERSION="9.9.8" \
    TOKENFLEET_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TOKENFLEET_UPDATE_API_URL="$TEST_UPDATE_URL" \
    TOKENFLEET_COMMUNITY_SERVER_URL="$TEST_COMMUNITY_URL" \
    TOKENFLEET_TEAM_ID="$TEST_TEAM_ID" \
    "$RELEASE_SCRIPT" >/dev/null 2>&1; then
  fail "release packaging unexpectedly succeeded with a missing signing identity"
fi
[[ -f "$ATOMIC_FIXTURE/TokenFleet-previous.zip" ]] || fail "failed packaging deleted the rollback artifact"
[[ "$(find "$ATOMIC_FIXTURE" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == "1" ]] \
  || fail "failed packaging left staged or public-looking partial artifacts"

assert_equal "$DIST_FINGERPRINT_BEFORE" "$(bundle_fingerprint "$DIST_APP_BUNDLE")" \
  "identity/package preflight changed the existing dist bundle"

COMPLETED=true
echo "PASS: TokenFleet identity, fixed origin, isolated builds, plist binding, atomic staging, and release preservation"
