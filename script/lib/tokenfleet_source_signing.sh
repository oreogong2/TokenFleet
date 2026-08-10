#!/usr/bin/env bash

# Shared helpers for TokenFleet's zero-fee, per-Mac source distribution path.
# This file is sourced by installer/test scripts; it intentionally performs no
# action on its own.

TOKENFLEET_SOURCE_BUNDLE_ID="com.lingdong.TokenFleet"
TOKENFLEET_SOURCE_IDENTITY_CN="TokenFleet Local Source Signing (com.lingdong.TokenFleet)"
TOKENFLEET_SOURCE_BACKEND_ENABLED="file-login-v1"
TOKENFLEET_SOURCE_BACKEND_DISABLED="disabled"

tokenfleet_source_error() {
  echo "TokenFleet source distribution: $*" >&2
}

tokenfleet_source_login_keychain() {
  local raw keychain expected
  raw="$(/usr/bin/security login-keychain -d user 2>/dev/null)" || raw=""
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    # Current macOS releases may return an empty login-keychain result even
    # though the user's default keychain is the regular login.keychain-db.
    # The exact path check below prevents this compatibility fallback from
    # selecting iCloud, metadata, system, or another application's keychain.
    raw="$(/usr/bin/security default-keychain -d user 2>/dev/null)" || return 1
  fi
  keychain="$raw"
  keychain="${keychain#${keychain%%[![:space:]]*}}"
  keychain="${keychain%${keychain##*[![:space:]]}}"
  keychain="${keychain#\"}"
  keychain="${keychain%\"}"
  keychain="${keychain#${keychain%%[![:space:]]*}}"
  keychain="${keychain%${keychain##*[![:space:]]}}"
  expected="$HOME/Library/Keychains/login.keychain-db"
  [[ "$keychain" == "$expected" && -f "$keychain" && ! -L "$keychain" ]] || return 1
  printf '%s\n' "$keychain"
}

tokenfleet_source_identity_hashes() {
  local keychain="$1"
  /usr/bin/security find-identity -p codesigning "$keychain" 2>/dev/null \
    | /usr/bin/awk -v expected="$TOKENFLEET_SOURCE_IDENTITY_CN" '
      {
        line = $0
        sub(/^[^"]*"/, "", line)
        sub(/".*$/, "", line)
        hash = $2
        if (line == expected && length(hash) == 40 && hash ~ /^[0-9A-Fa-f]+$/) {
          print toupper(hash)
        }
      }
    '
}

tokenfleet_source_single_identity_hash() {
  local keychain="$1" hashes count
  hashes="$(tokenfleet_source_identity_hashes "$keychain")" || return 1
  # A user-trusted self-signed certificate can be listed twice by
  # `security find-identity` with the same SHA-1 fingerprint. Deduplicate the
  # fingerprints, while still rejecting two genuinely different identities
  # that reuse TokenFleet's exact certificate label.
  hashes="$(printf '%s\n' "$hashes" | /usr/bin/awk 'NF' | /usr/bin/sort -u)"
  count="$(printf '%s\n' "$hashes" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$count" -gt 1 ]]; then
    tokenfleet_source_error "more than one exact local signing identity exists; remove the duplicate in Keychain Access before continuing"
    return 1
  fi
  [[ "$count" == "1" ]] || return 1
  printf '%s\n' "$hashes"
}

tokenfleet_source_certificate_sha1() {
  local certificate="$1" fingerprint
  fingerprint="$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 2>/dev/null)" \
    || return 1
  fingerprint="${fingerprint#*=}"
  fingerprint="${fingerprint//:/}"
  fingerprint="$(printf '%s' "$fingerprint" | /usr/bin/tr '[:lower:]' '[:upper:]')"
  [[ ${#fingerprint} -eq 40 && "$fingerprint" =~ ^[0-9A-F]+$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

tokenfleet_source_export_identity_certificate() {
  local keychain="$1" expected_fingerprint="$2" output="$3" actual_fingerprint
  [[ "$keychain" == /* && -f "$keychain" && ! -L "$keychain" \
      && ${#expected_fingerprint} -eq 40 \
      && "$expected_fingerprint" =~ ^[0-9A-F]+$ \
      && -n "$output" && ! -e "$output" ]] || return 1
  /usr/bin/security find-certificate \
    -c "$TOKENFLEET_SOURCE_IDENTITY_CN" -p "$keychain" >"$output" || return 1
  chmod 600 "$output"
  actual_fingerprint="$(tokenfleet_source_certificate_sha1 "$output")" || return 1
  [[ "$actual_fingerprint" == "$expected_fingerprint" ]]
}

tokenfleet_source_identity_has_codesign_trust() {
  local keychain="$1" expected_fingerprint="$2" work_dir certificate
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-source-trust-check.XXXXXX")" \
    || return 1
  chmod 700 "$work_dir"
  certificate="$work_dir/certificate.pem"
  if ! tokenfleet_source_export_identity_certificate \
      "$keychain" "$expected_fingerprint" "$certificate"; then
    rm -rf -- "$work_dir"
    return 1
  fi
  if ! /usr/bin/security verify-cert \
      -c "$certificate" -p codeSign -k "$keychain" -L -l -q; then
    rm -rf -- "$work_dir"
    return 1
  fi
  rm -rf -- "$work_dir"
}

tokenfleet_source_add_user_codesign_trust() {
  local keychain="$1" expected_fingerprint="$2" certificate="$3"
  [[ "$keychain" == /* && -f "$keychain" && ! -L "$keychain" \
      && -f "$certificate" && ! -L "$certificate" ]] || return 1
  [[ "$(tokenfleet_source_certificate_sha1 "$certificate")" == "$expected_fingerprint" ]] \
    || return 1
  # Default trust-settings domain is the current user. The policy constraint
  # is codeSign only: this does not trust the certificate for TLS, S/MIME,
  # packages, software updates, or another purpose.
  /usr/bin/security add-trusted-cert \
    -r trustRoot -p codeSign -k "$keychain" "$certificate" >/dev/null || return 1
  tokenfleet_source_identity_has_codesign_trust "$keychain" "$expected_fingerprint"
}

tokenfleet_source_create_identity() {
  local keychain="$1" add_user_trust="${2:-false}"
  local work_dir private_key private_key_der certificate fingerprint imported_hash
  [[ "$add_user_trust" == "true" || "$add_user_trust" == "false" ]] || return 1
  [[ "$keychain" == /* && -f "$keychain" && ! -L "$keychain" ]] || {
    tokenfleet_source_error "the signing keychain must be an existing absolute non-symlinked file"
    return 1
  }

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-source-identity.XXXXXX")" || return 1
  chmod 700 "$work_dir"
  private_key="$work_dir/private-key.pem"
  private_key_der="$work_dir/private-key.pkcs1"
  certificate="$work_dir/certificate.pem"

  # The key exists only inside a 0700 temporary directory long enough to be
  # imported as non-extractable. It is never echoed or copied into the repo.
  if ! (
    umask 077
    /usr/bin/openssl req \
      -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
      -subj "/CN=$TOKENFLEET_SOURCE_IDENTITY_CN/O=TokenFleet Local Source Build" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,digitalSignature,keyCertSign" \
      -addext "extendedKeyUsage=codeSigning" \
      -keyout "$private_key" \
      -out "$certificate" >/dev/null 2>&1
  ); then
    rm -rf -- "$work_dir"
    tokenfleet_source_error "could not generate the local signing identity"
    return 1
  fi

  fingerprint="$(tokenfleet_source_certificate_sha1 "$certificate")" || {
    rm -rf -- "$work_dir"
    tokenfleet_source_error "could not fingerprint the generated certificate"
    return 1
  }

  if ! /usr/bin/openssl rsa \
      -in "$private_key" -outform DER -out "$private_key_der" >/dev/null 2>&1; then
    rm -rf -- "$work_dir"
    tokenfleet_source_error "could not convert the generated private key for Keychain import"
    return 1
  fi

  if [[ "$add_user_trust" == "true" ]]; then
    if ! tokenfleet_source_add_user_codesign_trust \
        "$keychain" "$fingerprint" "$certificate"; then
      /usr/bin/security remove-trusted-cert "$certificate" >/dev/null 2>&1 || true
      /usr/bin/security delete-certificate -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
      rm -rf -- "$work_dir"
      tokenfleet_source_error "could not restrict trust for the local certificate to user-level code signing"
      return 1
    fi
  elif ! /usr/bin/security add-certificates -k "$keychain" "$certificate" >/dev/null; then
    rm -rf -- "$work_dir"
    tokenfleet_source_error "Keychain rejected the local signing certificate; unlock it and retry"
    return 1
  fi

  # The unencrypted PEM is never passed through argv or stdout. Importing it
  # directly avoids putting a wrapping password in the process list. -x makes
  # the imported key non-extractable, and -T grants only codesign access.
  if ! /usr/bin/security import "$private_key_der" \
      -k "$keychain" \
      -t priv \
      -f openssl \
      -x \
      -T /usr/bin/codesign >/dev/null; then
    if [[ "$add_user_trust" == "true" ]]; then
      /usr/bin/security remove-trusted-cert "$certificate" >/dev/null 2>&1 || true
    fi
    /usr/bin/security delete-certificate -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    rm -rf -- "$work_dir"
    tokenfleet_source_error "Keychain rejected the local identity; unlock the login keychain and retry"
    return 1
  fi
  imported_hash="$(tokenfleet_source_single_identity_hash "$keychain")" || {
    /usr/bin/security delete-identity -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    /usr/bin/security delete-certificate -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    rm -rf -- "$work_dir"
    tokenfleet_source_error "the imported certificate did not form exactly one code-signing identity"
    return 1
  }
  if [[ "$imported_hash" != "$fingerprint" ]]; then
    /usr/bin/security delete-identity -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    /usr/bin/security delete-certificate -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    rm -rf -- "$work_dir"
    tokenfleet_source_error "the imported identity fingerprint changed unexpectedly"
    return 1
  fi
  if [[ "$add_user_trust" == "true" ]] \
      && ! tokenfleet_source_identity_has_codesign_trust \
        "$keychain" "$fingerprint"; then
    /usr/bin/security remove-trusted-cert "$certificate" >/dev/null 2>&1 || true
    /usr/bin/security delete-identity -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    /usr/bin/security delete-certificate -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    rm -rf -- "$work_dir"
    tokenfleet_source_error "could not restrict trust for the local identity to user-level code signing"
    return 1
  fi
  rm -rf -- "$work_dir"
  printf '%s\n' "$imported_hash"
}

tokenfleet_source_ensure_identity() {
  local keychain="$1" require_user_trust="${2:-false}" existing
  [[ "$require_user_trust" == "true" || "$require_user_trust" == "false" ]] || return 1
  if existing="$(tokenfleet_source_single_identity_hash "$keychain")"; then
    if [[ "$require_user_trust" == "true" ]] \
        && ! tokenfleet_source_identity_has_codesign_trust "$keychain" "$existing"; then
      tokenfleet_source_error "the existing local identity is not trusted for user-level code signing"
      return 1
    fi
    printf '%s\n' "$existing"
    return 0
  fi
  if [[ -n "$(tokenfleet_source_identity_hashes "$keychain")" ]]; then
    return 1
  fi
  tokenfleet_source_create_identity "$keychain" "$require_user_trust"
}

tokenfleet_source_sign_one() {
  local path="$1" identifier="$2" identity_hash="$3" keychain="$4" requirement
  requirement="=designated => identifier \"$identifier\" and certificate leaf = H\"$identity_hash\""
  /usr/bin/codesign \
    --force \
    --timestamp=none \
    --options runtime \
    --identifier "$identifier" \
    --requirements "$requirement" \
    --keychain "$keychain" \
    --sign "$identity_hash" \
    "$path"
}

tokenfleet_source_sign_stable_app() {
  local app="$1" identity_hash="$2" keychain="$3"
  local helper="$app/Contents/Helpers/TokenFleetHelper"
  [[ -d "$app" && ! -L "$app" && -x "$helper" ]] || return 1
  tokenfleet_source_sign_one \
    "$helper" \
    "$TOKENFLEET_SOURCE_BUNDLE_ID.helper" \
    "$identity_hash" \
    "$keychain"
  tokenfleet_source_sign_one \
    "$app" \
    "$TOKENFLEET_SOURCE_BUNDLE_ID" \
    "$identity_hash" \
    "$keychain"
}

tokenfleet_source_sign_adhoc_app() {
  local app="$1"
  local helper="$app/Contents/Helpers/TokenFleetHelper"
  [[ -d "$app" && ! -L "$app" && -x "$helper" ]] || return 1
  /usr/bin/codesign --force --timestamp=none \
    --identifier "$TOKENFLEET_SOURCE_BUNDLE_ID.helper" --sign - "$helper"
  /usr/bin/codesign --force --timestamp=none \
    --identifier "$TOKENFLEET_SOURCE_BUNDLE_ID" --sign - "$app"
}

tokenfleet_source_app_certificate_sha1() {
  local app="$1" identifier requirements hashes count fingerprint test_requirement
  [[ -d "$app" && ! -L "$app" ]] || return 1
  identifier="$(tokenfleet_source_plist_value "$app" CFBundleIdentifier)" || return 1
  requirements="$(/usr/bin/codesign --display --requirements - "$app" 2>&1)" \
    || return 1
  hashes="$(printf '%s\n' "$requirements" \
    | /usr/bin/sed -n 's/.*certificate leaf = H"\([0-9A-Fa-f]\{40\}\)".*/\1/p' \
    | /usr/bin/tr '[:lower:]' '[:upper:]' \
    | /usr/bin/sort -u)"
  count="$(printf '%s\n' "$hashes" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  [[ "$count" == "1" ]] || return 1
  fingerprint="$(printf '%s\n' "$hashes" | /usr/bin/awk 'NF { print; exit }')"
  test_requirement="=identifier \"$identifier\" and certificate leaf = H\"$fingerprint\""
  # macOS 26 no longer emits files for --extract-certificates on this
  # self-signed source identity. An external -R requirement evaluates the
  # sealed identifier and the actual signing certificate, so a forged internal
  # designated requirement cannot satisfy this check.
  /usr/bin/codesign --verify --strict -R "$test_requirement" "$app" >/dev/null 2>&1 \
    || return 1
  printf '%s\n' "$fingerprint"
}

tokenfleet_source_plist_value() {
  local app="$1" key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null
}

tokenfleet_source_assert_no_entitlements() {
  local app="$1" work_dir entitlements
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-source-entitlements.XXXXXX")" || return 1
  chmod 700 "$work_dir"
  entitlements="$work_dir/entitlements.plist"
  /usr/bin/codesign --display --entitlements "$entitlements" "$app" >/dev/null 2>&1 || true
  if [[ -s "$entitlements" ]]; then
    rm -rf -- "$work_dir"
    return 1
  fi
  rm -rf -- "$work_dir"
}

tokenfleet_source_verify_stable_app() {
  local app="$1" expected_origin="$2" expected_hash="$3"
  local signature requirement actual_hash
  [[ "$(tokenfleet_source_plist_value "$app" CFBundleIdentifier)" == "$TOKENFLEET_SOURCE_BUNDLE_ID" ]] || return 1
  [[ "$(tokenfleet_source_plist_value "$app" TokenFleetCredentialBackend)" == "$TOKENFLEET_SOURCE_BACKEND_ENABLED" ]] || return 1
  [[ "$(tokenfleet_source_plist_value "$app" TokenFleetCommunityServerURL)" == "$expected_origin" ]] || return 1
  [[ -z "$(tokenfleet_source_plist_value "$app" TokenFleetDeveloperTeamID)" ]] || return 1
  [[ -z "$(tokenfleet_source_plist_value "$app" TokenFleetUpdateAPIURL)" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)" || return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Fq "Identifier=$TOKENFLEET_SOURCE_BUNDLE_ID" || return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Eq '(^|[=(,])adhoc([,)]|$)' && return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Eq '(^|[=(,])linker-signed([,)]|$)' && return 1
  printf '%s\n' "$signature" | /usr/bin/grep -q '^Authority=' || return 1
  actual_hash="$(tokenfleet_source_app_certificate_sha1 "$app")" || return 1
  [[ "$actual_hash" == "$expected_hash" ]] || return 1
  requirement="$(/usr/bin/codesign --display --requirements - "$app" 2>&1)" || return 1
  printf '%s\n' "$requirement" | /usr/bin/grep -Fq "identifier \"$TOKENFLEET_SOURCE_BUNDLE_ID\"" || return 1
  printf '%s\n' "$requirement" | /usr/bin/grep -Fiq "$expected_hash" || return 1
  tokenfleet_source_assert_no_entitlements "$app"
}

tokenfleet_source_verify_adhoc_app() {
  local app="$1" signature
  [[ "$(tokenfleet_source_plist_value "$app" CFBundleIdentifier)" == "$TOKENFLEET_SOURCE_BUNDLE_ID" ]] || return 1
  [[ "$(tokenfleet_source_plist_value "$app" TokenFleetCredentialBackend)" == "$TOKENFLEET_SOURCE_BACKEND_DISABLED" ]] || return 1
  [[ -z "$(tokenfleet_source_plist_value "$app" TokenFleetCommunityServerURL)" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)" || return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Fq "Identifier=$TOKENFLEET_SOURCE_BUNDLE_ID" || return 1
  printf '%s\n' "$signature" | /usr/bin/grep -Eq '(^|[=(,])adhoc([,)]|$)' || return 1
  if tokenfleet_source_app_certificate_sha1 "$app" >/dev/null 2>&1; then
    return 1
  fi
  tokenfleet_source_assert_no_entitlements "$app"
}
