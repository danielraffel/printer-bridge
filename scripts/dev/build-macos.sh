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

codesign --force --deep --sign - "$OUTPUT_APP"
file "$OUTPUT_APP/Contents/MacOS/PrinterBridge"
file "$OUTPUT_DAEMON"
