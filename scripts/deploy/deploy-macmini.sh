#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
APP_PATH="${1:-$ROOT/.build/DerivedData/PrinterBridge/Build/Products/Debug/PrinterBridge.app}"
REMOTE_PATH="${2:-Applications/PrinterBridge/}"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found at: $APP_PATH" >&2
  echo "Build the app first with ./scripts/dev/build-macos.sh" >&2
  exit 1
fi

ssh macmini "mkdir -p \"\$HOME/$REMOTE_PATH\""
scp -r "$APP_PATH" "macmini:$REMOTE_PATH"
