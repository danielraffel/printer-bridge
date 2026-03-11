#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
cd "$ROOT/apps/macos"
rm -rf PrinterBridge.xcodeproj
xcodegen generate
