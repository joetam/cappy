#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 <release-dmg> <release-tag>" >&2
    exit 1
fi

REPO_DIR="${0:A:h:h}"
ARCHIVE="$1"
TAG="$2"
PRIVATE_KEY="${CAPPY_SPARKLE_PRIVATE_KEY:-}"
GENERATE_APPCAST="$REPO_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [[ ! -f "$ARCHIVE" || "$TAG" != v<->.<->.<-> ]]; then
    echo "The release archive or semantic release tag is invalid." >&2
    exit 1
fi
if [[ -z "$PRIVATE_KEY" ]]; then
    echo "CAPPY_SPARKLE_PRIVATE_KEY is required to sign the update feed." >&2
    exit 1
fi
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "Sparkle's generate_appcast tool is missing. Resolve Swift packages first." >&2
    exit 1
fi

APPCAST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cappy-appcast.XXXXXX")"
trap 'rm -rf -- "$APPCAST_DIR"' EXIT
cp -f "$ARCHIVE" "$APPCAST_DIR/${ARCHIVE:t}"

print -rn -- "$PRIVATE_KEY" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/joetam/cappy/releases/download/$TAG/" \
    --full-release-notes-url "https://github.com/joetam/cappy/releases/tag/$TAG" \
    --link "https://github.com/joetam/cappy" \
    --maximum-deltas 0 \
    -o "$APPCAST_DIR/appcast.xml" \
    "$APPCAST_DIR"

APPCAST="$APPCAST_DIR/appcast.xml"
xmllint --noout "$APPCAST"
if ! grep -Fq "releases/download/$TAG/${ARCHIVE:t}" "$APPCAST" \
    || ! grep -Fq 'sparkle:edSignature=' "$APPCAST"; then
    echo "The generated appcast is missing its signed release enclosure." >&2
    exit 1
fi

cp -f "$APPCAST" "$REPO_DIR/dist/appcast.xml"
echo "$REPO_DIR/dist/appcast.xml"
