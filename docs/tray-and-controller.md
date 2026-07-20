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
  <selector group> ›
    ✓ <current proxy>  42 ms
      <other proxy>    88 ms
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

The check mark always represents controller state, not the last click. The tray
polls every five seconds and immediately after a mutation, but replaces the
native menu only when its semantic state or structure changes. Delay-only
updates do not replace a menu that macOS may currently be tracking, so hovering
a submenu is not interrupted by the polling timer. If the controller is
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
lifecycle entry point: when the daemon is absent it opens the signed installer
with administrator authorization; when installed but stopped it starts the
service safely; when the controller is reachable with TUN disabled it enables
TUN; and when checked it confirms before stopping the service and restoring
real system DNS. Profile activation validates `tun.enable: true`, stops the
LaunchDaemon so its unified shutdown restores real DNS, atomically replaces the
configuration, restarts the job, and accepts success only after controller,
TUN, Fake-IP route, DNS bridge, Mihomo DNS, and system DNS are all healthy.

## Mihomo API Mapping

| Action | Request |
|---|---|
| Refresh TUN/mode | `GET /configs` |
| Refresh selectors/nodes/delay history | `GET /proxies` |
| Enable Enhanced TUN | `PATCH /configs` with `tun.enable: true` |
| Select rule/global/direct | `PATCH /configs` with `mode` |
| Select proxy | `PUT /proxies/{group}` with `name` |

Local profile import/switch and network recovery do not use the controller
mutation API. They invoke the signed bundle's privileged installer workflow.
HTTP(S) subscription import first downloads as the logged-in user, supports no
authentication, Basic, Digest, Bearer, and a custom authentication header, and
then gives the privileged installer only a mode-0600 temporary YAML path. The
temporary file is deleted after validation/import; the URL and credentials
never cross the privilege boundary.

The controller binds only to `127.0.0.1:9090`. MetaCubeXD's generated
`config.js` points to the same endpoint, keeping tray and dashboard state on one
backend.

## Window Lifecycle

- Startup: hidden.
- `Show Main Window`: unminimize, show, and focus the MetaCubeXD window.
- Window close: hide rather than terminate.
- `Exit`: terminate the Tauri user process only; launchd keeps networking alive.
