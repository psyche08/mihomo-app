#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
: "${WRAPPER_NAME:?WRAPPER_NAME is required}"

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
INFO="$APP/Contents/Info.plist"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
EXPECTED_EXECUTABLES=(mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl)

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain one semantic version" >&2
  exit 1
fi
if [[ ! -f "$INFO" ]]; then
  echo "Xcode App Info.plist is missing: $INFO" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" != "$VERSION" ]]; then
  echo "Xcode MARKETING_VERSION does not match VERSION" >&2
  exit 1
fi

for executable in "${EXPECTED_EXECUTABLES[@]}"; do
  if [[ ! -x "$APP/Contents/MacOS/$executable" ]]; then
    echo "Xcode archive payload is missing executable: $executable" >&2
    exit 1
  fi
done

/bin/mkdir -p \
  "$APP/Contents/Resources/scripts" \
  "$APP/Contents/Resources/daemon" \
  "$APP/Contents/Resources/licenses"
/usr/bin/install -m 0644 "$ROOT/Resources/AppIcon/icon.icns" \
  "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/install -m 0644 "$ROOT/assets/Meta.png" \
  "$APP/Contents/Resources/Meta.png"
/usr/bin/install -m 0755 "$ROOT/scripts/install-daemon.sh" \
  "$APP/Contents/Resources/scripts/install-daemon.sh"
/usr/bin/install -m 0755 "$ROOT/scripts/install-daemon-remote.sh" \
  "$APP/Contents/Resources/scripts/install-daemon-remote.sh"
for resource in daemon.json default-config.yaml dev.linsheng.mihomo.daemon.plist; do
  /usr/bin/install -m 0644 "$ROOT/deploy/$resource" \
    "$APP/Contents/Resources/daemon/$resource"
done
/usr/bin/install -m 0644 "$ROOT/THIRD_PARTY_NOTICES.md" \
  "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
for license in Mihomo.LICENSE MetaCubeXD.LICENSE Sparkle.LICENSE; do
  /usr/bin/install -m 0644 "$ROOT/third_party/$license" \
    "$APP/Contents/Resources/licenses/$license"
done

SPARKLE_INFO="$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
if [[ ! -f "$SPARKLE_INFO" ]] ||
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_INFO")" != "2.9.4" ]]; then
  echo "Xcode archive must embed Sparkle 2.9.4" >&2
  exit 1
fi

BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
SOURCE_COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse HEAD)"
SOURCE_DIRTY=false
if [[ -n "$(/usr/bin/git -C "$ROOT" status --porcelain --untracked-files=normal -- . \
  ':(exclude).build' ':(exclude)build' ':(exclude)dist')" ]]; then
  SOURCE_DIRTY=true
fi
ARCHITECTURE="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/mihomo-app")"
if [[ "$ARCHITECTURE" != "arm64" ]]; then
  echo "Xcode Cloud release archive must contain exactly arm64, found: $ARCHITECTURE" >&2
  exit 1
fi

hash_executable() {
  /usr/bin/shasum -a 256 "$APP/Contents/MacOS/$1" | /usr/bin/awk '{print $1}'
}

/bin/cat > "$APP/Contents/Resources/BuildManifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Version</key><string>$VERSION</string>
<key>BuildVersion</key><string>$BUILD_VERSION</string>
<key>Architecture</key><string>$ARCHITECTURE</string>
<key>SourceCommit</key><string>$SOURCE_COMMIT</string>
<key>SourceDirty</key><$SOURCE_DIRTY/>
<key>SparkleVersion</key><string>2.9.4</string>
<key>DevelopmentUpdatesDisabled</key><false/>
<key>MihomoAppSHA256</key><string>$(hash_executable mihomo-app)</string>
<key>MihomoSHA256</key><string>$(hash_executable mihomo)</string>
<key>MihomoDaemonSHA256</key><string>$(hash_executable mihomo-daemon)</string>
<key>MihomoAgentSHA256</key><string>$(hash_executable mihomo-agent)</string>
<key>MihomoBoxCLISHA256</key><string>$(hash_executable mihomoboxctl)</string>
</dict></plist>
EOF
/usr/bin/plutil -lint "$APP/Contents/Resources/BuildManifest.plist" >/dev/null

echo "assembled Xcode archive resources version=$VERSION build=$BUILD_VERSION commit=$SOURCE_COMMIT"
