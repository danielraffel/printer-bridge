#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
ENV_FILE="${PRINTERBRIDGE_RELEASE_ENV_FILE:-}"
OUTPUT_DIR="$ROOT/.build/release"
OUTPUT_PKG="$OUTPUT_DIR/Printer-Bridge.pkg"
OUTPUT_SHA="$OUTPUT_DIR/Printer-Bridge.pkg.sha256"
WORK_DIR="$OUTPUT_DIR/pkg-work"
COMPONENT_PKG="$WORK_DIR/PrinterBridgeComponent.pkg"
COMPONENT_PLIST="$WORK_DIR/component.plist"
STAGING_ROOT="$WORK_DIR/root"
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

build_component_plist() {
  cat >"$COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key>
    <true/>
    <key>BundleIsRelocatable</key>
    <false/>
    <key>BundleIsVersionChecked</key>
    <true/>
    <key>BundleOverwriteAction</key>
    <string>upgrade</string>
    <key>RootRelativeBundlePath</key>
    <string>Applications/Printer Bridge.app</string>
  </dict>
</array>
</plist>
EOF
}

load_env_file
if [ "${PRINTERBRIDGE_SKIP_APP_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/dev/build-macos.sh"
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$WORK_DIR" "$OUTPUT_PKG" "$OUTPUT_SHA"
mkdir -p "$WORK_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
INSTALLER_IDENTITY="$(resolve_installer_identity || true)"

if [ -z "$INSTALLER_IDENTITY" ]; then
  echo "No Developer ID Installer identity found." >&2
  exit 1
fi

build_component_plist

mkdir -p "$STAGING_ROOT/Applications"
ditto "$APP_PATH" "$STAGING_ROOT/Applications/Printer Bridge.app"

pkgbuild \
  --root "$STAGING_ROOT" \
  --install-location / \
  --identifier com.danielraffel.printerbridge \
  --version "$VERSION" \
  --component-plist "$COMPONENT_PLIST" \
  "$COMPONENT_PKG"

build_distribution "$VERSION"

productbuild \
  --distribution "$DIST_XML" \
  --package-path "$WORK_DIR" \
  --resources "$RESOURCES_DIR" \
  --sign "$INSTALLER_IDENTITY" \
  "$OUTPUT_PKG"

if [ "${PRINTERBRIDGE_SKIP_NOTARIZATION:-0}" != "1" ]; then
  if [ -n "${PULP_NOTARY_KEY_PATH:-}" ]; then
    require_env PULP_NOTARY_KEY_ID
    require_env PULP_NOTARY_ISSUER_ID
    xcrun notarytool submit "$OUTPUT_PKG" \
      --key "$PULP_NOTARY_KEY_PATH" \
      --key-id "$PULP_NOTARY_KEY_ID" \
      --issuer "$PULP_NOTARY_ISSUER_ID" \
      --wait
  else
    require_env APPLE_ID
    require_env TEAM_ID
    require_env APP_SPECIFIC_PASSWORD
    xcrun notarytool submit "$OUTPUT_PKG" \
      --apple-id "$APPLE_ID" \
      --team-id "$TEAM_ID" \
      --password "$APP_SPECIFIC_PASSWORD" \
      --wait
  fi

  xcrun stapler staple "$OUTPUT_PKG"
fi

pkgutil --check-signature "$OUTPUT_PKG"
spctl -a -vv -t install "$OUTPUT_PKG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "Printer-Bridge.pkg" > "Printer-Bridge.pkg.sha256"
)

echo "Created installer:"
echo "  $OUTPUT_PKG"
echo "Checksum:"
echo "  $OUTPUT_SHA"
