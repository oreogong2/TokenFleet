#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/TokenStepSwift"
TEST_ARCHITECTURE="${TOKENFLEET_SWIFT_TEST_ARCHITECTURE:-$(uname -m)}"
if [[ "$TEST_ARCHITECTURE" != "arm64" && "$TEST_ARCHITECTURE" != "x86_64" ]]; then
  echo "Unsupported collector fixture architecture: $TEST_ARCHITECTURE" >&2
  exit 1
fi
SWIFT_TARGET="$TEST_ARCHITECTURE-apple-macos14.0"
BUILD_DIR="/tmp/tokenstep-codex-cumulative-fixture-$UID-$$"
OVERLAY_DIR="$BUILD_DIR/vfs-overlay"
OVERLAY_FILE="$OVERLAY_DIR/overlay.yaml"
EMPTY_MODULEMAP="$OVERLAY_DIR/empty.modulemap"
EXECUTABLE="$BUILD_DIR/codex-cumulative-fixture-check"
MODULE_DIR="$BUILD_DIR/module"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

python3 "$ROOT_DIR/script/audit_codex_accounting.py" --self-test

mkdir -p "$BUILD_DIR" "$OVERLAY_DIR" "$MODULE_DIR"
cat > "$EMPTY_MODULEMAP" <<'EOF'
// Intentionally empty.
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

swiftc \
  -target "$SWIFT_TARGET" \
  -vfsoverlay "$OVERLAY_FILE" \
  -Xcc -ivfsoverlay \
  -Xcc "$OVERLAY_FILE" \
  -parse-as-library \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/AppPaths.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/Localization.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/Theme.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/TokenPricing.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Models/UsageModels.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/CursorUsageCSVParser.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/UsageCollector.swift" \
  "$SWIFT_DIR/Tests/Fixtures/CodexCumulativeFixtureCheck.swift" \
  -o "$EXECUTABLE"

"$EXECUTABLE"

# SwiftPM manifest linking is broken on some CommandLineTools-only machines.
# The standalone fixture above executes the assertions; this additional pass
# still type-checks the XCTest coverage that CI runs with a complete toolchain.
if printf '%s\n' 'import XCTest' | swiftc -typecheck - >/dev/null 2>&1; then
  swiftc \
    -target "$SWIFT_TARGET" \
    -vfsoverlay "$OVERLAY_FILE" \
    -Xcc -ivfsoverlay \
    -Xcc "$OVERLAY_FILE" \
    -parse-as-library \
    -enable-testing \
    -emit-module \
    -module-name TokenStepSwift \
    "$SWIFT_DIR/Sources/TokenStepSwift/Support/AppPaths.swift" \
    "$SWIFT_DIR/Sources/TokenStepSwift/Support/Localization.swift" \
    "$SWIFT_DIR/Sources/TokenStepSwift/Support/Theme.swift" \
    "$SWIFT_DIR/Sources/TokenStepSwift/Support/TokenPricing.swift" \
    "$SWIFT_DIR/Sources/TokenStepSwift/Models/UsageModels.swift" \
    "$SWIFT_DIR/Sources/TokenStepSwift/Services/CursorUsageCSVParser.swift" \
    "$SWIFT_DIR/Sources/TokenStepSwift/Services/UsageCollector.swift" \
    -emit-module-path "$MODULE_DIR/TokenStepSwift.swiftmodule"

  swiftc \
    -target "$SWIFT_TARGET" \
    -vfsoverlay "$OVERLAY_FILE" \
    -Xcc -ivfsoverlay \
    -Xcc "$OVERLAY_FILE" \
    -typecheck \
    -I "$MODULE_DIR" \
    "$SWIFT_DIR/Tests/TokenStepSwiftTests/UsageCollectorCodexTests.swift"

  echo "UsageCollectorCodexTests XCTest source type-check passed"
else
  echo "XCTest type-check skipped: active CommandLineTools has no XCTest module"
fi
