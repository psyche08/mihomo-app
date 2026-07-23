# Tray and Controller Contract

The main window is hidden at startup. Tauri uses macOS accessory activation
policy so the tray is the primary interface.

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
selector, but that selector is not a separate user choice. Before enabling
Global mode, the tray resolves the selector chain and ensures it ends at a real
proxy rather than `DIRECT`, `REJECT`, `PASS`, an empty group, or a selector
cycle. It prefers the already selected proxy chain, then a valid user proxy
group, and only then a raw proxy node. The change is accepted only after a
successful `PATCH /configs` and a subsequent controller readback confirms both
the requested mode and the proxy route. Failure is shown as an action error;
the check mark remains controller-owned.

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

The tray has exactly two administrator-authorized entry points: the first TUN
enable when the daemon is not installed, and explicit `Install / Repair
Daemon…`. Once installed, TUN enable/disable, service start/stop/restart,
profile import/switch/reload, outbound mode, proxy selection, and delay tests
all use the signed CLI transport and authenticated XPC. None of those paths
reinvoke the installer or request another administrator dialog.

## XPC Control Mapping

| Action | Typed XPC operation |
|---|---|
| Refresh TUN/mode/nodes/delays | `runtime.snapshot` |
| Test every displayed node | `proxy.test-delay` |
| Enable Enhanced TUN | `runtime.set-tun` |
| Select rule/global/direct | `runtime.set-outbound-mode` |
| Select proxy | `runtime.select-proxy` |
| Reload active profile | `profile.reload` |
| Import/switch profile | `profile.import` / `profile.switch` |
| Start/stop/restart proxy runtime | `agent.start` / `agent.stop` / `agent.restart` |
| MetaCubeXD controller REST | validated `dashboard.controller-request` |
| MetaCubeXD live streams | `dashboard.controller-stream-open/next/close` |

The desktop bridge covers the fixed MetaCubeXD controller contract: config,
proxy and group selection/latency, proxy and rule providers, rules, connection
close, cache flush, GEO refresh, and the `connections`, `traffic`, `memory`, and
`logs` WebSockets. Each browser WebSocket owns one long-lived signed CLI/XPC
session and one long-lived controller WebSocket. Length-framed messages reuse
that path until close; they do not create a process, XPC peer, or upstream
WebSocket per message. The daemon limits concurrent sessions, expires abandoned
sessions, validates method/path/body before forwarding, and injects the
root-owned controller credential. Controller identity fields and
the DNS recursion-boundary keys remain non-editable. A config reload with an
empty payload maps to `profile.reload`; MetaCubeXD's remote-config action may
send a non-empty inline payload through XPC, but must use an empty `path` so the
controller cannot read an arbitrary root-owned file. Runtime restart maps to
`agent.restart`; backend/UI self-upgrade remains blocked because bundled
artifacts must stay pinned, checksummed, and signed.

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
- `Show Main Window`: first request controller `/version` through XPC. If the
  active controller (normally `127.0.0.1:9090`) is unavailable, keep the window
  hidden and show a service-unavailable dialog. On success, refresh the desktop
  bridge, reconnect the local dashboard, unminimize, show, and focus it. The
  dashboard receives a process-random loopback bridge token, never Mihomo's
  root-owned controller secret. The bridge exposes only mapped controller
  operations and forwards them through the signed XPC helper.
- Window close: hide rather than terminate.
- `Exit`: terminate the Tauri user process only; launchd keeps networking alive.
