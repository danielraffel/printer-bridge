#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
CLI_PATH="${1:-$ROOT/.build/bin/PrinterBridgeCLI}"
REMOTE_PATH="${2:-bin/PrinterBridgeCLI}"

if [ ! -f "$CLI_PATH" ]; then
  echo "CLI binary not found at: $CLI_PATH" >&2
  echo "Build the CLI first with ./scripts/dev/build-cli.sh" >&2
  exit 1
fi

ssh macmini "mkdir -p \"\$HOME/$(dirname "$REMOTE_PATH")\""
scp "$CLI_PATH" "macmini:$REMOTE_PATH"
ssh macmini "chmod +x \"\$HOME/$REMOTE_PATH\""
