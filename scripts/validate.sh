#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift test --disable-sandbox
Tests/e2e.sh
/usr/bin/python3 -m unittest discover -s Tests -p 'test_*.py'
/bin/bash -n scripts/*.sh
/usr/bin/plutil -lint deploy/dev.linsheng.mihomo-app.daemon.plist
scripts/install-daemon.sh --dry-run

/usr/bin/env cargo fmt --manifest-path src-tauri/Cargo.toml --check
/usr/bin/env cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
/usr/bin/env cargo test --manifest-path src-tauri/Cargo.toml

/usr/bin/env npm run prepare:bundle
/usr/bin/env npm run tauri -- build --bundles app

APP="$ROOT/src-tauri/target/release/bundle/macos/Mihomo App.app"
test -x "$APP/Contents/MacOS/mihomo-app"
test -x "$APP/Contents/MacOS/mihomo"
test -x "$APP/Contents/MacOS/mihomo-daemon"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "validated $APP"
