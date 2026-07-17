# AGENTS.md

`mihomo-app` is an open-source macOS menu-bar application. Tauri owns the GUI
and tray; the root `mihomo-daemon` owns the bundled Mihomo process, Enhanced
TUN privilege, DHCP-aware DNS forwarding, and macOS Global DNS.

## Always On

1. Preserve the privilege boundary: WebView content never executes privileged
   commands. Only the signed installer may install or repair the LaunchDaemon.
2. `mihomo-daemon` is the sole owner of the managed Mihomo process. Do not add
   a second GUI-owned kernel process.
3. Keep macOS DNS (`127.0.0.53:53`) separate from Mihomo's original-DNS escape
   (`127.0.0.1:1054`) to prevent recursion.
4. Never log DNS names, packets, subscription URLs, controller secrets, or
   proxy credentials.
5. Pin and checksum bundled upstream artifacts. Retain third-party licenses.
6. Validate Swift, Rust, MetaCubeXD generation, installer dry-run, and the final
   `.app` bundle before release.

## Progressive Disclosure

Load only the document matching the current task.

| Task | Read |
|---|---|
| Component/process/privilege architecture | [docs/architecture.md](docs/architecture.md) |
| DNS, Global DNS, alias, process supervision | [docs/daemon-and-dns.md](docs/daemon-and-dns.md) |
| Tray menu and Mihomo controller API | [docs/tray-and-controller.md](docs/tray-and-controller.md) |
| Build, upstream pins, signing, notarization | [docs/build-release.md](docs/build-release.md) |
| Installation, restoration, logs, diagnosis | [docs/operations.md](docs/operations.md) |
| Trust boundary and threat model | [docs/security.md](docs/security.md) |
| Architectural decisions and rejected options | [docs/decisions.md](docs/decisions.md) |

## Validation Entry

```bash
./scripts/validate.sh
```

Deployment and privileged installation are never implied by validation.
