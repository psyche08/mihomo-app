#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-daemon.sh"
STATUS_PROVIDER="$ROOT/Sources/MihomoDaemon/LocalDoHStatusProvider.swift"
XPC_MANAGER="$ROOT/Sources/MihomoDaemon/LocalDoHManager.swift"
APP_COORDINATOR="$ROOT/Sources/MihomoBoxApp/LocalDoHCoordinator.swift"
PROFILE_DOCUMENT="$ROOT/Sources/MihomoControl/LocalDoHPlanning.swift"

/bin/bash -n "$INSTALLER"

/usr/bin/grep -Fq 'LOCAL_DOH_CA_CERT="$LOCAL_DOH_DIR/ca.crt"' "$INSTALLER"
/usr/bin/grep -Fq '/usr/bin/security remove-trusted-cert -d "$trust_anchor"' "$INSTALLER"
/usr/bin/grep -Fq -- '-identifier "$LOCAL_DOH_PROFILE_IDENTIFIER" -output stdout-xml' "$INSTALLER"
/usr/bin/grep -Fq '"$(/usr/bin/stat -f '\''%u:%g:%Lp'\'' "$LOCAL_DOH_PROFILE")" == "0:0:644"' "$INSTALLER"
/usr/bin/grep -Fq '"$server_url" == "https://127.0.0.1/dns-query"' "$INSTALLER"
/usr/bin/grep -Fq '/bin/rm -f "$LOCAL_DOH_PROFILE"' "$INSTALLER"
if /usr/bin/grep -Eq -- '--install-local-doh|--remove-local-doh|add-trusted-cert' "$INSTALLER"; then
  echo "the installer must not own LocalHttpDns setup or certificate trust" >&2
  exit 1
fi
/usr/bin/grep -Fq '"-output", "stdout-xml"' "$STATUS_PROVIDER"
if /usr/bin/grep -Fq '"-output", "-"' "$STATUS_PROVIDER"; then
  echo "profile status inspection must not create a literal -.plist file" >&2
  exit 1
fi

/usr/bin/grep -Fq 'case installLocalDoH = "local-doh.install"' \
  "$ROOT/Sources/MihomoControl/ControlProtocol.swift"
if /usr/bin/grep -Fq 'local-doh.remove' "$ROOT/Sources/MihomoControl/ControlProtocol.swift"; then
  echo "LocalHttpDns removal must remain part of full helper uninstall only" >&2
  exit 1
fi
/usr/bin/grep -Fq 'server.startIfPrepared()' "$XPC_MANAGER"
/usr/bin/grep -Fq 'hadPreparedProfile' "$XPC_MANAGER"
/usr/bin/grep -Fq 'restorePreparedProfile(from: snapshot)' "$XPC_MANAGER"
/usr/bin/grep -Fq '"PayloadType": "com.apple.security.root"' "$PROFILE_DOCUMENT"
/usr/bin/grep -Fq 'expectedRootCertificate: rootCertificate' \
  "$ROOT/Sources/MihomoDaemon/LocalDoHStatusProvider.swift"
if /usr/bin/grep -Eq 'remove-trusted-cert|delete-certificate|authorizationdb|unlock-keychain' "$XPC_MANAGER"; then
  echo "explicit SSL trust must not delete certificates or bypass system authorization" >&2
  exit 1
fi
/usr/bin/grep -Fq 'func prepareCertificateTrust() throws -> Data' "$XPC_MANAGER"
/usr/bin/grep -Fq 'SecCertificateAddToKeychain(ca, keychain)' "$XPC_MANAGER"
/usr/bin/grep -Fq 'SecTrustSettingsSetTrustSettings(certificate, .admin, settings() as CFDictionary)' \
  "$ROOT/Sources/MihomoBoxApp/LocalDoHCertificateTrust.swift"
/usr/bin/grep -Fq 'try confirmTrust(preparing: true)' "$APP_COORDINATOR"
/usr/bin/grep -Fq 'try await control.verifyLocalDoHCertificateTrust()' "$APP_COORDINATOR"
/usr/bin/grep -Fq 'try await control.installLocalDoH()' "$APP_COORDINATOR"
if /usr/bin/grep -Eq 'InstallerCoordinator|osascript|runSpecialInstaller' "$APP_COORDINATOR"; then
  echo "Local DoH App actions must use the installed authenticated XPC helper" >&2
  exit 1
fi

restore_start="$(/usr/bin/grep -n '^restore() {' "$INSTALLER" | /usr/bin/cut -d: -f1)"
restore_profile="$(/usr/bin/awk -v start="$restore_start" 'NR >= start && index($0, "remove_local_doh_profile_if_installed") { print NR - start + 1; exit }' "$INSTALLER")"
restore_stop="$(/usr/bin/awk -v start="$restore_start" 'NR >= start && index($0, "launchctl bootout") { print NR - start + 1; exit }' "$INSTALLER")"
if ((restore_profile >= restore_stop)); then
  echo "uninstall must verify Local DoH profile removal before deleting its server identity" >&2
  exit 1
fi

echo "Local DoH installer safety tests passed"
