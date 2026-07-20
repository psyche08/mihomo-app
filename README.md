# MihomoBox

An open-source native macOS menu-bar controller for Mihomo.

- Tauri v2 application with a hidden-by-default main window.
- App and tray artwork is derived from Mihomo's official `Meta.png`.
- MetaCubeXD is built and embedded as the main dashboard.
- Tray controls required Enhanced TUN, outbound mode, proxy selection with
  latency, local and authenticated HTTP(S) YAML import/switch, network
  recovery, daemon installation, and exit.
- The App bundle contains architecture-matched `mihomo`, `mihomo-daemon`, and
  `mihomoboxctl` executables under `Contents/MacOS`.
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

Restore system DNS and remove the daemon:

```bash
sudo scripts/install-daemon.sh --restore
```

Import and transactionally activate a local profile:

```bash
sudo scripts/install-daemon.sh --import-profile /path/to/profile.yaml --activate
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

Read-only commands do not require elevated privileges. Mutating commands enter
the same bundled installer boundary and request authorization with `sudo`.

## Documentation

Start with [AGENTS.md](AGENTS.md). It routes architecture, daemon/DNS, tray API,
build/release, operations, security, and decision records without loading all
implementation context at once.

This project is MIT licensed. MetaCubeXD and Mihomo remain independent upstream
projects; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
