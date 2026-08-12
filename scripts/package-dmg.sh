#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
VERSION="$(sed -n 's/^public let quotaReleaseVersion = "\([^"]*\)"$/\1/p' "$REPO_DIR/Sources/QuotaContracts/Models.swift")"
ARCH="${CAPPY_RELEASE_ARCH:-$(uname -m)}"
APP_DIR="$REPO_DIR/build/Cappy.app"
DIST_DIR="$REPO_DIR/dist"
OUTPUT_DMG="$DIST_DIR/Cappy-$VERSION-macos-$ARCH.dmg"
BACKGROUND="$REPO_DIR/build/CappyDMGBackground.png"
VOLUME_NAME="Cappy"
SIGNING_IDENTITY="${CAPPY_CODESIGN_IDENTITY:--}"
SIGNING_KEYCHAIN="${CAPPY_CODESIGN_KEYCHAIN:-}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cappy-dmg-stage.XXXXXX")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cappy-dmg-mount.XXXXXX")"
RW_DMG="$(mktemp "${TMPDIR:-/tmp}/cappy-dmg.XXXXXX").dmg"
MOUNTED=false

cleanup() {
    local exit_code=$?
    if [[ "$MOUNTED" == true ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
    fi
    rm -rf -- "$STAGING_DIR" "$MOUNT_DIR"
    rm -f -- "$RW_DMG"
    return $exit_code
}
trap cleanup EXIT

if [[ ! -d "$APP_DIR" ]]; then
    echo "Missing application bundle. Run scripts/package-app.sh first." >&2
    exit 1
fi
if [[ -z "$VERSION" || "$ARCH" != "arm64" ]]; then
    echo "Cappy DMGs currently require a versioned Apple-silicon app." >&2
    exit 1
fi

"$REPO_DIR/scripts/render-dmg-background.swift" "$BACKGROUND" >/dev/null
mkdir -p "$STAGING_DIR/.background"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/Cappy.app"
cp -f "$BACKGROUND" "$STAGING_DIR/.background/CappyDMGBackground.png"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDRW \
    -fs HFS+ \
    -ov \
    "$RW_DMG" >/dev/null
hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" \
    "$RW_DMG" >/dev/null
MOUNTED=true

/usr/bin/osascript - "$MOUNT_DIR" <<'APPLESCRIPT'
on run arguments
    set mountPath to item 1 of arguments
    set mountedFolderAlias to POSIX file mountPath as alias

    tell application "Finder"
        set mountedFolder to folder mountedFolderAlias
        set dmgWindow to make new Finder window to mountedFolder
        delay 1
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set pathbar visible of dmgWindow to false
        set the bounds of dmgWindow to {120, 120, 840, 600}
        set theViewOptions to the icon view options of dmgWindow
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:CappyDMGBackground.png" of mountedFolder
        set position of item "Cappy.app" of mountedFolder to {180, 240}
        set position of item "Applications" of mountedFolder to {540, 240}
        update mountedFolder without registering applications
        delay 2
        close dmgWindow
    end tell
end run
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=false

mkdir -p "$DIST_DIR"
rm -f -- "$OUTPUT_DMG"
hdiutil convert \
    "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$OUTPUT_DMG" >/dev/null

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --timestamp)
    if [[ -n "$SIGNING_KEYCHAIN" ]]; then
        SIGNING_ARGUMENTS+=(--keychain "$SIGNING_KEYCHAIN")
    fi
    codesign "${SIGNING_ARGUMENTS[@]}" "$OUTPUT_DMG" >/dev/null
    codesign --verify --strict "$OUTPUT_DMG"
fi

hdiutil verify "$OUTPUT_DMG" >/dev/null
echo "$OUTPUT_DMG"
