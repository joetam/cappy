#!/bin/zsh
set -euo pipefail

if command -v swift-format >/dev/null 2>&1; then
    exec swift-format lint --recursive --parallel Sources Package.swift
fi

if FORMATTER_PATH="$(xcrun --find swift-format 2>/dev/null)" && [[ -x "$FORMATTER_PATH" ]]; then
    exec "$FORMATTER_PATH" lint --recursive --parallel Sources Package.swift
fi

echo "swift-format is required. Install it with: brew install swift-format" >&2
exit 1
