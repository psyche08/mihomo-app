#!/bin/bash
# Independent ad-hoc sandbox App processes; no root, system extension, network, or real Claude configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/mihomobox-code-access.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
printf 'int main(void) { return 0; }\n' > "$STAGE/fixture.c"
xcrun clang "$STAGE/fixture.c" -o "$STAGE/fixture"
codesign --force --sign - --identifier dev.linsheng.mihomo.fixture "$STAGE/fixture" >/dev/null 2>&1
cp "$STAGE/fixture" "$STAGE/version2"
printf 'not authorized' > "$STAGE/sibling"
mkdir -p "$STAGE/CLI.app/Contents/MacOS"
cp "$STAGE/fixture" "$STAGE/CLI.app/Contents/MacOS/fixture"
cat > "$STAGE/CLI.app/Contents/Info.plist" <<'PLIST'
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.linsheng.mihomo.fixture</string><key>CFBundleExecutable</key><string>fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$STAGE/CLI.app" >/dev/null 2>&1
cp "$ROOT/Tests/Fixtures/app-proxy-code-access.swift" "$STAGE/main.swift"
xcrun swiftc "$STAGE/main.swift" "$ROOT/Sources/MihomoControl/AppProxyIdentitySnapshot.swift" -o "$STAGE/driver"
for role in Sender Receiver; do
  mkdir -p "$STAGE/$role.app/Contents/MacOS"
  cp "$STAGE/driver" "$STAGE/$role.app/Contents/MacOS/driver"
  cat > "$STAGE/$role.app/Contents/Info.plist" <<PLIST
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.linsheng.mihomo.code-access-test.$role</string><key>CFBundleExecutable</key><string>driver</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
done
cat > "$STAGE/sender.plist" <<PLIST
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>$STAGE/fixture</string><string>$STAGE/version2</string><string>$STAGE/CLI.app/</string></array></dict></plist>
PLIST
cat > "$STAGE/receiver.plist" <<'PLIST'
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$STAGE/sender.plist" "$STAGE/Sender.app" >/dev/null 2>&1
codesign --force --sign - --entitlements "$STAGE/receiver.plist" "$STAGE/Receiver.app" >/dev/null 2>&1
"$STAGE/Sender.app/Contents/MacOS/driver" issue "$STAGE/CLI.app/Contents/MacOS/fixture" > "$STAGE/package-grant"
"$STAGE/Receiver.app/Contents/MacOS/driver" receive "$STAGE/CLI.app/Contents/MacOS/fixture" "$STAGE/sibling" < "$STAGE/package-grant"
if [[ "${APP_PROXY_TEST_ROOT:-0}" == 1 ]]; then
  /usr/bin/sudo -n "$STAGE/Receiver.app/Contents/MacOS/driver" rootReceive "$STAGE/CLI.app/Contents/MacOS/fixture" "$STAGE/sibling" < "$STAGE/package-grant"
fi
# Package-wide grants must remain read-only, even when the executable itself is unchanged.
"$STAGE/driver" issue "$STAGE/CLI.app/Contents/MacOS/fixture" > "$STAGE/writable-package"
"$STAGE/Receiver.app/Contents/MacOS/driver" deny "$STAGE/CLI.app/Contents/MacOS/fixture" "$STAGE/sibling" < "$STAGE/writable-package"
# A sealed metadata replacement invalidates the snapshot despite an unchanged Mach-O.
printf '\n<!-- replaced metadata -->\n' >> "$STAGE/CLI.app/Contents/Info.plist"
"$STAGE/Receiver.app/Contents/MacOS/driver" replaced "$STAGE/CLI.app/Contents/MacOS/fixture" "$STAGE/sibling" < "$STAGE/package-grant"
"$STAGE/Sender.app/Contents/MacOS/driver" issue "$STAGE/fixture" > "$STAGE/grant"
"$STAGE/Receiver.app/Contents/MacOS/driver" receive "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/grant"
# Optional cross-UID fixture only; never asks for a password or installs an extension.
if [[ "${APP_PROXY_TEST_ROOT:-0}" == 1 ]]; then
  /usr/bin/sudo -n "$STAGE/Receiver.app/Contents/MacOS/driver" rootReceive "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/grant"
fi
# A fresh receiver process must recover from a same-boot grant.
"$STAGE/Receiver.app/Contents/MacOS/driver" receive "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/grant"
"$STAGE/Sender.app/Contents/MacOS/driver" issue "$STAGE/version2" > "$STAGE/grant2"
python3 - "$STAGE" <<'PYTEST'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
a=json.loads((root/'grant').read_bytes()); b=json.loads((root/'grant2').read_bytes())
a['records']+=b['records']; a['grants']+=b['grants']
(root/'multiple').write_text(json.dumps(a))
bad=json.loads((root/'grant').read_bytes()); bad['records'][0]['id']='com.anthropic.claude-code'
(root/'forged').write_text(json.dumps(bad))
PYTEST
"$STAGE/Receiver.app/Contents/MacOS/driver" receive "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/multiple"
"$STAGE/Receiver.app/Contents/MacOS/driver" invalidIdentity "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/forged"
# Regression: a grant minted by an unsandboxed process must never be accepted.
"$STAGE/driver" issue "$STAGE/fixture" > "$STAGE/writable-grant"
"$STAGE/Receiver.app/Contents/MacOS/driver" deny "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/writable-grant"
# Replace the inode at the same path; a saved grant/identity must not silently authorize it.
mv "$STAGE/version2" "$STAGE/fixture"
"$STAGE/Receiver.app/Contents/MacOS/driver" replaced "$STAGE/fixture" "$STAGE/sibling" < "$STAGE/grant"
if [[ "${APP_PROXY_TEST_ROOT:-0}" == 1 ]]; then
  echo 'Code access sandbox integration passed (same-UID cases + root read-only receiver; Powerbox, reboot and NetworkExtension remain separate gates)'
else
  echo 'Code access sandbox integration passed (same UID; use APP_PROXY_TEST_ROOT=1 for optional root receiver)'
fi
