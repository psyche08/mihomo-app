#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="v1.19.30"
if [[ -n "${TARGET_TRIPLE:-}" ]]; then
  TRIPLE="$TARGET_TRIPLE"
else
  case "${TARGET_ARCH:-$(/usr/bin/uname -m)}" in
    arm64) TRIPLE="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-darwin" ;;
    *) echo "unsupported target architecture" >&2; exit 1 ;;
  esac
fi
DEST="$ROOT/.build/staging/mihomo-$TRIPLE"
CACHE="$ROOT/.cache/mihomo"

case "$TRIPLE" in
  aarch64-apple-darwin)
    ASSET="mihomo-darwin-arm64-$VERSION.gz"
    EXPECTED_SHA256="2c7f3a7904fa1cee291e124123e630e7b1ebd13765dd9bf26c0a28432004d9f4"
    ;;
  x86_64-apple-darwin)
    ASSET="mihomo-darwin-amd64-compatible-$VERSION.gz"
    EXPECTED_SHA256="6e75de0732e8afabe413ff7c235e8f16226ce136672371c60787cbf9607402c5"
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
