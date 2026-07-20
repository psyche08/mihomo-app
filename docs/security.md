# Security Model

## Trust Boundaries

- MetaCubeXD is immutable local content inside the signed App. It receives no
  shell or privileged Tauri capability. Its CSP permits controller traffic
  only to loopback `127.0.0.1` ports.
- The controller is loopback-only and always uses bearer authentication. An
  empty profile secret is replaced by a persistent random 256-bit secret during
  privileged profile activation. Wildcard binds are reduced to loopback and a
  concrete remote host is rejected.
- Privileged installation is an explicit menu action and uses the macOS
  administrator dialog. No credential is captured by the application.
- Remote installation uses the same bundled installer through an authenticated
  SSH session and `sudo`; the App does not store or relay the administrator
  credential.
- launchd executes stable root-owned copies, never files in a user-writable Git
  checkout or movable App bundle.

## Supply Chain

- MetaCubeXD uses a pinned tag.
- Mihomo uses a pinned release and SHA-256.
- Cargo/npm/pnpm lockfiles pin package dependency graphs.
- Third-party license notices ship with the application.

## Sensitive Data

Do not log or publish:

- DNS query names or packets;
- proxy nodes containing credentials;
- subscription URLs;
- controller tokens;
- notarization credentials.

Tray labels necessarily show configured proxy names and current latency to the
local logged-in user; they are never written to daemon logs.

The controller secret is stored in mode-`0600` root-owned runtime files and a
mode-`0640`, root:`admin` GUI metadata file. It is injected into the local
MetaCubeXD endpoint only when the main window is shown and is never printed by
installer, tray, or daemon logging.

HTTP subscription credentials live only in the importing process and are not
persisted. Tray credential fields use hidden input. CLI secrets use a hidden
TTY prompt or `--secret-stdin`; password/token values are never command-line
arguments. Downloads use an ephemeral URL session, reject non-HTTP(S) and HTTPS
downgrade redirects, remove authentication headers on cross-origin redirects,
cap the response at 16 MiB, and pass only a mode-0600 temporary YAML file to the
root installer.

## Recovery Guarantees

- Original DNS is backed up before mutation.
- Restore is compare-before-write and respects external changes.
- Pre-existing `127.0.0.53` aliases are not removed.
- Original-DNS sockets bind to the physical interface to avoid TUN recursion.
- A stale PID is terminated only after executable-path verification.
