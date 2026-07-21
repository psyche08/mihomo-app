# Architectural Decisions

## Tauri instead of Electron

The requested distribution uses Tauri v2 for a smaller native shell and a Rust
tray/controller layer. MetaCubeXD remains the dashboard rather than reimplementing
its proxy, rule, connection, and log interfaces.

## Build MetaCubeXD, do not load a hosted panel

Bundled static assets work offline, have deterministic reviewable provenance,
and avoid executing UI code that changed after the App was signed.

## Root agent owns Mihomo continuously

Switching between a GUI-owned unprivileged process and a root TUN process creates
duplicate-owner and handoff races. One agent owner keeps the PID, controller,
DNS, and Enhanced TUN state coherent. The GUI never starts a second kernel.

## Privileged daemon is an authenticated XPC broker

Putting XPC policy, DNS, network observation, and Mihomo supervision in one
process makes the privileged attack surface unnecessarily broad. The daemon is
therefore limited to mutual code-signing authentication, typed command
authorization, serialized profile/lifecycle transactions, and agent
supervision. The agent owns the network data plane and has no client-facing
service.

## Exact signing certificate instead of Team ID only

The App and CLI use different signing identifiers, so requiring one identifier
would reject a legitimate peer. Team ID alone accepts any other product signed
by that team. Both XPC sides instead derive a peer code-signing requirement from
their leaf certificate. This permits the signed MihomoBox family while
rejecting another certificate, invalid signature, ad-hoc build, or unsigned
binary.

## Copy bundle payloads to stable system paths

A LaunchDaemon that executes inside `/Applications/MihomoBox.app` breaks when
the user moves, replaces, or deletes the App. The signed bundle is the install
source; root-owned copies are the runtime.

## SystemConfiguration DNS instead of a DNS Settings profile

The agent uses public SystemConfiguration preference APIs, manages the active
PrimaryService, and observes per-service resolver changes. This removes
interactive profile enrollment and certificate/DoH plumbing while retaining
macOS supplemental-domain and interface routing information.

## Separate port 53 and port 1054

DNS messages do not carry source-process identity. A single listener cannot
reliably distinguish macOS from Mihomo and would permit recursive forwarding.
