#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$ROOT/build/per-app-dns-feasibility"
mkdir -p "$OUTPUT"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework NetworkExtension -framework Security \
  "$ROOT/tools/per-app-dns-feasibility/main.swift" -o "$OUTPUT/probe"
"$OUTPUT/probe" | tee "$OUTPUT/result.json"
