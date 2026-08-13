#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/bin/env node -p "require('./src-tauri/tauri.conf.json').version")"
test "$VERSION" = "$(/usr/bin/env node -p "require('./package.json').version")"
test "$VERSION" = "$(/usr/bin/env node -p "require('./package-lock.json').version")"
test "$VERSION" = "$(/usr/bin/env node -p "require('./package-lock.json').packages[''].version")"
test "$VERSION" = "$(/usr/bin/sed -n 's/^version = "\([^"]*\)"/\1/p' \
  src-tauri/Cargo.toml | /usr/bin/head -1)"
test "$VERSION" = "$(/usr/bin/env node -e '
  const source = require("fs").readFileSync("src-tauri/Cargo.lock", "utf8")
  const versions = [...source.matchAll(
    /\[\[package\]\]\nname = "mihomo-app"\nversion = "([^"]+)"/g
  )].map((match) => match[1])
  if (versions.length !== 1) process.exit(1)
  process.stdout.write(versions[0])
')"
/usr/bin/env node -e \
  'for (const path of process.argv.slice(1)) JSON.parse(require("fs").readFileSync(path, "utf8"))' \
  src-tauri/tauri.conf.json src-tauri/tauri.release.conf.json
/usr/bin/env node -e '
  const config = require("./src-tauri/tauri.conf.json")
  if ((config.app?.windows ?? []).length !== 0) throw new Error("Tauri must not create a WebView")
  if (Object.hasOwn(config.build ?? {}, "frontendDist")) throw new Error("frontendDist must be absent")
'
/usr/bin/grep -q 'github.com/psyche08/mihomo-app/releases/latest/download/latest.json' \
  src-tauri/tauri.conf.json

env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift test --disable-sandbox
Tests/e2e.sh
/bin/bash Tests/test_release_common.sh
/bin/bash -n scripts/*.sh
/usr/bin/plutil -lint deploy/dev.linsheng.mihomo.daemon.plist
test "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' \
  deploy/dev.linsheng.mihomo.daemon.plist)" = "true"
mihomobox_tun_validation_awk='
  /^tun:$/ { tun_blocks += 1; in_tun = 1; next }
  in_tun && /^[^[:space:]]/ { in_tun = 0 }
  in_tun && /^  enable:/ {
    enable_keys += 1
    if ($0 ~ /^  enable:[[:space:]]+true([[:space:]]|$)/) enabled = 1
    else invalid = 1
  }
  END { exit(tun_blocks == 1 && enable_keys == 1 && enabled && !invalid ? 0 : 1) }
'
/usr/bin/awk "$mihomobox_tun_validation_awk" deploy/default-config.yaml
if printf 'tun:\n  nested:\n    enable: true\n' |
  /usr/bin/awk "$mihomobox_tun_validation_awk"; then
  echo "nested tun enable must not satisfy the default-config gate" >&2
  exit 1
fi
if /usr/bin/grep -R -q '"autostart:' src-tauri/capabilities; then
  echo "UI capabilities must not control login autostart" >&2
  exit 1
fi
scripts/install-daemon.sh --dry-run

/usr/bin/env npm run prepare:metacubexd
/usr/bin/env npm run prepare:binaries
test -f .build/release/libMihomoBoxUI.a
if .build/release/mihomoboxctl profile import-url ftp://invalid.example/profile.yaml \
  >/dev/null 2>&1; then
  echo "CLI accepted a non-HTTP subscription URL" >&2
  exit 1
fi
if .build/release/mihomoboxctl profile import-url https://invalid.example/profile.yaml \
  --auth header --header Host >/dev/null 2>&1; then
  echo "CLI accepted a restricted subscription authentication header" >&2
  exit 1
fi
/usr/bin/env cargo fmt --manifest-path src-tauri/Cargo.toml --check
/usr/bin/env cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
/usr/bin/env cargo test --manifest-path src-tauri/Cargo.toml

/usr/bin/env npm run prepare:bundle
/usr/bin/env npm run tauri -- build --bundles app

APP="$ROOT/src-tauri/target/release/bundle/macos/MihomoBox.app"
test -x "$APP/Contents/MacOS/mihomo-app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$APP/Contents/Info.plist")" = "$VERSION"
test -x "$APP/Contents/MacOS/mihomo"
test -x "$APP/Contents/MacOS/mihomo-daemon"
test -x "$APP/Contents/MacOS/mihomo-agent"
test -x "$APP/Contents/MacOS/mihomoboxctl"
test ! -e "$APP/Contents/Resources/index.html"
test ! -d "$APP/Contents/Resources/ui-dist"
/usr/bin/otool -L "$APP/Contents/MacOS/mihomo-app" |
  /usr/bin/grep -q '/SwiftUI.framework/'
"$APP/Contents/MacOS/mihomoboxctl" --help >/dev/null
test -x "$APP/Contents/Resources/scripts/install-daemon.sh"
test -x "$APP/Contents/Resources/scripts/install-daemon-remote.sh"
test -f "$APP/Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist"
test ! -e "$APP/Contents/Resources/daemon/dev.linsheng.mihomo-app.daemon.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :Label' \
  "$APP/Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist")" = \
  "dev.linsheng.mihomo.daemon"
test "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:dev.linsheng.mihomo.daemon.control' \
  "$APP/Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist")" = \
  "true"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "validated $APP"
