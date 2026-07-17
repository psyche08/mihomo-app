# Mihomo App

An open-source native macOS menu-bar controller for Mihomo.

- Tauri v2 application with a hidden-by-default main window.
- App and tray artwork is derived from Mihomo's official `Meta.png`.
- MetaCubeXD is built and embedded as the main dashboard.
- Tray controls Enhanced TUN, outbound mode, proxy selection with latency,
  profile reload, daemon installation, and exit.
- The App bundle contains architecture-matched `mihomo` and
  `mihomo-daemon` executables under `Contents/MacOS`.
- The root daemon supervises Mihomo and provides DHCP-aware system DNS without
  a DNS Settings profile.

## Build

Requirements: macOS 14+, Xcode/Swift, Rust, Node.js, npm, pnpm, and `dig`.

```bash
npm install
npm run build
```

The build pins MetaCubeXD `v1.269.0`, Mihomo `v1.19.28`, and verifies the
Mihomo release checksum before bundling.

Install or repair the privileged daemon from the tray, or inspect the operation
first:

```bash
sudo scripts/install-daemon.sh --dry-run
```

Restore Global DNS and remove the daemon:

```bash
sudo scripts/install-daemon.sh --restore
```

## Documentation

Start with [AGENTS.md](AGENTS.md). It routes architecture, daemon/DNS, tray API,
build/release, operations, security, and decision records without loading all
implementation context at once.

This project is MIT licensed. MetaCubeXD and Mihomo remain independent upstream
projects; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
