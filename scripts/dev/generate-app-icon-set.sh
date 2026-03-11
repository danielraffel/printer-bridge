#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
SOURCE_IMAGE="${1:-$ROOT/assets/branding/printerbridge-app-icon-master.png}"
APP_ICON_SET_DIR="$ROOT/apps/macos/PrinterBridgeApp/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE_IMAGE" ]; then
  echo "Icon source image not found at: $SOURCE_IMAGE" >&2
  exit 1
fi

mkdir -p "$APP_ICON_SET_DIR"

generate_icon() {
  size="$1"
  name="$2"
  sips -z "$size" "$size" "$SOURCE_IMAGE" --out "$APP_ICON_SET_DIR/$name" >/dev/null
}

generate_icon 16 icon_16x16.png
generate_icon 32 icon_16x16@2x.png
generate_icon 32 icon_32x32.png
generate_icon 64 icon_32x32@2x.png
generate_icon 128 icon_128x128.png
generate_icon 256 icon_128x128@2x.png
generate_icon 256 icon_256x256.png
generate_icon 512 icon_256x256@2x.png
generate_icon 512 icon_512x512.png
generate_icon 1024 icon_512x512@2x.png
