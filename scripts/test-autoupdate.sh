#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cappy-autoupdate-test.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

INFO_PLIST="$REPO_DIR/macos/Info.plist"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")"

if [[ "$(print -rn -- "$PUBLIC_KEY" | base64 -D | wc -c | tr -d ' ')" != 32 ]]; then
    echo "SUPublicEDKey is not a 32-byte Ed25519 public key." >&2
    exit 1
fi
if [[ "$FEED_URL" != "https://github.com/joetam/cappy/releases/latest/download/appcast.xml" ]]; then
    echo "The Sparkle feed does not use Cappy's stable latest-release URL." >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CappyEnableSoftwareUpdates' "$INFO_PLIST")" != false ]]; then
    echo "Source builds must not enable automatic updates." >&2
    exit 1
fi

CASK="$TEMP_DIR/cappy.rb"
cp -f "$REPO_DIR/scripts/fixtures/cappy-homebrew-cask.rb" "$CASK"
"$REPO_DIR/scripts/update-homebrew-cask.sh" \
    "$CASK" \
    0.1.14 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null

if [[ "$(grep -Ec '^[[:space:]]*auto_updates true$' "$CASK")" != 1 ]] \
    || ! grep -Fq 'version "0.1.14"' "$CASK" \
    || ! grep -Fq 'sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$CASK"; then
    echo "The Homebrew updater did not produce a self-updating Cappy cask." >&2
    exit 1
fi

zsh -n \
    "$REPO_DIR/scripts/generate-appcast.sh" \
    "$REPO_DIR/scripts/package-app.sh" \
    "$REPO_DIR/scripts/update-homebrew-cask.sh"

echo "Automatic-update configuration is valid."
