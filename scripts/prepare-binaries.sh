#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TARGET_TRIPLE:-$(rustc -vV | /usr/bin/sed -n 's/^host: //p')}"

"$ROOT/scripts/fetch-mihomo.sh"
env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift build --disable-sandbox -c release --package-path "$ROOT"
/bin/mkdir -p "$ROOT/src-tauri/binaries"
/usr/bin/install -m 0755 "$ROOT/.build/release/mihomo-daemon" \
  "$ROOT/src-tauri/binaries/mihomo-daemon-$TRIPLE"
