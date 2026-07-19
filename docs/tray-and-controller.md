# Tray and Controller Contract

The main window is hidden at startup. Tauri uses macOS accessory activation
policy so the tray is the primary interface.

## Menu

```text
Show Main Window
───────────────
Network: Healthy
✓ Enhanced TUN (required by managed DNS)
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
  ✓ <active profile>.yaml
    <other profile>.yaml
Restart Active Profile Safely
Install / Repair Daemon…
Stop Service & Restore Network…
───────────────
Exit
```

The check mark always represents controller state, not the last click. The tray
refreshes every five seconds and immediately after a mutation. If the
controller is unavailable, controller mutations are disabled while profile
switching, daemon repair, and network recovery remain available.

Managed system DNS requires Enhanced TUN. The tray can enable TUN but cannot
directly disable it. Profile activation validates `tun.enable: true`, stops the
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

The controller binds only to `127.0.0.1:9090`. MetaCubeXD's generated
`config.js` points to the same endpoint, keeping tray and dashboard state on one
backend.

## Window Lifecycle

- Startup: hidden.
- `Show Main Window`: unminimize, show, and focus the MetaCubeXD window.
- Window close: hide rather than terminate.
- `Exit`: terminate the Tauri user process only; launchd keeps networking alive.
