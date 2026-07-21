#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TARGET_TRIPLE:-$(rustc -vV | /usr/bin/sed -n 's/^host: //p')}"
BUILD_ROOT_MARKER="$ROOT/.build/.mihomo-app-project-root"

PREVIOUS_ROOT="$(/bin/cat "$BUILD_ROOT_MARKER" 2>/dev/null || true)"
if [[ -d "$ROOT/.build" && "$PREVIOUS_ROOT" != "$ROOT" ]]; then
  /usr/bin/swift package --package-path "$ROOT" clean
fi

"$ROOT/scripts/fetch-mihomo.sh"
env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift build --disable-sandbox -c release --package-path "$ROOT"
/bin/mkdir -p "$(dirname "$BUILD_ROOT_MARKER")"
/bin/echo "$ROOT" > "$BUILD_ROOT_MARKER"
/bin/mkdir -p "$ROOT/src-tauri/binaries"
/usr/bin/install -m 0755 "$ROOT/.build/release/mihomo-daemon" \
  "$ROOT/src-tauri/binaries/mihomo-daemon-$TRIPLE"
/usr/bin/install -m 0755 "$ROOT/.build/release/mihomo-agent" \
  "$ROOT/src-tauri/binaries/mihomo-agent-$TRIPLE"
/usr/bin/install -m 0755 "$ROOT/.build/release/mihomoboxctl" \
  "$ROOT/src-tauri/binaries/mihomoboxctl-$TRIPLE"
