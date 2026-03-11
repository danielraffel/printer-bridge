#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
APP_PATH="$ROOT/.build/dist/Printer Bridge.app"
PKG_PATH="${1:-$ROOT/.build/release/Printer-Bridge.pkg}"
SHA_PATH="${2:-$ROOT/.build/release/Printer-Bridge.pkg.sha256}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
TAG="v$VERSION"
TITLE="Printer Bridge $VERSION"
NOTES_FILE="$(mktemp)"

cat >"$NOTES_FILE" <<EOF
Printer Bridge $VERSION

- Signed macOS installer package for Printer Bridge
- License agreement and install notes included in the installer
- Privacy Policy: https://www.generouscorp.com/printer-bridge/legal/privacy.html
- Terms: https://www.generouscorp.com/printer-bridge/legal/terms.html

Download the installer asset below:
- Printer-Bridge.pkg
EOF

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" \
    "$PKG_PATH#Printer-Bridge.pkg" \
    "$SHA_PATH#Printer-Bridge.pkg.sha256" \
    --clobber
  gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" \
    "$PKG_PATH#Printer-Bridge.pkg" \
    "$SHA_PATH#Printer-Bridge.pkg.sha256" \
    --title "$TITLE" \
    --notes-file "$NOTES_FILE"
fi

rm -f "$NOTES_FILE"
