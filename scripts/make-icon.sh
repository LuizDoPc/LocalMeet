#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/Resources/AppIcon-source.png"
MASTER="$PROJECT_DIR/Resources/AppIcon-1024.png"
ICONSET="$PROJECT_DIR/Resources/AppIcon.iconset"

magick "$SOURCE" \
    -resize 1024x1024! \
    \( +clone -alpha transparent -fill white -draw 'roundrectangle 32,32 992,992 215,215' \) \
    -alpha off -compose CopyOpacity -composite \
    "$MASTER"

if [[ -d "$ICONSET" ]]; then
    mv "$ICONSET" "/tmp/LocalMeet-AppIcon-previous-$(date +%s).iconset"
fi
mkdir -p "$ICONSET"

sips -z 16 16 "$MASTER" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$MASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$MASTER" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$MASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/Resources/AppIcon.icns"
echo "$PROJECT_DIR/Resources/AppIcon.icns"
