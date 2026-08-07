#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
STILLS_DIR="${1:-}"

COMMAND=(
  "$REPO_DIR/scripts/render-launch-video.swift"
  "$REPO_DIR/docs/preview.png"
  "$REPO_DIR/docs/launch-wallpaper.png"
  "$REPO_DIR/docs/cappy-launch.mp4"
)

if [[ -n "$STILLS_DIR" ]]; then
  COMMAND+=("$STILLS_DIR")
fi

"${COMMAND[@]}"
