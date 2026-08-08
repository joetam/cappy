#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
APP_DIR="$REPO_DIR/build/Cappy.app"
CONTENTS="$APP_DIR/Contents"
SOURCE_VERSION="$(sed -n 's/^public let quotaReleaseVersion = "\([^"]*\)"$/\1/p' "$REPO_DIR/Sources/QuotaContracts/Models.swift")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/macos/Info.plist")"
BUILD_ARGUMENTS=(-c release)
SIGNING_IDENTITY="${CAPPY_CODESIGN_IDENTITY:--}"
SIGNING_KEYCHAIN="${CAPPY_CODESIGN_KEYCHAIN:-}"
if [[ -n "${CAPPY_BUILD_TRIPLE:-}" ]]; then
    BUILD_ARGUMENTS+=(--triple "$CAPPY_BUILD_TRIPLE")
fi

if [[ -z "$SOURCE_VERSION" || "$SOURCE_VERSION" != "$PLIST_VERSION" ]]; then
    echo "Release version mismatch between Models.swift and Info.plist" >&2
    exit 1
fi

cd "$REPO_DIR"
swift build "${BUILD_ARGUMENTS[@]}"
RELEASE_DIR="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"

if [[ "$APP_DIR" != "$REPO_DIR/build/Cappy.app" ]]; then
    echo "Refusing to clean an unexpected app path: $APP_DIR" >&2
    exit 1
fi
rm -rf -- "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp -f "$RELEASE_DIR/CappyMenu" "$CONTENTS/MacOS/Cappy"
cp -f "$RELEASE_DIR/quota-appserver" "$CONTENTS/Helpers/quota-appserver"
cp -f "$RELEASE_DIR/quota-adapter-codex" "$CONTENTS/Helpers/quota-adapter-codex"
cp -f "$RELEASE_DIR/quota-adapter-claude" "$CONTENTS/Helpers/quota-adapter-claude"
cp -f "$RELEASE_DIR/quota" "$CONTENTS/Helpers/quota"
cp -f "$REPO_DIR/macos/Info.plist" "$CONTENTS/Info.plist"
cp -f "$REPO_DIR/Sources/Clients/MacApp/Resources/ProviderCodex.png" "$CONTENTS/Resources/ProviderCodex.png"
cp -f "$REPO_DIR/Sources/Clients/MacApp/Resources/ProviderClaude.svg" "$CONTENTS/Resources/ProviderClaude.svg"

chmod 0755 "$CONTENTS/MacOS/Cappy" "$CONTENTS/Helpers/"*
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_ARGUMENTS=(--force --sign - --timestamp=none)
else
    SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
    if [[ -n "$SIGNING_KEYCHAIN" ]]; then
        SIGNING_ARGUMENTS+=(--keychain "$SIGNING_KEYCHAIN")
    fi
fi
for executable in "$CONTENTS/MacOS/Cappy" "$CONTENTS/Helpers/"*; do
    strip -S "$executable"
    codesign "${SIGNING_ARGUMENTS[@]}" "$executable" >/dev/null
done
codesign "${SIGNING_ARGUMENTS[@]}" "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"
"$CONTENTS/MacOS/Cappy" --render-preview "$REPO_DIR/docs/preview.png"
echo "$APP_DIR"
