#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/TokenStepSwift"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-price-catalog.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR/module-cache"
printf '// empty\n' > "$BUILD_DIR/empty.modulemap"
cat > "$BUILD_DIR/overlay.yaml" <<OVERLAY
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$BUILD_DIR/empty.modulemap"}]}
OVERLAY
swiftc -D TOKENSTEP_TESTING -parse-as-library \
  -target "${TOKENFLEET_SWIFT_TEST_ARCHITECTURE:-$(uname -m)}-apple-macosx14.0" \
  -sdk "${TOKENFLEET_SWIFT_SDK:-$(xcrun --sdk macosx --show-sdk-path)}" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -vfsoverlay "$BUILD_DIR/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$BUILD_DIR/overlay.yaml" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/AppPaths.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/Localization.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/MemoryPressure.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/Theme.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Support/TokenPricing.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Models/UsageModels.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/CursorUsageCSVParser.swift" \
  "$SWIFT_DIR/Sources/TokenStepSwift/Services/UsageCollector.swift" \
  "$SWIFT_DIR/Tests/Fixtures/ServerPriceCatalogFixtureCheck.swift" \
  -o "$BUILD_DIR/catalog-check"
mkdir -p "$BUILD_DIR/data"
TOKENFLEET_TEST_APP_SUPPORT_ROOT="$BUILD_DIR/data" "$BUILD_DIR/catalog-check" \
  "$SWIFT_DIR/Tests/Fixtures/server-price-catalog-v1.json" "$BUILD_DIR/data"
