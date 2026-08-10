#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=script/lib/tokenfleet_source_signing.sh
source "$ROOT_DIR/script/lib/tokenfleet_source_signing.sh"
# shellcheck source=script/fixtures/tokenfleet_source_test_stable.sh
source "$ROOT_DIR/script/fixtures/tokenfleet_source_test_stable.sh"

fail() {
  echo "TokenFleet source distribution verification failed: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d /private/tmp/tokenfleet-source-distribution-test.XXXXXX)"
INSTALL_ROOT="$(mktemp -d /private/tmp/.tokenfleet-source-install.XXXXXX)"
STATE_ROOT="$(mktemp -d /private/tmp/.tokenfleet-source-state.XXXXXX)"
COMMUNITY_INSTALL_ROOT="$(mktemp -d /private/tmp/.tokenfleet-community-install.XXXXXX)"
COMMUNITY_STATE_ROOT="$(mktemp -d /private/tmp/.tokenfleet-community-state.XXXXXX)"
ESCAPE_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-test-root-escape.XXXXXX")"
ESCAPE_TARGET="$(cd "$ESCAPE_TARGET" && pwd -P)"
KEYCHAIN="$TEST_ROOT/test.keychain"
CREATE_KEYCHAIN="$TEST_ROOT/create-isolated-keychain"
DIST_APP="$ROOT_DIR/TokenStepSwift/dist/TokenFleet.app"
COMMUNITY_ORIGIN="https://community.example.invalid"
COMPLETED=false
ISOLATED_IDENTITY_VERIFIED=false
REQUIRE_ISOLATED_KEYCHAIN="${TOKENFLEET_REQUIRE_ISOLATED_KEYCHAIN:-0}"
[[ "$REQUIRE_ISOLATED_KEYCHAIN" == "0" || "$REQUIRE_ISOLATED_KEYCHAIN" == "1" ]] \
  || fail "TOKENFLEET_REQUIRE_ISOLATED_KEYCHAIN must be 0 or 1"

fingerprint_tree() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
if not root.exists():
    print("MISSING")
    raise SystemExit
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    digest.update(str(path.relative_to(root)).encode() + b"\0")
    if path.is_file():
        digest.update(path.read_bytes())
print(digest.hexdigest())
PY
}

DIST_BEFORE="$(fingerprint_tree "$DIST_APP")"

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  rm -rf -- \
    "$TEST_ROOT" \
    "$INSTALL_ROOT" \
    "$STATE_ROOT" \
    "$COMMUNITY_INSTALL_ROOT" \
    "$COMMUNITY_STATE_ROOT" \
    "$ESCAPE_TARGET"
  [[ "$COMPLETED" == true || "$status" -ne 0 ]] || status=1
  exit "$status"
}
trap cleanup EXIT

bash -n \
  "$ROOT_DIR/script/build_swiftui_and_run.sh" \
  "$ROOT_DIR/script/install_from_source.sh" \
  "$ROOT_DIR/script/rollback_source_install.sh" \
  "$ROOT_DIR/script/uninstall_source_install.sh" \
  "$ROOT_DIR/script/lib/tokenfleet_source_signing.sh" \
  "$ROOT_DIR/script/fixtures/tokenfleet_source_test_stable.sh" \
  "$ROOT_DIR/script/test_verify_scripts_fail_closed.sh"

bash "$ROOT_DIR/script/test_verify_scripts_fail_closed.sh"

/usr/bin/xcrun clang \
  -framework CoreFoundation \
  -framework Security \
  "$ROOT_DIR/script/fixtures/create_isolated_file_keychain.c" \
  -o "$CREATE_KEYCHAIN"
KEYCHAIN_CREATE_LOG="$TEST_ROOT/create-keychain.log"
if "$CREATE_KEYCHAIN" "$KEYCHAIN" >"$KEYCHAIN_CREATE_LOG" 2>&1; then
  /usr/bin/security unlock-keychain -p tokenfleet-isolated-test-only "$KEYCHAIN" \
    || fail "isolated keychain was created but could not be unlocked"
  [[ -f "$KEYCHAIN" && ! -L "$KEYCHAIN" ]] || fail "isolated keychain was not created"
  [[ "$(/usr/bin/stat -f '%Lp' "$KEYCHAIN")" == "600" ]] || fail "isolated keychain is not mode 0600"

  IDENTITY_ONE="$(tokenfleet_source_ensure_identity "$KEYCHAIN")" \
    || fail "could not create an identity in the isolated keychain"
  IDENTITY_TWO="$(tokenfleet_source_ensure_identity "$KEYCHAIN")" \
    || fail "could not reuse the isolated identity"
  [[ "$IDENTITY_ONE" == "$IDENTITY_TWO" ]] || fail "identity changed between source upgrades"
  [[ ${#IDENTITY_ONE} -eq 40 && "$IDENTITY_ONE" =~ ^[0-9A-F]+$ ]] \
    || fail "identity fingerprint is malformed"
  if /usr/bin/security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "" \
      -o "$TEST_ROOT/exported-identity.p12" >/dev/null 2>&1; then
    fail "the local private key was exportable"
  fi
  [[ ! -s "$TEST_ROOT/exported-identity.p12" ]] || fail "identity export left private material"
  ISOLATED_IDENTITY_VERIFIED=true
else
  if [[ "$REQUIRE_ISOLATED_KEYCHAIN" == "1" ]]; then
    /bin/cat "$KEYCHAIN_CREATE_LOG" >&2
    fail "this environment requires the isolated legacy Keychain gate"
  fi
  # Some modern macOS test environments reject creation of a standalone
  # legacy file Keychain with errSecParam. Continue only with the synthetic,
  # non-Keychain state-machine fixture; production scripts still reject that
  # fixture, and a real login-Keychain install remains a separate pilot gate.
  echo "SKIP: isolated legacy file-Keychain creation is unavailable; running non-Keychain distribution state-machine gates" >&2
  IDENTITY_ONE="0123456789ABCDEF0123456789ABCDEF01234567"
fi

if TOKENFLEET_COMMUNITY_SERVER_URL="https://community.example.invalid" \
    TOKENFLEET_CREDENTIAL_BACKEND="disabled" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "disabled/ad-hoc build accepted a community origin"
fi
if TOKENFLEET_COMMUNITY_SERVER_URL="https://community.example.invalid" \
    TOKENFLEET_CREDENTIAL_BACKEND="file-login-v1" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch >/dev/null 2>&1; then
  fail "stable backend accepted a build without the external signing stage"
fi

# Synthetic signing is a state-machine fixture, never a production escape
# hatch. Both public scripts must reject it before touching a real install.
if TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
      "$ROOT_DIR/script/install_from_source.sh" --local-only --no-launch >/dev/null 2>&1; then
  fail "production installer accepted the synthetic stable-signing hook"
fi
if TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
      "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null 2>&1; then
  fail "production rollback accepted the synthetic stable-verification hook"
fi

[[ "$ESCAPE_TARGET" == /private/* && "$ESCAPE_TARGET" != /private/tmp/* ]] \
  || fail "test-root escape fixture did not resolve outside /private/tmp"
ESCAPE_PATH="/private/tmp/../${ESCAPE_TARGET#/private/}"
if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$ESCAPE_PATH" \
    TOKENFLEET_SOURCE_STATE_ROOT="$STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
      "$ROOT_DIR/script/install_from_source.sh" --local-only --no-launch >/dev/null 2>&1; then
  fail "installer accepted a test root that escapes /private/tmp after resolution"
fi
if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$ESCAPE_PATH" \
    TOKENFLEET_SOURCE_STATE_ROOT="$STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
      "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null 2>&1; then
  fail "rollback accepted a test root that escapes /private/tmp after resolution"
fi

LEAK_SENTINEL="enrollment-secret-must-not-appear"
UNKNOWN_OUTPUT="$TEST_ROOT/unknown-output.txt"
if "$ROOT_DIR/script/install_from_source.sh" "$LEAK_SENTINEL" >"$UNKNOWN_OUTPUT" 2>&1; then
  fail "installer accepted an unknown enrollment-like argument"
fi
if /usr/bin/grep -Fq "$LEAK_SENTINEL" "$UNKNOWN_OUTPUT"; then
  fail "installer echoed an unknown enrollment-like value"
fi

TOKENFLEET_SOURCE_TEST_MODE=1 \
TOKENFLEET_SOURCE_INSTALL_ROOT="$INSTALL_ROOT" \
TOKENFLEET_SOURCE_STATE_ROOT="$STATE_ROOT" \
TOKENFLEET_VERSION="0.1.0-source.1" \
  "$ROOT_DIR/script/install_from_source.sh" --local-only --no-launch >/dev/null

INSTALLED_APP="$INSTALL_ROOT/TokenFleet.app"
tokenfleet_source_verify_adhoc_app "$INSTALLED_APP" \
  || fail "local-only installed App did not stay ad-hoc/disabled"

ADHOC_FIXTURE_APP="$TEST_ROOT/TokenFleet-disabled-fixture.app"
/usr/bin/ditto "$INSTALLED_APP" "$ADHOC_FIXTURE_APP"
tokenfleet_source_verify_adhoc_app "$ADHOC_FIXTURE_APP" \
  || fail "could not preserve a verified local-only rollback fixture"

MANUAL_BACKUP="$STATE_ROOT/backups/TokenFleet-20000101T000000Z-fixture.app"
/usr/bin/ditto "$INSTALLED_APP" "$MANUAL_BACKUP"
TOKENFLEET_SOURCE_TEST_MODE=1 \
TOKENFLEET_SOURCE_INSTALL_ROOT="$INSTALL_ROOT" \
TOKENFLEET_SOURCE_STATE_ROOT="$STATE_ROOT" \
  "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null
tokenfleet_source_verify_adhoc_app "$INSTALLED_APP" \
  || fail "rollback did not restore a verified local-only App"

TOKENFLEET_SOURCE_TEST_MODE=1 \
TOKENFLEET_SOURCE_INSTALL_ROOT="$INSTALL_ROOT" \
TOKENFLEET_SOURCE_STATE_ROOT="$STATE_ROOT" \
  "$ROOT_DIR/script/uninstall_source_install.sh" >/dev/null
[[ ! -e "$INSTALLED_APP" ]] || fail "uninstall left the App installed"
[[ -n "$(find "$STATE_ROOT/Trash" -type d -name 'TokenFleet-*.app' -print -quit)" ]] \
  || fail "uninstall did not preserve a recoverable Trash copy"

# Exercise community install/rollback state transitions with an ad-hoc-signed,
# synthetic stable fixture. This proves state/origin/pin and publication logic,
# not real certificate continuity; the latter remains a clean-Mac manual gate.
TOKENFLEET_SOURCE_TEST_MODE=1 \
TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
TOKENFLEET_VERSION="0.1.0-source.2" \
  "$ROOT_DIR/script/install_from_source.sh" \
    --enable-community-sync \
    --community-server "$COMMUNITY_ORIGIN" \
    --yes \
    --no-launch >/dev/null

COMMUNITY_APP="$COMMUNITY_INSTALL_ROOT/TokenFleet.app"
PIN_FILE="$COMMUNITY_STATE_ROOT/signing-identity.sha1"
ORIGIN_FILE="$COMMUNITY_STATE_ROOT/community-origin"
PERSISTED_PIN="$(/usr/bin/tr -d '[:space:]' <"$PIN_FILE")"
PERSISTED_ORIGIN="$(/bin/cat "$ORIGIN_FILE")"
[[ "$PERSISTED_PIN" == "$IDENTITY_ONE" ]] \
  || fail "community install did not persist the isolated signer pin"
[[ "$PERSISTED_ORIGIN" == "$COMMUNITY_ORIGIN" ]] \
  || fail "community install did not persist the canonical origin"
[[ "$(/usr/bin/stat -f '%Lp' "$PIN_FILE")" == "600" \
    && "$(/usr/bin/stat -f '%Lp' "$ORIGIN_FILE")" == "600" ]] \
  || fail "community state files are not mode 0600"
tokenfleet_source_test_verify_stable_app \
  "$COMMUNITY_APP" "$COMMUNITY_ORIGIN" "$PERSISTED_PIN" \
  || fail "community source install did not produce a verified synthetic stable fixture"

COMMUNITY_BASELINE="$(fingerprint_tree "$COMMUNITY_APP")"
ALTERNATE_ORIGIN="https://alternate-community.example.invalid"
if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
    TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
    TOKENFLEET_VERSION="0.1.0-source.3" \
      "$ROOT_DIR/script/install_from_source.sh" \
        --enable-community-sync \
        --community-server "$ALTERNATE_ORIGIN" \
        --yes \
        --no-launch >/dev/null 2>&1; then
  fail "community install silently changed the recorded origin"
fi
[[ "$(fingerprint_tree "$COMMUNITY_APP")" == "$COMMUNITY_BASELINE" ]] \
  || fail "rejected origin change modified the prior community App"
[[ "$(/bin/cat "$ORIGIN_FILE")" == "$COMMUNITY_ORIGIN" \
    && "$(/usr/bin/tr -d '[:space:]' <"$PIN_FILE")" == "$PERSISTED_PIN" \
    && "$(/bin/cat "$COMMUNITY_STATE_ROOT/current-backend")" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]] \
  || fail "rejected origin change modified persisted community state"

if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
    TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
    TOKENFLEET_SOURCE_TEST_FAIL_STATE_COMMIT=after-community-origin \
    TOKENFLEET_VERSION="0.1.0-source.3" \
      "$ROOT_DIR/script/install_from_source.sh" \
        --enable-community-sync \
        --community-server "$COMMUNITY_ORIGIN" \
        --yes \
        --no-launch >/dev/null 2>&1; then
  fail "injected community state-publication failure unexpectedly succeeded"
fi
[[ "$(fingerprint_tree "$COMMUNITY_APP")" == "$COMMUNITY_BASELINE" ]] \
  || fail "state-publication failure did not restore the prior community App"
[[ "$(/bin/cat "$ORIGIN_FILE")" == "$COMMUNITY_ORIGIN" \
    && "$(/usr/bin/tr -d '[:space:]' <"$PIN_FILE")" == "$PERSISTED_PIN" \
    && "$(/bin/cat "$COMMUNITY_STATE_ROOT/current-backend")" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]] \
  || fail "state-publication failure left community state partially updated"

COMMUNITY_BACKUP="$COMMUNITY_STATE_ROOT/backups/TokenFleet-20010101T000000Z-community.app"
/usr/bin/ditto "$COMMUNITY_APP" "$COMMUNITY_BACKUP"
mv "$COMMUNITY_APP" "$TEST_ROOT/removed-community-current.app"
[[ ! -e "$COMMUNITY_APP" ]] || fail "could not simulate a missing current App"

if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
    TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
      "$ROOT_DIR/script/install_from_source.sh" \
        --local-only \
        --no-launch >/dev/null 2>&1; then
  fail "missing App plus persisted community state silently installed local-only"
fi
[[ ! -e "$COMMUNITY_APP" \
    && "$(/bin/cat "$COMMUNITY_STATE_ROOT/current-backend")" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" \
    && "$(/bin/cat "$ORIGIN_FILE")" == "$COMMUNITY_ORIGIN" ]] \
  || fail "rejected missing-App downgrade changed App or persisted community state"

TOKENFLEET_SOURCE_TEST_MODE=1 \
TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
  "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null
tokenfleet_source_test_verify_stable_app \
  "$COMMUNITY_APP" "$COMMUNITY_ORIGIN" "$PERSISTED_PIN" \
  || fail "disaster rollback could not restore a missing community App"
[[ "$(/bin/cat "$ORIGIN_FILE")" == "$COMMUNITY_ORIGIN" ]] \
  || fail "disaster rollback changed the persisted community origin"

COMMUNITY_BEFORE_CORRUPT_TEST="$(fingerprint_tree "$COMMUNITY_APP")"
if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
    TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
    TOKENFLEET_SOURCE_TEST_CORRUPT_STAGED_APP=1 \
      "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null 2>&1; then
  fail "rollback published a community App corrupted after staging"
fi
[[ "$(fingerprint_tree "$COMMUNITY_APP")" == "$COMMUNITY_BEFORE_CORRUPT_TEST" ]] \
  || fail "failed staged verification changed the installed community App"

DISABLED_BACKUP="$COMMUNITY_STATE_ROOT/backups/TokenFleet-29990101T000000Z-disabled.app"
/usr/bin/ditto "$ADHOC_FIXTURE_APP" "$DISABLED_BACKUP"
COMMUNITY_BEFORE_DOWNGRADE_TEST="$(fingerprint_tree "$COMMUNITY_APP")"

mv "$COMMUNITY_APP" "$TEST_ROOT/r6-missing-community-current.app"
if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
    TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
      "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null 2>&1; then
  fail "persisted community backend did not prevent a silent downgrade with no current App"
fi
[[ ! -e "$COMMUNITY_APP" ]] \
  || fail "rejected missing-App downgrade unexpectedly published a backup"
mv "$TEST_ROOT/r6-missing-community-current.app" "$COMMUNITY_APP"

if TOKENFLEET_SOURCE_TEST_MODE=1 \
    TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
    TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
    TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
    TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
      "$ROOT_DIR/script/rollback_source_install.sh" --no-launch >/dev/null 2>&1; then
  fail "rollback silently disabled community sync"
fi
[[ "$(fingerprint_tree "$COMMUNITY_APP")" == "$COMMUNITY_BEFORE_DOWNGRADE_TEST" ]] \
  || fail "rejected community downgrade changed the installed App"
[[ "$(/bin/cat "$COMMUNITY_STATE_ROOT/current-backend")" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]] \
  || fail "rejected community downgrade changed persisted backend state"

TOKENFLEET_SOURCE_TEST_MODE=1 \
TOKENFLEET_SOURCE_INSTALL_ROOT="$COMMUNITY_INSTALL_ROOT" \
TOKENFLEET_SOURCE_STATE_ROOT="$COMMUNITY_STATE_ROOT" \
TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE=1 \
TOKENFLEET_SOURCE_TEST_STABLE_SHA1="$IDENTITY_ONE" \
  "$ROOT_DIR/script/rollback_source_install.sh" \
    --allow-disable-community-sync \
    --no-launch >/dev/null
tokenfleet_source_verify_adhoc_app "$COMMUNITY_APP" \
  || fail "explicit community downgrade did not restore the verified local-only backup"
[[ "$(/bin/cat "$COMMUNITY_STATE_ROOT/current-backend")" == "$TOKENFLEET_SOURCE_BACKEND_DISABLED" ]] \
  || fail "explicit community downgrade did not persist the disabled backend"
[[ "$(/bin/cat "$ORIGIN_FILE")" == "$COMMUNITY_ORIGIN" \
    && "$(/usr/bin/tr -d '[:space:]' <"$PIN_FILE")" == "$PERSISTED_PIN" ]] \
  || fail "rollback rewrote the persisted community origin or signer pin"

[[ "$(fingerprint_tree "$DIST_APP")" == "$DIST_BEFORE" ]] \
  || fail "isolated source verification changed TokenStepSwift/dist"

COMPLETED=true
if [[ "$ISOLATED_IDENTITY_VERIFIED" == true ]]; then
  echo "PASS: isolated identity reuse and non-export"
fi
echo "PASS: fail-closed verifiers, ad-hoc and community install, disaster/staged rollback, explicit downgrade, uninstall, and no dist mutation"
