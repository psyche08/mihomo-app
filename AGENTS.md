# AGENTS.md

`mihomo-app` is an open-source macOS menu-bar application. A pure Swift/AppKit
shell owns the app lifecycle, tray, Sparkle updater, and login startup; an
in-process SwiftUI module owns the main window. The root `mihomo-daemon` owns the bundled Mihomo process,
Enhanced TUN privilege, DHCP-aware DNS forwarding, and macOS Global DNS.

## Always On

1. Preserve the privilege boundary: the SwiftUI client exposes only typed
   controller actions over authenticated XPC. Only the signed installer may
   install or repair the LaunchDaemon.
2. `mihomo-daemon` is the sole owner of the managed Mihomo process. Do not add
   a second GUI-owned kernel process.
3. Keep macOS DNS (`127.0.0.53:53`) separate from Mihomo's original-DNS escape
   (`127.0.0.1:1054`) to prevent recursion.
4. Never log packets, subscription URLs, controller secrets, or proxy
   credentials. Error and warning lines from the proxy kernel are the one
   exception to naming things: they may carry the host, the address, the reason
   and the proxy in use, because a count alone cannot diagnose a fault after it
   has passed — a proxy that accepts connections and never completes one fails
   by timing out, which the kernel reports at warning. Credentials are stripped
   from them regardless (`SanitizedProcessLogRedaction`), and each window keeps
   only a bounded sample. Info stays counted only.
5. Pin and checksum bundled upstream artifacts. Retain third-party licenses.
6. Validate Swift, the pinned Sparkle package and MetaCubeXD visual reference,
   installer dry-run, and the final `.app` bundle before release.
7. Starting with 1.1.0, production Apps are built and Developer ID signed
   locally using the Xcode project, notarized and stapled locally through
   `scripts/release-local.zsh`. Preserve the published local certificate,
   Sparkle key, bundle identifiers and migration certificate allowlist.
   Publish the signed, ticket-attached ZIP and signed appcast as one release.
   Historical Cloud releases retain their exact original bytes; the frozen
   0.9.1 bridge remains historical only. Compilation and validation do not
   authorize installation or publication.
8. Never execute `security unlock-keychain`, directly or indirectly. Keychain
   availability is an operator-controlled prerequisite; scripts and agents
   must fail closed instead of unlocking it.

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
