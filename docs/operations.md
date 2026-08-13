# Operations

## Install or Repair

Use `Install / Repair Daemon…` from the tray. The App invokes the bundled
installer through the standard macOS administrator authorization dialog.
If no previously authenticated active profile exists, installation stages a
REJECT-only provisioning profile and starts only the authenticated XPC daemon;
the agent, TUN, and managed DNS remain stopped. The selected user profile is
then activated over typed XPC. Only a full-health readback starts networking
and clears provisioning; a failed activation leaves real system DNS intact.

For a remote Mac, first transfer a release App through an authenticated channel
and verify the complete bundle, then invoke the detached entry point **without**
`sudo` from the authenticated SSH session:

```bash
APP=/Applications/MihomoBox.app
/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
/usr/sbin/spctl --assess --type execute "$APP"
"$APP/Contents/Resources/scripts/install-daemon-remote.sh"
```

The wrapper itself is deliberately unprivileged and refuses root execution. It
hands control to the signed `mihomoboxctl install --detached` entry point, which
requests `sudo` and constructs the fixed snapshot-verification bootstrap. After
root has copied and verified the App, the verified installer runs under `nohup`
and the CLI prints a root-only log path. Migration therefore continues if the
TUN handoff interrupts SSH. A checkout, an App from an unauthenticated transfer,
or a standalone copy of the wrapper is not a trusted remote installation source.
Launchd never executes from the movable App bundle.

The visible bundle is `MihomoBox.app`. Existing
`/Library/Application Support/Mihomo App` and `/Library/Logs/Mihomo App` paths
remain stable so upgrades preserve configuration, DNS backups, and structured
diagnostic logs. Upgrade installation removes legacy raw `mihomo.log`
generations because older Mihomo output may contain DNS names or endpoints.
The upgraded supervisor performs the same one-time cleanup after component-only
automatic updates, so this does not depend on rerunning the installer.

The installer:

1. copies `mihomo`, `mihomo-daemon`, `mihomo-agent`, from the App to
   `/Library/Application Support/Mihomo App/`;
2. migrates `/opt/homebrew/etc/mihomo/` when present, otherwise installs the
   minimal default profile;
3. forces only the loopback controller and DNS recursion-boundary keys;
4. validates the copied Mihomo configuration;
5. stops a running Homebrew Mihomo service to prevent duplicate owners;
6. installs the XPC Mach service and starts the root daemon, which launches the agent;
7. verifies controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, persisted
   PrimaryService DNS, and effective resolver state.

There are two intentionally separate startup mechanisms. The root
LaunchDaemon starts the managed network service at system startup with the
active profile, whose managed configuration requires `tun.enable: true`. Once
the App has observed a healthy Enhanced TUN runtime, it also applies a one-time
current-user login-item default so the hidden tray App returns after login.
Only an installed copy under `/Applications` or `~/Applications` applies this
default. That login item is not privileged and never owns a Mihomo process.
Turning it off later in macOS System Settings is respected.

It copies the signed CLI out of the verified snapshot into root-owned
Application Support, then makes `/usr/local/bin/mihomoboxctl` a user-executed
symlink to that stable copy. The link never points into the movable App, and
root never executes through it. A mode-`0600`, root-owned target record lets
repair or uninstall distinguish its exact link; an unrelated existing file or
symlink at the global CLI path is preserved. The standalone global CLI handles
typed XPC operations only. Install or uninstall must be launched from the tray
or the CLI inside the signed App so the running Mach-O can bind the exact App
snapshot before elevation.

Upgrades migrate the former `dev.linsheng.mihomo-app.daemon` label to
`dev.linsheng.mihomo.daemon`. The old job is stopped and its plist removed
before the new job starts; rollback restores the prior running label.

After this bootstrap has installed an update-capable daemon, normal App updates
do not require another administrator dialog. On launch, the App compares the
bundled and installed daemon/agent/Mihomo digests. Changed binaries cross the
authenticated XPC channel, are independently validated against the same leaf
certificate, atomically replaced with rollback, and restarted by the daemon or
launchd. Daemon replacement remains `update_pending` across launchd restart
until the new set passes full network health; App and CLI report success only
after that commit. Plist, path-layout, or signing-certificate
migrations still require **Install / Repair Daemon**.

Sparkle performs automatic signed update checks from the Swift user process.
It verifies the signed appcast, the enclosure's EdDSA signature, Apple code
signature, and notarization chain before atomically replacing the App and
relaunching. System profiling is disabled. The updater never changes the root
LaunchDaemon directly; the relaunched App performs the existing authenticated
three-component synchronization. Updater diagnostics must not include proxy or
subscription configuration.

Inspect without changes:

```bash
scripts/install-daemon.sh --app-bundle /Applications/MihomoBox.app --dry-run
```

Dry-run is intentionally unprivileged and is not signature or release proof.
Real root execution of `install-daemon.sh` accepts only the private snapshot
created and verified by the signed Swift bootstrap.

## Restore

Stop the service and restore normal networking while preserving profiles and
installation files:

```bash
mihomoboxctl stop
```

The tray exposes the same operation through authenticated XPC.
It restores system DNS, removes the managed alias, flushes system/Mihomo DNS
caches, stops TUN, and removes its routes.

To remove the installed service and files entirely, invoke the CLI inside the
signed App (the standalone root-owned CLI deliberately cannot authorize an App
snapshot):

```bash
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl uninstall
```

Restore stops the daemon, agent, and Mihomo child, restores the backed-up service/global DNS,
removes only a daemon-created alias, restarts a previously active Homebrew
Mihomo service, removes the managed CLI symlink, and removes installed system
files.

## CLI

```bash
mihomoboxctl status [--json]
mihomoboxctl profile list [--json]
mihomoboxctl profile import /path/to/profile.yaml [--activate]
mihomoboxctl profile import-url URL [--name profile.yaml] [--activate]
  [--auth none|basic|digest|bearer|header]
  [--username USER] [--header NAME] [--secret-stdin]
mihomoboxctl profile switch profile.yaml
mihomoboxctl profile reload
mihomoboxctl install [--detached]
mihomoboxctl start
mihomoboxctl restart
mihomoboxctl stop
mihomoboxctl components update
/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl uninstall
```

Only `install` and `uninstall` invoke the administrator-authorized installer.
Status, profile, lifecycle, Enhanced TUN, outbound-mode, proxy-selection, and
latency operations use the fixed, versioned XPC allowlist. `components update`
uses the same boundary for the fixed signed binary set and never accepts a path
or arbitrary filename. The daemon accepts only a CLI signed with its exact leaf
certificate. `stop` terminates the agent; the agent restores DNS while the
daemon and Mach service remain available.

For automation, `status` exits with `0` for a running or safely stopped
consistent network, `1` when MihomoBox is not installed, `2` for an inconsistent
network, and `3` when launchd has the job loaded but its runtime is unavailable.
Invalid CLI usage exits with `64`.

HTTP authentication examples:

```bash
# Basic and Digest prompt for the password without echoing it.
mihomoboxctl profile import-url https://example.invalid/basic \
  --name work.yaml --auth basic --username example-user --activate
mihomoboxctl profile import-url https://example.invalid/digest \
  --name digest.yaml --auth digest --username example-user

# Bearer token from stdin for SSH/automation; avoid putting it in shell history.
printf '%s\n' "$MIHOMOBOX_SUBSCRIPTION_TOKEN" | \
  mihomoboxctl profile import-url https://example.invalid/bearer \
    --name remote.yaml --auth bearer --secret-stdin --activate

# API key or another provider-specific header.
printf '%s\n' "$MIHOMOBOX_SUBSCRIPTION_KEY" | \
  mihomoboxctl profile import-url https://example.invalid/header \
    --name api-key.yaml --auth header --header X-API-Key --secret-stdin
```

The URL is never printed or sent to root. The downloaded profile is limited to
16 MiB and only its bytes and safe filename cross XPC for validation and an
atomic profile transaction. Credentials are intentionally not persisted;
importing or refreshing requires supplying them again.

## Runtime Paths

```text
~/Library/Application Support/MihomoBox/profiles/
~/Library/Application Support/MihomoBox/active-profile
/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist
/Library/Application Support/Mihomo App/daemon.json
/Library/Application Support/Mihomo App/controller.json
/Library/Application Support/Mihomo App/controller-secret
/Library/Application Support/Mihomo App/component-version
/Library/Application Support/Mihomo App/mihomo
/Library/Application Support/Mihomo App/mihomo-daemon
/Library/Application Support/Mihomo App/mihomo-agent
/Library/Application Support/Mihomo App/mihomoboxctl
/Library/Application Support/Mihomo App/mihomo-data/config.yaml
/Library/Application Support/Mihomo App/profiles/
/Library/Application Support/Mihomo App/active-profile
/Library/Logs/Mihomo App/mihomo.log
/Library/Logs/Mihomo App/mihomo-daemon.log
/Library/Logs/Mihomo App/mihomo-daemon-crash.log
/Library/Logs/Mihomo App/mihomo-agent.log
/Library/Logs/Mihomo App/mihomo-agent-crash.log
/Library/Logs/Mihomo App/mihomo-agent-command.log
/Library/Logs/Mihomo App/mihomo-agent-command-crash.log
~/Library/Logs/MihomoBox/mihomobox.log
~/Library/Logs/MihomoBox/mihomobox-crash.log
```

Every file is limited to 100 MiB and keeps three numbered generations (`.1`
through `.3`). Normal logs are batch-written at most once per second or when
64 KiB is ready. `mihomo.log` contains aggregate output counts rather than raw
Mihomo lines. The crash logs are independent of normal rotation so a panic or
fatal-signal record survives even when the main log rolls. The tray's `Tools >
Open Diagnostic Logs…` command opens both user and daemon log folders.

The user paths stage local tray imports before daemon installation. When a
profile accompanies first installation, the unprivileged App freezes its
bounded bytes before authorization; root never reopens that user-writable path.
After the verified installer brings up the daemon, the App sends those bytes
through the typed XPC profile transaction for validation and activation. If
that first-install activation fails, it stops the agent and confirms TUN and
system DNS restoration before returning the error, rather than leaving the
minimal direct profile active.

## Diagnosis

```bash
sudo launchctl print system/dev.linsheng.mihomo.daemon
sudo '/Library/Application Support/Mihomo App/mihomo-agent' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --check-system-dns
sudo '/Library/Application Support/Mihomo App/mihomo-agent' \
  --config '/Library/Application Support/Mihomo App/daemon.json' \
  --health
tail -f '/Library/Logs/Mihomo App/mihomo-daemon.log'
tail -f '/Library/Logs/Mihomo App/mihomo-agent.log'
tail -f '/Library/Logs/Mihomo App/mihomo.log'
tail -f '/Library/Logs/Mihomo App/mihomo-daemon-crash.log'
tail -f '/Library/Logs/Mihomo App/mihomo-agent-crash.log'
tail -f "$HOME/Library/Logs/MihomoBox/mihomobox.log"
tail -f "$HOME/Library/Logs/MihomoBox/mihomobox-crash.log"
dig @127.0.0.53 -p 53 example.com
dig @127.0.0.1 -p 1054 example.com
scutil --dns
```

The `--check-system-dns` command verifies the persisted CurrentSet
PrimaryService DNS value (or the Global fallback when no primary service is
available). `scutil --dns` verifies the effective dynamic resolver state; the
installer requires both checks to pass.

`--health` reports controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, and
system-DNS consistency. The first failed observation immediately disables
Fake-IP answers. Domains still owned by Fake-IP fail closed instead of leaking
to original DNS; only domains explicitly excluded by the active Fake-IP policy
may receive real upstream answers. Recovery starts after three consecutive
failures; only a failed recovery window rolls back real system DNS and stops
the managed Mihomo child.
