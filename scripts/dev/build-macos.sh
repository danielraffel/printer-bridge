#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
DERIVED_DATA="$ROOT/.build/DerivedData/PrinterBridge"

"$ROOT/scripts/dev/generate-xcode-project.sh"

xcodebuild \
  -project "$ROOT/apps/macos/PrinterBridge.xcodeproj" \
  -scheme PrinterBridge \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  ONLY_ACTIVE_ARCH=YES \
  build
