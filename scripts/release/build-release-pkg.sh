#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
ENV_FILE="${PRINTERBRIDGE_RELEASE_ENV_FILE:-}"
OUTPUT_DIR="$ROOT/.build/release"
OUTPUT_PKG="$OUTPUT_DIR/Printer-Bridge.pkg"
OUTPUT_SHA="$OUTPUT_DIR/Printer-Bridge.pkg.sha256"
WORK_DIR="$OUTPUT_DIR/pkg-work"
COMPONENT_PKG="$WORK_DIR/PrinterBridgeComponent.pkg"
DIST_XML="$WORK_DIR/distribution.xml"
RESOURCES_DIR="$ROOT/packaging/macos/resources"
APP_PATH="$ROOT/.build/dist/Printer Bridge.app"

load_env_file() {
  if [ -n "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a && . "$ENV_FILE" && set +a
  fi
}

resolve_installer_identity() {
  if [ -n "${PRINTERBRIDGE_INSTALLER_IDENTITY:-}" ]; then
    printf '%s\n' "$PRINTERBRIDGE_INSTALLER_IDENTITY"
    return 0
  fi

  security find-identity -v -p basic 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' \
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

build_distribution() {
  version="$1"
  cat >"$DIST_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Printer Bridge</title>
    <welcome file="Welcome.html"/>
    <readme file="ReadMe.html"/>
    <license file="License.html"/>
    <pkg-ref id="com.danielraffel.printerbridge"/>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.danielraffel.printerbridge"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.danielraffel.printerbridge" visible="false">
        <pkg-ref id="com.danielraffel.printerbridge"/>
    </choice>
    <pkg-ref id="com.danielraffel.printerbridge" version="$version" onConclusion="none">PrinterBridgeComponent.pkg</pkg-ref>
</installer-gui-script>
EOF
}

load_env_file
"$ROOT/scripts/dev/build-macos.sh"

mkdir -p "$OUTPUT_DIR"
rm -rf "$WORK_DIR" "$OUTPUT_PKG" "$OUTPUT_SHA"
mkdir -p "$WORK_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
INSTALLER_IDENTITY="$(resolve_installer_identity || true)"

if [ -z "$INSTALLER_IDENTITY" ]; then
  echo "No Developer ID Installer identity found." >&2
  exit 1
fi

pkgbuild \
  --component "$APP_PATH" \
  --install-location /Applications \
  --identifier com.danielraffel.printerbridge \
  --version "$VERSION" \
  "$COMPONENT_PKG"

build_distribution "$VERSION"

productbuild \
  --distribution "$DIST_XML" \
  --package-path "$WORK_DIR" \
  --resources "$RESOURCES_DIR" \
  --sign "$INSTALLER_IDENTITY" \
  "$OUTPUT_PKG"

if [ "${PRINTERBRIDGE_SKIP_NOTARIZATION:-0}" != "1" ]; then
  require_env APPLE_ID
  require_env TEAM_ID
  require_env APP_SPECIFIC_PASSWORD

  xcrun notarytool submit "$OUTPUT_PKG" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple "$OUTPUT_PKG"
fi

pkgutil --check-signature "$OUTPUT_PKG"
spctl -a -vv -t install "$OUTPUT_PKG"
shasum -a 256 "$OUTPUT_PKG" > "$OUTPUT_SHA"

echo "Created installer:"
echo "  $OUTPUT_PKG"
echo "Checksum:"
echo "  $OUTPUT_SHA"
