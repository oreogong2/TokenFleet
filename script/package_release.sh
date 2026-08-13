#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenFleet"
PRODUCT_NAME="TokenFleet"
HELPER_NAME="TokenFleetHelper"
RELEASE_DIR="${TOKENFLEET_RELEASE_DIR:-$ROOT_DIR/release}"
VERSION="${TOKENFLEET_VERSION:-0.1.0}"
BUNDLE_VERSION="${VERSION%%[-+]*}"
BUNDLE_ID="${TOKENFLEET_BUNDLE_ID:-com.lingdong.TokenFleet}"
UPDATE_API_URL="${TOKENFLEET_UPDATE_API_URL:-}"
COMMUNITY_SERVER_URL="${TOKENFLEET_COMMUNITY_SERVER_URL:-}"
TEAM_ID="${TOKENFLEET_TEAM_ID:-}"
IDENTITY="${CODE_SIGN_IDENTITY:-}"

usage() {
  cat <<'USAGE'
Usage:
  TOKENFLEET_VERSION=0.1.0 \
  TOKENFLEET_BUNDLE_ID="com.yourcompany.TokenFleet" \
  TOKENFLEET_TEAM_ID="ABCDE12345" \
  TOKENFLEET_UPDATE_API_URL="https://updates.example.com/tokenfleet/latest" \
  TOKENFLEET_COMMUNITY_SERVER_URL="https://tokenfleet.example.com" \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  TOKENFLEET_NOTARY_PROFILE="notarytool-profile" \
  ./script/package_release.sh

Notarization credentials are mandatory; choose one:
  TOKENFLEET_NOTARY_PROFILE="notarytool-profile"
  or
  TOKENFLEET_NOTARY_KEY="/secure/path/AuthKey_ABC123DEFG.p8" \
  TOKENFLEET_NOTARY_KEY_ID="ABC123DEFG" \
  TOKENFLEET_NOTARY_ISSUER="00000000-0000-0000-0000-000000000000"

Outputs:
  release/TokenFleet-<version>/TokenFleet-<version>.zip
  release/TokenFleet-<version>/TokenFleet-<version>.dmg
  release/TokenFleet-<version>/TokenFleet-<version>-SHA256SUMS
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$IDENTITY" ]]; then
  echo "CODE_SIGN_IDENTITY is required for public distribution." >&2
  echo "Run: security find-identity -p codesigning -v" >&2
  exit 2
fi

SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$VERSION" =~ $SEMVER_PATTERN ]]; then
  echo "TOKENFLEET_VERSION must be a safe semantic version such as 0.1.0 or 0.1.0-beta.1." >&2
  exit 2
fi

if [[ -z "$UPDATE_API_URL" ]]; then
  echo "TOKENFLEET_UPDATE_API_URL is required for public distribution." >&2
  exit 2
fi

if [[ -z "$COMMUNITY_SERVER_URL" ]]; then
  echo "TOKENFLEET_COMMUNITY_SERVER_URL is required for public distribution." >&2
  exit 2
fi
if ! /usr/bin/python3 "$ROOT_DIR/script/validate_community_origin.py" "$COMMUNITY_SERVER_URL"; then
  echo "TOKENFLEET_COMMUNITY_SERVER_URL is not a canonical production DNS origin." >&2
  exit 2
fi

if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || [[ "$BUNDLE_ID" == "com.huangshu.TokenStep" ]]; then
  echo "TOKENFLEET_BUNDLE_ID must be an independent reverse-DNS identifier." >&2
  exit 2
fi

if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "TOKENFLEET_TEAM_ID is required and must be the 10-character Apple Developer Team ID." >&2
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

NOTARY_PROFILE="${TOKENFLEET_NOTARY_PROFILE:-}"
NOTARY_KEY="${TOKENFLEET_NOTARY_KEY:-}"
NOTARY_KEY_ID="${TOKENFLEET_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${TOKENFLEET_NOTARY_ISSUER:-}"

if [[ -n "$NOTARY_PROFILE" ]] \
    && [[ -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER" ]]; then
  echo "Choose exactly one notarization method: a keychain profile or an App Store Connect API key." >&2
  exit 2
fi

if [[ -z "$NOTARY_PROFILE" ]] \
    && [[ -z "$NOTARY_KEY" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER" ]]; then
  echo "Notarization credentials are required for public distribution." >&2
  echo "Set TOKENFLEET_NOTARY_PROFILE or TOKENFLEET_NOTARY_KEY + TOKENFLEET_NOTARY_KEY_ID + TOKENFLEET_NOTARY_ISSUER." >&2
  exit 2
fi

if [[ -n "$NOTARY_KEY" ]] && [[ ! -f "$NOTARY_KEY" || -L "$NOTARY_KEY" ]]; then
  echo "TOKENFLEET_NOTARY_KEY must point to a regular, non-symlinked App Store Connect API private-key file." >&2
  exit 2
fi

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  if ! actual="$(/usr/libexec/PlistBuddy -c "Print $key" "$plist" 2>/dev/null)"; then
    echo "Release bundle is missing required Info.plist key: $key" >&2
    exit 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Release bundle Info.plist does not match the captured release input: $key" >&2
    exit 1
  fi
}

verify_bundle_contract() {
  local bundle="$1"
  local plist="$bundle/Contents/Info.plist"
  [[ -f "$plist" ]] || {
    echo "Release bundle is missing Contents/Info.plist." >&2
    exit 1
  }
  plutil -lint "$plist" >/dev/null
  assert_plist_value "$plist" CFBundleExecutable "$PRODUCT_NAME"
  assert_plist_value "$plist" CFBundleIdentifier "$BUNDLE_ID"
  assert_plist_value "$plist" CFBundleName "$APP_NAME"
  assert_plist_value "$plist" CFBundleDisplayName "$APP_NAME"
  assert_plist_value "$plist" CFBundleShortVersionString "$BUNDLE_VERSION"
  assert_plist_value "$plist" CFBundleVersion "$BUNDLE_VERSION"
  assert_plist_value "$plist" TokenFleetReleaseVersion "$VERSION"
  assert_plist_value "$plist" TokenFleetUpdateAPIURL "$UPDATE_API_URL"
  assert_plist_value "$plist" TokenFleetCommunityServerURL "$COMMUNITY_SERVER_URL"
  assert_plist_value "$plist" TokenFleetDeveloperTeamID "$TEAM_ID"
}

verify_universal_executable() {
  local executable="$1"
  [[ -f "$executable" ]] || {
    echo "Universal release executable is missing: $executable" >&2
    exit 1
  }
  local architectures
  architectures="$(/usr/bin/lipo -archs "$executable")" || {
    echo "Could not inspect release architectures: $executable" >&2
    exit 1
  }
  for required in arm64 x86_64; do
    if [[ " $architectures " != *" $required "* ]]; then
      echo "Release executable is missing $required: $executable ($architectures)" >&2
      exit 1
    fi
  done
}

verify_bundle_architectures() {
  local bundle="$1"
  verify_universal_executable "$bundle/Contents/MacOS/$PRODUCT_NAME"
  verify_universal_executable "$bundle/Contents/Helpers/$HELPER_NAME"
}

mkdir -p "$RELEASE_DIR"
VERSION_RELEASE_DIR="$RELEASE_DIR/$APP_NAME-$VERSION"
ZIP_PATH="$VERSION_RELEASE_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$VERSION_RELEASE_DIR/$APP_NAME-$VERSION.dmg"
CHECKSUM_PATH="$VERSION_RELEASE_DIR/$APP_NAME-$VERSION-SHA256SUMS"
LEGACY_ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
LEGACY_DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
LEGACY_CHECKSUM_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-SHA256SUMS"

for artifact in "$VERSION_RELEASE_DIR" "$LEGACY_ZIP_PATH" "$LEGACY_DMG_PATH" "$LEGACY_CHECKSUM_PATH"; do
  if [[ -e "$artifact" ]]; then
    echo "Refusing to overwrite existing release artifact: $artifact" >&2
    echo "Move or archive that exact version before retrying; other versions are never removed." >&2
    exit 2
  fi
done

PACKAGE_WORK_DIR="$(mktemp -d "$RELEASE_DIR/.tokenfleet-release.XXXXXX")"
trap 'rm -rf "$PACKAGE_WORK_DIR"' EXIT
BUILD_OUTPUT_ROOT="$(mktemp -d "$PACKAGE_WORK_DIR/.tokenfleet-build.XXXXXX")"
BUILT_APP_BUNDLE="$BUILD_OUTPUT_ROOT/$APP_NAME.app"
ARTIFACT_STAGING="$PACKAGE_WORK_DIR/artifacts"
mkdir -p "$ARTIFACT_STAGING"
STAGED_ZIP_PATH="$ARTIFACT_STAGING/$APP_NAME-$VERSION.zip"
STAGED_DMG_PATH="$ARTIFACT_STAGING/$APP_NAME-$VERSION.dmg"
STAGED_CHECKSUM_PATH="$ARTIFACT_STAGING/$APP_NAME-$VERSION-SHA256SUMS"

echo "Building $APP_NAME $VERSION..."
TOKENFLEET_VERSION="$VERSION" \
TOKENFLEET_BUNDLE_ID="$BUNDLE_ID" \
TOKENFLEET_UPDATE_API_URL="$UPDATE_API_URL" \
TOKENFLEET_COMMUNITY_SERVER_URL="$COMMUNITY_SERVER_URL" \
TOKENFLEET_TEAM_ID="$TEAM_ID" \
TOKENFLEET_CREDENTIAL_BACKEND="file-login-v1" \
TOKENFLEET_EXTERNAL_SIGNING_STAGE="1" \
TOKENFLEET_APP_OUTPUT_ROOT="$BUILD_OUTPUT_ROOT" \
  "$ROOT_DIR/script/build_swiftui_and_run.sh" --no-launch

verify_bundle_contract "$BUILT_APP_BUNDLE"
verify_bundle_architectures "$BUILT_APP_BUNDLE"
APP_BUNDLE="$PACKAGE_WORK_DIR/$APP_NAME.app"
ditto "$BUILT_APP_BUNDLE" "$APP_BUNDLE"
verify_bundle_contract "$APP_BUNDLE"
verify_bundle_architectures "$APP_BUNDLE"

clean_bundle_metadata() {
  find "$APP_BUNDLE" \( -name ".DS_Store" -o -name "*.nssyncsc" \) -delete
}

signing_team_id() {
  codesign -dvv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}'
}

echo "Signing app with Developer ID..."
clean_bundle_metadata
if [[ -f "$APP_BUNDLE/Contents/Helpers/$HELPER_NAME" ]]; then
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP_BUNDLE/Contents/Helpers/$HELPER_NAME"
  [[ "$(signing_team_id "$APP_BUNDLE/Contents/Helpers/$HELPER_NAME")" == "$TEAM_ID" ]] || {
    echo "Signed helper TeamIdentifier does not match TOKENFLEET_TEAM_ID." >&2
    exit 1
  }
fi
clean_bundle_metadata
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_bundle_contract "$APP_BUNDLE"
[[ "$(signing_team_id "$APP_BUNDLE")" == "$TEAM_ID" ]] || {
  echo "Signed app TeamIdentifier does not match TOKENFLEET_TEAM_ID." >&2
  exit 1
}

DMG_STAGING="$PACKAGE_WORK_DIR/dmg-staging"

echo "Creating zip..."
ditto -c -k --keepParent "$APP_BUNDLE" "$STAGED_ZIP_PATH"

submit_for_notarization() {
  local artifact="$1"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
    return
  fi

  if [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
    xcrun notarytool submit "$artifact" \
      --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER" \
      --wait
    return
  fi

  echo "Notarization credentials are missing." >&2
  echo "Set TOKENFLEET_NOTARY_PROFILE or the complete App Store Connect API-key triple." >&2
  exit 2
}

echo "Submitting zip for notarization..."
submit_for_notarization "$STAGED_ZIP_PATH"
echo "Stapling app ticket..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
echo "Recreating zip with stapled app..."
rm -f "$STAGED_ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$STAGED_ZIP_PATH"

echo "Creating dmg..."
mkdir -p "$DMG_STAGING"
ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_CREATED=false
for attempt in 1 2 3; do
  rm -f "$STAGED_DMG_PATH"
  if hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$STAGED_DMG_PATH"; then
    DMG_CREATED=true
    break
  fi
  echo "DMG creation attempt $attempt failed; retrying..." >&2
  sleep $((attempt * 3))
done

if [[ "$DMG_CREATED" != true ]]; then
  echo "DMG creation failed after 3 attempts." >&2
  exit 1
fi
echo "Signing dmg with Developer ID..."
codesign --force --timestamp --sign "$IDENTITY" "$STAGED_DMG_PATH"
codesign --verify --verbose=2 "$STAGED_DMG_PATH"

echo "Submitting dmg for notarization..."
submit_for_notarization "$STAGED_DMG_PATH"
echo "Stapling dmg ticket..."
xcrun stapler staple "$STAGED_DMG_PATH"
xcrun stapler validate "$STAGED_DMG_PATH"

echo "Validating signature..."
spctl -a -vv "$APP_BUNDLE"
spctl -a -vv -t open --context context:primary-signature "$STAGED_DMG_PATH"
ZIP_VALIDATE_DIR="$PACKAGE_WORK_DIR/zip-validate"
mkdir -p "$ZIP_VALIDATE_DIR"
ditto -x -k "$STAGED_ZIP_PATH" "$ZIP_VALIDATE_DIR"
xcrun stapler validate "$ZIP_VALIDATE_DIR/$APP_NAME.app"
verify_bundle_contract "$ZIP_VALIDATE_DIR/$APP_NAME.app"
verify_bundle_architectures "$ZIP_VALIDATE_DIR/$APP_NAME.app"

(
  cd "$ARTIFACT_STAGING"
  shasum -a 256 "$(basename "$STAGED_ZIP_PATH")" "$(basename "$STAGED_DMG_PATH")" >"$(basename "$STAGED_CHECKSUM_PATH")"
)

# Recheck immediately before publishing the entire version as one directory.
if [[ -e "$VERSION_RELEASE_DIR" ]]; then
  echo "Refusing to overwrite release directory created during packaging: $VERSION_RELEASE_DIR" >&2
  exit 2
fi

# ARTIFACT_STAGING lives inside RELEASE_DIR, so a single directory rename makes
# the complete ZIP + DMG + checksum set visible atomically.
mv -n "$ARTIFACT_STAGING" "$VERSION_RELEASE_DIR"

[[ ! -e "$ARTIFACT_STAGING" \
    && -f "$ZIP_PATH" && -f "$DMG_PATH" && -f "$CHECKSUM_PATH" ]] || {
  echo "Atomic version-directory publication did not produce the complete release set." >&2
  exit 1
}

echo
echo "Release artifacts:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
