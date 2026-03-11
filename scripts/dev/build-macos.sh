#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
DERIVED_DATA_ARM64="$ROOT/.build/DerivedData/PrinterBridgeRelease-arm64"
DERIVED_DATA_X86_64="$ROOT/.build/DerivedData/PrinterBridgeRelease-x86_64"
OUTPUT_DIR="$ROOT/.build/dist"
OUTPUT_APP="$OUTPUT_DIR/PrinterBridge.app"
ARM64_APP="$DERIVED_DATA_ARM64/Build/Products/Release/PrinterBridge.app"
X86_64_APP="$DERIVED_DATA_X86_64/Build/Products/Release/PrinterBridge.app"
ARM64_DAEMON="$DERIVED_DATA_ARM64/Build/Products/Release/PrinterBridgeDaemon"
X86_64_DAEMON="$DERIVED_DATA_X86_64/Build/Products/Release/PrinterBridgeDaemon"
OUTPUT_DAEMON="$OUTPUT_APP/Contents/Resources/PrinterBridgeDaemon"

resolve_codesign_identity() {
  if [ -n "${PRINTERBRIDGE_CODESIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$PRINTERBRIDGE_CODESIGN_IDENTITY"
    return 0
  fi

  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1
}

"$ROOT/scripts/dev/generate-app-icon-set.sh"
"$ROOT/scripts/dev/generate-xcode-project.sh"

rm -rf "$DERIVED_DATA_ARM64" "$DERIVED_DATA_X86_64" "$OUTPUT_APP"
mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -project "$ROOT/apps/macos/PrinterBridge.xcodeproj" \
  -scheme PrinterBridge \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_ARM64" \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build

xcodebuild \
  -project "$ROOT/apps/macos/PrinterBridge.xcodeproj" \
  -scheme PrinterBridge \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_X86_64" \
  -arch x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  build

ditto "$ARM64_APP" "$OUTPUT_APP"

lipo \
  -create \
  "$ARM64_APP/Contents/MacOS/PrinterBridge" \
  "$X86_64_APP/Contents/MacOS/PrinterBridge" \
  -output "$OUTPUT_APP/Contents/MacOS/PrinterBridge"

lipo \
  -create \
  "$ARM64_DAEMON" \
  "$X86_64_DAEMON" \
  -output "$OUTPUT_DAEMON"

chmod 755 "$OUTPUT_DAEMON"

SIGNING_IDENTITY="$(resolve_codesign_identity || true)"
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "🔏 Signing with: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$OUTPUT_DAEMON"
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp "$OUTPUT_APP"
else
  echo "⚠️  No Developer ID identity found; falling back to ad hoc signing."
  codesign --force --sign - "$OUTPUT_DAEMON"
  codesign --force --deep --sign - "$OUTPUT_APP"
fi

file "$OUTPUT_APP/Contents/MacOS/PrinterBridge"
file "$OUTPUT_DAEMON"
