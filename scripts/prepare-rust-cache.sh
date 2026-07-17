#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/src-tauri/target"
MARKER="$TARGET/.mihomo-app-project-root"
PREVIOUS_ROOT="$(/bin/cat "$MARKER" 2>/dev/null || true)"

if [[ -d "$TARGET" && "$PREVIOUS_ROOT" != "$ROOT" ]]; then
  /usr/bin/env cargo clean --manifest-path "$ROOT/src-tauri/Cargo.toml"
fi
/bin/mkdir -p "$TARGET"
/bin/echo "$ROOT" > "$MARKER"
