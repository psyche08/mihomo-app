#!/bin/bash
# Local compile only. Production signing/packaging belongs to Xcode Cloud.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:?destination systemextension directory required}"
ARCH="${2:-arm64}"
mkdir -p "$DESTINATION/Contents/MacOS"
xcrun swiftc -O -D MAIN_APP_PROXY -target "$ARCH-apple-macos14.0" \
  -module-name MihomoAppProxy "$ROOT"/experiments/DNSIdentityProbe/Extension/*.swift \
  -o "$DESTINATION/Contents/MacOS/MihomoAppProxy"
/usr/bin/sed \
  -e 's/$(EXECUTABLE_NAME)/MihomoAppProxy/g' \
  -e 's/$(PRODUCT_MODULE_NAME)/MihomoAppProxy/g' \
  -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.linsheng.mihomo-app.app-proxy/g' \
  -e 's/$(PRODUCT_NAME)/MihomoAppProxy/g' \
  -e "s/\$(MARKETING_VERSION)/$(cat "$ROOT/VERSION")/g" \
  -e 's/$(CURRENT_PROJECT_VERSION)/1/g' \
  -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/g' \
  "$ROOT/Config/AppProxyExtension-Info.plist" > "$DESTINATION/Contents/Info.plist"
plutil -lint "$DESTINATION/Contents/Info.plist"
