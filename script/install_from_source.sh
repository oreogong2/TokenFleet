#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=script/lib/tokenfleet_source_signing.sh
source "$ROOT_DIR/script/lib/tokenfleet_source_signing.sh"

MODE="local-only"
COMMUNITY_SERVER_URL=""
ALLOW_DISABLE_SYNC=false
ASSUME_YES=false
LAUNCH=true
TEST_MODE="${TOKENFLEET_SOURCE_TEST_MODE:-0}"
TEST_STABLE_FIXTURE="${TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE:-0}"
TEST_STABLE_SHA1="${TOKENFLEET_SOURCE_TEST_STABLE_SHA1:-}"
TEST_FAIL_STATE_COMMIT="${TOKENFLEET_SOURCE_TEST_FAIL_STATE_COMMIT:-}"
VERSION="${TOKENFLEET_VERSION:-0.1.0-beta.11}"
BUILD_ROOT=""
INSTALL_STAGE_ROOT=""
STATE_TRANSACTION_ROOT=""
STATE_MUTATED=false
PUBLISHED=false
OLD_APP_BACKUP=""
TARGET_APP=""

usage() {
  cat <<'USAGE'
TokenFleet source installer (macOS 14+, Apple Silicon or Intel)

Local-only, ad-hoc signed (default; community sync is disabled):
  ./script/install_from_source.sh

Enable community sync with a stable per-Mac self-signed identity:
  ./script/install_from_source.sh \
    --enable-community-sync \
    --community-server https://tokenfleet.example.com

Options:
  --enable-community-sync       Opt in to the stable local signing identity.
  --community-server ORIGIN     Fixed canonical HTTPS community origin.
  --local-only                  Explicitly select the default ad-hoc mode.
  --allow-disable-community-sync
                                Allow replacing an existing sync build with a
                                local-only build; credentials are preserved.
  --no-launch                   Install without opening TokenFleet.
  --yes                         Skip the identity-creation confirmation.
  --help                        Show this help.

This installer never accepts or prints a one-time enrollment code. Paste that
code only inside TokenFleet after installation.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-community-sync)
      MODE="community"
      shift
      ;;
    --community-server)
      [[ $# -ge 2 ]] || {
        tokenfleet_source_error "--community-server requires one origin"
        exit 2
      }
      COMMUNITY_SERVER_URL="$2"
      shift 2
      ;;
    --local-only)
      MODE="local-only"
      shift
      ;;
    --allow-disable-community-sync)
      ALLOW_DISABLE_SYNC=true
      shift
      ;;
    --no-launch)
      LAUNCH=false
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      # Never echo an unknown value: a member might accidentally paste an
      # enrollment code into this terminal command.
      tokenfleet_source_error "unknown argument; use --help for the supported public options"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "community" ]]; then
  [[ -n "$COMMUNITY_SERVER_URL" ]] || {
    tokenfleet_source_error "community mode requires --community-server"
    exit 2
  }
  /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$COMMUNITY_SERVER_URL" \
    || {
      tokenfleet_source_error "community origin is not one canonical production HTTPS origin"
      exit 2
    }
else
  [[ -z "$COMMUNITY_SERVER_URL" ]] || {
    tokenfleet_source_error "--community-server also requires --enable-community-sync"
    exit 2
  }
fi

SOURCE_ARCHITECTURE="$(/usr/bin/uname -m)"
if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  tokenfleet_source_error "source installation requires macOS"
  exit 2
fi
case "$SOURCE_ARCHITECTURE" in
  arm64|x86_64) ;;
  *)
    tokenfleet_source_error "unsupported Mac architecture"
    exit 2
    ;;
esac

for command_path in \
  /usr/bin/codesign \
  /usr/bin/ditto \
  /usr/bin/openssl \
  /usr/bin/plutil \
  /usr/bin/python3 \
  /usr/bin/security \
  /usr/bin/swiftc \
  /usr/libexec/PlistBuddy; do
  [[ -x "$command_path" ]] || {
    tokenfleet_source_error "required system tool is missing: $command_path"
    exit 2
  }
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
    tokenfleet_source_error "test roots must be existing non-symlinked directories under /private/tmp"
    exit 2
  }
  INSTALL_ROOT="$RESOLVED_INSTALL_ROOT"
  STATE_ROOT="$RESOLVED_STATE_ROOT"
  LAUNCH=false
else
  [[ "$TEST_MODE" == "0" ]] || {
    tokenfleet_source_error "TOKENFLEET_SOURCE_TEST_MODE must be 0 or 1"
    exit 2
  }
  [[ -z "${TOKENFLEET_SOURCE_INSTALL_ROOT:-}" \
      && -z "${TOKENFLEET_SOURCE_STATE_ROOT:-}" \
      && -z "${TOKENFLEET_SOURCE_KEYCHAIN:-}" \
      && -z "${TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE:-}" \
      && -z "${TOKENFLEET_SOURCE_TEST_STABLE_SHA1:-}" \
      && -z "${TOKENFLEET_SOURCE_TEST_FAIL_STATE_COMMIT:-}" ]] || {
    tokenfleet_source_error "test path overrides are forbidden outside isolated test mode"
    exit 2
  }
  INSTALL_ROOT="$HOME/Applications"
  STATE_ROOT="$HOME/Library/Application Support/TokenFleet/SourceInstall"
fi

if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
  [[ "$TEST_MODE" == "1" \
      && ${#TEST_STABLE_SHA1} -eq 40 \
      && "$TEST_STABLE_SHA1" =~ ^[0-9A-F]+$ \
      && ( -z "$TEST_FAIL_STATE_COMMIT" \
        || "$TEST_FAIL_STATE_COMMIT" == "after-community-origin" ) ]] || {
    tokenfleet_source_error "synthetic signing is restricted to an isolated test with an explicit fixture fingerprint"
    exit 2
  }
  # shellcheck source=script/fixtures/tokenfleet_source_test_stable.sh
  source "$ROOT_DIR/script/fixtures/tokenfleet_source_test_stable.sh"
elif [[ "$TEST_STABLE_FIXTURE" == "0" ]]; then
  [[ -z "$TEST_STABLE_SHA1" && -z "$TEST_FAIL_STATE_COMMIT" ]] || {
    tokenfleet_source_error "synthetic signing options require the isolated stable fixture"
    exit 2
  }
else
  tokenfleet_source_error "TOKENFLEET_SOURCE_TEST_STABLE_FIXTURE must be 0 or 1"
  exit 2
fi

tokenfleet_install_app_certificate_sha1() {
  if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
    tokenfleet_source_test_app_certificate_sha1 "$1"
  else
    tokenfleet_source_app_certificate_sha1 "$1"
  fi
}

tokenfleet_install_verify_stable_app() {
  if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
    tokenfleet_source_test_verify_stable_app "$@"
  else
    tokenfleet_source_verify_stable_app "$@"
  fi
}

if [[ -e "$INSTALL_ROOT" && ( ! -d "$INSTALL_ROOT" || -L "$INSTALL_ROOT" ) ]]; then
  tokenfleet_source_error "install root must be a real directory: $INSTALL_ROOT"
  exit 2
fi
mkdir -p "$INSTALL_ROOT"
[[ -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || {
  tokenfleet_source_error "could not create a safe install root"
  exit 2
}

mkdir -p "$STATE_ROOT/backups"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/backups"
TARGET_APP="$INSTALL_ROOT/TokenFleet.app"
BACKEND_FILE="$STATE_ROOT/current-backend"
FINGERPRINT_FILE="$STATE_ROOT/signing-identity.sha1"
ORIGIN_FILE="$STATE_ROOT/community-origin"

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 && "$STATE_MUTATED" == true \
      && -n "$STATE_TRANSACTION_ROOT" && -d "$STATE_TRANSACTION_ROOT/previous" ]]; then
    for state_name in current-backend signing-identity.sha1 community-origin; do
      state_path="$STATE_ROOT/$state_name"
      if [[ -e "$state_path" || -L "$state_path" ]]; then
        if [[ -f "$state_path" && ! -L "$state_path" ]]; then
          rm -f -- "$state_path"
        else
          tokenfleet_source_error "could not restore an unexpected state target: $state_path"
          continue
        fi
      fi
      if [[ -f "$STATE_TRANSACTION_ROOT/previous/$state_name" ]]; then
        mv "$STATE_TRANSACTION_ROOT/previous/$state_name" "$state_path"
      fi
    done
  fi
  if [[ "$status" -ne 0 && "$PUBLISHED" == true && -e "$TARGET_APP" ]]; then
    rm -rf -- "$TARGET_APP"
  fi
  if [[ "$status" -ne 0 && -n "$OLD_APP_BACKUP" \
      && -e "$OLD_APP_BACKUP" && ! -e "$TARGET_APP" ]]; then
    mv "$OLD_APP_BACKUP" "$TARGET_APP"
  fi
  if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
    rm -rf -- "$BUILD_ROOT"
  fi
  if [[ -n "$INSTALL_STAGE_ROOT" && -d "$INSTALL_STAGE_ROOT" ]]; then
    rm -rf -- "$INSTALL_STAGE_ROOT"
  fi
  if [[ -n "$STATE_TRANSACTION_ROOT" && -d "$STATE_TRANSACTION_ROOT" ]]; then
    rm -rf -- "$STATE_TRANSACTION_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT

RECORDED_BACKEND=""
if [[ -e "$BACKEND_FILE" || -L "$BACKEND_FILE" ]]; then
  [[ -f "$BACKEND_FILE" && ! -L "$BACKEND_FILE" ]] || {
    tokenfleet_source_error "the recorded credential backend is not a regular file"
    exit 2
  }
  RECORDED_BACKEND="$(/usr/bin/tr -d '[:space:]' <"$BACKEND_FILE")"
  [[ "$RECORDED_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" \
      || "$RECORDED_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_DISABLED" ]] || {
    tokenfleet_source_error "the recorded credential backend is malformed"
    exit 2
  }
fi

RECORDED_ORIGIN=""
if [[ -e "$ORIGIN_FILE" || -L "$ORIGIN_FILE" ]]; then
  [[ -f "$ORIGIN_FILE" && ! -L "$ORIGIN_FILE" ]] || {
    tokenfleet_source_error "the recorded community origin is not a regular file"
    exit 2
  }
  RECORDED_ORIGIN="$(/usr/bin/tr -d '\r\n' <"$ORIGIN_FILE")"
  /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$RECORDED_ORIGIN" \
    >/dev/null || {
      tokenfleet_source_error "the recorded community origin is malformed"
      exit 2
    }
fi

CURRENT_BACKEND=""
CURRENT_FINGERPRINT=""
if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
  [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || {
    tokenfleet_source_error "refusing to replace a symlink or non-App target: $TARGET_APP"
    exit 2
  }
  [[ "$(tokenfleet_source_plist_value "$TARGET_APP" CFBundleIdentifier)" == "$TOKENFLEET_SOURCE_BUNDLE_ID" ]] || {
    tokenfleet_source_error "the existing target is not the expected TokenFleet bundle"
    exit 2
  }
  CURRENT_BACKEND="$(tokenfleet_source_plist_value "$TARGET_APP" TokenFleetCredentialBackend || true)"
  if [[ "$CURRENT_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]]; then
    CURRENT_FINGERPRINT="$(tokenfleet_install_app_certificate_sha1 "$TARGET_APP")" || {
      tokenfleet_source_error "the existing sync build has no readable signing certificate"
      exit 2
    }
  fi
  if [[ "$TEST_MODE" != "1" ]] && /usr/bin/pgrep -x TokenFleet >/dev/null 2>&1; then
    tokenfleet_source_error "quit TokenFleet before upgrading or replacing it"
    exit 2
  fi
fi

if [[ "$MODE" == "local-only" && "$ALLOW_DISABLE_SYNC" != true \
    && ( "$CURRENT_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" \
      || "$RECORDED_BACKEND" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ) ]]; then
  tokenfleet_source_error "this Mac has community sync enabled or recorded"
  tokenfleet_source_error "add --allow-disable-community-sync to make the downgrade explicit"
  exit 2
fi

if [[ "$MODE" == "community" && -n "$RECORDED_ORIGIN" \
    && "$RECORDED_ORIGIN" != "$COMMUNITY_SERVER_URL" ]]; then
  tokenfleet_source_error "the requested community origin differs from this Mac's recorded origin"
  tokenfleet_source_error "do not change origins in place; re-enroll through an approved migration"
  exit 2
fi

RECORDED_FINGERPRINT=""
if [[ -f "$FINGERPRINT_FILE" && ! -L "$FINGERPRINT_FILE" ]]; then
  RECORDED_FINGERPRINT="$(/usr/bin/tr -d '[:space:]' <"$FINGERPRINT_FILE")"
  [[ ${#RECORDED_FINGERPRINT} -eq 40 && "$RECORDED_FINGERPRINT" =~ ^[0-9A-F]+$ ]] || {
    tokenfleet_source_error "the recorded signing identity fingerprint is malformed"
    exit 2
  }
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/.tokenfleet-build.XXXXXX")"
chmod 700 "$BUILD_ROOT"
BUILT_APP="$BUILD_ROOT/TokenFleet.app"

if [[ "$MODE" == "community" ]]; then
  TOKENFLEET_VERSION="$VERSION" \
  TOKENFLEET_BUNDLE_ID="$TOKENFLEET_SOURCE_BUNDLE_ID" \
  TOKENFLEET_UPDATE_API_URL="" \
  TOKENFLEET_COMMUNITY_SERVER_URL="$COMMUNITY_SERVER_URL" \
  TOKENFLEET_TEAM_ID="" \
  TOKENFLEET_CREDENTIAL_BACKEND="$TOKENFLEET_SOURCE_BACKEND_ENABLED" \
  TOKENFLEET_EXTERNAL_SIGNING_STAGE="1" \
  TOKENFLEET_ARCHITECTURES="$SOURCE_ARCHITECTURE" \
  TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_ROOT" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch
else
  TOKENFLEET_VERSION="$VERSION" \
  TOKENFLEET_BUNDLE_ID="$TOKENFLEET_SOURCE_BUNDLE_ID" \
  TOKENFLEET_UPDATE_API_URL="" \
  TOKENFLEET_COMMUNITY_SERVER_URL="" \
  TOKENFLEET_TEAM_ID="" \
  TOKENFLEET_CREDENTIAL_BACKEND="$TOKENFLEET_SOURCE_BACKEND_DISABLED" \
  TOKENFLEET_ARCHITECTURES="$SOURCE_ARCHITECTURE" \
  TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_ROOT" \
    "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch
fi

IDENTITY_FINGERPRINT=""
if [[ "$MODE" == "community" ]]; then
  if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
    IDENTITY_FINGERPRINT="$TEST_STABLE_SHA1"
  else
    if [[ "$TEST_MODE" == "1" ]]; then
      KEYCHAIN="${TOKENFLEET_SOURCE_KEYCHAIN:-}"
      [[ "$KEYCHAIN" == /private/tmp/* && -f "$KEYCHAIN" && ! -L "$KEYCHAIN" ]] || {
        tokenfleet_source_error "isolated community tests require a temporary keychain under /private/tmp"
        exit 2
      }
    else
      KEYCHAIN="$(tokenfleet_source_login_keychain)" || {
        tokenfleet_source_error "could not resolve a regular login keychain"
        exit 2
      }
    fi

    EXISTING_IDENTITY=""
    if EXISTING_IDENTITY="$(tokenfleet_source_single_identity_hash "$KEYCHAIN")"; then
      :
    elif [[ -n "$CURRENT_FINGERPRINT" || -n "$RECORDED_FINGERPRINT" ]]; then
      tokenfleet_source_error "the prior local signing identity is missing; do not rotate it silently"
      tokenfleet_source_error "restore that identity or reinstall and re-enroll this device"
      exit 2
    else
      if [[ "$ASSUME_YES" != true ]]; then
        echo "Community sync needs one non-exportable self-signed identity in your login Keychain."
        echo "It is used only to keep TokenFleet's local Keychain ACL stable across source upgrades."
        echo "（中文说明：社群同步需要在你的登录钥匙串里创建一把不可导出的本机 App 签名钥匙，"
        echo "  仅用于保持升级后权限稳定；钥匙只存在这台 Mac 上，绝不上传。）"
        printf 'Create it now? [y/N] '
        IFS= read -r answer
        case "$answer" in
          y|Y|yes|YES) ;;
          *)
            tokenfleet_source_error "cancelled before changing the login Keychain"
            exit 2
            ;;
        esac
      fi
    fi

    IDENTITY_FINGERPRINT="$(tokenfleet_source_ensure_identity "$KEYCHAIN" true)" || exit 1
  fi

  if [[ -n "$RECORDED_FINGERPRINT" && "$RECORDED_FINGERPRINT" != "$IDENTITY_FINGERPRINT" ]]; then
    tokenfleet_source_error "the login Keychain identity does not match the recorded source identity"
    exit 2
  fi
  if [[ -n "$CURRENT_FINGERPRINT" && "$CURRENT_FINGERPRINT" != "$IDENTITY_FINGERPRINT" ]]; then
    tokenfleet_source_error "the installed sync build was signed by a different identity"
    exit 2
  fi

  if [[ "$TEST_STABLE_FIXTURE" == "1" ]]; then
    tokenfleet_source_test_sign_stable_app "$BUILT_APP" "$IDENTITY_FINGERPRINT"
  else
    echo "接下来 macOS 可能弹出系统对话框：「codesign 想要访问你的钥匙串中的密钥」。"
    echo "这是系统在为本机刚才那把签名钥匙做授权：钥匙只存在你自己的登录钥匙串里、不可导出、不会上传。"
    echo "请输入这台 Mac 的登录密码——密码只交给 macOS 系统本身，TokenFleet 无法读取。"
    echo "建议点「始终允许」，之后升级就不会再弹这个窗。"
    tokenfleet_source_sign_stable_app "$BUILT_APP" "$IDENTITY_FINGERPRINT" "$KEYCHAIN"
  fi
  tokenfleet_install_verify_stable_app \
    "$BUILT_APP" "$COMMUNITY_SERVER_URL" "$IDENTITY_FINGERPRINT" || {
      tokenfleet_source_error "stable signature verification failed; nothing was installed"
      exit 1
    }
else
  tokenfleet_source_sign_adhoc_app "$BUILT_APP"
  tokenfleet_source_verify_adhoc_app "$BUILT_APP" || {
    tokenfleet_source_error "ad-hoc local-only verification failed; nothing was installed"
    exit 1
  }
fi

INSTALL_STAGE_ROOT="$(mktemp -d "$INSTALL_ROOT/.tokenfleet-install.XXXXXX")"
chmod 700 "$INSTALL_STAGE_ROOT"
STAGED_APP="$INSTALL_STAGE_ROOT/TokenFleet.app"
/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"

if [[ "$MODE" == "community" ]]; then
  tokenfleet_install_verify_stable_app \
    "$STAGED_APP" "$COMMUNITY_SERVER_URL" "$IDENTITY_FINGERPRINT" || {
      tokenfleet_source_error "staged stable App failed verification"
      exit 1
    }
else
  tokenfleet_source_verify_adhoc_app "$STAGED_APP" || {
    tokenfleet_source_error "staged local-only App failed verification"
    exit 1
  }
fi

# Prepare the complete next state and a rollback snapshot before replacing the
# App. If any later state publication fails, cleanup restores both the prior
# App and these exact prior state files.
STATE_TRANSACTION_ROOT="$(mktemp -d "$STATE_ROOT/.state-transaction.XXXXXX")"
chmod 700 "$STATE_TRANSACTION_ROOT"
mkdir "$STATE_TRANSACTION_ROOT/next" "$STATE_TRANSACTION_ROOT/previous"
chmod 700 "$STATE_TRANSACTION_ROOT/next" "$STATE_TRANSACTION_ROOT/previous"
for state_name in current-backend signing-identity.sha1 community-origin; do
  state_path="$STATE_ROOT/$state_name"
  if [[ -e "$state_path" || -L "$state_path" ]]; then
    [[ -f "$state_path" && ! -L "$state_path" ]] || {
      tokenfleet_source_error "state target must be a regular non-symlinked file: $state_path"
      exit 2
    }
    /usr/bin/ditto "$state_path" "$STATE_TRANSACTION_ROOT/previous/$state_name"
  fi
done

NEXT_BACKEND="$TOKENFLEET_SOURCE_BACKEND_DISABLED"
[[ "$MODE" == "community" ]] && NEXT_BACKEND="$TOKENFLEET_SOURCE_BACKEND_ENABLED"
printf '%s\n' "$NEXT_BACKEND" >"$STATE_TRANSACTION_ROOT/next/current-backend"
chmod 600 "$STATE_TRANSACTION_ROOT/next/current-backend"
if [[ "$MODE" == "community" ]]; then
  printf '%s\n' "$IDENTITY_FINGERPRINT" >"$STATE_TRANSACTION_ROOT/next/signing-identity.sha1"
  printf '%s\n' "$COMMUNITY_SERVER_URL" >"$STATE_TRANSACTION_ROOT/next/community-origin"
  chmod 600 \
    "$STATE_TRANSACTION_ROOT/next/signing-identity.sha1" \
    "$STATE_TRANSACTION_ROOT/next/community-origin"
fi

if [[ -e "$TARGET_APP" ]]; then
  TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  OLD_VERSION="$(tokenfleet_source_plist_value "$TARGET_APP" TokenFleetReleaseVersion || true)"
  SAFE_OLD_VERSION="$(printf '%s' "$OLD_VERSION" | /usr/bin/tr -cd 'A-Za-z0-9._+-')"
  [[ -n "$SAFE_OLD_VERSION" ]] || SAFE_OLD_VERSION="unknown"
  OLD_APP_BACKUP="$STATE_ROOT/backups/TokenFleet-$TIMESTAMP-$SAFE_OLD_VERSION.app"
  [[ ! -e "$OLD_APP_BACKUP" ]] || {
    tokenfleet_source_error "backup collision: $OLD_APP_BACKUP"
    exit 1
  }
  mv "$TARGET_APP" "$OLD_APP_BACKUP"
fi

if ! mv "$STAGED_APP" "$TARGET_APP"; then
  tokenfleet_source_error "could not publish the verified App"
  exit 1
fi
PUBLISHED=true

STATE_MUTATED=true
mv "$STATE_TRANSACTION_ROOT/next/current-backend" "$STATE_ROOT/current-backend"
if [[ "$MODE" == "community" ]]; then
  mv "$STATE_TRANSACTION_ROOT/next/signing-identity.sha1" "$FINGERPRINT_FILE"
  mv "$STATE_TRANSACTION_ROOT/next/community-origin" "$ORIGIN_FILE"
  if [[ "$TEST_FAIL_STATE_COMMIT" == "after-community-origin" ]]; then
    tokenfleet_source_error "injected failure after community state publication"
    exit 1
  fi
fi
STATE_MUTATED=false

PUBLISHED=false
OLD_APP_BACKUP=""

if [[ "$LAUNCH" == true ]]; then
  /usr/bin/open "$TARGET_APP"
fi

if [[ "$MODE" == "community" ]]; then
  echo "Installed stable self-signed TokenFleet at: $TARGET_APP"
  echo "Community sync backend: $TOKENFLEET_SOURCE_BACKEND_ENABLED"
  echo "The enrollment code is never handled by this script; paste it only in the App."
else
  echo "Installed ad-hoc TokenFleet at: $TARGET_APP"
  echo "Community sync is disabled. Local usage statistics remain available."
fi
if [[ -n "$(find "$STATE_ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'TokenFleet-*.app' -print -quit)" ]]; then
  echo "Rollback copies are preserved under: $STATE_ROOT/backups"
fi
