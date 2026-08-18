#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/bin/tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain one semantic version" >&2
  exit 1
fi
DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
if [[ -n "${SPARKLE_PUBLIC_ED_KEY_FILE:-}" ]]; then
  if [[ ! -f "$SPARKLE_PUBLIC_ED_KEY_FILE" || -L "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY_FILE must be a regular, non-symlink file" >&2
    exit 1
  fi
  EXPECTED_SPARKLE_PUBLIC_ED_KEY="$(/bin/cat "$SPARKLE_PUBLIC_ED_KEY_FILE")"
else
  EXPECTED_SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY}"
fi
if [[ "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" =~ [[:space:]] ]] ||
  [[ ! "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "Sparkle public key must be one base64 key without whitespace" >&2
  exit 1
fi
EXPECTED_AUTOMATIC_UPDATES=true
EXPECTED_DEVELOPMENT_UPDATES_DISABLED=false
EXPECTED_SPARKLE_FEED_URL="https://github.com/psyche08/mihomo-app/releases/latest/download/appcast.xml"
if [[ "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" == "$DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY" ]]; then
  EXPECTED_AUTOMATIC_UPDATES=false
  EXPECTED_DEVELOPMENT_UPDATES_DISABLED=true
  EXPECTED_SPARKLE_FEED_URL="https://updates.invalid/appcast.xml"
fi

/usr/bin/plutil -lint Config/Info.plist.in >/dev/null
if [[ "$(/usr/bin/grep -o '@VERSION@' Config/Info.plist.in | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" != "1" ]] ||
  [[ "$(/usr/bin/grep -o '@BUILD_VERSION@' Config/Info.plist.in | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" != "1" ]] ||
  [[ "$(/usr/bin/grep -o '@SPARKLE_PUBLIC_ED_KEY@' Config/Info.plist.in | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" != "1" ]]; then
  echo "Info.plist template placeholders are invalid" >&2
  exit 1
fi

env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift test --disable-sandbox
/bin/bash Tests/test_release_common.sh
/bin/bash Tests/test_installer_lock.sh
/bin/bash -n scripts/*.sh Tests/e2e.sh
/usr/bin/plutil -lint deploy/dev.linsheng.mihomo.daemon.plist
test "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' \
  deploy/dev.linsheng.mihomo.daemon.plist)" = "true"

# This is an awk program, not shell interpolation.
# shellcheck disable=SC2016
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
if /usr/bin/grep -Eq '^[[:space:]]+-[[:space:]]+DIRECT([[:space:]]*)$' \
  deploy/default-config.yaml ||
  ! /usr/bin/grep -Eq '^      - REJECT([[:space:]]*)$' deploy/default-config.yaml; then
  echo "default provisioning config must fail closed through REJECT" >&2
  exit 1
fi
if printf 'tun:\n  nested:\n    enable: true\n' |
  /usr/bin/awk "$mihomobox_tun_validation_awk"; then
  echo "nested tun enable must not satisfy the default-config gate" >&2
  exit 1
fi

# MetaCubeXD remains a pinned visual reference only; it is not embedded in the
# pure Swift application bundle.
scripts/prepare-metacubexd.sh
if [[ "$EXPECTED_DEVELOPMENT_UPDATES_DISABLED" == false ]]; then
  scripts/build-macos-app.sh
else
  DEVELOPMENT_DISABLE_UPDATES=1 scripts/build-macos-app.sh
fi
MIHOMO_AGENT_BINARY="$ROOT/.build/release/mihomo-agent" Tests/e2e.sh

APP="$ROOT/build/MihomoBox.app"
INFO="$APP/Contents/Info.plist"
MANIFEST="$APP/Contents/Resources/BuildManifest.plist"
PROVENANCE="$ROOT/build/MihomoBox-$VERSION-unsigned-bundle.sha256"
TRAY_ICON="$APP/Contents/Resources/Meta.png"
test -d "$APP"
for executable in mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl; do
  test -x "$APP/Contents/MacOS/$executable"
done
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = \
  "dev.linsheng.mihomo-app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")" = \
  "mihomo-app"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")" = \
  "$EXPECTED_SPARKLE_FEED_URL"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")" = \
  "$EXPECTED_SPARKLE_PUBLIC_ED_KEY"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$INFO")" = \
  "$EXPECTED_AUTOMATIC_UPDATES"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$INFO")" = \
  "$EXPECTED_AUTOMATIC_UPDATES"
test "$(/usr/libexec/PlistBuddy -c 'Print :MihomoBoxDevelopmentUpdatesDisabled' "$INFO")" = \
  "$EXPECTED_DEVELOPMENT_UPDATES_DISABLED"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUSignedFeedFailureExpirationInterval' "$INFO")" = "0"

test -d "$APP/Contents/Frameworks/Sparkle.framework"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")" = "2.9.4"
test "$(/usr/libexec/PlistBuddy -c 'Print :Version' "$MANIFEST")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :SparkleVersion' "$MANIFEST")" = "2.9.4"
/usr/bin/otool -L "$APP/Contents/MacOS/mihomo-app" |
  /usr/bin/grep -q '@rpath/Sparkle.framework/'
/usr/bin/otool -l "$APP/Contents/MacOS/mihomo-app" |
  /usr/bin/grep -q '@executable_path/../Frameworks'
/usr/bin/otool -L "$APP/Contents/MacOS/mihomo-app" |
  /usr/bin/grep -q '/SwiftUI.framework/'

test -x "$APP/Contents/Resources/scripts/install-daemon.sh"
test -x "$APP/Contents/Resources/scripts/install-daemon-remote.sh"
test -f "$APP/Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist"
test -f "$APP/Contents/Resources/licenses/Mihomo.LICENSE"
test -f "$APP/Contents/Resources/licenses/MetaCubeXD.LICENSE"
test -f "$APP/Contents/Resources/licenses/Sparkle.LICENSE"
test -f "$TRAY_ICON"
test ! -L "$TRAY_ICON"
test "$(/usr/bin/stat -f '%Lp' "$TRAY_ICON")" = "644"
/usr/bin/cmp -s assets/Meta.png "$TRAY_ICON"
/usr/bin/grep -Fq \
  $'F\t644\t0dc1c7df03c02ac34ea60b7b169020648abdc6e199627c2e1276d337249289c8\tContents/Resources/Meta.png' \
  "$PROVENANCE"
test ! -e "$APP/Contents/Resources/index.html"
test ! -d "$APP/Contents/Resources/ui-dist"
test "$(/usr/libexec/PlistBuddy -c 'Print :Label' \
  "$APP/Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist")" = \
  "dev.linsheng.mihomo.daemon"
test "$(/usr/libexec/PlistBuddy \
  -c 'Print :MachServices:dev.linsheng.mihomo.daemon.control' \
  "$APP/Contents/Resources/daemon/dev.linsheng.mihomo.daemon.plist")" = "true"

if "$APP/Contents/MacOS/mihomoboxctl" profile import-url \
  ftp://invalid.example/profile.yaml >/dev/null 2>&1; then
  echo "CLI accepted a non-HTTP subscription URL" >&2
  exit 1
fi
if "$APP/Contents/MacOS/mihomoboxctl" profile import-url \
  https://invalid.example/profile.yaml --auth header --header Host \
  >/dev/null 2>&1; then
  echo "CLI accepted a restricted subscription authentication header" >&2
  exit 1
fi
scripts/install-daemon.sh --app-bundle "$APP" --dry-run

echo "validated $APP"
