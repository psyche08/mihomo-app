# Tray and Controller Contract

The main window is native SwiftUI and hidden at startup. A pure Swift
`NSApplicationDelegate` keeps the macOS accessory activation policy and event
loop, `NSStatusItem` owns the tray, Sparkle owns App updates, and an in-process
`NSHostingController` owns the dashboard window.

## Menu

```text
Show Main Window
───────────────
Network: Healthy
✓ Enhanced TUN
───────────────
Outbound Mode ›
  ✓ Rule
    Global
    Direct
Proxy List ›
  Test Now
  ───────────────
  ✓ 🇯🇵 <current proxy>    🟢 256 ms
    🇺🇸 <other proxy>      🟠 324 ms
Profiles ›
  Import Local YAML…
  Import HTTP Subscription…
  ✓ <active profile>.yaml
    <other profile>.yaml
Reload Profiles
───────────────
Tools ›
  Install / Repair Daemon…
  Open Diagnostic Logs…
  Check for Updates…
───────────────
Exit
```

The check mark always represents agent/controller state returned over XPC, not
the last click. The tray polls every five seconds and immediately after a mutation, but replaces the
native menu only when its semantic state or structure changes. Delay-only
updates do not replace a menu that macOS may currently be tracking, so hovering
a submenu is not interrupted by the polling timer. `Test Now` concurrently
asks the daemon to test every leaf proxy and then explicitly refreshes the
displayed latency. Proxy groups, nested selectors, and built-in direct/reject
targets are omitted from this flat node list. If the controller is
unavailable, controller mutations are disabled while profile switching, daemon
repair, and network recovery remain available.

Outbound mode semantics are user-facing rather than selector-facing:

- `Rule` follows the configured rules.
- `Global` sends all traffic through a proxy.
- `Direct` sends all traffic directly.

Mihomo internally implements Global mode through its built-in `GLOBAL`
selector, but that selector is not a separate user choice. The root daemon
resolves the selector chain and ensures it ends at a real
proxy rather than `DIRECT`, `REJECT`, `PASS`, an empty group, or a selector
cycle. It prefers the already selected proxy chain, then a valid user proxy
group, and only then a raw proxy node. Mode and selector changes are one
daemon-serialized transaction: before-state, mutation, authoritative readback,
and rollback cannot be interleaved by another signed client. If rollback or
network restoration cannot be proved, the daemon stops the agent and restores
DNS. The App sends one typed XPC request and renders the returned snapshot; it
does not repeat rollback or stop decisions outside the privilege boundary.

Managed system DNS requires Enhanced TUN. This item is also the service
lifecycle entry point: without a selected profile it first tells the user to
add one; when the daemon is absent it opens the signed installer with
administrator authorization and supplies the selected profile for the first
start; when installed but stopped it starts the service safely; when the
controller is reachable with TUN disabled it enables TUN; and when checked it
confirms before stopping the service and restoring real system DNS. Profile
activation validates `tun.enable: true`, stops the agent so its unified
shutdown restores real DNS, atomically replaces the configuration, restarts
the agent, and accepts success only after controller, TUN, Fake-IP route, DNS
bridge, Mihomo DNS, and system DNS are all healthy.

The first time an installed App observes that Enhanced TUN and the managed
network are both healthy, the native App enables a current-user macOS login
item. This is a one-time default: a cancelled or failed action that never
reaches healthy runtime state cannot register anything, and MihomoBox does not
re-add the login item after the user later turns it off in System Settings.
Only an App under `/Applications` or `~/Applications` can apply the default, so
a DMG, App Translocation, Downloads copy, or development smoke build cannot
persist a temporary path. The AppKit shell writes and validates the user-level
LaunchAgent atomically; SwiftUI views receive no LaunchAgent write API. The login
item starts the hidden menu-bar App after login and does not directly launch
Mihomo or execute a privileged operation.

The tray has exactly two administrator-authorized entry points: the first TUN
enable when the daemon is not installed, and explicit `Install / Repair
Daemon…`. Once installed, TUN enable/disable, service start/stop/restart,
profile import/switch/reload, outbound mode, proxy selection, and delay tests
all use the native typed client and authenticated XPC. None of those paths
reinvoke the installer or request another administrator dialog.

## XPC Control Mapping

| Action | Typed XPC operation |
|---|---|
| Refresh TUN/mode/nodes/delays | `runtime.snapshot` |
| Test every displayed node | `proxy.test-delay` |
| Enable Enhanced TUN | `runtime.set-tun` |
| Select rule/global/direct | `runtime.set-outbound-mode` |
| Select proxy | `runtime.select-proxy` |
| Refresh proxy provider | `runtime.refresh-proxy-provider` |
| Reload active profile | `profile.reload` |
| Import/switch profile | `profile.import` / `profile.switch` |
| Start/stop/restart proxy runtime | `agent.start` / `agent.stop` / `agent.restart` |
| SwiftUI controller reads/mutations | typed operations or validated `dashboard.controller-request` |
| SwiftUI live streams | `dashboard.controller-stream-open/next/close` |

The native `ControlGateway` covers config, proxy/group selection and latency,
proxy and rule providers, rules, connection close, cache flush, GEO refresh,
and the `connections`, `traffic`, `memory`, and `logs` streams. Ordinary calls
reuse one serialized signed XPC session. Each live stream owns a separate XPC
session so a blocking stream cannot starve mutations; closing or hiding the
window cancels the Swift task and explicitly closes its daemon-side stream.
The daemon binds every stream identifier to the XPC peer that opened it, so a
different signed peer cannot read or close that stream. Frames are bounded to
16 MiB and histories/logs are bounded in memory.

`DashboardStore` consumes only that typed gateway in normal builds. It loads
the static catalogs again when their page is opened, refreshes proxy and rule
providers after profile reload/restart, and derives Usage only from the live
connection/traffic streams. Connection close is not applied optimistically:
the store reads `/connections` back before changing the displayed state. Proxy
selection, outbound mode, Allow LAN, Unified Delay, IPv6, core log level, TCP
concurrency, and process lookup mode likewise use typed mutations followed by
controller readback. A refused action remains visible as an in-window error.
Preview fixtures require an explicit development flag and a checkout build
path; an installed application cannot enter preview mode.

There is no loopback HTTP server, browser token, WebView, or `mihomoboxctl`
child process in the desktop data path. The daemon still validates every
method/path/body and injects the root-owned controller credential. The public
Swift gateway exposes fixed actions and safe runtime patches only; controller
identity, DNS recursion-boundary keys, and every TUN field remain
unrepresentable. Profile reload maps to `profile.reload`, runtime restart maps
to `agent.restart`. The daemon accepts either restart only after a bounded,
fresh read proves controller, TUN, Fake-IP mode and route, both DNS bridges,
system DNS ownership, network consistency, and a safe Global selector chain.
Failure rolls the profile back when possible and otherwise stops the runtime;
the window only waits for the resulting authoritative snapshot. Backend/UI self-upgrade
remains blocked because bundled artifacts must stay pinned, checksummed, and
signed.

Local YAML import copies the selected regular file into the current user's
mode-`0700` staging directory as a mode-`0600` file so it is immediately visible
in the tray. When the daemon is installed, the desktop sends bounded profile
bytes—not a user-controlled path—through authenticated XPC. The daemon validates
and atomically installs/reloads it without another administrator prompt.
HTTP(S) subscription import first downloads as the logged-in user, supports no
authentication, Basic, Digest, Bearer, and a custom authentication header, and
then sends only bounded YAML bytes through XPC. The URL and credentials never
cross the privilege boundary.

Profile activation reads `external-controller` and `secret`. The controller
port is preserved, while `localhost` and wildcard binds are normalized to
`127.0.0.1`; concrete remote hosts are rejected. An empty secret causes the
installer to generate and reuse a random 256-bit secret. The root-owned active
Mihomo configuration and daemon
configuration receive the same endpoint and secret. Controller credentials stay
root-owned; Desktop and CLI receive typed state/results rather than the secret.

## Window Lifecycle

- Startup: hidden.
- Login startup: after the one-time default above has been applied, macOS starts
  the current-user App hidden. The root LaunchDaemon separately restores the
  managed service and its `tun.enable: true` profile at system startup.
- `Show Main Window`: create or reuse the single SwiftUI `NSWindow`, unminimize,
  show, and focus it. The store immediately loads an authenticated XPC snapshot
  and starts four independent bounded streams. If the daemon/controller is
  unavailable, the window stays visible with a reconnectable offline state;
  it never receives Mihomo's root-owned controller secret.
- Window resize: AppKit owns the resizable window bounds and SwiftUI fills the
  current content area instead of driving the window back to its ideal size.
  MihomoBox persists the last non-full-screen frame after a live resize, hide,
  or exit, restores it on the next process launch, and clamps stale geometry to
  a currently visible display and the dashboard's minimum content size.
- Window close: hide rather than terminate.
- Window hide/minimize: cancel live streams; showing restarts them idempotently.
- `Exit`: cancel user-process tasks, tear down the SwiftUI host, remove the
  status item, then terminate only the Swift user process;
  launchd keeps networking alive.
