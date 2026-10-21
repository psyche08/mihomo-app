#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d /private/tmp/mihomobox-proxy-config.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp "$ROOT/Tests/Fixtures/app-proxy-configuration.swift" "$STAGE/main.swift"
/usr/bin/swiftc -D MAIN_APP_PROXY \
  "$ROOT/experiments/DNSIdentityProbe/Extension/AIProxyConfiguration.swift" \
  "$STAGE/main.swift" -o "$STAGE/config-test"
"$STAGE/config-test"
