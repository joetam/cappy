#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
MASTER_ICON="$REPO_DIR/Sources/Clients/MacApp/Resources/CappyIcon-1024.png"
OUTPUT_ICON="$REPO_DIR/Sources/Clients/MacApp/Resources/Cappy.icns"
ICONSET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cappy-iconset.XXXXXX")"
trap 'rm -rf -- "$ICONSET_DIR"' EXIT

if [[ "$(sips -g pixelWidth "$MASTER_ICON" | awk '/pixelWidth/ { print $2 }')" != "1024" \
    || "$(sips -g pixelHeight "$MASTER_ICON" | awk '/pixelHeight/ { print $2 }')" != "1024" ]]; then
    echo "CappyIcon-1024.png must be exactly 1024x1024." >&2
    exit 1
fi

# Supply full-bleed square artwork and let macOS apply its platform mask. A
# pre-masked transparent icon is treated as legacy artwork on macOS 26 and gets
# inset onto a gray fallback plate.
if [[ "$(sips -g hasAlpha "$MASTER_ICON" | awk '/hasAlpha/ { print $2 }')" != "no" ]]; then
    echo "CappyIcon-1024.png must be opaque, full-bleed artwork without an alpha channel." >&2
    exit 1
fi

mkdir -p "$ICONSET_DIR/Cappy.iconset"
for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    size="${specification%% *}"
    filename="${specification#* }"
    sips -z "$size" "$size" "$MASTER_ICON" \
        --out "$ICONSET_DIR/Cappy.iconset/$filename" >/dev/null
done

iconutil -c icns "$ICONSET_DIR/Cappy.iconset" -o "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
