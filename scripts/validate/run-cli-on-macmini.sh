#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  set -- overview
fi

ARGS=""
for arg in "$@"; do
  escaped=$(printf "%s" "$arg" | sed "s/'/'\\\\''/g")
  ARGS="$ARGS '$escaped'"
done

ssh macmini "export PATH=\"\$HOME/bin:\$PATH\"; \"\$HOME/bin/PrinterBridgeCLI\"$ARGS"
