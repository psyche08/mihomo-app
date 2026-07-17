#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/assets/Meta.png"
EXPECTED_SHA256="0dc1c7df03c02ac34ea60b7b169020648abdc6e199627c2e1276d337249289c8"
OUTPUT="$ROOT/src-tauri/icons"

verify() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "icon checksum mismatch for $path: expected $expected, got $actual" >&2
    exit 1
  fi
}

verify "$SOURCE" "$EXPECTED_SHA256"
verify "$OUTPUT/32x32.png" "e7ccba78681b89c4950b0ade992aa7c9cd88d8aa902b495e1192d5036408e4ad"
verify "$OUTPUT/128x128.png" "d71567bcf8b356e678f79b67f085325829830d5a936ddccd7c78635f750a0743"
verify "$OUTPUT/128x128@2x.png" "f7144a16e4e50d6ee7329e0cc9d8e6c3137e7ef1d70e9f7c397547a70463977d"
verify "$OUTPUT/icon.icns" "472db0ccf0e913b1b37f660277378a65d61df63dfa5e11541271fdeea324ea15"

echo "verified icons derived from official MetaCubeX/mihomo Meta.png"
