#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="v1.269.0"
EXPECTED_REVISION="6802999f204fdb7a97b41ade2f49693ed5eab8c9"
CACHE="$ROOT/.cache/metacubexd"
OUTPUT="$ROOT/ui-dist"
BUILD_MARKER="$CACHE/.mihomo-app-built-revision"

if [[ ! -d "$CACHE/.git" ]]; then
  /usr/bin/git clone --depth 1 --branch "$VERSION" \
    https://github.com/MetaCubeX/metacubexd.git "$CACHE"
elif [[ "$(/usr/bin/git -C "$CACHE" describe --tags --always 2>/dev/null)" != "$VERSION" ]]; then
  /usr/bin/git -C "$CACHE" fetch --depth 1 origin "refs/tags/$VERSION:refs/tags/$VERSION"
  /usr/bin/git -C "$CACHE" checkout --detach "$VERSION"
fi

CURRENT_REVISION="$(/usr/bin/git -C "$CACHE" rev-parse HEAD)"
if [[ "$CURRENT_REVISION" != "$EXPECTED_REVISION" ]]; then
  echo "MetaCubeXD revision mismatch: expected $EXPECTED_REVISION, got $CURRENT_REVISION" >&2
  exit 1
fi
BUILT_REVISION="$(/bin/cat "$BUILD_MARKER" 2>/dev/null || true)"
if [[ ! -f "$CACHE/packages/ui/.output/public/index.html" || "$BUILT_REVISION" != "$CURRENT_REVISION" ]]; then
  (
    cd "$CACHE"
    /usr/bin/env pnpm install --frozen-lockfile
    NUXT_APP_BASE_URL=./ /usr/bin/env pnpm build:ui
  )
  /bin/echo "$CURRENT_REVISION" > "$BUILD_MARKER"
fi

/bin/rm -rf "$OUTPUT"
/bin/mkdir -p "$OUTPUT/THIRD_PARTY_LICENSES"
/bin/cp -R "$CACHE/packages/ui/.output/public/." "$OUTPUT/"
/usr/bin/install -m 0644 "$ROOT/assets/config.js" "$OUTPUT/config.js"
/usr/bin/install -m 0644 "$CACHE/LICENSE" "$OUTPUT/THIRD_PARTY_LICENSES/MetaCubeXD.LICENSE"
