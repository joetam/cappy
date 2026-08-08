#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
VERSION="$(sed -n 's/^public let quotaReleaseVersion = "\([^"]*\)"$/\1/p' "$REPO_DIR/Sources/QuotaContracts/Models.swift")"
APP_DIR="$REPO_DIR/build/Cappy.app"
ARCHIVE="$REPO_DIR/dist/Cappy-$VERSION-macos-arm64.zip"
CHECKSUM="$ARCHIVE.sha256"
NOTARY_KEY_PATH="${APPLE_NOTARY_PRIVATE_KEY_PATH:-}"
NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"

if [[ -z "$NOTARY_KEY_PATH" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
    echo "Notarization credentials are incomplete." >&2
    exit 1
fi
if [[ ! -f "$NOTARY_KEY_PATH" || ! -d "$APP_DIR" || ! -f "$ARCHIVE" ]]; then
    echo "The signing key, app bundle, or release archive is missing." >&2
    exit 1
fi

xcrun notarytool submit "$ARCHIVE" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --timeout 30m

xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
spctl --assess --type execute "$APP_DIR"

rm -f -- "$ARCHIVE" "$CHECKSUM"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
(
    cd "${ARCHIVE:h}"
    shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256"
)

echo "$ARCHIVE"
