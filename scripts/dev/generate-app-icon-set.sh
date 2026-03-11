#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
SOURCE_IMAGE="${1:-$ROOT/assets/branding/printerbridge-airprint-app-icon-master.png}"
APP_ICON_SET_DIR="$ROOT/apps/macos/PrinterBridgeApp/Resources/Assets.xcassets/AppIcon.appiconset"
GENERATED_DIR="$ROOT/assets/branding/generated"
RENDERED_IMAGE="$GENERATED_DIR/printerbridge-app-icon-rendered.png"
PREVIEW_IMAGE="$GENERATED_DIR/printerbridge-app-icon-preview.png"

if [ ! -f "$SOURCE_IMAGE" ]; then
  echo "Icon source image not found at: $SOURCE_IMAGE" >&2
  exit 1
fi

mkdir -p "$APP_ICON_SET_DIR"
mkdir -p "$GENERATED_DIR"

python3 - "$SOURCE_IMAGE" "$RENDERED_IMAGE" "$PREVIEW_IMAGE" <<'PY'
from pathlib import Path
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageOps

source_path = Path(sys.argv[1])
rendered_path = Path(sys.argv[2])
preview_path = Path(sys.argv[3])

canvas_size = 1024
tile_inset = 60
tile_size = canvas_size - (tile_inset * 2)
corner_radius = 210
shadow_offset_y = 18
shadow_blur = 28
shadow_opacity = 92

source = Image.open(source_path).convert("RGBA")

tile_image = ImageOps.fit(source, (tile_size, tile_size), method=Image.Resampling.LANCZOS, centering=(0.5, 0.5))

mask = Image.new("L", (tile_size, tile_size), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.rounded_rectangle((0, 0, tile_size - 1, tile_size - 1), radius=corner_radius, fill=255)

rounded_tile = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
rounded_tile.paste(tile_image, (0, 0), mask)

canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

shadow = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, shadow_opacity))
shadow.putalpha(mask)
shadow = shadow.filter(ImageFilter.GaussianBlur(radius=shadow_blur))

tile_origin = ((canvas_size - tile_size) // 2, (canvas_size - tile_size) // 2)
shadow_origin = (tile_origin[0], tile_origin[1] + shadow_offset_y)

canvas.alpha_composite(shadow, shadow_origin)
canvas.alpha_composite(rounded_tile, tile_origin)

canvas.save(rendered_path)
canvas.save(preview_path)
PY

generate_icon() {
  size="$1"
  name="$2"
  sips -z "$size" "$size" "$RENDERED_IMAGE" --out "$APP_ICON_SET_DIR/$name" >/dev/null
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

echo "Preview written to: $PREVIEW_IMAGE"
