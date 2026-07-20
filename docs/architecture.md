# Architecture

## Components

```text
MihomoBox.app (current user, Tauri)
├── Contents/MacOS/mihomo-app       tray + window + controller client
├── Contents/MacOS/mihomo           pinned upstream kernel
├── Contents/MacOS/mihomo-daemon    Swift privileged service payload
├── WebView                         generated MetaCubeXD dashboard
└── Resources/daemon + scripts      installer inputs

/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist (root)
└── /Library/Application Support/Mihomo App/mihomo-daemon
    ├── supervises copied Mihomo kernel as root
    ├── listens on 127.0.0.53:53 and 127.0.0.1:1054
    ├── manages CurrentSet/Network/Service/<PrimaryService>/DNS
    └── tracks DHCP and split DNS resolvers per interface
```

The App bundle is the distribution source. Installation copies privileged
executables to stable system paths; launchd never references a movable `.app`
bundle or a source checkout.

## Ownership

| Resource | Owner | Reason |
|---|---|---|
| Main window and tray | current user Tauri process | UI must not run as root |
| Mihomo controller reads/writes | Tauri via `127.0.0.1:9090` | loopback API is the state source |
| Mihomo kernel process | root daemon | Enhanced TUN must not change process owner |
| `lo0` alias and system DNS | root daemon | SystemConfiguration and interface changes require privilege |
| MetaCubeXD files | immutable App resources | no remote UI code execution |

## Startup Sequence

1. launchd starts `mihomo-daemon` before user login.
2. The daemon discovers DHCP/supplemental resolvers and their interfaces.
3. It binds the original-DNS listener on `127.0.0.1:1054`.
4. It adds `127.0.0.53` to `lo0`, binds UDP/TCP 53, and starts the copied Mihomo
   binary using the managed config directory.
5. After controller, TUN, fake-IP route, and DNS validation, it backs up and
   applies DNS to the active PrimaryService.
6. Tauri starts later as an accessory application; the main window remains
   hidden and the tray polls the Mihomo controller.

## Runtime Ports

| Endpoint | Direction | Purpose |
|---|---|---|
| `127.0.0.53:53` UDP/TCP | macOS → daemon | system DNS through Mihomo, with original-DNS fallback |
| `127.0.0.1:1153` UDP/TCP | daemon → Mihomo | Mihomo DNS listener |
| `127.0.0.1:1054` UDP/TCP | Mihomo → daemon | nonrecursive path to current DHCP DNS |
| `127.0.0.1:9090` HTTP/WS | GUI/MetaCubeXD → Mihomo | controller API |

See [daemon-and-dns.md](daemon-and-dns.md) for failure and restoration rules.
