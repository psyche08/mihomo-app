#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BUILD_ARCH="${SWIFT_BUILD_ARCH:-$(/usr/bin/uname -m)}"
case "$SWIFT_BUILD_ARCH" in
  arm64) DEFAULT_TRIPLE="aarch64-apple-darwin" ;;
  x86_64) DEFAULT_TRIPLE="x86_64-apple-darwin" ;;
  *) echo "unsupported Swift build architecture: $SWIFT_BUILD_ARCH" >&2; exit 1 ;;
esac
TRIPLE="${TARGET_TRIPLE:-$DEFAULT_TRIPLE}"
BUILD_ROOT_MARKER="$ROOT/.build/.mihomo-app-project-root"

PREVIOUS_ROOT="$(/bin/cat "$BUILD_ROOT_MARKER" 2>/dev/null || true)"
if [[ -d "$ROOT/.build" && "$PREVIOUS_ROOT" != "$ROOT" ]]; then
  /usr/bin/swift package --package-path "$ROOT" clean
fi

TARGET_TRIPLE="$TRIPLE" "$ROOT/scripts/fetch-mihomo.sh"
env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift build --disable-sandbox -c release --arch "$SWIFT_BUILD_ARCH" \
    --package-path "$ROOT"
/bin/mkdir -p "$(dirname "$BUILD_ROOT_MARKER")"
/bin/echo "$ROOT" > "$BUILD_ROOT_MARKER"
