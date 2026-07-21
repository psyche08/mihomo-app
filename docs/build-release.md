# Build and Release

## Pinned Inputs

| Component | Pin | Verification |
|---|---|---|
| Tauri | `2.11.x` Cargo/npm lockfiles | Cargo/npm integrity metadata |
| MetaCubeXD | tag `v1.269.0`, commit `6802999f204fdb7a97b41ade2f49693ed5eab8c9` | exact revision check; MIT license copied |
| Mihomo | release `v1.19.28` | architecture-specific SHA-256 |
| App icon | upstream Mihomo `Meta.png` | bundled source SHA-256 |

`scripts/prepare-metacubexd.sh` builds the upstream static dashboard and
overlays only `config.js`. It does not fork or patch MetaCubeXD source.

`scripts/fetch-mihomo.sh` selects the target-triple asset, verifies the pinned
archive checksum, and stages the executable using Tauri's required
`name-<target-triple>` convention.

`scripts/prepare-binaries.sh` builds the Swift release daemon, agent, and XPC
client and stages all external binaries. Tauri places them in `Contents/MacOS`
without the target suffix.

SwiftPM and Cargo both cache absolute build paths. Their preparation scripts
record the project root and clean only generated caches when the checkout moves.

`scripts/prepare-icons.sh` verifies the checked-in official Mihomo `Meta.png`
and all derived PNG/ICNS outputs by SHA-256. Generated icons are committed;
normal builds do not rewrite ICNS metadata.

## Local Validation

```bash
./scripts/validate.sh
```

The final bundle check must prove:

```text
MihomoBox.app/Contents/MacOS/mihomo-app
MihomoBox.app/Contents/MacOS/mihomo
MihomoBox.app/Contents/MacOS/mihomo-daemon
MihomoBox.app/Contents/MacOS/mihomo-agent
MihomoBox.app/Contents/MacOS/mihomoboxctl
```

For an explicit window smoke test without changing the default hidden startup:

```bash
MIHOMO_APP_SMOKE_SHOW_WINDOW=1 \
  'src-tauri/target/release/bundle/macos/MihomoBox.app/Contents/MacOS/mihomo-app'
```

## Signing and Notarization

Unsigned local builds are acceptable for development only. Release builds use
the Developer ID Application certificate whose team matches
`NOTARY_TEAM_ID`. The app, daemon, agent, and CLI helper are signed with that
same leaf certificate because the XPC boundary rejects a differently signed
peer. Credentials are supplied only through:

```text
NOTARY_TEAM_ID
NOTARY_APPLE_ID
NOTARY_PASSWORD
```

Run `scripts/release-macos.sh`; it selects the matching identity, builds and
signs the Tauri bundle, submits the App archive with `notarytool`, staples the
App, creates and signs the DMG, submits and staples the DMG, and verifies both
artifacts with Gatekeeper. Never print credential values.

## Automatic Updates

The signed App checks the latest GitHub release manifest ten seconds after
startup. A newer version is downloaded, verified with the updater public key,
installed, and the App restarts. This updates only the user-owned App bundle;
it never modifies the root LaunchDaemon. Daemon replacement remains an explicit
**Install / Repair Daemon** action so the signed installer retains the sole
privileged installation boundary.

The updater private key is not part of the repository. Local releases default
to `~/.tauri/mihomobox.key`, or use `TAURI_SIGNING_PRIVATE_KEY` /
`TAURI_UPDATER_KEY_PATH`. Losing or rotating this key prevents already-installed
clients from accepting later updates.

Each GitHub release must publish these assets from `dist/` under tag `vX.Y.Z`:

```text
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz
MihomoBox-X.Y.Z-macos-arm64.app.tar.gz.sig
MihomoBox-X.Y.Z-macos-arm64.dmg
latest.json
```

`latest.json` points `darwin-aarch64` at the versioned updater archive. The
archive is generated from the notarized and stapled App, then signed with the
Tauri updater key. GitHub's `releases/latest/download/latest.json` endpoint is
the stable update feed.

## License Outputs

The project MIT license and `THIRD_PARTY_NOTICES.md` are bundled. Generated
MetaCubeXD assets include the upstream full license text. Mihomo binaries are
unmodified official release artifacts.
