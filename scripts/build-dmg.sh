#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_PATH="$PROJECT_DIR/dist/LocalMeet.app"
DMG_PATH="$PROJECT_DIR/dist/LocalMeet-1.1-Apple-Silicon.dmg"

"$PROJECT_DIR/scripts/build-app.sh"

STAGING_DIR="$(mktemp -d /tmp/LocalMeet-DMG.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/LocalMeet.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$PROJECT_DIR/Resources/DMG-README.txt" "$STAGING_DIR/Leia-me.txt"

if [[ -f "$DMG_PATH" ]]; then
    mv "$DMG_PATH" "/tmp/LocalMeet-previous-$(date +%s).dmg"
fi

hdiutil create \
    -volname "LocalMeet" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
echo "$DMG_PATH"
