#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
VERSION="$(sed -n 's/^public let quotaReleaseVersion = "\([^"]*\)"$/\1/p' "$REPO_DIR/Sources/QuotaContracts/Models.swift")"
ARCH="${CAPPY_RELEASE_ARCH:-arm64}"

if [[ -n "${CAPPY_RELEASE_TAG:-}" && "$CAPPY_RELEASE_TAG" != "v$VERSION" ]]; then
    echo "Release tag $CAPPY_RELEASE_TAG does not match app version v$VERSION." >&2
    exit 1
fi

if [[ "$ARCH" != "arm64" ]]; then
    echo "Only the Apple-silicon release is currently supported." >&2
    exit 1
fi

export CAPPY_BUILD_TRIPLE="arm64-apple-macosx14.0"
"$REPO_DIR/scripts/package-app.sh"

for executable in "$REPO_DIR/build/Cappy.app/Contents/MacOS/Cappy" "$REPO_DIR/build/Cappy.app/Contents/Helpers/"*; do
    if [[ "$(lipo -archs "$executable")" != "arm64" ]]; then
        echo "Release contains a non-arm64 executable: $executable" >&2
        exit 1
    fi
done

DIST_DIR="$REPO_DIR/dist"
ARCHIVE="$DIST_DIR/Cappy-$VERSION-macos-arm64.zip"
mkdir -p "$DIST_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$REPO_DIR/build/Cappy.app" "$ARCHIVE"
(
    cd "$DIST_DIR"
    shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256"
)

echo "$ARCHIVE"
