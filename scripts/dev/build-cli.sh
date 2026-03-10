#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
DERIVED_DATA_ARM64="$ROOT/.build/DerivedData/PrinterBridgeCLI-arm64"
DERIVED_DATA_X86_64="$ROOT/.build/DerivedData/PrinterBridgeCLI-x86_64"
OUTPUT_DIR="$ROOT/.build/bin"
OUTPUT_PATH="$OUTPUT_DIR/PrinterBridgeCLI"

"$ROOT/scripts/dev/generate-xcode-project.sh"

rm -rf "$DERIVED_DATA_ARM64" "$DERIVED_DATA_X86_64"
mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -project "$ROOT/apps/macos/PrinterBridge.xcodeproj" \
  -scheme PrinterBridgeCLI \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_ARM64" \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build

xcodebuild \
  -project "$ROOT/apps/macos/PrinterBridge.xcodeproj" \
  -scheme PrinterBridgeCLI \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_X86_64" \
  -arch x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  build

lipo \
  -create \
  "$DERIVED_DATA_ARM64/Build/Products/Debug/PrinterBridgeCLI" \
  "$DERIVED_DATA_X86_64/Build/Products/Debug/PrinterBridgeCLI" \
  -output "$OUTPUT_PATH"

codesign --force --sign - "$OUTPUT_PATH"
lipo -info "$OUTPUT_PATH"
