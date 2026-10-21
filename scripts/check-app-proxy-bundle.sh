#!/bin/bash
set -euo pipefail
APP="${1:?App path required}"
EXT="$APP/Contents/Library/SystemExtensions/dev.linsheng.mihomo-app.app-proxy.systemextension"
INFO="$EXT/Contents/Info.plist"
test -d "$EXT" && test ! -L "$EXT"
test -x "$EXT/Contents/MacOS/MihomoAppProxy"
test ! -L "$EXT/Contents/MacOS/MihomoAppProxy"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = dev.linsheng.mihomo-app.app-proxy
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")" = MihomoAppProxy
test "$(/usr/libexec/PlistBuddy -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.app-proxy' "$INFO")" = MihomoAppProxy.AppProbeProvider
if [[ "${2:-}" == --signed ]]; then
  codesign --verify --strict "$EXT"
  # Compare the actual leaf bytes to the host, not just the mutable team name.
  AUDIT_DIR="$(mktemp -d /private/tmp/mihomobox-app-proxy-audit.XXXXXX)"
  trap 'rm -rf "$AUDIT_DIR"' EXIT
  mkdir "$AUDIT_DIR/host" "$AUDIT_DIR/extension"
  (cd "$AUDIT_DIR/host" && codesign -d --extract-certificates "$APP" >/dev/null 2>&1)
  (cd "$AUDIT_DIR/extension" && codesign -d --extract-certificates "$EXT" >/dev/null 2>&1)
  cmp "$AUDIT_DIR/host/codesign0" "$AUDIT_DIR/extension/codesign0"
  for code in "$APP" "$EXT"; do
    codesign -d --entitlements :- "$code" > "$AUDIT_DIR/entitlements.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.networkextension' "$AUDIT_DIR/entitlements.plist" | grep -q app-proxy-provider-systemextension
    test -f "$code/Contents/embedded.provisionprofile"
  done
fi
echo 'App Proxy bundle checks passed'
