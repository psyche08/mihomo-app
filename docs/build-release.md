# Build and Release

## Current release policy

Production release artifacts originate only from Xcode Cloud after the 0.9.1
certificate bridge. Xcode Cloud owns the release build, Developer ID signing,
notarization, ticket attachment and App packaging. Starting with 0.9.3, GitHub
publishes that exact ticket-attached ZIP byte-for-byte plus a locally generated
signed Sparkle appcast. A local build, re-sign or repack must never be
substituted. Local compilation, tests and validation use ad-hoc signing only.

Version 0.9.1 is the sole migration exception. It may reuse only the already
built App bound to source commit `acb6f380c76d5d5a8bd96d208ce6a5e3947cdb4f`,
signed by published Developer ID leaf
`2E1EF531C972A15F5B5C58855001FA6FA1186383`. Its exact pre-staple ZIP is
notarized through `tools/notarytool-rs`; packaging and GitHub publication may
then run locally. The exception does not authorize rebuilding or re-signing
the accepted App and expires immediately after 0.9.1.

## Pinned Inputs

| Component | Pin | Verification |
|---|---|---|
| Sparkle | `2.9.4` | SwiftPM exact version; binary artifact checksum `cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0` |
| MetaCubeXD visual reference | tag `v1.271.0`, commit `c4622599d0a597378729a91c3b7f76c5d9803831` | exact revision check; MIT license copied |
| Mihomo | release `v1.19.30` | architecture-specific SHA-256 |
| App and tray icon | upstream Mihomo `Meta.png` | source, embedded tray resource and derived-output SHA-256 |

`VERSION` is the sole product-version source. SwiftPM builds the user App,
daemon, agent and operator CLI. `scripts/build-macos-app.sh` assembles those
products, the pinned Mihomo binary, Sparkle.framework and checked-in resources
into `build/MihomoBox.app`.

The pinned MetaCubeXD checkout is a visual reference only. Its JavaScript is
never linked, copied into the App, or executed at runtime.

## Operator-owned compilation

Compilation, tests, validation, signing, notarization, packaging and deployment
must be run by the operator outside an agent sandbox. An agent may edit or
statically inspect the commands, but must not execute them.

From the repository root, the operator runs:

```bash
./scripts/validate.sh
```

For a production bundle, set either `SPARKLE_PUBLIC_ED_KEY` or
`SPARKLE_PUBLIC_ED_KEY_FILE` to the base64 raw 32-byte public key. The file must
be regular and non-symlink; the key must be one token with no embedded
whitespace. With neither value, validation explicitly builds a development App
whose feed and automatic updates are disabled, and release rejects that App.

Validation resolves pinned Swift packages, refreshes the visual reference,
runs Swift and shell tests, builds the bundle through
`scripts/build-macos-app.sh`, and performs structural checks on the final App.
It never installs the LaunchDaemon and never changes the current network.

## GitHub publication from Xcode Cloud

Starting with 0.9.3, the formal release set contains exactly two files:

```text
MihomoBox-X.Y.Z-macos-arm64.zip
appcast.xml
```

The ZIP must be downloaded from the Xcode Cloud Notarize post-action as
**Notarized App (ticket attached)**. The Archive action's similarly named
Developer ID ZIP is not the publication input because it may not contain the
stapled ticket. The downloaded ZIP is renamed only: its bytes and SHA-256 must
remain identical, and the App must never be extracted and repackaged for
distribution.

From a clean checkout at the exact Cloud source commit, validate the ZIP and
create the signed feed metadata:

```bash
./scripts/prepare-cloud-release.zsh \
  --cloud-zip '/absolute/path/to/MihomoBox.app.zip'
```

This command verifies the source commit, version and build number, all five
executables, the pinned Cloud Developer ID leaf, Gatekeeper acceptance, the
stapled ticket and production Sparkle settings. It then copies the ZIP
byte-for-byte to its versioned name and uses pinned Sparkle 2.9.4 tools to
generate and independently verify `dist/appcast.xml`. Local work is limited to
feed metadata; this command does not build, sign, notarize, staple or package
the App.

Prepare a state-bound GitHub draft, then publish the exact draft after review:

```bash
STATE_DIR="$PWD/dist/.release-state/X.Y.Z-FULL_SOURCE_COMMIT"
./scripts/release-github.zsh prepare --state-dir "$STATE_DIR"
./scripts/release-github.zsh publish \
  --state-dir "$STATE_DIR" \
  --confirm vX.Y.Z@FULL_SOURCE_COMMIT
```

The helper creates an annotated tag, atomically keeps `main` and that tag on
the same commit, freezes every formal asset's byte length and SHA-256, and
binds all mutations to one numeric GitHub release ID. An existing asset with a
different digest stops the release; the workflow never uses `--clobber`,
deletes an asset, or selects a mutable draft by tag alone.

The local `release-product.zsh` and `release-macos.sh` signing/notarization path
is retained only for the frozen 0.9.1 migration exception and historical
recovery. It is not a production path for 0.9.2 or later. Its state and legacy
five-file release set must never be reused for a Cloud release.

The bundle gate must find exactly these product executables:

```text
MihomoBox.app/Contents/MacOS/mihomo-app
MihomoBox.app/Contents/MacOS/mihomo
MihomoBox.app/Contents/MacOS/mihomo-daemon
MihomoBox.app/Contents/MacOS/mihomo-agent
MihomoBox.app/Contents/MacOS/mihomoboxctl
```

It must also verify `Sparkle.framework`, `@executable_path/../Frameworks`, the
bundle identifier, `VERSION`, third-party licenses and the absence of WebView
or Tauri runtime assets.

## Xcode Cloud Developer ID transition

The committed Cloud product is `XcodeCloud/MihomoBox.xcodeproj` with the shared
`MihomoBox` scheme. It is a thin archive surface over the package-owned source:
the App and three native helper targets consume local Swift package library
products, while a checksum-pinned Mihomo binary and audited resources are
embedded before Xcode's signing phase. `Package.resolved` is committed in both
the package root and the Xcode project workspace.

Xcode Cloud is configured in two stages:

1. Create a macOS Archive action for the shared `MihomoBox` scheme, Developer ID
   distribution, clean build, and the current Xcode/macOS image.
2. Add Apple's Notarize post-action. Do not add notary credentials, a Developer
   ID private key, the Sparkle private key, or Keychain commands to custom
   scripts; Xcode Cloud owns Developer ID signing and the built-in post-action
   owns App notarization.

The first Cloud archive is bootstrap evidence, not a public update.
`ci_post_xcodebuild.sh` verifies Team ID `89LGY6BD53`, requires all five product
executables to share the App leaf, and logs exactly one
`MIHOMOBOX_CLOUD_DEVELOPER_ID_LEAF_SHA1=...` marker when the Developer ID export
is available. Download the archive and inspect it manually if Xcode Cloud does
not expose that path to the post-build script.

The first notarized Cloud archive, Build 4 from commit `d437935`, observed leaf
`44B2EB8C6C3C6A85A3687EEDED7D85EB7C13524A` on all five product executables.
`SigningCertificateRequirement.migrationLeafSHA1s` pins it beside the published
`2E1EF531C972A15F5B5C58855001FA6FA1186383` leaf. The local release script
refuses to sign 0.9.1 unless that source allowlist contains exactly those two
unique leaves. Publish 0.9.1 with the published certificate; only a later
version may be distributed from the Cloud certificate. Keep the Sparkle EdDSA
key unchanged during this Developer ID rotation.

For 0.9.3 and later, the ticket-attached App ZIP from the Notarize post-action
is the Sparkle enclosure and GitHub application artifact. It replaces the
locally created DMG, tar archive and `latest.json`; only the signed appcast is
generated locally. GitHub immutable-asset verification and signed-machine
runtime acceptance remain independent gates.

The source tree also contains the independent cross-platform Notary API client
at `tools/notarytool-rs`. It uses App Store Connect API-key JWT authentication,
uploads through Apple's temporary S3 credentials, and supports submission
status, history, waiting, developer logs, and append-only recovery state. It
does not sign or staple software. Its only production use is the explicitly
authorized 0.9.1 bridge described above; it otherwise remains a compatibility
and recovery tool for designated test artifacts and must not substitute for a
Cloud production artifact.

For an explicit development-window smoke test:

```bash
'build/MihomoBox.app/Contents/MacOS/mihomo-app' --smoke-show-window
```

Add `--native-ui-preview` to use bounded in-memory visual fixtures. Preview is
honored only for development executables in this checkout; an installed App
always uses authenticated XPC.

An ad-hoc validation bundle proves linkage, tests and packaging only. The Mach
service deliberately rejects an ad-hoc peer, so a release-signed machine gate
must still verify the real App-to-daemon IPC path.

## Signed-machine acceptance

Before publication, use an isolated Mac with a release-signed App and an
explicitly installed test LaunchDaemon:

1. verify all five executables share the App's Developer ID leaf;
2. run signed, read-only `mihomoboxctl rpc version`, `rpc snapshot` and
   `rpc connections` probes;
3. open the SwiftUI window without preview and verify all live pages;
4. verify tray TUN, mode, proxy and profile controls with authoritative XPC
   readback;
5. verify component synchronization, hidden login startup, window restoration,
   DNS/TUN health and one daemon-owned Mihomo process;
6. exercise the legacy 0.7-to-current-0.8.x updater, its explicit verified
   daemon-repair migration, and the Sparkle updater path from 0.8.0.

This acceptance changes runtime state and is not part of normal validation.

## Signing and notarization

`scripts/release-macos.sh` never compiles. It accepts the already validated
`build/MihomoBox.app`, verifies its version, build manifest, and the external
`build/MihomoBox-X.Y.Z-unsigned-bundle.sha256` provenance tree, then signs from
the inside out. The external tree records every unsigned bundle directory,
regular file and safe relative symbolic link, including modes, file hashes and
link-target hashes. Links whose normalized target escapes the App and all
socket, device, FIFO or unknown entries are rejected. Release recomputes the
whole tree byte-for-byte, so extra, missing or modified entries fail even if an
in-bundle manifest is also changed. A non-default App path must supply the
matching external manifest with `--provenance`. Sparkle helpers/framework,
`mihomo-app`, `mihomo`, daemon, agent, CLI and the outer App must all use the
same Developer ID Application leaf.
Do not use `codesign --deep` to sign; use it only for final verification.

The release pipeline uses these operator credentials and fixed audited inputs.
The wrapper derives the fixed paths/pins automatically; only the credential
variables and an optional disambiguating identity fingerprint are inherited:

```text
NOTARY_TEAM_ID
NOTARY_APPLE_ID
NOTARY_PASSWORD
CODESIGN_IDENTITY_FINGERPRINT (optional; required only when the team has multiple identities)
SPARKLE_DISTRIBUTION_ROOT
SPARKLE_ED_KEY_PATH
SPARKLE_GENERATE_APPCAST_SHA256
SPARKLE_SIGN_UPDATE_SHA256
SPARKLE_SIGNATURE_VERIFIER
SPARKLE_SIGNATURE_VERIFIER_SHA256
LEGACY_MINISIGN
LEGACY_UPDATER_PRIVATE_KEY_FILE
LEGACY_UPDATER_SMOKE_ARCHIVE (optional path override)
LEGACY_UPDATER_SMOKE_SIGNATURE (optional path override)
PUBLISHED_080_ARCHIVE (optional path override)
PUBLISHED_080_SIGNATURE (optional path override)
```

`SPARKLE_DISTRIBUTION_ROOT` points at the complete Sparkle 2.9.4 binary
distribution containing `Sparkle.framework`, `bin/generate_appcast` and
`bin/sign_update`. `SPARKLE_ED_KEY_PATH` is a regular non-symlink file with
mode `0400` or `0600`; it contains the base64 Sparkle Ed25519 private key and is
never copied into the App. Because these two tools receive release material and
the private key, their lower-case SHA-256 values must independently match the
audited `SPARKLE_GENERATE_APPCAST_SHA256` and
`SPARKLE_SIGN_UPDATE_SHA256` pins. Do not derive those expected values from the
same untrusted directory during a release. If the requested team has more than one matching
Developer ID Application identity, `CODESIGN_IDENTITY_FINGERPRINT` must be the
exact 40-hex fingerprint. The script never silently selects the first identity.
`LEGACY_MINISIGN` points at the external standard Minisign executable used only
for the temporary 0.7 migration feed.

Before the first release signature, the script authenticates the frozen
published 0.7.0 and 0.8.0 legacy updater archives with the embedded legacy
Minisign public key and requires their exact published SHA-256 values, product
versions and bundle identifier. The default inputs are the corresponding
archive and `.sig` pairs already under `dist/`; the optional path overrides
must still contain those exact bytes and cannot replace the pins. The selected
Developer ID Application fingerprint must equal the frozen 0.7.0 leaf
fingerprint, and both the authenticated 0.8.0 archive and the new App must
contain the frozen 0.8.0 `SUPublicEDKey`. A missing asset, altered wrapper,
different certificate or rotated Sparkle key stops before `codesign`.

`SPARKLE_SIGNATURE_VERIFIER` is a separately audited Ed25519 verifier, not a
build command or a Keychain wrapper. It must be an executable regular
non-symlink file whose lower-case SHA-256 exactly equals
`SPARKLE_SIGNATURE_VERIFIER_SHA256`. Its stable command-line contract is:

```text
verifier --public-key BASE64_RAW_32_BYTE_KEY \
         --signature BASE64_RAW_64_BYTE_SIGNATURE \
         --file EXACT_MESSAGE_FILE
```

`--help` must advertise all three options. Exit status zero means the signature
is valid for the exact bytes of `EXACT_MESSAGE_FILE`; every malformed input,
signature mismatch, read failure or unsupported format must return nonzero. It
must not read a private key, contact a network service, access or unlock a
Keychain, rewrite the input, or accept a digest in place of the file bytes.
Before signing any release artifacts, the release script asks Sparkle 2.9.4
`sign_update` to sign a fresh challenge with the private key file and verifies
that challenge against the App's `SUPublicEDKey`. After `generate_appcast`, it
extracts the signature from the single enclosure whose URL names the current
DMG and verifies the exact DMG bytes with that same App public key. Thus a wrong
private key, wrong App public key, stale enclosure or altered DMG fails closed.

Private keys and credentials never enter the repository or logs. The release
workflow must never invoke `security unlock-keychain`; keychain access is an
operator-controlled prerequisite.

Notarization state is stored under `dist/.release-state/`, keyed by the exact
artifact SHA-256. Once one unambiguous submission ID has been observed, that ID
is permanent for the state: retries only query or wait and never submit again.
A missing or ambiguous ID after a submit attempt fails closed for manual
reconciliation. Accepted artifacts proceed directly to stapling.

One atomic `dist/.release-state/release.lock` covers signing through final feed
generation. A live owner blocks a concurrent release; a stale lock is diagnosed
but never removed automatically. Before fresh signing, all five executable
SHA-256 values must match the bundle's `BuildManifest.plist`. Immediately after
signing, an external state file binds the source commit, signing fingerprint,
App CodeDirectory hash, `CodeResources` SHA-256 and all five signed executable
hashes. `--resume` requires that complete binding to match the existing App and
will not re-sign it. Any previous state for the same version makes a fresh run
fail closed and require explicit `--resume`.

Resume the exact existing artifact without rebuilding or re-signing:

```bash
./scripts/release-macos.sh --resume
```

Do not delete a state file to force another submission. A rejected artifact
requires a new build; a transport failure with a known ID requires resuming the
same state.

## Automatic-update migration

The native 0.8 App uses Sparkle's signed `appcast.xml`, EdDSA enclosure
signatures and Apple code signing. Sparkle performs update verification,
permission handling, atomic replacement and relaunch. Its private EdDSA key is
separate from the legacy updater key.

Production bundles default `SUEnableAutomaticChecks` and
`SUAutomaticallyUpdate` to true. The Config switch writes those two Sparkle
settings through `SPUUpdater`; an explicit user choice therefore overrides the
bundle defaults across later launches. Development bundles continue to disable
the updater when the release public key is absent. Production bundles also pin
`SUScheduledImpatientCheckInterval` to 12 hours, and the App accepts Sparkle's
no-UI immediate-install handler after an automatic download so a long-lived
menu-bar process cannot leave the updater pending indefinitely.

Existing 0.7 clients only understand the previous Minisign-compatible manifest.
Historical 0.8.x through 0.9.1 GitHub Releases therefore carried both feeds:

```text
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz.sig
MihomoBox-X.Y.Z-macos-arm64.dmg
latest.json
appcast.xml
```

`latest.json`, the tar archive and its signature existed only to move installed
0.7 clients onto 0.8. The native App never parses that manifest. The last
legacy bridge remains available on its historical release; 0.9.3 and later do
not regenerate or publish that format.

Replacing the App is not proof that privileged migration succeeded. A real
0.7 acceptance run must continue after relaunch: the native App must classify
the authenticated version-1 daemon as repair-required, keep incompatible
controls disabled, and migrate only after the operator explicitly selects the
verified installer. Acceptance then requires protocol version 2, a current
root-owned `component-version`, matching daemon/agent/Mihomo/CLI artifacts,
exactly one managed runtime, and complete TUN/Fake-IP/DNS health. Also replay
the mixed state produced by 0.8.0 (0.8 App with a 0.7 daemon) and the normal
Sparkle update from a healthy 0.8 daemon.

The signed `appcast.xml` serves 0.8 and later. For 0.9.3 and later its enclosure
is the exact Cloud ZIP. Appcast generation uses tools from the pinned Sparkle
2.9.4 binary distribution, a private key supplied by path and the matching
GitHub tag URL. The release gate independently verifies the enclosure's
Ed25519 signature over those exact ZIP bytes with the public key embedded in
the Cloud App.

## GitHub Release assets

Release titles and descriptions are English. Starting with 0.9.3, the exact
Cloud ZIP and signed appcast are one atomic two-file release set; do not upload
a subset. Historical releases keep their original five-file set unchanged.

Before uploading, freeze SHA-256 values and verify:

- the Cloud ZIP SHA-256 is unchanged after its versioned rename;
- App and all five executables have the expected Cloud leaf certificate;
- App passes code-sign, stapler and Gatekeeper verification;
- `appcast.xml` enclosure URL, length, versions and EdDSA signature match the
  exact Cloud ZIP;
- no asset, state or submission identifier from a previous release is reused.

## License outputs

The project MIT license, `THIRD_PARTY_NOTICES.md`, Mihomo, MetaCubeXD and Sparkle
license texts are bundled. Mihomo remains an unmodified official release
artifact; MetaCubeXD remains a non-shipped design reference.
