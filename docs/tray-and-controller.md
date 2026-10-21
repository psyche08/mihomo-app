# Tray and Controller Contract

The main window is native SwiftUI and hidden at startup. A pure Swift
`NSApplicationDelegate` keeps the macOS accessory activation policy and event
loop, `NSStatusItem` owns the tray, Sparkle owns App updates, and an in-process
`NSHostingController` owns the dashboard window.

The status item loads the exact pinned `assets/Meta.png` bytes embedded as
`Contents/Resources/Meta.png`, renders them as an 18-point template image for
light/dark menu bars, and uses a system symbol only as a damaged-bundle
fallback.

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
  Edit Profile ›
Reload Profiles
───────────────
Tools ›
  Install / Repair Daemon…
  Uninstall Helper…
  Open Diagnostic Logs…
  Check for Updates…
───────────────
Version X.Y.Z
Exit
```

Each imported profile is also available under **Edit Profile**. The native
editor keeps the user-owned YAML mirror in the current user context, provides
Mihomo-key completion and YAML highlighting, and validates the complete draft
with the bundled Mihomo executable before an atomic save. An installed daemon
receives the validated bytes through authenticated XPC; editing an inactive
profile does not activate it. The user mirror is rolled back if synchronization
fails.

The editor resolves active-profile state from the installed daemon immediately
before saving instead of trusting a possibly stale user mirror. Active-profile
saves are labelled **Validate & Apply**; inactive saves state that a later switch
is required. Syntax highlighting is delayed until typing pauses and never
rewrites text attributes while an input method has marked text, so YAML editing
does not disturb composition or the insertion point. The editor also identifies
the DNS forwarding, controller, secret, and log-level fields that MihomoBox
normalizes to preserve the privilege and DNS-recursion boundaries.

**Tools › Uninstall Helper…** is available only when both the signed installer
and managed root artifacts are present. After explicit confirmation it runs the
verified App-snapshot installer with `--restore`: Mihomo is stopped, real system
DNS is restored, and root-owned helpers, configuration, logs, LaunchDaemons and
the managed CLI link are removed. The App and current-user profile mirror are
preserved.

The disabled version row is read from the signed App bundle's
`CFBundleShortVersionString`; it is informational and never comes from daemon
or controller state.

The dashboard keeps live controller streams scoped to the selected page.
Overview owns connections, traffic, and memory; Connections owns connections;
Usage owns connections and traffic; Logs owns logs. Proxies, Rules, and Config
use bounded request/readback calls and keep no stream open. Moving between
pages cancels both inactive streams and their retry timers, so a hidden or
static page cannot keep polling the controller in the background.

Connections uses a native two-pane dashboard. The left pane groups clients by
the outermost `.app` bundle in the reported executable path, so an App's main
process and nested Helper Apps share one client; processes outside an App fall
back to the reported process name and then the executable basename. App groups
use the same icon macOS resolves for their bundle and always offer
`All Clients`; each group shows its active count and aggregate live throughput,
or its retained recent count when inactive. The right pane shows newest-first
recent connections for the selected client and can narrow them to Recent,
Active, or Closed without opening another controller stream. Recent is the
de-duplicated union of the live set and the session's bounded history of up to
500 closed connections. Search, transferring-only filtering, per-connection
close, filtered active close, pause/resume, and the full connection detail
sheet remain available.

The check mark always represents agent/controller state returned over XPC, not
the last click. The tray refreshes immediately at startup, when its menu opens,
and after a mutation. While the controller is unavailable it retries every 500
milliseconds for the first ten seconds and then every ten seconds; a healthy
background runtime is sampled every thirty seconds. It replaces the native
menu only when its semantic state or structure changes. Delay-only updates do
not replace a menu that macOS may currently be tracking, so hovering a submenu
is not interrupted by the polling timer. `Test Now` concurrently
asks the daemon to test every leaf proxy and then explicitly refreshes the
displayed latency. Proxy groups, nested selectors, and built-in direct/reject
targets are omitted from this flat node list. If the controller is
unavailable, controller mutations are disabled while profile switching, daemon
repair, and network recovery remain available.

Long mutations publish their phase in the disabled network-status row
(`Starting…`, `Stopping…`, `Applying profile…`, or `Applying change…`) and the
tray disables conflicting actions until completion. The Config page applies
the same presentation lock to settings, reload/restart, cache flushes, and GEO
updates: one operation is shown with an inline spinner and duplicate clicks are
discarded instead of queued behind the daemon transaction.

An authenticated protocol-version mismatch is distinct from an unavailable
daemon. Any older daemon is shown as `Network: Daemon upgrade required`; all
tray XPC-backed TUN, profile, mode, and proxy controls are disabled, while
an emphasized `Upgrade Daemon…` action and `Tools > Install / Repair Daemon…
(Required)` remain available. The App stays hidden and never opens an
administrator prompt automatically. Selecting the action first explains that
Mihomo and Enhanced TUN will restart briefly while LocalHttpDns stays available, then enters the
existing exact-signature verified installer. A newer daemon is shown as
requiring an App update and cannot be repaired by the older App.

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

In Local DoH mode, LocalHttpDns is the service prerequisite for Enhanced TUN.
Explicit Global DNS mode instead requires the verified TUN DNS path and no
remaining MihomoBox DoH profile. Without a selected
profile the item first tells the user to add one. When the daemon is absent it
opens the signed installer with administrator authorization and supplies the
selected profile for the first standby start. It then prepares the fixed
certificate/profile and opens Device Management. Until macOS reports that
profile installed, enabling TUN is rejected. Once approved, the same item
persists `tun.enable: true`; turning it off persists `false` and returns to a
healthy controller/DNS standby. Neither action stops LocalHttpDns or writes the
macOS system DNS server list in Local DoH mode. Global DNS mode restores the
original system DNS when Enhanced TUN is stopped.

On first installed App launch, the native App enables a current-user macOS login
item independently of helper, network, or Enhanced TUN readiness. This is a
one-time default, and MihomoBox does not
re-add the login item after the user later turns it off in System Settings.
Only an App under `/Applications` or `~/Applications` can apply the default, so
a DMG, App Translocation, Downloads copy, or development smoke build cannot
persist a temporary path. The AppKit shell writes and validates the user-level
LaunchAgent atomically; SwiftUI views receive no LaunchAgent write API. The login
item starts the hidden menu-bar App after login and does not directly launch
Mihomo or execute a privileged operation. After the first compatible controller
snapshot with an active profile, the App reads the daemon's sticky Enhanced-mode
preference and attempts one authenticated start if needed. Failed starts do not
create a polling restart loop. Turning Enhanced mode off affects this session;
the daemon remembers successful activation for the next boot or App launch.

The tray has exactly two administrator-authorized entry points: the first TUN
enable when the daemon is not installed, and explicit `Install / Repair
Daemon…`. Once installed, TUN enable/disable, service start/stop/restart,
profile import/switch/reload, outbound mode, proxy selection, and delay tests
all use the native typed client and authenticated XPC. None of those paths
reinvoke the installer or request another administrator dialog.

Tray reload re-reads the active regular YAML file from the current user's
profile mirror and sends its bounded bytes over authenticated XPC for the same
transactional validation and activation as import. If no safe local mirror is
available, it falls back to reloading the daemon's root-owned copy. That
root-owned reload keeps the agent and DNS bridge running and replaces only the
Mihomo child; importing changed user bytes still uses the full atomic profile
activation transaction.

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
| Read fixed Local DoH server/profile state | `local-doh.status` |
| Prepare identity/runtime and root-owned Local DoH profile | `local-doh.install` |
| Explicitly install/trust the fixed CA for SSL | `local-doh.trust-certificate` |
| Select Global DNS or ready Local DoH | `runtime.set-dns-mode` |
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

Signed production builds enable Sparkle background checks and automatic
downloads by default. Config exposes one `Automatic Updates` switch backed by
Sparkle's own persisted `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`
settings, so disabling it survives relaunch without a second preference that
can drift. Manual `Tools > Check for Updates…` remains available. Development
bundles without the release key keep updates unavailable and show the switch
disabled. An automatically downloaded update uses Sparkle's no-UI immediate
install/relaunch path; the daemon-owned active tunnel does not depend on the App
process remaining alive.

Config's **DNS Integration** panel exposes Global DNS / Local DoH selection,
separate certificate-trust and installed-profile readiness, explicit SSL trust
approval, and links to Device Management and Keychain Access. The App confirms
trust and Global DNS profile-removal actions before authenticated XPC. Busy
state prevents duplicate clicks; failed or cancelled authorization cannot
optimistically mark SSL trust ready. Mode selection is read back from the
daemon, including confirmed DoH profile removal for Global DNS. Re-entering
Local DoH after Global DNS requires user-approved profile installation again.

The legacy split-DNS planner reads the current
authenticated `/rules` and `/proxies` snapshot, recognizes both YAML
`DOMAIN-SUFFIX` and controller `DomainSuffix` spellings, follows each current
selector chain to a concrete remote proxy, and expands selected `GEOSITE`
selectors from the managed root-owned database. Attribute filters are
intersected; plain/regex entries and whole-list inversions are counted rather
than widening scope. The complete suffix set is deduplicated without a silent
cap. Global/Direct modes, DIRECT selections, unknown leaves and selector cycles
fail closed. The Config panel shows expanded-GeoSite, omitted,
unrepresentable-entry, inversion, and exact-to-suffix counts and polls the fixed
`local-doh.status` projection while visible. Domain names never leave the root
daemon. After the signed helper is installed, authenticated XPC prepares the
fixed root TLS endpoint and `.mobileconfig`; the App opens that profile and the
exact Device Management pane for mandatory macOS review. Only full helper
uninstall removes the LocalHttpDns state. The busy state disables repeat clicks
throughout the administrator and profile-generation steps.

There is no loopback HTTP server, browser token, WebView, or `mihomoboxctl`
child process in the desktop data path. The daemon still validates every
method/path/body and injects the root-owned controller credential. The public
Swift gateway exposes fixed actions and safe runtime patches only; controller
identity, DNS recursion-boundary keys, and every TUN field remain
unrepresentable. Profile reload maps to `profile.reload`, runtime restart maps
to `agent.restart`. The daemon accepts either restart only after a bounded,
generation-matched agent snapshot proves either controller/DNS standby or the
complete controller/TUN/Fake-IP route, plus restored system DNS and network
consistency. Enhanced mode is followed by a safe Global selector-chain check.
The daemon does not issue
repeated DNS probes while it waits for that snapshot.
Failure rolls the profile back when possible and otherwise stops the runtime;
the window only waits for the resulting authoritative snapshot. Backend/UI self-upgrade
remains blocked because bundled artifacts must stay pinned, checksummed, and
signed.

Successful `runtime.tray-state` reads are intentionally excluded from routine
started/success audit lines. Authentication, protocol rejection, request
failure, every mutation, and state-transition events remain logged. This keeps
periodic presentation refreshes from dominating the root daemon log.

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
  always-on LocalHttpDns service and the persisted standby/Enhanced state.
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

## Profile network settings

Use **Profiles › Edit Profile › Network Settings…** to update the YAML draft,
then **Validate & Apply** (active profile) or **Validate & Save** (inactive).
The native editor uses the existing bundled-core validation and authenticated
profile transaction, including runtime health verification and rollback.

- **Mixed port** gives HTTP and SOCKS5 the same listener; separate `port` and
  `socks-port` listeners are disabled with `0`. Existing mixed/HTTP/SOCKS ports
  seed the field, in that order, with `7897` used only for a new listener. The
  Config dashboard displays actual controller ports and uses the mixed listener
  as both protocol endpoints. Missing/disabled ports display **Off**.
- **TUN stack** supports `mixed`, `system`, and `gvisor`. Mixed uses system TCP
  and gVisor UDP. Editing the stack does not enable Enhanced TUN or change its
  Local DoH approval prerequisites.
- **Per-app VPN routing** is process-based routing inside Mihomo's TUN, not
  Apple's MDM Per-App VPN. Choose application bundles and either proxy only the
  selected apps or bypass them. Bundle-prefix matching includes nested helpers;
  external services and processes without an identified bundle do not match.
  **Enable per-app routing** controls the generated rules independently of the
  selected mode. **Add Applications…** adds bundles without duplicates;
  **Remove Selected** removes one or more highlighted rows. Each row shows the
  application name and full path, so identically named bundles can be distinguished.
- **Only selected apps** prepends a rule to the selected existing policy for
  each bundle, a REJECT fallback for unsupported UDP, and then `MATCH,DIRECT`.
  This explicitly makes all unmatched traffic direct. **Bypass selected apps**
  prepends DIRECT rules and leaves remaining traffic to the profile's rules.
  Both set Rule mode and process discovery to `always`. Changing mode to Global
  or Direct, or disabling process discovery later, overrides these semantics.
- Turning **Enable per-app routing** off removes the generated app rules and
  retains the application list, chosen routing mode and policy for the next use.
  Original profile rules are retained underneath the marked block. Mode/process
  settings remain at their last saved values; the chooser is not an undo of
  unrelated YAML edits. Earlier metadata without an explicit enable flag keeps
  its original behavior (`profileRules` means off).
- These settings control process routing. DNS still follows the current system
  DNS configuration; the separate DNS identity probe is experimental and is
  not enabled by this switch. **Update Draft** changes the editor; **Validate &
  Apply** commits an active profile through the existing daemon transaction.

A comment records the chooser values; YAML remains authoritative for the port
and stack. The editor replaces its marked app-rule block on subsequent edits.
Custom listeners, merged mappings and ambiguous/duplicate managed keys require
manual YAML editing rather than guessing how to rewrite them. Arbitrary policy
names still have to pass the bundled core's validator before saving. No new
controller mutation, privileged shell command, or GUI-owned core is introduced.

## App Proxy application routes

Config now includes **App Proxy**, separate from the profile editor's TUN
process rules. Four rows cover ChatGPT/Codex Desktop, Codex CLI, Claude Desktop,
and Claude CLI. Each row can select a concrete node or follow an existing proxy
group. Discovered signed helper executables inherit their application's route;
Terminal/editor `matchTools` rules still select only the two CLI families.
A host-only identity that cannot identify the actual CLI is rejected, rather
than assigned an arbitrary application's route.

**Apply Routes** sends `app-proxy.set-routing` over authenticated XPC. The root
daemon checks a revision of the active raw profile and saved settings, validates
the selected targets against the current controller catalog, and uses the
existing profile activation/rollback transaction. After startup it validates
the new controller catalog too. The pinned core's `-t` check alone does not
reject an unknown listener `proxy`, so it is not sufficient evidence. A failed
or ambiguous reply requires refresh before another apply/enable.

Settings live in the root-owned `app-proxy.json`, alongside the active-profile
state. Subscription bytes and the user's profile mirror are preserved. The
runtime overlay adds four loopback mixed listeners on ports 17971–17974, each
with its explicit outbound `proxy`; TCP, UDP and intercepted DNS-over-HTTPS
use the same application-specific listener. Switching a node restarts the
managed runtime and can interrupt existing connections. Settings also apply to
subsequent profiles; missing targets cause activation to roll back. Custom
listeners, conflicting ports and ambiguous YAML mappings require manual profile
changes. **Reset Routes**, available after disabling the extension, removes the
overlay so a profile with incompatible listeners or node names can be selected.

**Enable App Proxy…** requests macOS approval for the bundled
`dev.linsheng.mihomo-app.app-proxy` system extension, discovers current signed
application identities, saves a source-application VPN configuration, verifies
its complete readback, and waits for a connected state. **Disable App Proxy**
saves and verifies disabled preferences and waits for disconnection. Neither
operation installs or repairs the root daemon, nor starts a second core.
Local unsigned builds expose routing settings but cannot activate an extension.
Refresh updates discovered targets and the VPN status; changing application
versions/paths requires disable/re-enable to rediscover their signatures.

The earlier standalone `MihomoDNSProbe.app` has a separate extension identity
and must be disabled before enabling the main App's extension. It is not
silently migrated or deactivated. This change does not claim strict system DNS
isolation, complete attribution of every CLI-host flow, automatic recovery
across reboot, or live validation of the newly bundled extension. Those require
an appropriately provisioned Xcode Cloud build and macOS approval.
