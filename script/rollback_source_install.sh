#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=script/lib/tokenfleet_source_signing.sh
source "$ROOT_DIR/script/lib/tokenfleet_source_signing.sh"

LAUNCH=true
ALLOW_DISABLE_SYNC=false
TEST_MODE="${TOKENFLEET_SOURCE_TEST_MODE:-0}"
TEST_STABLE_FIXTURE="${TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE:-0}"
TEST_STABLE_SHA1="${TOKENFLEET_SOURCE_TEST_STABLE_SHA1:-}"

usage() {
  cat <<'USAGE'
Usage: ./script/rollback_source_install.sh [--no-launch] [--allow-disable-community-sync]

Restores the newest verified source-install backup without deleting it. The
currently installed App is first retained as another rollback copy.

Options:
  --allow-disable-community-sync
                                Allow restoring a local-only backup over an
                                installed community-sync build.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch)
      LAUNCH=false
      shift
      ;;
    --allow-disable-community-sync)
      ALLOW_DISABLE_SYNC=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      tokenfleet_source_error "unknown rollback argument: $1"
      exit 2
      ;;
  esac
done

if [[ "$TEST_MODE" == "1" ]]; then
  INSTALL_ROOT="${TOKENFLEET_SOURCE_INSTALL_ROOT:-}"
  STATE_ROOT="${TOKENFLEET_SOURCE_STATE_ROOT:-}"
  RESOLVED_INSTALL_ROOT="$(cd "$INSTALL_ROOT" 2>/dev/null && pwd -P)" || RESOLVED_INSTALL_ROOT=""
  RESOLVED_STATE_ROOT="$(cd "$STATE_ROOT" 2>/dev/null && pwd -P)" || RESOLVED_STATE_ROOT=""
  [[ "$RESOLVED_INSTALL_ROOT" == /private/tmp/* \
      && "$RESOLVED_STATE_ROOT" == /private/tmp/* \
      && -d "$INSTALL_ROOT" \
      && -d "$STATE_ROOT" \
      && ! -L "$INSTALL_ROOT" \
      && ! -L "$STATE_ROOT" ]] || {
    tokenfleet_source_error "rollback test roots must be isolated under /private/tmp"
    exit 2
  }
  INSTALL_ROOT="$RESOLVED_INSTALL_ROOT"
  STATE_ROOT="$RESOLVED_STATE_ROOT"
  LAUNCH=false
else
  [[ "$TEST_MODE" == "0" \
      && -z "${TOKENFLEET_SOURCE_INSTALL_ROOT:-}" \
      && -z "${TOKENFLEET_SOURCE_STATE_ROOT:-}" \
      && -z "${TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE:-}" \
      && -z "${TOKENFLEET_SOURCE_TEST_STABLE_SHA1:-}" ]] || {
    tokenfleet_source_error "rollback path overrides are test-only"
    exit 2
  }
  INSTALL_ROOT="$HOME/Applications"
  STATE_ROOT="$HOME/Library/Application Support/TokenFleet/SourceInstall"
fi

if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
  [[ "$TEST_MODE" == "1" \
      && ${#TEST_STABLE_SHA1} -eq 40 \
      && "$TEST_STABLE_SHA1" =~ ^[0-9A-F]+$ ]] || {
    tokenfleet_source_error "synthetic verification is restricted to an isolated test with an explicit fixture fingerprint"
    exit 2
  }
  # shellcheck source=script/fixtures/tokenfleet_source_test_stable.sh
  source "$ROOT_DIR/script/fixtures/tokenfleet_source_test_stable.sh"
elif [[ "$TEST_STABLE_FIXTURE" == "0" ]]; then
  [[ -z "$TEST_STABLE_SHA1" ]] || {
    tokenfleet_source_error "synthetic verification options require the isolated stable fixture"
    exit 2
  }
else
  tokenfleet_source_error "TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE must be 0 or 1"
  exit 2
fi

tokenfleet_rollback_app_certificate_sha1() {
  if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
    tokenfleet_source_test_app_certificate_sha1 "$1"
  else
    tokenfleet_source_app_certificate_sha1 "$1"
  fi
}

tokenfleet_rollback_verify_stable_app() {
  if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
    [[ "$3" == "$TEST_STABLE_SHA1" ]] || return 1
    tokenfleet_source_test_verify_stable_app "$@"
  else
    tokenfleet_source_verify_stable_app "$@"
  fi
}

TARGET_APP="$INSTALL_ROOT/TokenFleet.app"
BACKUP_ROOT="$STATE_ROOT/backups"
[[ -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" \
    && -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]] || {
  tokenfleet_source_error "no safe source-install backup directory exists"
  exit 2
}

if [[ "$TEST_MODE" != "1" ]] && /usr/bin/pgrep -x TokenFleet >/dev/null 2>&1; then
  tokenfleet_source_error "quit TokenFleet before rolling back"
  exit 2
fi

LATEST_BACKUP="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name 'TokenFleet-*.app' -print | /usr/bin/sort | /usr/bin/tail -n 1)"
[[ -n "$LATEST_BACKUP" && -d "$LATEST_BACKUP" && ! -L "$LATEST_BACKUP" ]] || {
  tokenfleet_source_error "no rollback App is available"
  exit 2
}

RECORDED_FINGERPRINT=""
FINGERPRINT_FILE="$STATE_ROOT/signing-identity.sha1"
ORIGIN_FILE="$STATE_ROOT/community-origin"
if [[ -f "$FINGERPRINT_FILE" && ! -L "$FINGERPRINT_FILE" ]]; then
  RECORDED_FINGERPRINT="$(/usr/bin/tr -d '[:space:]' <"$FINGERPRINT_FILE")"
  [[ ${#RECORDED_FINGERPRINT} -eq 40 && "$RECORDED_FINGERPRINT" =~ ^[0-9A-F]+$ ]] || {
    tokenfleet_source_error "the recorded signing identity fingerprint is malformed"
    exit 2
  }
fi

PERSISTED_BACKEND=""
BACKEND_FILE="$STATE_ROOT/current-backend"
if [[ -e "$BACKEND_FILE" || -L "$BACKEND_FILE" ]]; then
  [[ -f "$BACKEND_FILE" && ! -L "$BACKEND_FILE" ]] || {
    tokenfleet_source_error "the recorded backend state is not a regular file"
    exit 2
  }
  PERSISTED_BACKEND="$(/bin/cat "$BACKEND_FILE")" || {
    tokenfleet_source_error "the recorded backend state is unreadable"
    exit 2
  }
  [[ "$PERSISTED_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" \
      || "$PERSISTED_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_DISABLED" ]] || {
    tokenfleet_source_error "the recorded backend state is malformed"
    exit 2
  }
fi

BACKEND="$(tokenfleet_source_plist_value "$LATEST_BACKUP" TokenFleetCredentialBackend || true)"
if [[ "$BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]]; then
  [[ -n "$RECORDED_FINGERPRINT" ]] || {
    tokenfleet_source_error "no recorded source signing identity exists for this backup"
    exit 1
  }
  [[ -f "$ORIGIN_FILE" && ! -L "$ORIGIN_FILE" ]] || {
    tokenfleet_source_error "no recorded community origin exists for this backup"
    exit 1
  }
  EXPECTED_ORIGIN="$(/bin/cat "$ORIGIN_FILE")" || {
    tokenfleet_source_error "the recorded community origin is unreadable"
    exit 1
  }
  /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$EXPECTED_ORIGIN" >/dev/null || {
    tokenfleet_source_error "the recorded community origin is invalid"
    exit 1
  }

  ORIGIN="$(tokenfleet_source_plist_value "$LATEST_BACKUP" TokenFleetCommunityServerURL || true)"
  /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$ORIGIN" >/dev/null || {
    tokenfleet_source_error "backup contains an invalid community origin"
    exit 1
  }
  FINGERPRINT="$(tokenfleet_rollback_app_certificate_sha1 "$LATEST_BACKUP")" || {
    tokenfleet_source_error "backup has no signing certificate"
    exit 1
  }
  [[ "$FINGERPRINT" == "$RECORDED_FINGERPRINT" ]] || {
    tokenfleet_source_error "backup signing identity does not match the recorded source identity"
    exit 1
  }
  [[ "$ORIGIN" == "$EXPECTED_ORIGIN" ]] || {
    tokenfleet_source_error "backup community origin does not match the recorded origin"
    exit 1
  }
  tokenfleet_rollback_verify_stable_app \
    "$LATEST_BACKUP" "$EXPECTED_ORIGIN" "$RECORDED_FINGERPRINT" || {
    tokenfleet_source_error "backup stable signature is invalid"
    exit 1
  }

  # A valid installed community App is useful corroboration, but it is not the
  # recovery authority: a missing or damaged App is exactly why rollback is
  # needed. Only a current App that still verifies against the persisted pin
  # can veto a conflicting persisted origin.
  if [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]]; then
    CURRENT_BACKEND="$(tokenfleet_source_plist_value "$TARGET_APP" TokenFleetCredentialBackend || true)"
    if [[ "$CURRENT_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]]; then
      CURRENT_ORIGIN="$(tokenfleet_source_plist_value "$TARGET_APP" TokenFleetCommunityServerURL || true)"
      if /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$CURRENT_ORIGIN" >/dev/null 2>&1 \
          && tokenfleet_rollback_verify_stable_app \
            "$TARGET_APP" "$CURRENT_ORIGIN" "$RECORDED_FINGERPRINT"; then
        [[ "$CURRENT_ORIGIN" == "$EXPECTED_ORIGIN" ]] || {
          tokenfleet_source_error "the verified current App conflicts with the recorded community origin"
          exit 1
        }
      fi
    fi
  fi
elif [[ "$BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_DISABLED" ]]; then
  CURRENT_SIGNALS_COMMUNITY=false
  if [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" \
      && "$(tokenfleet_source_plist_value "$TARGET_APP" TokenFleetCredentialBackend || true)" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]]; then
    CURRENT_SIGNALS_COMMUNITY=true
  fi
  if [[ "$PERSISTED_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]]; then
    CURRENT_SIGNALS_COMMUNITY=true
  fi
  if [[ "$CURRENT_SIGNALS_COMMUNITY" == true && "$ALLOW_DISABLE_SYNC" != true ]]; then
    tokenfleet_source_error "the installed App has community sync enabled"
    tokenfleet_source_error "add --allow-disable-community-sync to make the downgrade explicit"
    exit 2
  fi
  tokenfleet_source_verify_adhoc_app "$LATEST_BACKUP" || {
    tokenfleet_source_error "backup ad-hoc signature is invalid"
    exit 1
  }
  FINGERPRINT=""
else
  tokenfleet_source_error "backup uses an unsupported credential backend"
  exit 1
fi

STAGE_ROOT="$(mktemp -d "$INSTALL_ROOT/.tokenfleet-rollback.XXXXXX")"
CURRENT_BACKUP=""
PUBLISHED=false
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 && "$PUBLISHED" == true && -e "$TARGET_APP" ]]; then
    rm -rf -- "$TARGET_APP"
  fi
  if [[ "$status" -ne 0 && -n "$CURRENT_BACKUP" \
      && -e "$CURRENT_BACKUP" && ! -e "$TARGET_APP" ]]; then
    mv "$CURRENT_BACKUP" "$TARGET_APP"
  fi
  if [[ -d "$STAGE_ROOT" ]]; then
    rm -rf -- "$STAGE_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT

STAGED_APP="$STAGE_ROOT/TokenFleet.app"
/usr/bin/ditto "$LATEST_BACKUP" "$STAGED_APP"

if [[ "$TEST_MODE" == "1" && "${TOKENFLEET_SOURCE_TEST_CORRUPT_STAGED_APP:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy \
    -c 'Set :CFBundleIdentifier invalid.test-only.bundle' \
    "$STAGED_APP/Contents/Info.plist"
fi

# Re-verify the copied bytes immediately before publication. The source backup
# may be replaced between the initial check and ditto; only the staged copy is
# authoritative for what will actually be installed.
if [[ "$BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]]; then
  tokenfleet_rollback_verify_stable_app \
    "$STAGED_APP" "$EXPECTED_ORIGIN" "$RECORDED_FINGERPRINT" || {
      tokenfleet_source_error "staged community backup failed final verification"
      exit 1
    }
else
  tokenfleet_source_verify_adhoc_app "$STAGED_APP" || {
    tokenfleet_source_error "staged local-only backup failed final verification"
    exit 1
  }
fi

if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
  [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" \
      && "$(tokenfleet_source_plist_value "$TARGET_APP" CFBundleIdentifier)" == "$TOKENFLEET_SOURCE_BUNDLE_ID" ]] || {
    tokenfleet_source_error "refusing to replace an unexpected target"
    exit 2
  }
  TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  CURRENT_VERSION="$(tokenfleet_source_plist_value "$TARGET_APP" TokenFleetReleaseVersion || true)"
  SAFE_VERSION="$(printf '%s' "$CURRENT_VERSION" | /usr/bin/tr -cd 'A-Za-z0-9._+-')"
  [[ -n "$SAFE_VERSION" ]] || SAFE_VERSION="unknown"
  CURRENT_BACKUP="$BACKUP_ROOT/TokenFleet-$TIMESTAMP-rollback-from-$SAFE_VERSION.app"
  [[ ! -e "$CURRENT_BACKUP" ]] || {
    tokenfleet_source_error "rollback backup collision"
    exit 1
  }
  mv "$TARGET_APP" "$CURRENT_BACKUP"
fi

mv "$STAGED_APP" "$TARGET_APP"
PUBLISHED=true

STATE_TMP="$(mktemp "$STATE_ROOT/.current-backend.XXXXXX")"
printf '%s\n' "$BACKEND" >"$STATE_TMP"
chmod 600 "$STATE_TMP"
mv "$STATE_TMP" "$STATE_ROOT/current-backend"

PUBLISHED=false
CURRENT_BACKUP=""
if [[ "$LAUNCH" == true ]]; then
  /usr/bin/open "$TARGET_APP"
fi

echo "Restored verified backup: $LATEST_BACKUP"
echo "Current App: $TARGET_APP"
