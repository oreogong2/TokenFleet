#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/TokenStepSwift"
APP_NAME="TokenFleet"
PRODUCT_NAME="TokenFleet"
HELPER_NAME="TokenFleetHelper"
DEFAULT_DIST_DIR="$SWIFT_DIR/dist"
EXPLICIT_OUTPUT_ROOT="${TOKENFLEET_APP_OUTPUT_ROOT:-}"
if [[ -n "$EXPLICIT_OUTPUT_ROOT" ]]; then
  if [[ "$EXPLICIT_OUTPUT_ROOT" != /* ]] \
      || [[ ! -d "$EXPLICIT_OUTPUT_ROOT" ]] \
      || [[ -L "$EXPLICIT_OUTPUT_ROOT" ]]; then
    echo "TOKENFLEET_APP_OUTPUT_ROOT must be an existing absolute non-symlinked temporary directory." >&2
    exit 2
  fi
  DIST_DIR="$(cd "$EXPLICIT_OUTPUT_ROOT" && pwd -P)"
  case "$(basename "$DIST_DIR")" in
    .tokenfleet-build.*) ;;
    *)
      echo "TOKENFLEET_APP_OUTPUT_ROOT must be a dedicated mktemp directory named .tokenfleet-build.*." >&2
      exit 2
      ;;
  esac
  BUILD_DIR="$DIST_DIR/.build"
else
  DIST_DIR="$DEFAULT_DIST_DIR"
  BUILD_DIR="$SWIFT_DIR/.build"
fi
BUILD_LOG="$BUILD_DIR/swift-build.log"
HELPER_BUILD_LOG="$BUILD_DIR/swift-helper-build.log"
ICON_BUILD_LOG="$BUILD_DIR/swift-icon-build.log"
SDK_PATH="${TOKENFLEET_SWIFT_SDK:-}"
if [[ -z "$SDK_PATH" ]]; then
  if ! SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" \
      || [[ -z "$SDK_PATH" ]]; then
    echo "Unable to locate the active macOS SDK with xcrun." >&2
    exit 2
  fi
fi
MODULE_CACHE="$BUILD_DIR/module-cache"
OVERLAY_DIR="$BUILD_DIR/vfs-overlay"
OVERLAY_FILE="$OVERLAY_DIR/overlay.yaml"
EMPTY_MODULEMAP="$OVERLAY_DIR/empty.modulemap"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE="$BUILD_DIR/$PRODUCT_NAME"
HELPER_EXECUTABLE="$BUILD_DIR/$HELPER_NAME"
ARCHITECTURES_RAW="${TOKENFLEET_ARCHITECTURES:-arm64 x86_64}"
read -r -a ARCHITECTURES <<<"$ARCHITECTURES_RAW"
ICON_GENERATOR="$ROOT_DIR/script/generate_tokenfleet_icon.swift"
ICON_HOST_ARCH="$(/usr/bin/uname -m)"
VERSION="${TOKENFLEET_VERSION:-0.1.0-beta.8}"
BUNDLE_ID="${TOKENFLEET_BUNDLE_ID:-com.lingdong.TokenFleet}"
UPDATE_API_URL="${TOKENFLEET_UPDATE_API_URL:-}"
COMMUNITY_SERVER_URL="${TOKENFLEET_COMMUNITY_SERVER_URL:-}"
TEAM_ID="${TOKENFLEET_TEAM_ID:-}"
CREDENTIAL_BACKEND="${TOKENFLEET_CREDENTIAL_BACKEND:-disabled}"
EXTERNAL_SIGNING_STAGE="${TOKENFLEET_EXTERNAL_SIGNING_STAGE:-}"
BUNDLE_VERSION="${VERSION%%[-+]*}"
LAUNCH=true
VERIFY=false
APP_STAGING_ROOT=""
APP_BACKUP_ROOT=""
APP_BACKUP=""
PUBLISHED_APP=false

cleanup_build_output() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 ]]; then
    if [[ "$PUBLISHED_APP" == true && -e "$APP_BUNDLE" ]]; then
      rm -rf -- "$APP_BUNDLE"
    fi
    if [[ -n "$APP_BACKUP" && -e "$APP_BACKUP" && ! -e "$APP_BUNDLE" ]]; then
      mv "$APP_BACKUP" "$APP_BUNDLE"
    fi
  fi
  if [[ -n "$APP_STAGING_ROOT" && -d "$APP_STAGING_ROOT" ]]; then
    rm -rf -- "$APP_STAGING_ROOT"
  fi
  if [[ -n "$APP_BACKUP_ROOT" && -d "$APP_BACKUP_ROOT" ]]; then
    rm -rf -- "$APP_BACKUP_ROOT"
  fi
  exit "$status"
}
trap cleanup_build_output EXIT

for arg in "$@"; do
  case "$arg" in
    --no-launch)
      LAUNCH=false
      ;;
    --verify)
      VERIFY=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$VERSION" =~ $SEMVER_PATTERN ]]; then
  echo "TOKENFLEET_VERSION must be a safe semantic version such as 0.1.0 or 0.1.0-beta.1." >&2
  exit 2
fi

if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || [[ "$BUNDLE_ID" == "com.huangshu.TokenStep" ]]; then
  echo "TOKENFLEET_BUNDLE_ID must be an independent reverse-DNS identifier." >&2
  exit 2
fi

if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "TOKENFLEET_TEAM_ID must be the 10-character Apple Developer Team ID." >&2
  exit 2
fi

if [[ ! -d "$SDK_PATH" ]]; then
  echo "Swift SDK not found: $SDK_PATH" >&2
  exit 2
fi

if [[ "${#ARCHITECTURES[@]}" -eq 0 ]]; then
  echo "TOKENFLEET_ARCHITECTURES must include arm64, x86_64, or both." >&2
  exit 2
fi
case "$ICON_HOST_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported build host architecture: $ICON_HOST_ARCH" >&2
    exit 2
    ;;
esac
SEEN_ARCHITECTURES=" "
for architecture in "${ARCHITECTURES[@]}"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *)
      echo "Unsupported TOKENFLEET_ARCHITECTURES entry: $architecture" >&2
      exit 2
      ;;
  esac
  if [[ "$SEEN_ARCHITECTURES" == *" $architecture "* ]]; then
    echo "TOKENFLEET_ARCHITECTURES contains a duplicate: $architecture" >&2
    exit 2
  fi
  SEEN_ARCHITECTURES+="$architecture "
done

if [[ -n "$UPDATE_API_URL" ]]; then
  if [[ -z "$TEAM_ID" ]]; then
    echo "TOKENFLEET_TEAM_ID is required whenever the update service is enabled." >&2
    exit 2
  fi
  if [[ ! "$UPDATE_API_URL" =~ ^https://[^[:space:]\<\>\&\"]+$ ]]; then
    echo "TOKENFLEET_UPDATE_API_URL must be an HTTPS URL without whitespace." >&2
    exit 2
  fi
  case "$UPDATE_API_URL" in
    *Backtthefuture*TokenStep*|*backtthefuture*tokenstep*)
      echo "TOKENFLEET_UPDATE_API_URL must not point at the upstream TokenStep release feed." >&2
      exit 2
      ;;
  esac
fi

if [[ -n "$COMMUNITY_SERVER_URL" ]] \
    && ! /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$COMMUNITY_SERVER_URL"; then
  echo "TOKENFLEET_COMMUNITY_SERVER_URL must be one canonical HTTPS origin with a lowercase ASCII DNS hostname (at least one dot), no IP/single-label/localhost alias, and no path, query, fragment, credentials, percent encoding, or default :443." >&2
  exit 2
fi

case "$CREDENTIAL_BACKEND" in
  disabled)
    if [[ -n "$COMMUNITY_SERVER_URL" ]]; then
      echo "TOKENFLEET_COMMUNITY_SERVER_URL is forbidden when TOKENFLEET_CREDENTIAL_BACKEND=disabled." >&2
      echo "Use the audited source installer or release packager to create a stable signed sync build." >&2
      exit 2
    fi
    ;;
  file-login-v1)
    if [[ "$EXTERNAL_SIGNING_STAGE" != "1" || "$LAUNCH" == true ]]; then
      echo "file-login-v1 is only valid in a non-launching external signing stage." >&2
      exit 2
    fi
    if [[ -z "$COMMUNITY_SERVER_URL" ]]; then
      echo "TOKENFLEET_COMMUNITY_SERVER_URL is required for file-login-v1." >&2
      exit 2
    fi
    ;;
  *)
    echo "TOKENFLEET_CREDENTIAL_BACKEND must be disabled or file-login-v1." >&2
    exit 2
    ;;
esac

if [[ "$LAUNCH" == true ]]; then
  pkill -x "$PRODUCT_NAME" 2>/dev/null || true
  pkill -x "$HELPER_NAME" 2>/dev/null || true
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR" "$OVERLAY_DIR" "$MODULE_CACHE"
python3 "$ROOT_DIR/script/check_localization.py"
python3 "$ROOT_DIR/script/check_language_refresh.py"
cat > "$EMPTY_MODULEMAP" <<'EOF'
// Intentionally empty.
// CLT 16.x can leave both module.modulemap and bridging.modulemap defining SwiftBridging.
// This overlay hides the stale module.modulemap during this build without modifying /Library/Developer.
EOF
cat > "$OVERLAY_FILE" <<EOF
{
  "version": 0,
  "roots": [
    {
      "type": "directory",
      "name": "/Library/Developer/CommandLineTools/usr/include/swift",
      "contents": [
        {
          "type": "file",
          "name": "module.modulemap",
          "external-contents": "$EMPTY_MODULEMAP"
        }
      ]
    }
  ]
}
EOF
SOURCES=()
while IFS= read -r source; do
  SOURCES+=("$source")
done < <(find "$SWIFT_DIR/Sources/TokenStepSwift" -type f -name '*.swift' | sort)

: >"$BUILD_LOG"
APP_SLICES=()
for architecture in "${ARCHITECTURES[@]}"; do
  architecture_executable="$BUILD_DIR/$PRODUCT_NAME-$architecture"
  architecture_module_cache="$MODULE_CACHE/$architecture"
  mkdir -p "$architecture_module_cache"
  if ! swiftc \
    -target "$architecture-apple-macosx14.0" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$architecture_module_cache" \
    -vfsoverlay "$OVERLAY_FILE" \
    -Xcc -ivfsoverlay \
    -Xcc "$OVERLAY_FILE" \
    -parse-as-library \
    "${SOURCES[@]}" \
    -framework Security \
    -framework LocalAuthentication \
    -o "$architecture_executable" >>"$BUILD_LOG" 2>&1; then
    echo "TokenFleet $architecture SwiftUI build failed. Full log: $BUILD_LOG" >&2
    tail -n 24 "$BUILD_LOG" >&2
    exit 1
  fi
  APP_SLICES+=("$architecture_executable")
done
if [[ "${#APP_SLICES[@]}" -eq 1 ]]; then
  cp "${APP_SLICES[0]}" "$EXECUTABLE"
else
  /usr/bin/lipo -create "${APP_SLICES[@]}" -output "$EXECUTABLE"
fi

HELPER_SOURCES=(
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/AppPaths.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/Localization.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/MemoryPressure.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/Theme.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/TokenPricing.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Models/UsageModels.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/UsageCollector.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/CursorUsageCSVParser.swift"
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/DataService.swift"
  "$SWIFT_DIR/Sources/TokenStepHelper/main.swift"
)

: >"$HELPER_BUILD_LOG"
HELPER_SLICES=()
for architecture in "${ARCHITECTURES[@]}"; do
  architecture_helper="$BUILD_DIR/$HELPER_NAME-$architecture"
  architecture_module_cache="$MODULE_CACHE/$architecture"
  if ! swiftc \
    -target "$architecture-apple-macosx14.0" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$architecture_module_cache" \
    -vfsoverlay "$OVERLAY_FILE" \
    -Xcc -ivfsoverlay \
    -Xcc "$OVERLAY_FILE" \
    -parse-as-library \
    "${HELPER_SOURCES[@]}" \
    -o "$architecture_helper" >>"$HELPER_BUILD_LOG" 2>&1; then
    echo "TokenFleet $architecture helper build failed. Full log: $HELPER_BUILD_LOG" >&2
    tail -n 24 "$HELPER_BUILD_LOG" >&2
    exit 1
  fi
  HELPER_SLICES+=("$architecture_helper")
done
if [[ "${#HELPER_SLICES[@]}" -eq 1 ]]; then
  cp "${HELPER_SLICES[0]}" "$HELPER_EXECUTABLE"
else
  /usr/bin/lipo -create "${HELPER_SLICES[@]}" -output "$HELPER_EXECUTABLE"
fi

APP_STAGING_ROOT="$(mktemp -d "$DIST_DIR/.tokenfleet-app-stage.XXXXXX")"
STAGED_APP_BUNDLE="$APP_STAGING_ROOT/$APP_NAME.app"
CONTENTS="$STAGED_APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Helpers"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$HELPERS" "$RESOURCES"
cp "$EXECUTABLE" "$MACOS/$PRODUCT_NAME"
cp "$HELPER_EXECUTABLE" "$HELPERS/$HELPER_NAME"
[[ -f "$ICON_GENERATOR" ]] || {
  echo "TokenFleet icon generator is missing." >&2
  exit 2
}
: >"$ICON_BUILD_LOG"
if ! swiftc \
  -target "$ICON_HOST_ARCH-apple-macosx14.0" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE/icon" \
  -vfsoverlay "$OVERLAY_FILE" \
  -Xcc -ivfsoverlay \
  -Xcc "$OVERLAY_FILE" \
  "$ICON_GENERATOR" \
  -o "$BUILD_DIR/generate-tokenfleet-icon" >>"$ICON_BUILD_LOG" 2>&1; then
  echo "TokenFleet icon generator build failed. Full log: $ICON_BUILD_LOG" >&2
  tail -n 24 "$ICON_BUILD_LOG" >&2
  exit 1
fi
"$BUILD_DIR/generate-tokenfleet-icon" "$RESOURCES/TokenFleetIcon.icns"
[[ -s "$RESOURCES/TokenFleetIcon.icns" ]] || {
  echo "TokenFleet icon generation did not produce an ICNS file." >&2
  exit 1
}
cp "$ROOT_DIR/LICENSE" "$RESOURCES/LICENSE.txt"
cp "$ROOT_DIR/NOTICE" "$RESOURCES/NOTICE.txt"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>TokenFleetIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>TokenFleetReleaseVersion</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>TokenFleetUpdateAPIURL</key>
  <string>$UPDATE_API_URL</string>
  <key>TokenFleetDeveloperTeamID</key>
  <string>$TEAM_ID</string>
  <key>TokenFleetCommunityServerURL</key>
  <string>$COMMUNITY_SERVER_URL</string>
  <key>TokenFleetCredentialBackend</key>
  <string>$CREDENTIAL_BACKEND</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  APP_BACKUP_ROOT="$(mktemp -d "$DIST_DIR/.tokenfleet-app-backup.XXXXXX")"
  APP_BACKUP="$APP_BACKUP_ROOT/$APP_NAME.app"
  mv "$APP_BUNDLE" "$APP_BACKUP"
fi
if ! mv "$STAGED_APP_BUNDLE" "$APP_BUNDLE"; then
  echo "Could not publish the completed TokenFleet.app build." >&2
  exit 1
fi
PUBLISHED_APP=true

if [[ "$LAUNCH" == true ]]; then
  /usr/bin/open -n "$APP_BUNDLE"
fi

if [[ "$VERIFY" == true ]]; then
  if [[ "$LAUNCH" != true ]]; then
    echo "--verify requires launch; remove --no-launch" >&2
    exit 2
  fi
  sleep 2
  if pgrep -x "$PRODUCT_NAME" >/dev/null; then
    echo "TokenFleet SwiftUI is running"
  else
    echo "TokenFleet SwiftUI did not start" >&2
    exit 1
  fi
fi

echo "Built $APP_BUNDLE (bundle id: $BUNDLE_ID; credential backend: $CREDENTIAL_BACKEND; launch: $LAUNCH)"
