#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
APP_DIR="$REPO_DIR/build/Cappy.app"
CONTENTS="$APP_DIR/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
APP_ICON="$REPO_DIR/Sources/Clients/MacApp/Resources/Cappy.icns"
SPARKLE_LICENSE="$REPO_DIR/.build/artifacts/sparkle/Sparkle/LICENSE"
SOURCE_VERSION="$(sed -n 's/^public let quotaReleaseVersion = "\([^"]*\)"$/\1/p' "$REPO_DIR/Sources/QuotaContracts/Models.swift")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/macos/Info.plist")"
PLIST_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$REPO_DIR/macos/Info.plist")"
BUILD_ARGUMENTS=(-c release)
SIGNING_IDENTITY="${CAPPY_CODESIGN_IDENTITY:--}"
SIGNING_KEYCHAIN="${CAPPY_CODESIGN_KEYCHAIN:-}"
ENABLE_SOFTWARE_UPDATES="${CAPPY_ENABLE_SOFTWARE_UPDATES:-0}"
if [[ -n "${CAPPY_BUILD_TRIPLE:-}" ]]; then
    BUILD_ARGUMENTS+=(--triple "$CAPPY_BUILD_TRIPLE")
fi

if [[ -z "$SOURCE_VERSION" || "$SOURCE_VERSION" != "$PLIST_VERSION" ]]; then
    echo "Release version mismatch between Models.swift and Info.plist" >&2
    exit 1
fi

if [[ ! -f "$APP_ICON" ]]; then
    echo "Missing application icon. Run scripts/build-app-icon.sh first." >&2
    exit 1
fi

if [[ "$PLIST_ICON" != "${APP_ICON:t}" ]]; then
    echo "Info.plist CFBundleIconFile does not match the packaged application icon." >&2
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
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources" "$FRAMEWORKS"
cp -f "$RELEASE_DIR/CappyMenu" "$CONTENTS/MacOS/Cappy"
cp -f "$RELEASE_DIR/quota-appserver" "$CONTENTS/Helpers/quota-appserver"
cp -f "$RELEASE_DIR/quota-adapter-codex" "$CONTENTS/Helpers/quota-adapter-codex"
cp -f "$RELEASE_DIR/quota-adapter-claude" "$CONTENTS/Helpers/quota-adapter-claude"
cp -f "$RELEASE_DIR/quota" "$CONTENTS/Helpers/quota"
cp -f "$REPO_DIR/macos/Info.plist" "$CONTENTS/Info.plist"
cp -f "$APP_ICON" "$CONTENTS/Resources/Cappy.icns"
cp -f "$REPO_DIR/Sources/Clients/MacApp/Resources/ProviderCodex.png" "$CONTENTS/Resources/ProviderCodex.png"
cp -f "$REPO_DIR/Sources/Clients/MacApp/Resources/ProviderClaude.svg" "$CONTENTS/Resources/ProviderClaude.svg"
if [[ ! -d "$RELEASE_DIR/Sparkle.framework" ]]; then
    echo "The Swift build did not produce Sparkle.framework." >&2
    exit 1
fi
if [[ ! -f "$SPARKLE_LICENSE" ]]; then
    echo "The resolved Sparkle package is missing its license." >&2
    exit 1
fi
/usr/bin/ditto "$RELEASE_DIR/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"
cp -f "$SPARKLE_LICENSE" "$CONTENTS/Resources/Sparkle-LICENSE.txt"
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Cappy"

chmod 0755 "$CONTENTS/MacOS/Cappy" "$CONTENTS/Helpers/"*
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    if [[ "$ENABLE_SOFTWARE_UPDATES" == "1" ]]; then
        echo "Automatic updates require a Developer ID signed release bundle." >&2
        exit 1
    fi
    SIGNING_ARGUMENTS=(--force --sign - --timestamp=none)
else
    SIGNING_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
    if [[ -n "$SIGNING_KEYCHAIN" ]]; then
        SIGNING_ARGUMENTS+=(--keychain "$SIGNING_KEYCHAIN")
    fi

    if [[ "$ENABLE_SOFTWARE_UPDATES" == "1" ]]; then
        PUBLIC_UPDATE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$CONTENTS/Info.plist")"
        if [[ -z "$PUBLIC_UPDATE_KEY" || "$PUBLIC_UPDATE_KEY" == "CAPPY_SPARKLE_PUBLIC_KEY" ]]; then
            echo "The release bundle is missing Cappy's Sparkle public key." >&2
            exit 1
        fi
        /usr/libexec/PlistBuddy -c 'Set :CappyEnableSoftwareUpdates true' "$CONTENTS/Info.plist"
    fi
fi
for executable in "$CONTENTS/MacOS/Cappy" "$CONTENTS/Helpers/"*; do
    strip -S "$executable"
    codesign "${SIGNING_ARGUMENTS[@]}" "$executable" >/dev/null
done
SPARKLE_VERSION_DIR="$FRAMEWORKS/Sparkle.framework/Versions/B"
codesign "${SIGNING_ARGUMENTS[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" >/dev/null
codesign "${SIGNING_ARGUMENTS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" >/dev/null
codesign "${SIGNING_ARGUMENTS[@]}" "$SPARKLE_VERSION_DIR/Autoupdate" >/dev/null
codesign "${SIGNING_ARGUMENTS[@]}" "$SPARKLE_VERSION_DIR/Updater.app" >/dev/null
codesign "${SIGNING_ARGUMENTS[@]}" "$FRAMEWORKS/Sparkle.framework" >/dev/null
codesign "${SIGNING_ARGUMENTS[@]}" "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"
"$CONTENTS/MacOS/Cappy" --render-preview "$REPO_DIR/docs/preview.png"
echo "$APP_DIR"
