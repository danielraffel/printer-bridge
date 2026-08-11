#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
APP_PATH="$ROOT/.build/dist/Printer Bridge.app"
PKG_PATH="${1:-$ROOT/.build/release/Printer-Bridge.pkg}"
SHA_PATH="${2:-$ROOT/.build/release/Printer-Bridge.pkg.sha256}"
Dmg_PATH_DEFAULT="$ROOT/.build/release/Printer-Bridge.dmg"
DMG_PATH="${3:-$Dmg_PATH_DEFAULT}"
DMG_SHA_PATH="${4:-$ROOT/.build/release/Printer-Bridge.dmg.sha256}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
TAG="v$VERSION"
TITLE="Printer Bridge $VERSION"
NOTES_FILE="$(mktemp)"
if command -v ghapp >/dev/null 2>&1; then
  GH_CLI="ghapp"
else
  GH_CLI="gh"
fi
UPLOAD_ARGS="
$PKG_PATH#Printer-Bridge.pkg
$SHA_PATH#Printer-Bridge.pkg.sha256
"

if [ -f "$DMG_PATH" ] && [ -f "$DMG_SHA_PATH" ]; then
  UPLOAD_ARGS="${UPLOAD_ARGS}
$DMG_PATH#Printer-Bridge.dmg
$DMG_SHA_PATH#Printer-Bridge.dmg.sha256
"
fi

cat >"$NOTES_FILE" <<EOF
Printer Bridge $VERSION

- Fixes an IPP proxy stall that could leave iPhone print jobs cycling between Waiting and Printing
- Prevents slow CUPS capability checks from blocking unrelated print requests
- Signed macOS installer package for Printer Bridge
- Signed disk image with installer and uninstall command
- License agreement and install notes included in the installer
- Privacy Policy: https://www.generouscorp.com/printer-bridge/legal/privacy.html
- Terms: https://www.generouscorp.com/printer-bridge/legal/terms.html

Download assets:
- Printer-Bridge.dmg
- Printer-Bridge.pkg
EOF

if "$GH_CLI" release view "$TAG" >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  "$GH_CLI" release upload "$TAG" \
    $UPLOAD_ARGS \
    --clobber
  "$GH_CLI" release edit "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE"
else
  # shellcheck disable=SC2086
  "$GH_CLI" release create "$TAG" \
    $UPLOAD_ARGS \
    --title "$TITLE" \
    --notes-file "$NOTES_FILE"
fi

rm -f "$NOTES_FILE"
