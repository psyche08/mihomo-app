#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="v1.19.28"
TRIPLE="${TARGET_TRIPLE:-$(rustc -vV | /usr/bin/sed -n 's/^host: //p')}"
DEST="$ROOT/src-tauri/binaries/mihomo-$TRIPLE"
CACHE="$ROOT/.cache/mihomo"

case "$TRIPLE" in
  aarch64-apple-darwin)
    ASSET="mihomo-darwin-arm64-$VERSION.gz"
    EXPECTED_SHA256="40cdae2fab4b18df15f40eaa9dc3af70ab3d8be7f77164ae1e5f1af3a2a4fb44"
    ;;
  x86_64-apple-darwin)
    ASSET="mihomo-darwin-amd64-compatible-$VERSION.gz"
    EXPECTED_SHA256="a469cc2f6800e71b50eca3f74bc72a8f6f7e990a5d4aaecb81a68cf331516d9d"
    ;;
  *)
    echo "unsupported target triple: $TRIPLE" >&2
    exit 1
    ;;
esac

/bin/mkdir -p "$CACHE" "$(dirname "$DEST")"
ARCHIVE="$CACHE/$ASSET"
if [[ ! -f "$ARCHIVE" ]]; then
  /usr/bin/curl -fsSL --retry 3 \
    "https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/$ASSET" \
    -o "$ARCHIVE"
fi
ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Mihomo checksum mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256" >&2
  exit 1
fi
/usr/bin/gzip -dc "$ARCHIVE" > "$DEST.tmp"
/bin/chmod 0755 "$DEST.tmp"
/bin/mv "$DEST.tmp" "$DEST"
"$DEST" -v
