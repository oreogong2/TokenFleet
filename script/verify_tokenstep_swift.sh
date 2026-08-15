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
SWIFT_DIR="$ROOT_DIR/TokenStepSwift"
SDK_PATH="${TOKENFLEET_SWIFT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
TEST_ARCHITECTURE="${TOKENFLEET_SWIFT_TEST_ARCHITECTURE:-$(uname -m)}"
REQUIRE_SHARE_CARD_RENDER="${TOKENFLEET_REQUIRE_SHARE_CARD_RENDER:-1}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-swift-verify.XXXXXX")"
MODULE_CACHE="$BUILD_DIR/module-cache"
MODULE_PATH="$BUILD_DIR/TokenStepSwift.swiftmodule"
LIBRARY_PATH="$BUILD_DIR/libTokenStepSwift.dylib"
HARNESS_PATH="$BUILD_DIR/tokenstep-logic-harness"
APP_PATH="$BUILD_DIR/TokenStepSwiftApp"
OFFLINE_FIXTURE_PATH="$BUILD_DIR/team-sync-offline-recovery"
NETWORK_FIXTURE_PATH="$BUILD_DIR/network-supply-chain"
KEYCHAIN_FIXTURE_PATH="$BUILD_DIR/team-sync-keychain"
SHARE_CARD_FIXTURE_PATH="$BUILD_DIR/share-card-export"
BETA8_FINAL_VIEWS_FIXTURE_PATH="$BUILD_DIR/beta8-final-views-render"
COMPLETED=false

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  rm -rf "$BUILD_DIR"
  [[ "$COMPLETED" == true || "$status" -ne 0 ]] || status=1
  exit "$status"
}
trap cleanup EXIT

if [[ ! -d "$SDK_PATH" ]]; then
  echo "Swift SDK not found: $SDK_PATH" >&2
  exit 1
fi
if [[ "$TEST_ARCHITECTURE" != "arm64" && "$TEST_ARCHITECTURE" != "x86_64" ]]; then
  echo "Unsupported native Swift verification architecture: $TEST_ARCHITECTURE" >&2
  exit 1
fi
if [[ "$REQUIRE_SHARE_CARD_RENDER" != "0" && "$REQUIRE_SHARE_CARD_RENDER" != "1" ]]; then
  echo "TOKENFLEET_REQUIRE_SHARE_CARD_RENDER must be 0 or 1" >&2
  exit 1
fi

mkdir -p "$MODULE_CACHE"

POPOVER_TODAY_SOURCE="$SWIFT_DIR/Sources/TokenStepSwift/Views/Popover/PopoverTodayRingCard.swift"
MAIN_WINDOW_SOURCE="$SWIFT_DIR/Sources/TokenStepSwift/Views/MainWindowView.swift"
TODAY_SOURCE="$SWIFT_DIR/Sources/TokenStepSwift/Views/TodayView.swift"
PRIVACY_SOURCE="$SWIFT_DIR/Sources/TokenStepSwift/Views/Settings/SettingsUpdateAutostartPrivacyCards.swift"

rg -Fq 'MainWindowPresenter.shared.showTodayTools(appState: appState)' "$POPOVER_TODAY_SOURCE" \
  || { echo "today-all-tools action is not wired to the expansion presenter" >&2; exit 1; }
rg -Fq 'TodayView(toolExpansionRequest: navigation.todayToolExpansionRequest)' "$MAIN_WINDOW_SOURCE" \
  || { echo "main window does not pass the today tool expansion signal" >&2; exit 1; }
rg -Fq 'expansionRequest: toolExpansionRequest' "$TODAY_SOURCE" \
  || { echo "today tool card does not consume the expansion signal" >&2; exit 1; }

if rg -Fq '绝不读取 prompt、回复、代码或路径' "$PRIVACY_SOURCE" \
    || rg -Fq '本机仅保留聚合 Token' "$PRIVACY_SOURCE"; then
  echo "privacy card contains an absolute claim that exceeds collector behavior" >&2
  exit 1
fi
rg -Fq '内容字段不进入统计或上传' "$PRIVACY_SOURCE" \
  || { echo "privacy card does not state the content-field boundary" >&2; exit 1; }
rg -Fq '路径仅作本机增量定位' "$PRIVACY_SOURCE" \
  || { echo "privacy card does not disclose local path metadata" >&2; exit 1; }

SOURCE_LIST="$BUILD_DIR/sources.list"
if ! rg --files "$SWIFT_DIR/Sources/TokenStepSwift" -g '*.swift' >"$SOURCE_LIST"; then
  echo "ripgrep failed while collecting TokenFleet Swift sources" >&2
  exit 1
fi
sort -o "$SOURCE_LIST" "$SOURCE_LIST"
SOURCES=()
SOURCE_COUNT=0
while IFS= read -r source; do
  SOURCES+=("$source")
  SOURCE_COUNT=$((SOURCE_COUNT + 1))
done <"$SOURCE_LIST"
[[ "$SOURCE_COUNT" -gt 0 ]] || {
  echo "no TokenFleet Swift sources were collected" >&2
  exit 1
}

TEST_SOURCE_LIST="$BUILD_DIR/test-sources.list"
if ! rg --files "$SWIFT_DIR/Tests/TokenStepSwiftTests" -g '*.swift' >"$TEST_SOURCE_LIST"; then
  echo "ripgrep failed while collecting TokenFleet Swift tests" >&2
  exit 1
fi
sort -o "$TEST_SOURCE_LIST" "$TEST_SOURCE_LIST"
TEST_SOURCES=()
TEST_SOURCE_COUNT=0
while IFS= read -r source; do
  TEST_SOURCES+=("$source")
  TEST_SOURCE_COUNT=$((TEST_SOURCE_COUNT + 1))
done <"$TEST_SOURCE_LIST"
[[ "$TEST_SOURCE_COUNT" -gt 0 ]] || {
  echo "no TokenFleet Swift test sources were collected" >&2
  exit 1
}

COMMON_FLAGS=(
  -target "$TEST_ARCHITECTURE-apple-macosx14.0"
  -sdk "$SDK_PATH"
  -module-cache-path "$MODULE_CACHE"
)

swiftc \
  -typecheck \
  "${COMMON_FLAGS[@]}" \
  -module-name TokenStepSwift \
  -D TOKENSTEP_TESTING \
  "${SOURCES[@]}"

# Link the complete macOS app target without launching it. This catches missing
# symbols across upstream UI/system capabilities while keeping user data untouched.
swiftc \
  -emit-executable \
  -parse-as-library \
  "${COMMON_FLAGS[@]}" \
  -module-name TokenStepSwift \
  -D TOKENSTEP_TESTING \
  -o "$APP_PATH" \
  "${SOURCES[@]}" \
  -framework Security \
  -framework LocalAuthentication \
  -lsqlite3

swiftc \
  -emit-module \
  -parse-as-library \
  -enable-testing \
  "${COMMON_FLAGS[@]}" \
  -module-name TokenStepSwift \
  -D TOKENSTEP_TESTING \
  -emit-module-path "$MODULE_PATH" \
  "${SOURCES[@]}"

swiftc \
  -emit-module \
  -parse-as-library \
  "${COMMON_FLAGS[@]}" \
  -module-name XCTest \
  -emit-module-path "$BUILD_DIR/XCTest.swiftmodule" \
  "$ROOT_DIR/script/fixtures/TokenStepXCTestStub.swift"

swiftc \
  -typecheck \
  "${COMMON_FLAGS[@]}" \
  -I "$BUILD_DIR" \
  -module-name TokenStepSwiftTests \
  "${TEST_SOURCES[@]}"

swiftc \
  -emit-library \
  -parse-as-library \
  -enable-testing \
  "${COMMON_FLAGS[@]}" \
  -module-name TokenStepSwift \
  -D TOKENSTEP_TESTING \
  -emit-module-path "$MODULE_PATH" \
  -o "$LIBRARY_PATH" \
  "${SOURCES[@]}" \
  -framework Security \
  -framework LocalAuthentication \
  -lsqlite3

swiftc \
  -parse-as-library \
  "${COMMON_FLAGS[@]}" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lTokenStepSwift \
  -Xlinker -rpath \
  -Xlinker "$BUILD_DIR" \
  "$SWIFT_DIR/Tests/Fixtures/NetworkSupplyChainFixtureCheck.swift" \
  -o "$NETWORK_FIXTURE_PATH"

"$NETWORK_FIXTURE_PATH"

swiftc \
  -parse-as-library \
  "${COMMON_FLAGS[@]}" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lTokenStepSwift \
  -Xlinker -rpath \
  -Xlinker "$BUILD_DIR" \
  "$SWIFT_DIR/Tests/Fixtures/TeamSyncKeychainFixtureCheck.swift" \
  -framework Security \
  -framework LocalAuthentication \
  -o "$KEYCHAIN_FIXTURE_PATH"

"$KEYCHAIN_FIXTURE_PATH"

if [[ "$REQUIRE_SHARE_CARD_RENDER" == "1" ]]; then
  swiftc \
    -parse-as-library \
    "${COMMON_FLAGS[@]}" \
    -I "$BUILD_DIR" \
    -L "$BUILD_DIR" \
    -lTokenStepSwift \
    -Xlinker -rpath \
    -Xlinker "$BUILD_DIR" \
    "$SWIFT_DIR/Tests/Fixtures/ShareCardExportFixtureCheck.swift" \
    -o "$SHARE_CARD_FIXTURE_PATH"

  "$SHARE_CARD_FIXTURE_PATH"

  swiftc \
    -parse-as-library \
    "${COMMON_FLAGS[@]}" \
    -I "$BUILD_DIR" \
    -L "$BUILD_DIR" \
    -lTokenStepSwift \
    -Xlinker -rpath \
    -Xlinker "$BUILD_DIR" \
    "$SWIFT_DIR/Tests/Fixtures/Beta8FinalViewsRender.swift" \
    -o "$BETA8_FINAL_VIEWS_FIXTURE_PATH"

  TOKENFLEET_TEST_APP_SUPPORT_ROOT="$BUILD_DIR/beta8-final-app-support" \
  TOKENFLEET_TEST_RELEASE_VERSION="0.1.0-beta.8" \
  TOKENFLEET_BETA8_RENDER_DIR="${TOKENFLEET_BETA8_RENDER_DIR:-$BUILD_DIR/beta8-final-output}" \
    "$BETA8_FINAL_VIEWS_FIXTURE_PATH"
else
  echo "Share-card UI render fixture skipped; this run is not a render-inclusive Swift gate" >&2
fi

swiftc \
  -parse-as-library \
  "${COMMON_FLAGS[@]}" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lTokenStepSwift \
  -Xlinker -rpath \
  -Xlinker "$BUILD_DIR" \
  "$ROOT_DIR/script/fixtures/TokenStepLogicHarness.swift" \
  -o "$HARNESS_PATH"

"$HARNESS_PATH"

swiftc \
  -parse-as-library \
  "${COMMON_FLAGS[@]}" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lTokenStepSwift \
  -Xlinker -rpath \
  -Xlinker "$BUILD_DIR" \
  -D TOKENFLEET_IMPORT_APP_MODULE \
  "$SWIFT_DIR/Tests/Fixtures/TeamSyncOfflineRecoveryFixtureCheck.swift" \
  -o "$OFFLINE_FIXTURE_PATH"

TOKENFLEET_TEST_APP_SUPPORT_ROOT="$BUILD_DIR/offline-app-support" \
  "$OFFLINE_FIXTURE_PATH"

SDKROOT="$SDK_PATH" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
TOKENFLEET_SWIFT_TEST_ARCHITECTURE="$TEST_ARCHITECTURE" \
  bash "$ROOT_DIR/script/test_codex_cumulative_collector.sh"

SDKROOT="$SDK_PATH" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
TOKENFLEET_SWIFT_TEST_ARCHITECTURE="$TEST_ARCHITECTURE" \
  bash "$ROOT_DIR/script/test_ccswitch_proxy_collector.sh"

SDKROOT="$SDK_PATH" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
TOKENFLEET_SWIFT_TEST_ARCHITECTURE="$TEST_ARCHITECTURE" \
  bash "$ROOT_DIR/script/test_usage_recalibration_migration.sh"

python3 "$ROOT_DIR/script/check_localization.py"
python3 "$ROOT_DIR/script/check_language_refresh.py"

COMPLETED=true
if [[ "$REQUIRE_SHARE_CARD_RENDER" == "1" ]]; then
  echo "TokenFleet Swift verification passed (share-card UI render fixture: executed; XCTest sources: typechecked only)"
else
  echo "TokenFleet Swift verification passed (share-card UI render fixture: skipped; XCTest sources: typechecked only)"
fi
