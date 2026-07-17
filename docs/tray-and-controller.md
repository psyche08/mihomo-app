# Tray and Controller Contract

The main window is hidden at startup. Tauri uses macOS accessory activation
policy so the tray is the primary interface.

## Menu

```text
Show Main Window
───────────────
✓ Enhanced TUN
Outbound Mode ›
  ✓ Rule
    Global
    Direct
Proxy List ›
  <selector group> ›
    ✓ <current proxy>  42 ms
      <other proxy>    88 ms
Reload Profile
Install / Repair Daemon…
───────────────
Exit
```

The check mark always represents controller state, not the last click. The tray
refreshes every five seconds and immediately after a mutation. If the
controller is unavailable, state-changing items are disabled and the daemon
installer remains available.

## Mihomo API Mapping

| Action | Request |
|---|---|
| Refresh TUN/mode | `GET /configs` |
| Refresh selectors/nodes/delay history | `GET /proxies` |
| Toggle Enhanced TUN | `PATCH /configs` with `tun.enable` |
| Select rule/global/direct | `PATCH /configs` with `mode` |
| Select proxy | `PUT /proxies/{group}` with `name` |
| Reload active profile | `PUT /configs?force=true` |

The controller binds only to `127.0.0.1:9090`. MetaCubeXD's generated
`config.js` points to the same endpoint, keeping tray and dashboard state on one
backend.

## Window Lifecycle

- Startup: hidden.
- `Show Main Window`: unminimize, show, and focus the MetaCubeXD window.
- Window close: hide rather than terminate.
- `Exit`: terminate the Tauri user process only; launchd keeps networking alive.
