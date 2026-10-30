#!/bin/bash
# Retry only Apple's transient timestamp outage, always with frozen export options.
set -euo pipefail
archive="${1:?archive required}"
destination="${2:?export destination required}"
options="${3:?export options required}"
log="${4:?log path required}"
for attempt in 1 2 3; do
  if [[ -e "$destination" ]]; then
    saved="${destination}.interrupted.$(date +%s).$$.$attempt"
    mv "$destination" "$saved"
  fi
  if xcodebuild -exportArchive -archivePath "$archive" -exportPath "$destination" \
    -exportOptionsPlist "$options" > "$log.$attempt" 2>&1; then
    cp "$log.$attempt" "$log"
    exit 0
  fi
  cp "$log.$attempt" "$log"
  if ! grep -Fq 'timestamp service is not available' "$log" || [[ "$attempt" == 3 ]]; then
    echo "Developer ID export failed; see $log" >&2
    exit 1
  fi
  echo "Timestamp service unavailable; retrying export (attempt $attempt of 3)" >&2
  sleep "$attempt"
done
