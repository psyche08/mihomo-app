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

The check mark always represents controller state, not the last click. The tray
polls every five seconds and immediately after a mutation, but replaces the
native menu only when its semantic state or structure changes. Delay-only
updates do not replace a menu that macOS may currently be tracking, so hovering
a submenu is not interrupted by the polling timer. `Test Now` concurrently
calls the delay endpoint for every leaf proxy and then explicitly refreshes the
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
activation validates `tun.enable: true`, stops the LaunchDaemon so its unified
shutdown restores real DNS, atomically replaces the configuration, restarts
the job, and accepts success only after controller, TUN, Fake-IP route, DNS
bridge, Mihomo DNS, and system DNS are all healthy.

## Mihomo API Mapping

| Action | Request |
|---|---|
| Refresh TUN/mode | `GET /configs` |
| Refresh selectors/nodes/delay history | `GET /proxies` |
| Test every displayed node | `GET /proxies/{node}/delay` |
| Enable Enhanced TUN | `PATCH /configs` with `tun.enable: true` |
| Select rule/global/direct | `PATCH /configs` with `mode` |
| Select proxy | `PUT /proxies/{group}` with `name` |

Local YAML import does not use the controller mutation API or request
administrator authorization. It copies the selected regular file into the
current user's mode-`0700` MihomoBox profile directory as a mode-`0600` file
and marks it selected, so it is immediately visible in the tray. The signed
installer is still the only component that validates and copies that profile
into the root-owned runtime when Enhanced TUN is enabled. Switching an
installed daemon's profile and network recovery also use that privileged
installer workflow.
HTTP(S) subscription import first downloads as the logged-in user, supports no
authentication, Basic, Digest, Bearer, and a custom authentication header, and
then gives the privileged installer only a mode-0600 temporary YAML path. The
temporary file is deleted after validation/import; the URL and credentials
never cross the privilege boundary.

Profile activation reads `external-controller` and `secret`. The controller
port is preserved, while `localhost` and wildcard binds are normalized to
`127.0.0.1`; concrete remote hosts are rejected. An empty secret causes the
installer to generate and reuse a random 256-bit secret. The root-owned active
Mihomo configuration and daemon
configuration receive the same endpoint and secret, while a mode-`0640`,
root:`admin` metadata file provides them to the current-user Tauri client.
Every tray, daemon-health, and MetaCubeXD request uses the bearer secret.

## Window Lifecycle

- Startup: hidden.
- `Show Main Window`: load the active profile's persisted endpoint and secret,
  select the managed `local-mihomo` MetaCubeXD endpoint, reconnect, unminimize,
  show, and focus the window.
- Window close: hide rather than terminate.
- `Exit`: terminate the Tauri user process only; launchd keeps networking alive.
