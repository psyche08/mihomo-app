# Architectural Decisions

## Pure Swift/AppKit application shell

MihomoBox 0.8 replaces the remaining Tauri/Rust user-process shell with one
Swift executable. `NSApplicationDelegate` owns the accessory lifecycle,
`NSStatusItem` owns the tray, and `NSHostingController` owns the SwiftUI
dashboard. The user process talks directly to the existing authenticated XPC
client library; there is no WebView, Rust FFI, loopback bridge, or CLI child in
the desktop control path.

The executable remains named `mihomo-app`, the bundle identifier remains
`dev.linsheng.mihomo-app`, and the installed bundle remains `MihomoBox.app`.
Those stable identities let existing login items, installers, root-component
synchronization, and 0.7-to-0.8 replacement target the same product.

## Native SwiftUI dashboard instead of a bundled WebView

The original build embedded pinned MetaCubeXD static assets. The dashboard is
now reimplemented with SwiftUI while retaining MetaCubeXD's
seven-page information architecture and Sunset visual reference. This removes
the loopback HTTP/token bridge and browser-to-CLI transport, integrates with
macOS accessibility, and keeps all controller access behind a typed signed XPC
gateway. The MetaCubeXD tag and license remain pinned for reproducible design
provenance; no upstream JavaScript executes in the App.

## Sparkle instead of an application-specific updater

The native shell uses pinned Sparkle 2.9.4 for EdDSA verification, Apple code
signature validation, atomic replacement, authorization when necessary, and
relaunch. MihomoBox does not implement its own archive extractor or updater.
The appcast is served over HTTPS and is signed; system profiling is disabled.

The first native releases published two update contracts. Existing 0.7 clients
received the legacy `latest.json` and minisign-compatible archive signature,
while 0.8 and later clients use Sparkle's signed `appcast.xml`. Starting with
0.9.3, the legacy bridge is no longer regenerated: the Sparkle enclosure is the
exact ticket-attached Xcode Cloud App ZIP, renamed without changing its bytes.
Only the signed appcast metadata is generated locally. Historical legacy
assets remain available on their original releases.

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

## Exact signing-certificate family instead of Team ID only

The App and CLI use different signing identifiers, so requiring one identifier
would reject a legitimate peer. Team ID alone accepts any other product signed
by that team. Both XPC sides instead derive a peer code-signing requirement from
their leaf certificate. During normal operation this is one leaf. The bounded
0.9.1 Xcode Cloud transition adds only the explicitly pinned published and
Cloud leaves so an old-signed bridge and a new-signed release can replace each
other's privileged components. This permits the signed MihomoBox family while
rejecting another certificate, invalid signature, ad-hoc build, or unsigned
binary. The Cloud leaf must be learned from an audited Developer ID archive and
committed before publishing the bridge; Team ID is never a migration shortcut.

## Copy bundle payloads to stable system paths

A LaunchDaemon that executes inside `/Applications/MihomoBox.app` breaks when
the user moves, replaces, or deletes the App. The signed bundle is the install
source; root-owned copies are the runtime.

## Login startup follows a healthy Enhanced TUN activation

First launch alone does not add a login item or prompt for administrator
access. After the native App observes Enhanced TUN and the managed network both
healthy, it applies a one-time current-user login-start default. This also
migrates an already-healthy installation. A later user override is retained;
the App does not repeatedly re-register the item. The unprivileged login item
only restores the hidden tray App, while the root LaunchDaemon independently
restores LocalHttpDns and the persisted standby/Enhanced state at system startup.

## LocalHttpDns as the base service, Enhanced TUN as an optional layer

MihomoBox normally leaves the PrimaryService and Global DNS server list alone.
Installing the root helper establishes a valid controller/DNS standby
with TUN off. The daemon then prepares a manual DNS Settings profile with
`SupplementalMatchDomains` and an embedded local root certificate. Enhanced
TUN is unavailable until macOS reports that fixed profile installed and the
daemon-owned `127.0.0.1:443` endpoint is live.

The endpoint remains available when Mihomo restarts or TUN is disabled. It
prefers Mihomo DNS only for a completely healthy Enhanced runtime and otherwise
resolves through the current physical/scoped DNS. Manual profile confirmation
is retained because macOS does not permit the `profiles` CLI to install a
configuration profile interactively on the user's behalf. A failed LocalHttpDns
startup or preparation falls back to Global DNS at `198.18.0.1:53` with TUN
required. The daemon removes its fixed DoH profile so it cannot override Global
DNS, retaining the identity for retry. Failed removal remains visible in Config.
Port 9443 is released. A wildcard 443 listener cannot be evaded by binding a
different local IPv4 address; the TUN address also cannot support an independent
always-on HTTPS resolver.

## Separate port 53 and port 1054

DNS messages do not carry source-process identity. A single listener cannot
reliably distinguish macOS from Mihomo and would permit recursive forwarding.
