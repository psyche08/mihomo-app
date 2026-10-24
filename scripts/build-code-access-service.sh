#!/bin/bash
# Development compilation only. Xcode Cloud owns production signing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:?destination .xpc required}"
ARCH="${2:-arm64}"
mkdir -p "$DESTINATION/Contents/MacOS"
xcrun swiftc -O -target "$ARCH-apple-macos14.0" \
  "$ROOT/CodeAccessService/main.swift" "$ROOT/Sources/MihomoControl/AppProxyIdentitySnapshot.swift" \
  -o "$DESTINATION/Contents/MacOS/MihomoCodeAccess"
cp "$ROOT/Config/CodeAccessService-Info.plist" "$DESTINATION/Contents/Info.plist"
