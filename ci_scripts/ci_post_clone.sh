#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
XCCONFIG_VERSION="$(/usr/bin/sed -n 's/^MARKETING_VERSION = //p' "$ROOT/Config/XcodeCloud.xcconfig")"

if [[ "$VERSION" != "$XCCONFIG_VERSION" ]]; then
  echo "Xcode Cloud MARKETING_VERSION must match VERSION" >&2
  exit 1
fi

TARGET_TRIPLE=aarch64-apple-darwin "$ROOT/scripts/fetch-mihomo.sh"
"$ROOT/scripts/prepare-icons.sh"

echo "prepared pinned Xcode Cloud inputs for MihomoBox $VERSION"
