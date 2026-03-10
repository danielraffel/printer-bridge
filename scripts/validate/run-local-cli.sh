#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
CLI_PATH="$ROOT/.build/bin/PrinterBridgeCLI"

if [ "$#" -gt 0 ] && [ -x "$1" ]; then
  CLI_PATH="$1"
  shift
fi

if [ ! -x "$CLI_PATH" ]; then
  echo "CLI binary not found at: $CLI_PATH" >&2
  echo "Build the CLI first with ./scripts/dev/build-cli.sh" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  set -- overview
fi

"$CLI_PATH" "$@"
