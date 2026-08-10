#!/usr/bin/env bash

# Synthetic stable-signing fixture for source-install state-machine tests.
# Callers must enforce TOKENFLEET_SOURCE_TEST_MODE=1 and isolated, non-symlinked
# /private/tmp install/state roots before sourcing this file. Production code
# must never route through these helpers.

TOKENFLEET_SOURCE_TEST_SIGNER_MARKER="TokenFleetSyntheticSignerSHA1.test-only"

tokenfleet_source_test_sign_stable_app() {
  local app="$1" identity_hash="$2" marker
  [[ -d "$app" && ! -L "$app" \
      && ${#identity_hash} -eq 40 \
      && "$identity_hash" =~ ^[0-9A-F]+$ ]] || return 1
  marker="$app/Contents/Resources/$TOKENFLEET_SOURCE_TEST_SIGNER_MARKER"
  printf '%s\n' "$identity_hash" >"$marker" || return 1
  chmod 600 "$marker" || return 1
  tokenfleet_source_sign_adhoc_app "$app"
}

tokenfleet_source_test_app_certificate_sha1() {
  local app="$1" marker fingerprint
  marker="$app/Contents/Resources/$TOKENFLEET_SOURCE_TEST_SIGNER_MARKER"
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  fingerprint="$(/usr/bin/tr -d '[:space:]' <"$marker")" || return 1
  [[ ${#fingerprint} -eq 40 && "$fingerprint" =~ ^[0-9A-F]+$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

tokenfleet_source_test_verify_stable_app() {
  local app="$1" expected_origin="$2" expected_hash="$3" actual_hash signature
  [[ "$(tokenfleet_source_plist_value "$app" CFBundleIdentifier)" == "$TOKENFLEET_SOURCE_BUNDLE_ID" ]] || return 1
  [[ "$(tokenfleet_source_plist_value "$app" TokenFleetCredentialBackend)" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]] || return 1
  [[ "$(tokenfleet_source_plist_value "$app" TokenFleetCommunityServerURL)" == "$expected_origin" ]] || return 1
  [[ -z "$(tokenfleet_source_plist_value "$app" TokenFleetDeveloperTeamID)" ]] || return 1
  [[ -z "$(tokenfleet_source_plist_value "$app" TokenFleetUpdateAPIURL)" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)" || return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Fq "Identifier=$TOKENFLEET_SOURCE_BUNDLE_ID" || return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Eq '(^|[=(,])adhoc([,)]|$)' || return 1
  actual_hash="$(tokenfleet_source_test_app_certificate_sha1 "$app")" || return 1
  [[ "$actual_hash" == "$expected_hash" ]] || return 1
  tokenfleet_source_assert_no_entitlements "$app"
}
