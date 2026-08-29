#!/usr/bin/env bash
set -euo pipefail

EXPECTED_TEAM_ID="89LGY6BD53"
PUBLISHED_LEAF_SHA1="2E1EF531C972A15F5B5C58855001FA6FA1186383"
SIGNED_PATH="${CI_DEVELOPER_ID_SIGNED_APP_PATH:-}"

if [[ -z "$SIGNED_PATH" ]]; then
  echo "Developer ID export is not available for this action; certificate audit skipped"
  exit 0
fi

APP="$SIGNED_PATH"
if [[ ! -d "$APP" || "$APP" != *.app ]]; then
  APP="$(/usr/bin/find "$SIGNED_PATH" -maxdepth 4 -type d -name MihomoBox.app -print -quit)"
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "CI_DEVELOPER_ID_SIGNED_APP_PATH contains no MihomoBox.app" >&2
  exit 1
fi

certificate_leaf_sha1() {
  local signed_code="$1"
  local extraction
  extraction="$(/usr/bin/mktemp -d /private/tmp/mihomobox-cloud-cert.XXXXXX)"
  if ! (cd "$extraction" && /usr/bin/codesign -d --extract-certificates "$signed_code" >/dev/null 2>&1); then
    /bin/rm -rf -- "$extraction"
    return 1
  fi
  if [[ ! -f "$extraction/codesign0" ]]; then
    /bin/rm -rf -- "$extraction"
    return 1
  fi
  /usr/bin/shasum -a 1 "$extraction/codesign0" | /usr/bin/awk '{print toupper($1)}'
  /bin/rm -rf -- "$extraction"
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
TEAM_ID="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
if [[ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "Cloud archive TeamIdentifier mismatch: expected $EXPECTED_TEAM_ID, got $TEAM_ID" >&2
  exit 1
fi

APP_LEAF="$(certificate_leaf_sha1 "$APP")"
if [[ ! "$APP_LEAF" =~ ^[0-9A-F]{40}$ ]]; then
  echo "failed to extract Cloud Developer ID leaf fingerprint" >&2
  exit 1
fi
for executable in mihomo-app mihomo mihomo-daemon mihomo-agent mihomoboxctl; do
  path="$APP/Contents/MacOS/$executable"
  if [[ ! -x "$path" ]]; then
    echo "Cloud archive is missing executable: $executable" >&2
    exit 1
  fi
  leaf="$(certificate_leaf_sha1 "$path")"
  if [[ "$leaf" != "$APP_LEAF" ]]; then
    echo "Cloud archive executable uses a different leaf: $executable" >&2
    exit 1
  fi
done

echo "MIHOMOBOX_CLOUD_DEVELOPER_ID_LEAF_SHA1=$APP_LEAF"
if [[ "$APP_LEAF" == "$PUBLISHED_LEAF_SHA1" ]]; then
  echo "Cloud archive reused the published leaf; no certificate bridge is required"
else
  echo "Cloud archive uses a new leaf; add the logged fingerprint to the 0.9.1 migration allowlist"
fi
