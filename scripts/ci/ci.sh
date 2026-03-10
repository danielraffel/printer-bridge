#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"

"$ROOT/scripts/dev/test-core.sh"
"$ROOT/scripts/dev/build-macos.sh"
"$ROOT/scripts/dev/build-cli.sh"
"$ROOT/.build/bin/PrinterBridgeCLI" smoke-test
