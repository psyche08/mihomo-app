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

`scripts/prepare-binaries.sh` builds the Swift release daemon and stages both
external binaries. Tauri places them in `Contents/MacOS` without the target
suffix.

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
`NOTARY_TEAM_ID`. Credentials are supplied only through:

```text
NOTARY_TEAM_ID
NOTARY_APPLE_ID
NOTARY_PASSWORD
```

Run `scripts/release-macos.sh`; it selects the matching identity, builds and
signs the Tauri bundle, submits the archive with `notarytool`, staples the App,
and verifies Gatekeeper. Never print credential values.

## License Outputs

The project MIT license and `THIRD_PARTY_NOTICES.md` are bundled. Generated
MetaCubeXD assets include the upstream full license text. Mihomo binaries are
unmodified official release artifacts.
