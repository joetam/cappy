#!/bin/zsh
set -euo pipefail

REPO_DIR="${CAPPY_REPO_DIR:-${0:A:h:h}}"
MODELS_FILE="$REPO_DIR/Sources/QuotaContracts/Models.swift"
PLIST_FILE="$REPO_DIR/macos/Info.plist"

SOURCE_VERSION="$(sed -n 's/^public let quotaReleaseVersion = "\([^"]*\)"$/\1/p' "$MODELS_FILE")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_FILE")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_FILE")"

if [[ "$SOURCE_VERSION" != <->.<->.<-> ]]; then
    echo "Source release version is not semantic: $SOURCE_VERSION" >&2
    exit 1
fi
if [[ "$PLIST_VERSION" != "$SOURCE_VERSION" ]]; then
    echo "Source version $SOURCE_VERSION does not match Info.plist version $PLIST_VERSION." >&2
    exit 1
fi
if [[ "$BUILD_NUMBER" != <-> ]]; then
    echo "Bundle build number is not an integer: $BUILD_NUMBER" >&2
    exit 1
fi

VERSION_PARTS=("${(@s:.:)SOURCE_VERSION}")
NEXT_VERSION="${VERSION_PARTS[1]}.${VERSION_PARTS[2]}.$((VERSION_PARTS[3] + 1))"
NEXT_BUILD_NUMBER="$((BUILD_NUMBER + 1))"

sed -i '' \
    "s/^public let quotaReleaseVersion = \"$SOURCE_VERSION\"$/public let quotaReleaseVersion = \"$NEXT_VERSION\"/" \
    "$MODELS_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" "$PLIST_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD_NUMBER" "$PLIST_FILE"

echo "$NEXT_VERSION"
