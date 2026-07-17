# Architectural Decisions

## Tauri instead of Electron

The requested distribution uses Tauri v2 for a smaller native shell and a Rust
tray/controller layer. MetaCubeXD remains the dashboard rather than reimplementing
its proxy, rule, connection, and log interfaces.

## Build MetaCubeXD, do not load a hosted panel

Bundled static assets work offline, have deterministic reviewable provenance,
and avoid executing UI code that changed after the App was signed.

## Root daemon owns Mihomo continuously

Switching between a GUI-owned unprivileged process and a root TUN process creates
duplicate-owner and handoff races. One daemon owner keeps the PID, controller,
DNS, and Enhanced TUN state coherent. The GUI never starts a second kernel.

## Copy bundle payloads to stable system paths

A LaunchDaemon that executes inside `/Applications/Mihomo App.app` breaks when
the user moves, replaces, or deletes the App. The signed bundle is the install
source; root-owned copies are the runtime.

## Global DNS API instead of DNS Settings profile

The daemon uses public SystemConfiguration preference APIs and observes network
changes. This removes interactive profile enrollment, certificate/DoH plumbing,
and `mDNSResponder` resolver-path ambiguity.

## Separate port 53 and port 1054

DNS messages do not carry source-process identity. A single listener cannot
reliably distinguish macOS from Mihomo and would permit recursive forwarding.
