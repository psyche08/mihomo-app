# Operations

## Install or Repair

Use `Install / Repair Daemon…` from the tray. The App invokes the bundled
installer through the standard macOS administrator authorization dialog.

For a remote Mac, invoke the detached installer entry point from an authenticated
SSH session with `sudo`. It is embedded at
`Contents/Resources/scripts/install-daemon-remote.sh`, starts the real installer
under `nohup`, and prints a root-only log path. Migration therefore continues if
the TUN handoff interrupts SSH. Launchd never executes from the movable App
bundle.

The visible bundle is `MihomoBox.app`. Existing
`/Library/Application Support/Mihomo App` and `/Library/Logs/Mihomo App` paths
remain stable so upgrades preserve configuration, DNS backups, and structured
diagnostic logs. Upgrade installation removes legacy raw `mihomo.log`
generations because older Mihomo output may contain DNS names or endpoints.
The upgraded supervisor performs the same one-time cleanup after component-only
automatic updates, so this does not depend on rerunning the installer.

The installer:

1. copies `mihomo`, `mihomo-daemon`, `mihomo-agent`, and the profile configurator from the App to
   `/Library/Application Support/Mihomo App/`;
2. migrates `/opt/homebrew/etc/mihomo/` when present, otherwise installs the
   minimal default profile;
3. forces only the loopback controller and DNS recursion-boundary keys;
4. validates the copied Mihomo configuration;
5. stops a running Homebrew Mihomo service to prevent duplicate owners;
6. installs the XPC Mach service and starts the root daemon, which launches the agent;
7. verifies controller, TUN, Fake-IP route, DNS bridge, Mihomo DNS, persisted
   PrimaryService DNS, and effective resolver state.

It also installs `/usr/local/bin/mihomoboxctl` as a symlink to the signed App
bundle. An unrelated existing file or symlink at that path is preserved.

Upgrades migrate the former `dev.linsheng.mihomo-app.daemon` label to
`dev.linsheng.mihomo.daemon`. The old job is stopped and its plist removed
before the new job starts; rollback restores the prior running label.

After this bootstrap has installed an update-capable daemon, normal App updates
do not require another administrator dialog. On launch, the App compares the
bundled and installed daemon/agent/Mihomo digests. Changed binaries cross the
authenticated XPC channel, are independently validated against the same leaf
certificate, atomically replaced with rollback, and restarted by the daemon or
launchd. Plist, configuration-helper, path-layout, or signing-certificate
migrations still require **Install / Repair Daemon**.

The App checks for updates thirty seconds after launch and every six hours after
a successful check. Network or feed failures retry with exponential delays from
thirty seconds to thirty minutes. The updater logs only error categories and
retry counters, never endpoint URLs.

Inspect without changes:

```bash
sudo scripts/install-daemon.sh --dry-run
```

## Restore

Stop the service and restore normal networking while preserving profiles and
installation files:

```bash
sudo scripts/install-daemon.sh --restore-network
```

The tray exposes the same operation through authenticated XPC.
It restores system DNS, removes the managed alias, flushes system/Mihomo DNS
caches, stops TUN, and removes its routes.

To remove the installed service and files entirely:

```bash
sudo scripts/install-daemon.sh --restore
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
mihomoboxctl install
mihomoboxctl start
mihomoboxctl restart
mihomoboxctl stop
mihomoboxctl components update
mihomoboxctl uninstall
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
/Library/Application Support/Mihomo App/mihomo
/Library/Application Support/Mihomo App/mihomo-daemon
/Library/Application Support/Mihomo App/mihomo-agent
/Library/Application Support/Mihomo App/configure_mihomo.py
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

The user paths stage local tray imports before daemon installation. The signed
installer validates the selected staged profile, copies it into the root-owned
profile directory, makes it active, and starts the managed service in the same
administrator-authorized transaction.

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
Fake-IP answers and serves real IPs. Recovery starts after three consecutive
failures; only a failed recovery window rolls back real system DNS and stops
the managed Mihomo child.
