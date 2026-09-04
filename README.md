# MihomoBox

An open-source native macOS menu-bar controller for Mihomo.

- Pure Swift/AppKit menu-bar shell with a hidden-by-default SwiftUI main window.
- App artwork is derived from Mihomo's official `Meta.png`; the tray embeds
  that exact pinned artwork as its template icon.
- The seven-page dashboard follows MetaCubeXD's information architecture and
  Sunset visual language, implemented natively with SwiftUI.
- Tray controls include Enhanced TUN, outbound mode, proxy selection with
  latency, local and authenticated HTTP(S) YAML import/switch, network
  recovery, daemon installation, and exit.
- The App bundle contains architecture-matched `mihomo`, `mihomo-daemon`,
  `mihomo-agent`, and `mihomoboxctl` executables under `Contents/MacOS`.
- The root daemon supervises Mihomo and provides DHCP-aware system DNS without
  a DNS Settings profile.
- Sparkle verifies and atomically installs signed App updates; desktop control
  goes directly from Swift to authenticated Mach XPC.

## Build

Requirements: macOS 14+, Xcode/Swift, `pnpm` for refreshing the pinned visual
reference, `minisign` for the temporary 0.7 updater compatibility asset, and
`dig`.

Compilation is intentionally operator-executed outside agent sandboxes. Use the
native build command documented in [docs/build-release.md](docs/build-release.md).

The build pins Mihomo `v1.19.30` and verifies its release checksum before
bundling. MetaCubeXD `v1.271.0` remains pinned as the reproducible design and
interaction reference for the native UI.

Install or repair the privileged daemon from the tray, or inspect the operation
first:

```bash
scripts/install-daemon.sh --app-bundle ./build/MihomoBox.app --dry-run
```

Restore system DNS and remove the daemon through the signed bundled CLI:

```bash
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl uninstall
```

Import and transactionally activate a local profile over authenticated XPC:

```bash
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl \
  profile import /path/to/profile.yaml --activate
```

After installation, the same safe operations are available through the CLI:

```bash
mihomoboxctl status
mihomoboxctl profile list
mihomoboxctl profile import ~/Desktop/profile.yaml --activate
mihomoboxctl profile import-url https://example.invalid/profile.yaml \
  --name remote.yaml --auth bearer --activate
mihomoboxctl restart
mihomoboxctl stop
```

Read-only and normal runtime/profile mutations use authenticated XPC without
elevation. Only `install`, `uninstall`, and explicit repair enter the verified
App-snapshot installer boundary and request administrator authorization.

## Documentation

Start with [AGENTS.md](AGENTS.md). It routes architecture, daemon/DNS, tray API,
build/release, operations, security, and decision records without loading all
implementation context at once.

This project is MIT licensed. MetaCubeXD and Mihomo remain independent upstream
projects; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
