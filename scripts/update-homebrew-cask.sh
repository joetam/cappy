#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "Usage: $0 <cask-file> <version> <sha256>" >&2
    exit 1
fi

CASK_FILE="$1"
VERSION="$2"
SHA256="$3"

if [[ ! -f "$CASK_FILE" ]]; then
    echo "Homebrew cask file not found: $CASK_FILE" >&2
    exit 1
fi
if ! print -r -- "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Release version is not semantic: $VERSION" >&2
    exit 1
fi
if ! print -r -- "$SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "Release checksum is not a lowercase SHA-256 value." >&2
    exit 1
fi

ruby - "$CASK_FILE" "$VERSION" "$SHA256" <<'RUBY'
cask_file, version, sha256 = ARGV
contents = File.read(cask_file)

unless contents.scan(/^[ \t]*version[ \t]+"[^"]+"[ \t]*$/).length == 1
  abort "Expected exactly one cask version declaration."
end
unless contents.scan(/^[ \t]*sha256[ \t]+"[0-9a-f]+"[ \t]*$/).length == 1
  abort "Expected exactly one cask SHA-256 declaration."
end

current_version = contents.match(/^[ \t]*version[ \t]+"([^"]+)"[ \t]*$/)[1]
current_parts = current_version.split(".").map { |part| Integer(part, 10) }
next_parts = version.split(".").map { |part| Integer(part, 10) }
if (current_parts <=> next_parts) == 1
  abort "Refusing to downgrade the cask from #{current_version} to #{version}."
end

contents.sub!(/^([ \t]*version[ \t]+)"[^"]+"[ \t]*$/, "\\1\"#{version}\"")
contents.sub!(/^([ \t]*sha256[ \t]+)"[0-9a-f]+"[ \t]*$/, "\\1\"#{sha256}\"")
unless contents.scan(/macos-arm64\.(?:zip|dmg)/).length == 1
  abort "Expected exactly one Cappy macOS archive URL."
end
contents.sub!(/macos-arm64\.(?:zip|dmg)/, "macos-arm64.dmg")
File.write(cask_file, contents)
RUBY

echo "Updated ${CASK_FILE:t} to Cappy $VERSION."
