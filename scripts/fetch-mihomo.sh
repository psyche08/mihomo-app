#!/usr/bin/env bash
set -euo pipefail

# MihomoBox bundles upstream Mihomo v1.19.30 plus one patch: RFC 9298
# CONNECT-UDP for the MASQUE h3-l4proxy outbound (`udp-uri`). The patched
# source is pinned by commit, built with the toolchain and flags of the
# upstream release, and accepted only if the binary matches the pinned SHA-256.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_VERSION="v1.19.30"
VERSION="$UPSTREAM_VERSION-connect-udp.1"
SOURCE_REPOSITORY="https://github.com/psyche08/mihomo.git"
SOURCE_COMMIT="bf7ef5dfaf038d03163c8aab8bdd741f25ae75ae"
SOURCE_TIME="2026-11-27T12:51:58+08:00"
GO_TOOLCHAIN="go1.26.6"
if [[ -n "${TARGET_TRIPLE:-}" ]]; then
  TRIPLE="$TARGET_TRIPLE"
else
  case "${TARGET_ARCH:-$(/usr/bin/uname -m)}" in
    arm64) TRIPLE="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-darwin" ;;
    *) echo "unsupported target architecture" >&2; exit 1 ;;
  esac
fi
DEST="$ROOT/.build/staging/mihomo-$TRIPLE"
CACHE="$ROOT/.cache/mihomo"

case "$TRIPLE" in
  aarch64-apple-darwin)
    GOARCH_VALUE="arm64"
    GOAMD64_VALUE=""
    EXPECTED_SHA256="201b6c8a5df8e05a4f435671d0fa72e333954c8dd878c6048fc99a1335c37128"
    ;;
  x86_64-apple-darwin)
    # Matches the upstream "amd64-compatible" release asset.
    GOARCH_VALUE="amd64"
    GOAMD64_VALUE="v1"
    EXPECTED_SHA256="04db7519e78351dbf72fe4cf23f73ed036bdf40b9d921b92862c2930c3b43d4e"
    ;;
  *)
    echo "unsupported target triple: $TRIPLE" >&2
    exit 1
    ;;
esac

sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

/bin/mkdir -p "$CACHE" "$(dirname "$DEST")"
BINARY="$CACHE/mihomo-$TRIPLE-$VERSION-${SOURCE_COMMIT:0:12}"
if [[ ! -f "$BINARY" || "$(sha256 "$BINARY")" != "$EXPECTED_SHA256" ]]; then
  # Xcode build phases run with a minimal PATH; Go only needs to be new enough
  # to fetch the pinned toolchain (GOTOOLCHAIN, Go 1.21+).
  GO="$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin" command -v go || true)"
  if [[ -z "$GO" ]]; then
    for candidate in /opt/homebrew/opt/go*/bin/go; do
      [[ -x "$candidate" ]] && GO="$candidate"
    done
  fi
  [[ -n "$GO" ]] || { echo "building Mihomo requires Go 1.21 or later on PATH" >&2; exit 1; }

  SOURCE="$CACHE/source-${SOURCE_COMMIT:0:12}"
  if [[ "$(/usr/bin/git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)" != "$SOURCE_COMMIT" ]]; then
    /bin/rm -rf "$SOURCE"
    /usr/bin/git init -q "$SOURCE"
    /usr/bin/git -C "$SOURCE" fetch -q --depth 1 "$SOURCE_REPOSITORY" "$SOURCE_COMMIT"
    /usr/bin/git -C "$SOURCE" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
  [[ "$(/usr/bin/git -C "$SOURCE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] \
    || { echo "Mihomo source is not at the pinned commit" >&2; exit 1; }
  [[ -z "$(/usr/bin/git -C "$SOURCE" status --porcelain)" ]] \
    || { echo "Mihomo source checkout is modified: $SOURCE" >&2; exit 1; }

  (
    cd "$SOURCE"
    env -u GOFLAGS -u GOEXPERIMENT GOWORK=off GOTOOLCHAIN="$GO_TOOLCHAIN" CGO_ENABLED=0 \
      GOOS=darwin GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" \
      "$GO" build -tags with_gvisor -trimpath -buildvcs=false \
      -ldflags "-X 'github.com/metacubex/mihomo/constant.Version=$VERSION' -X 'github.com/metacubex/mihomo/constant.BuildTime=$SOURCE_TIME' -w -s -buildid=" \
      -o "$BINARY.tmp" .
  )
  ACTUAL_SHA256="$(sha256 "$BINARY.tmp")"
  if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    /bin/mv "$BINARY.tmp" "$BINARY.rejected"
    echo "Mihomo checksum mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256 ($BINARY.rejected)" >&2
    exit 1
  fi
  /bin/mv "$BINARY.tmp" "$BINARY"
fi
/usr/bin/install -m 0755 "$BINARY" "$DEST.tmp"
/bin/mv "$DEST.tmp" "$DEST"
"$DEST" -v
