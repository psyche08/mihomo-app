#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/assets/Meta.png"
EXPECTED_SHA256="0dc1c7df03c02ac34ea60b7b169020648abdc6e199627c2e1276d337249289c8"
GENERATED="$ROOT/.cache/generated-icons"
OUTPUT="$ROOT/src-tauri/icons"

actual="$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')"
if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
  echo "official Meta.png checksum mismatch: expected $EXPECTED_SHA256, got $actual" >&2
  exit 1
fi

/bin/rm -rf "$GENERATED"
/bin/mkdir -p "$GENERATED" "$OUTPUT"
"$ROOT/node_modules/.bin/tauri" icon "$SOURCE" --output "$GENERATED" >/dev/null
/bin/cp "$GENERATED/32x32.png" "$OUTPUT/32x32.png"
/bin/cp "$GENERATED/128x128.png" "$OUTPUT/128x128.png"
/bin/cp "$GENERATED/128x128@2x.png" "$OUTPUT/128x128@2x.png"
/bin/cp "$GENERATED/icon.icns" "$OUTPUT/icon.icns"

echo "prepared icons from official MetaCubeX/mihomo Meta.png"
