#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
"$REPO_DIR/scripts/render-launch-video.swift" "$REPO_DIR/docs/preview.png" "$REPO_DIR/docs/cappy-launch.mp4"
