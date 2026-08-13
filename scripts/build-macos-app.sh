#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_VERSION="${MIHOMO_BUILD_VERSION:-$VERSION}"
SWIFT_BUILD_ARCH="${SWIFT_BUILD_ARCH:-$(/usr/bin/uname -m)}"
DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain one semantic version" >&2
  exit 1
fi
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "MIHOMO_BUILD_VERSION must contain only dot-separated integers" >&2
  exit 1
fi
case "$SWIFT_BUILD_ARCH" in
  arm64) TARGET_TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TARGET_TRIPLE="x86_64-apple-darwin" ;;
  *) echo "unsupported Swift build architecture: $SWIFT_BUILD_ARCH" >&2; exit 1 ;;
esac

if [[ -n "${SPARKLE_PUBLIC_ED_KEY_FILE:-}" ]]; then
  if [[ ! -f "$SPARKLE_PUBLIC_ED_KEY_FILE" || -L "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY_FILE must be a regular, non-symlink file" >&2
    exit 1
  fi
  SPARKLE_PUBLIC_ED_KEY="$(/bin/cat "$SPARKLE_PUBLIC_ED_KEY_FILE")"
else
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    if [[ "${DEVELOPMENT_DISABLE_UPDATES:-0}" != "1" ]]; then
      echo "provide SPARKLE_PUBLIC_ED_KEY or explicitly set DEVELOPMENT_DISABLE_UPDATES=1" >&2
      exit 1
    fi
    SPARKLE_PUBLIC_ED_KEY="$DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY"
  fi
fi
if [[ "$SPARKLE_PUBLIC_ED_KEY" =~ [[:space:]] ]]; then
  echo "SPARKLE public key must not contain whitespace" >&2
  exit 1
fi
if [[ ! "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY must be one base64-encoded Ed25519 public key" >&2
  exit 1
fi
DEVELOPMENT_UPDATES_DISABLED=false
AUTOMATIC_UPDATES_ENABLED=true
SPARKLE_FEED_URL="https://github.com/psyche08/mihomo-app/releases/latest/download/appcast.xml"
if [[ "$SPARKLE_PUBLIC_ED_KEY" == "$DEVELOPMENT_SPARKLE_PUBLIC_ED_KEY" ]]; then
  if [[ "${DEVELOPMENT_DISABLE_UPDATES:-0}" != "1" ]]; then
    echo "the development updater placeholder requires DEVELOPMENT_DISABLE_UPDATES=1" >&2
    exit 1
  fi
  DEVELOPMENT_UPDATES_DISABLED=true
  AUTOMATIC_UPDATES_ENABLED=false
  SPARKLE_FEED_URL="https://updates.invalid/appcast.xml"
  echo "assembling development App with updater disabled; release will reject it"
fi

export SWIFT_BUILD_ARCH TARGET_TRIPLE
"$ROOT/scripts/prepare-icons.sh"
"$ROOT/scripts/prepare-binaries.sh"

BIN_DIR="$(env \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/mihomo-app-swift-cache}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/mihomo-app-clang-cache}" \
  /usr/bin/swift build --disable-sandbox -c release --arch "$SWIFT_BUILD_ARCH" \
    --package-path "$ROOT" --show-bin-path)"
for executable in mihomo-app mihomo-daemon mihomo-agent mihomoboxctl; do
  if [[ ! -x "$BIN_DIR/$executable" ]]; then
    echo "SwiftPM product is missing: $BIN_DIR/$executable" >&2
    exit 1
  fi
done
MIHOMO_BINARY="$ROOT/.build/staging/mihomo-$TARGET_TRIPLE"
if [[ ! -x "$MIHOMO_BINARY" ]]; then
  echo "pinned Mihomo binary is missing: $MIHOMO_BINARY" >&2
  exit 1
fi

SPARKLE_FRAMEWORKS=()
while IFS= read -r framework; do
  SPARKLE_FRAMEWORKS+=("$framework")
done < <(/usr/bin/find "$ROOT/.build/artifacts" -name Sparkle.framework -type d -print)
if (( ${#SPARKLE_FRAMEWORKS[@]} != 1 )); then
  echo "expected exactly one SwiftPM Sparkle.framework artifact, found ${#SPARKLE_FRAMEWORKS[@]}" >&2
  exit 1
fi
SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORKS[0]}"
SPARKLE_INFO="$SPARKLE_FRAMEWORK/Resources/Info.plist"
if [[ ! -f "$SPARKLE_INFO" ]]; then
  echo "Sparkle framework Info.plist is missing" >&2
  exit 1
fi
SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_INFO")"
if [[ "$SPARKLE_VERSION" != "2.9.4" ]]; then
  echo "expected Sparkle 2.9.4, found $SPARKLE_VERSION" >&2
  exit 1
fi

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/MihomoBox.app"
STAGING_APP="$BUILD_DIR/.MihomoBox.app.staging.$$"
case "$STAGING_APP" in
  "$BUILD_DIR"/.MihomoBox.app.staging.*) ;;
  *) echo "unsafe staging App path" >&2; exit 1 ;;
esac
cleanup() {
  [[ ! -e "$STAGING_APP" ]] || /bin/rm -rf -- "$STAGING_APP"
  [[ -z "${PROVENANCE_STAGED:-}" || ! -e "$PROVENANCE_STAGED" ]] ||
    /bin/rm -f -- "$PROVENANCE_STAGED"
  [[ -z "${PROVENANCE_TREE:-}" || ! -e "$PROVENANCE_TREE" ]] ||
    /bin/rm -f -- "$PROVENANCE_TREE"
}
trap cleanup EXIT
/bin/mkdir -p \
  "$STAGING_APP/Contents/MacOS" \
  "$STAGING_APP/Contents/Frameworks" \
  "$STAGING_APP/Contents/Resources/scripts" \
  "$STAGING_APP/Contents/Resources/daemon" \
  "$STAGING_APP/Contents/Resources/licenses"

/usr/bin/install -m 0755 "$BIN_DIR/mihomo-app" "$STAGING_APP/Contents/MacOS/mihomo-app"
/usr/bin/install -m 0755 "$MIHOMO_BINARY" "$STAGING_APP/Contents/MacOS/mihomo"
/usr/bin/install -m 0755 "$BIN_DIR/mihomo-daemon" "$STAGING_APP/Contents/MacOS/mihomo-daemon"
/usr/bin/install -m 0755 "$BIN_DIR/mihomo-agent" "$STAGING_APP/Contents/MacOS/mihomo-agent"
/usr/bin/install -m 0755 "$BIN_DIR/mihomoboxctl" "$STAGING_APP/Contents/MacOS/mihomoboxctl"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$STAGING_APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/install -m 0644 "$ROOT/Resources/AppIcon/icon.icns" \
  "$STAGING_APP/Contents/Resources/AppIcon.icns"

/usr/bin/install -m 0755 "$ROOT/scripts/install-daemon.sh" \
  "$STAGING_APP/Contents/Resources/scripts/install-daemon.sh"
/usr/bin/install -m 0755 "$ROOT/scripts/install-daemon-remote.sh" \
  "$STAGING_APP/Contents/Resources/scripts/install-daemon-remote.sh"
for resource in daemon.json default-config.yaml dev.linsheng.mihomo.daemon.plist; do
  /usr/bin/install -m 0644 "$ROOT/deploy/$resource" \
    "$STAGING_APP/Contents/Resources/daemon/$resource"
done
/usr/bin/install -m 0644 "$ROOT/THIRD_PARTY_NOTICES.md" \
  "$STAGING_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
for license in Mihomo.LICENSE MetaCubeXD.LICENSE Sparkle.LICENSE; do
  /usr/bin/install -m 0644 "$ROOT/third_party/$license" \
    "$STAGING_APP/Contents/Resources/licenses/$license"
done

/usr/bin/sed \
  -e "s|@VERSION@|$VERSION|g" \
  -e "s|@BUILD_VERSION@|$BUILD_VERSION|g" \
  -e "s|@SPARKLE_PUBLIC_ED_KEY@|$SPARKLE_PUBLIC_ED_KEY|g" \
  "$ROOT/Config/Info.plist.in" > "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :SUAutomaticallyUpdate $AUTOMATIC_UPDATES_ENABLED" \
  "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :SUEnableAutomaticChecks $AUTOMATIC_UPDATES_ENABLED" \
  "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :MihomoBoxDevelopmentUpdatesDisabled $DEVELOPMENT_UPDATES_DISABLED" \
  "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" \
  "$STAGING_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGING_APP/Contents/Info.plist" >/dev/null

if ! /usr/bin/otool -L "$STAGING_APP/Contents/MacOS/mihomo-app" |
  /usr/bin/grep -q '@rpath/Sparkle.framework/'; then
  echo "mihomo-app is not linked to the embedded Sparkle framework via @rpath" >&2
  exit 1
fi
if ! /usr/bin/otool -l "$STAGING_APP/Contents/MacOS/mihomo-app" |
  /usr/bin/grep -q '@executable_path/../Frameworks'; then
  echo "mihomo-app is missing the embedded-framework runpath" >&2
  exit 1
fi
for executable in mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl; do
  if ! /usr/bin/lipo -archs "$STAGING_APP/Contents/MacOS/$executable" |
    /usr/bin/grep -Eq "(^|[[:space:]])$SWIFT_BUILD_ARCH([[:space:]]|$)"; then
    echo "$executable does not contain architecture $SWIFT_BUILD_ARCH" >&2
    exit 1
  fi
done

SOURCE_COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse HEAD)"
SOURCE_DIRTY=false
if [[ -n "$(/usr/bin/git -C "$ROOT" status --porcelain --untracked-files=normal -- . \
  ':(exclude)build' ':(exclude)dist')" ]]; then
  SOURCE_DIRTY=true
fi
APP_SHA="$(/usr/bin/shasum -a 256 "$STAGING_APP/Contents/MacOS/mihomo-app" | /usr/bin/awk '{print $1}')"
MIHOMO_SHA="$(/usr/bin/shasum -a 256 "$STAGING_APP/Contents/MacOS/mihomo" | /usr/bin/awk '{print $1}')"
DAEMON_SHA="$(/usr/bin/shasum -a 256 "$STAGING_APP/Contents/MacOS/mihomo-daemon" | /usr/bin/awk '{print $1}')"
AGENT_SHA="$(/usr/bin/shasum -a 256 "$STAGING_APP/Contents/MacOS/mihomo-agent" | /usr/bin/awk '{print $1}')"
CLI_SHA="$(/usr/bin/shasum -a 256 "$STAGING_APP/Contents/MacOS/mihomoboxctl" | /usr/bin/awk '{print $1}')"
/bin/cat > "$STAGING_APP/Contents/Resources/BuildManifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Version</key><string>$VERSION</string>
<key>BuildVersion</key><string>$BUILD_VERSION</string>
<key>Architecture</key><string>$SWIFT_BUILD_ARCH</string>
<key>SourceCommit</key><string>$SOURCE_COMMIT</string>
<key>SourceDirty</key><$SOURCE_DIRTY/>
<key>SparkleVersion</key><string>$SPARKLE_VERSION</string>
<key>DevelopmentUpdatesDisabled</key><$DEVELOPMENT_UPDATES_DISABLED/>
<key>MihomoAppSHA256</key><string>$APP_SHA</string>
<key>MihomoSHA256</key><string>$MIHOMO_SHA</string>
<key>MihomoDaemonSHA256</key><string>$DAEMON_SHA</string>
<key>MihomoAgentSHA256</key><string>$AGENT_SHA</string>
<key>MihomoBoxCLISHA256</key><string>$CLI_SHA</string>
</dict></plist>
EOF
/usr/bin/plutil -lint "$STAGING_APP/Contents/Resources/BuildManifest.plist" >/dev/null

# Freeze the complete unsigned bundle tree outside the App. The release step
# consumes this exact provenance file, so replacing a resource together with
# the in-bundle manifest cannot make a modified prebuilt App appear original.
PROVENANCE="$BUILD_DIR/MihomoBox-$VERSION-unsigned-bundle.sha256"
PROVENANCE_STAGED="$BUILD_DIR/.MihomoBox-$VERSION-unsigned-bundle.sha256.staging.$$"
PROVENANCE_TREE="$BUILD_DIR/.MihomoBox-$VERSION-unsigned-tree.$$"

bundle_symlink_target_is_safe() {
  local link_path="$1"
  local target="$2"
  local bundle_root="$3"
  local combined
  local component
  local resolved
  local depth=0
  local -a components=()

  if [[ -z "$target" || "$target" == /* ]] ||
    [[ "$target" == *$'\n'* || "$target" == *$'\r'* || "$target" == *$'\t'* ]]; then
    return 1
  fi

  combined="$(/usr/bin/dirname "$link_path")/$target"
  IFS='/' read -r -a components <<< "$combined"
  for component in "${components[@]}"; do
    case "$component" in
      ''|.) ;;
      ..)
        if (( depth == 0 )); then
          return 1
        fi
        depth=$((depth - 1))
        ;;
      *) depth=$((depth + 1)) ;;
    esac
  done

  if ! resolved="$(/usr/bin/perl -MCwd=abs_path -e '
    use strict;
    use warnings;
    my $resolved = abs_path($ARGV[0]);
    exit 2 unless defined $resolved;
    print $resolved;
  ' "$bundle_root/$link_path")"; then
    return 1
  fi
  case "$resolved" in
    "$bundle_root"|"$bundle_root"/*) ;;
    *) return 1 ;;
  esac
}

create_unsigned_tree() {
  local app="$1"
  local output="$2"
  local record_path
  local mode
  local sha256
  local target
  local target_sha256
  local bundle_root

  if ! {
    /usr/bin/printf 'MIHOMOBOX-UNSIGNED-BUNDLE-PROVENANCE-V2\n'
    (
      cd "$app"
      bundle_root="$(pwd -P)"
      /usr/bin/find . -print0 |
        while IFS= read -r -d '' relative; do
          record_path="${relative#./}"
          [[ -n "$record_path" ]] || record_path='.'
          if [[ "$record_path" == *$'\n'* || "$record_path" == *$'\r'* ||
            "$record_path" == *$'\t'* ]]; then
            echo "unsigned App entry has an unsupported control character in its path" >&2
            exit 1
          fi

          mode="$(/usr/bin/stat -f '%Lp' "$relative")"
          if [[ -L "$relative" ]]; then
            if ! target="$(/usr/bin/perl -e '
              use strict;
              use warnings;
              my $target = readlink($ARGV[0]);
              exit 2 unless defined $target;
              exit 3 if $target =~ /[\t\r\n]/;
              print $target;
            ' "$relative")"; then
              echo "unsigned App symlink has an unreadable or unsupported target: $record_path" >&2
              exit 1
            fi
            if ! bundle_symlink_target_is_safe \
              "$record_path" "$target" "$bundle_root"; then
              echo "unsigned App symlink target escapes the bundle or is unsafe: $record_path" >&2
              exit 1
            fi
            target_sha256="$(/usr/bin/printf '%s' "$target" |
              /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
            /usr/bin/printf 'L\t%s\t%s\t%s\t%s\n' \
              "$mode" "$target_sha256" "$record_path" "$target"
          elif [[ -d "$relative" ]]; then
            /usr/bin/printf 'D\t%s\t-\t%s\n' "$mode" "$record_path"
          elif [[ -f "$relative" ]]; then
            sha256="$(/usr/bin/shasum -a 256 "$relative" | /usr/bin/awk '{print $1}')"
            /usr/bin/printf 'F\t%s\t%s\t%s\n' "$mode" "$sha256" "$record_path"
          else
            echo "unsigned App contains a socket, device, FIFO, or unsupported entry: $record_path" >&2
            exit 1
          fi
        done |
        LC_ALL=C /usr/bin/sort
    )
  } > "$output"; then
    /bin/rm -f -- "$output"
    return 1
  fi
}
(
  create_unsigned_tree "$STAGING_APP" "$PROVENANCE_STAGED"
)
if [[ ! -s "$PROVENANCE_STAGED" ]]; then
  echo "unsigned App provenance manifest is empty" >&2
  exit 1
fi
/bin/chmod 0644 "$PROVENANCE_STAGED"
/bin/mv -f "$PROVENANCE_STAGED" "$PROVENANCE"

/bin/mkdir -p "$BUILD_DIR"
if [[ -e "$APP" ]]; then
  case "$APP" in
    "$ROOT/build/MihomoBox.app") /bin/rm -rf -- "$APP" ;;
    *) echo "unsafe destination App path" >&2; exit 1 ;;
  esac
fi
/bin/mv "$STAGING_APP" "$APP"
create_unsigned_tree "$APP" "$PROVENANCE_TREE"
if ! /usr/bin/cmp -s "$PROVENANCE" "$PROVENANCE_TREE"; then
  echo "final App differs from its unsigned bundle provenance" >&2
  /bin/rm -f -- "$PROVENANCE_TREE"
  exit 1
fi
/bin/rm -f -- "$PROVENANCE_TREE"
trap - EXIT
echo "assembled $APP"
echo "recorded unsigned bundle provenance $PROVENANCE"
