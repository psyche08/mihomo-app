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
7. Production release artifacts are built, Developer ID signed, notarized and
   packaged only by Xcode Cloud, with one migration exception: version 0.9.1
   may reuse the already-built App bound to commit `acb6f38`, sign with the
   published Developer ID leaf, notarize through `tools/notarytool-rs`, package
   locally and publish to GitHub. This exception must not rebuild or re-sign
   the accepted App and expires after 0.9.1. Any later external publication or
   distribution must use the exact Cloud artifacts. Local development may
   compile, test and validate with ad-hoc signing. Compilation or validation
   never implies authorization to publish or deploy.
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
