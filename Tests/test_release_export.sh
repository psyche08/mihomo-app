#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE=$(mktemp -d /private/tmp/mihomobox-export-test.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/bin"
cat > "$STAGE/bin/xcodebuild" <<'FAKE'
#!/bin/bash
set -eu
n=0; [[ ! -f "$TEST_STATE/count" ]] || n=$(cat "$TEST_STATE/count")
n=$((n+1)); echo "$n" > "$TEST_STATE/count"
printf '%s\n' "$@" > "$TEST_STATE/args.$n"
if [[ "$TEST_MODE" == permanent ]]; then echo 'No matching profile'; exit 1; fi
if [[ "$n" == 1 || "$TEST_MODE" == outage ]]; then echo 'The timestamp service is not available.'; exit 1; fi
exit 0
FAKE
cat > "$STAGE/bin/sleep" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$STAGE/bin/"*
export PATH="$STAGE/bin:$PATH" TEST_STATE="$STAGE" TEST_MODE=transient
bash "$ROOT/scripts/release-export.sh" archive export options "$STAGE/log"
test "$(cat "$STAGE/count")" = 2
cmp "$STAGE/args.1" "$STAGE/args.2"
rm "$STAGE/count"
export TEST_MODE=permanent
if bash "$ROOT/scripts/release-export.sh" archive export options "$STAGE/log"; then exit 1; fi
test "$(cat "$STAGE/count")" = 1
rm "$STAGE/count"
export TEST_MODE=outage
if bash "$ROOT/scripts/release-export.sh" archive export options "$STAGE/log"; then exit 1; fi
test "$(cat "$STAGE/count")" = 3
echo 'release export recovery tests passed'
