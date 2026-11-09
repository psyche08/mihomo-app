#!/bin/bash
# Independent ad-hoc sandbox App processes; no root, system extension, network, or real Claude configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/mihomobox-code-access.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
CODE="$STAGE/code"
FILE="$CODE/1.0/fixture"
SIBLING="$STAGE/other/sibling"
mkdir -p "$CODE/1.0" "$STAGE/other"
printf 'int main(void) { return 0; }\n' > "$STAGE/fixture.c"
xcrun clang "$STAGE/fixture.c" -o "$FILE"
codesign --force --sign - --identifier dev.linsheng.mihomo.fixture "$FILE" >/dev/null 2>&1
printf 'not authorized' > "$SIBLING"
ln -s code "$STAGE/link"
cp "$ROOT/Tests/Fixtures/app-proxy-code-access.swift" "$STAGE/main.swift"
xcrun swiftc "$STAGE/main.swift" "$ROOT/Sources/MihomoControl/AppProxyIdentitySnapshot.swift" -o "$STAGE/driver"
for role in Sender Receiver; do
  mkdir -p "$STAGE/$role.app/Contents/MacOS"
  cp "$STAGE/driver" "$STAGE/$role.app/Contents/MacOS/driver"
  cat > "$STAGE/$role.app/Contents/Info.plist" <<PLIST
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.linsheng.mihomo.code-access-test.$role</string><key>CFBundleExecutable</key><string>driver</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
done
# The sender stands in for the code-access broker: read-only access to the code, as its entitlements give.
cat > "$STAGE/sender.plist" <<PLIST
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>$CODE/</string></array></dict></plist>
PLIST
cat > "$STAGE/receiver.plist" <<'PLIST'
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$STAGE/sender.plist" "$STAGE/Sender.app" >/dev/null 2>&1
codesign --force --sign - --entitlements "$STAGE/receiver.plist" "$STAGE/Receiver.app" >/dev/null 2>&1
SENDER="$STAGE/Sender.app/Contents/MacOS/driver"
RECEIVER="$STAGE/Receiver.app/Contents/MacOS/driver"
# A folder grant lets the sandboxed provider read and validate code below it, nothing else.
"$SENDER" issue "$CODE" > "$STAGE/grant"
"$RECEIVER" receive "$CODE" "$FILE" "$SIBLING" < "$STAGE/grant"
# A fresh receiver process recovers from a same-boot grant.
"$RECEIVER" receive "$CODE" "$FILE" "$SIBLING" < "$STAGE/grant"
# Optional cross-UID fixture only; never asks for a password or installs an extension.
if [[ "${APP_PROXY_TEST_ROOT:-0}" == 1 ]]; then
  /usr/bin/sudo -n "$RECEIVER" rootReceive "$CODE" "$FILE" "$SIBLING" < "$STAGE/grant"
fi
# The broker never grants a folder it could write, nor a path through a link.
if "$STAGE/driver" issue "$CODE" > /dev/null 2>&1; then
  echo 'an issuer with write access minted a grant' >&2; exit 1
fi
"$STAGE/driver" refuseLink "$STAGE/link"
# Regression: a writable grant minted outside the read-only broker is never accepted.
"$STAGE/driver" issueWritable "$CODE" > "$STAGE/writable-grant"
"$RECEIVER" deny "$CODE" "$FILE" "$SIBLING" < "$STAGE/writable-grant"
# A grant cannot be relabelled to another folder.
python3 - "$STAGE" <<'PYTEST'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
policy = json.loads((root / 'grant').read_bytes())
policy['folders'] = [str(root / 'other')]
(root / 'relabelled').write_text(json.dumps(policy))
PYTEST
"$RECEIVER" stale "$STAGE/other" "$SIBLING" "$FILE" < "$STAGE/relabelled"
# A grant follows the folder it was minted for: a replacement at the same path needs a fresh grant,
# which the host mints when the code stamp (device and inode) changes.
mv "$CODE" "$STAGE/code-old"
mkdir -p "$CODE/1.0"
cp "$STAGE/code-old/1.0/fixture" "$FILE"
"$RECEIVER" stale "$CODE" "$FILE" "$SIBLING" < "$STAGE/grant"
"$SENDER" issue "$CODE" > "$STAGE/fresh-grant"
"$RECEIVER" receive "$CODE" "$FILE" "$SIBLING" < "$STAGE/fresh-grant"
if [[ "${APP_PROXY_TEST_ROOT:-0}" == 1 ]]; then
  echo 'Code access sandbox integration passed (same-UID cases + root read-only receiver; reboot and NetworkExtension remain separate gates)'
else
  echo 'Code access sandbox integration passed (same UID; use APP_PROXY_TEST_ROOT=1 for optional root receiver)'
fi
