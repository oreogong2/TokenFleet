#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=script/lib/tokenfleet_source_signing.sh
source "$ROOT_DIR/script/lib/tokenfleet_source_signing.sh"

TEST_MODE="${TOKENFLEET_SOURCE_TEST_MODE:-0}"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h)
      echo "Usage: ./script/uninstall_source_install.sh"
      echo "Moves the source-installed App to Trash; local data and Keychain items are preserved."
      exit 0
      ;;
    *)
      tokenfleet_source_error "unknown uninstall argument: $1"
      exit 2
      ;;
  esac
fi

if [[ "$TEST_MODE" == "1" ]]; then
  INSTALL_ROOT="${TOKENFLEET_SOURCE_INSTALL_ROOT:-}"
  STATE_ROOT="${TOKENFLEET_SOURCE_STATE_ROOT:-}"
  [[ "$INSTALL_ROOT" == /private/tmp/* \
      && "$STATE_ROOT" == /private/tmp/* \
      && -d "$INSTALL_ROOT" \
      && -d "$STATE_ROOT" \
      && ! -L "$INSTALL_ROOT" \
      && ! -L "$STATE_ROOT" ]] || {
    tokenfleet_source_error "uninstall test roots must be isolated under /private/tmp"
    exit 2
  }
  TRASH_ROOT="$STATE_ROOT/Trash"
else
  [[ "$TEST_MODE" == "0" \
      && -z "${TOKENFLEET_SOURCE_INSTALL_ROOT:-}" \
      && -z "${TOKENFLEET_SOURCE_STATE_ROOT:-}" ]] || {
    tokenfleet_source_error "uninstall path overrides are test-only"
    exit 2
  }
  INSTALL_ROOT="$HOME/Applications"
  STATE_ROOT="$HOME/Library/Application Support/TokenFleet/SourceInstall"
  TRASH_ROOT="$HOME/.Trash"
fi

TARGET_APP="$INSTALL_ROOT/TokenFleet.app"
[[ -d "$TARGET_APP" && ! -L "$TARGET_APP" \
    && "$(tokenfleet_source_plist_value "$TARGET_APP" CFBundleIdentifier)" == "$TOKENFLEET_SOURCE_BUNDLE_ID" ]] || {
  tokenfleet_source_error "no expected source-installed TokenFleet App was found"
  exit 2
}
if [[ "$TEST_MODE" != "1" ]] && /usr/bin/pgrep -x TokenFleet >/dev/null 2>&1; then
  tokenfleet_source_error "quit TokenFleet before uninstalling it"
  exit 2
fi

mkdir -p "$TRASH_ROOT"
[[ -d "$TRASH_ROOT" && ! -L "$TRASH_ROOT" ]] || {
  tokenfleet_source_error "Trash target is not a real directory"
  exit 2
}
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
TRASH_APP="$TRASH_ROOT/TokenFleet-$TIMESTAMP.app"
[[ ! -e "$TRASH_APP" ]] || {
  tokenfleet_source_error "Trash destination already exists"
  exit 1
}

if [[ "$TEST_MODE" != "1" ]]; then
  LAUNCH_AGENT="$HOME/Library/LaunchAgents/$TOKENFLEET_SOURCE_BUNDLE_ID.login.plist"
  if [[ -f "$LAUNCH_AGENT" && ! -L "$LAUNCH_AGENT" ]]; then
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    TRASH_AGENT="$TRASH_ROOT/TokenFleet-login-$TIMESTAMP.plist"
    [[ ! -e "$TRASH_AGENT" ]] && mv "$LAUNCH_AGENT" "$TRASH_AGENT"
  fi
fi

mv "$TARGET_APP" "$TRASH_APP"
echo "Moved TokenFleet to: $TRASH_APP"
echo "Preserved local statistics, rollback copies, community credential, and signing identity."
echo "To remove those later, review them manually; this script never bulk-deletes Keychain or App Support data."
