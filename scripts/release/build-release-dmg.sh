#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
ENV_FILE="${PRINTERBRIDGE_RELEASE_ENV_FILE:-}"
OUTPUT_DIR="$ROOT/.build/release"
OUTPUT_DMG="$OUTPUT_DIR/Printer-Bridge.dmg"
OUTPUT_SHA="$OUTPUT_DIR/Printer-Bridge.dmg.sha256"
TEMP_DMG="$OUTPUT_DIR/Printer-Bridge-rw.dmg"
STAGING_DIR="$OUTPUT_DIR/dmg-root"
INSTALLER_SOURCE="$OUTPUT_DIR/Printer-Bridge.pkg"
INSTALLER_DISPLAY_NAME="Install Printer Bridge.pkg"
UNINSTALL_SOURCE="$ROOT/packaging/macos/Uninstall Printer Bridge.command"
UNINSTALL_DISPLAY_NAME="Uninstall Printer Bridge.command"
VOLUME_NAME="Printer Bridge"
WINDOW_LEFT=140
WINDOW_TOP=140
WINDOW_RIGHT=940
WINDOW_BOTTOM=520
INSTALLER_X=190
INSTALLER_Y=190
UNINSTALL_X=620
UNINSTALL_Y=190

load_env_file() {
  if [ -n "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a && . "$ENV_FILE" && set +a
  fi
}

resolve_codesign_identity() {
  if [ -n "${PRINTERBRIDGE_CODESIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$PRINTERBRIDGE_CODESIGN_IDENTITY"
    return 0
  fi

  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1
}

require_env() {
  name="$1"
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

detach_if_mounted() {
  if mount | grep -q "on /Volumes/${VOLUME_NAME} "; then
    hdiutil detach "/Volumes/${VOLUME_NAME}" >/dev/null
  fi
}

configure_finder_window() {
  osascript <<EOF
tell application "Finder"
  tell disk "${VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {${WINDOW_LEFT}, ${WINDOW_TOP}, ${WINDOW_RIGHT}, ${WINDOW_BOTTOM}}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 104
    set text size of theViewOptions to 13
    set position of item "${INSTALLER_DISPLAY_NAME}" of container window to {${INSTALLER_X}, ${INSTALLER_Y}}
    set position of item "${UNINSTALL_DISPLAY_NAME}" of container window to {${UNINSTALL_X}, ${UNINSTALL_Y}}
    update without registering applications
    delay 2
    close
    open
    delay 1
  end tell
end tell
EOF
}

load_env_file
if [ "${PRINTERBRIDGE_SKIP_PKG_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/release/build-release-pkg.sh"
fi

rm -rf "$STAGING_DIR" "$TEMP_DMG" "$OUTPUT_DMG" "$OUTPUT_SHA"
mkdir -p "$OUTPUT_DIR" "$STAGING_DIR"

cp "$INSTALLER_SOURCE" "$STAGING_DIR/$INSTALLER_DISPLAY_NAME"
cp "$UNINSTALL_SOURCE" "$STAGING_DIR/$UNINSTALL_DISPLAY_NAME"
chmod 755 "$STAGING_DIR/$UNINSTALL_DISPLAY_NAME"

detach_if_mounted || true

hdiutil create \
  -ov \
  -size 80m \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  "$TEMP_DMG" >/dev/null

hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" >/dev/null
cp -R "$STAGING_DIR/." "/Volumes/${VOLUME_NAME}/"
sync
configure_finder_window
hdiutil detach "/Volumes/${VOLUME_NAME}" >/dev/null

hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" >/dev/null
rm -f "$TEMP_DMG"

SIGNING_IDENTITY="$(resolve_codesign_identity || true)"
if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" "$OUTPUT_DMG"
fi

if [ "${PRINTERBRIDGE_SKIP_NOTARIZATION:-0}" != "1" ]; then
  require_env APPLE_ID
  require_env TEAM_ID
  require_env APP_SPECIFIC_PASSWORD

  xcrun notarytool submit "$OUTPUT_DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple "$OUTPUT_DMG"
fi

spctl -a -vv -t open --context context:primary-signature "$OUTPUT_DMG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "Printer-Bridge.dmg" > "Printer-Bridge.dmg.sha256"
)

echo "Created disk image:"
echo "  $OUTPUT_DMG"
echo "Checksum:"
echo "  $OUTPUT_SHA"
