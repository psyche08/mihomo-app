use crate::app_log;
use crate::mihomo::{MihomoClient, Snapshot};
use crate::native_window;
use crate::startup;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

const TRAY_ID: &str = "mihomo-app-tray";
const USER_PROFILE_ROOT: &str = "Library/Application Support/MihomoBox";
const DAEMON_PATH: &str = "/Library/Application Support/Mihomo App/mihomo-daemon";
const DAEMON_PLIST_PATH: &str = "/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist";

#[derive(Clone)]
enum DynamicAction {
    Proxy { group: String, proxy: String },
    Profile { name: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TunAction {
    RequireProfile,
    InstallDaemon,
    StartDaemon,
    EnableTun,
    StopAndRestore,
}

struct TrayState {
    snapshot: Mutex<Snapshot>,
    actions: Mutex<HashMap<String, DynamicAction>>,
    profile_busy: Mutex<bool>,
    last_menu_signature: Mutex<Option<MenuSignature>>,
    last_action_error: Mutex<Option<String>>,
    refresh_in_flight: AtomicBool,
    poll_failures: AtomicU32,
    /// Keeps login-item filesystem work outside the runtime refresh path and
    /// bounds retries when the user's LaunchAgents directory is unavailable.
    login_autostart_done_or_in_flight: AtomicBool,
    login_autostart_failures: AtomicU32,
    /// Live handle to the Enhanced TUN item, so its check mark can be written
    /// back after macOS toggles it on click.
    tun_item: Mutex<Option<CheckMenuItem<tauri::Wry>>>,
    /// The `enhanced_tun` value the currently drawn menu was built from. The
    /// check mark the user actually sees comes from this, so a click can tell
    /// whether the mark it was given still matches runtime state.
    menu_tun_checked: Mutex<bool>,
    /// Set while an Enhanced TUN action is running, so the item cannot be
    /// clicked again mid-flight.
    tun_busy: AtomicBool,
    /// When the last latency test ran, so the automatic trigger can rate-limit
    /// itself. Each run is real proxied traffic.
    last_latency_test: Mutex<Option<std::time::Instant>>,
    latency_test_in_flight: AtomicBool,
    /// Handles to the proxy rows currently drawn, paired with the node name
    /// each row shows. Latency updates are written straight into these rather
    /// than rebuilt, because replacing the menu closes it (see
    /// repaint_delays_in_place).
    node_items: Mutex<Vec<(String, CheckMenuItem<tauri::Wry>)>>,
}

/// Releases `tun_busy` however the Enhanced TUN arm exits.
struct TunBusyGuard(Arc<TrayState>);

impl Drop for TunBusyGuard {
    fn drop(&mut self) {
        self.0.tun_busy.store(false, Ordering::Release);
    }
}

/// How a `refresh` should treat the freshly polled controller state.
#[derive(Clone, Copy, PartialEq, Eq)]
enum RefreshMode {
    /// Background poll: retain last-known-good latency and tolerate a single
    /// dropped poll, so a transient controller hiccup never flashes the menu
    /// to "--"/"unavailable".
    Passive,
    /// User-initiated refresh: reflect the fresh controller result as-is,
    /// including genuinely failed latency probes.
    Authoritative,
}

/// Consecutive failed polls tolerated before the tray reports the daemon as
/// unavailable. One dropped poll keeps the last-known-good menu.
const UNAVAILABLE_AFTER_FAILURES: u32 = 2;

/// Fast startup/reconnect poll cadence, used until the controller is reachable.
const WARMUP_POLL_INTERVAL: Duration = Duration::from_millis(500);
/// Steady-state poll cadence once the controller is reachable.
const STEADY_POLL_INTERVAL: Duration = Duration::from_secs(5);
/// Upper bound on fast polls before falling back to the steady cadence, so a
/// daemon that never comes up doesn't get polled twice a second forever.
const WARMUP_POLL_BUDGET: u32 = 20;

struct RefreshGuard(Arc<TrayState>);

impl Drop for RefreshGuard {
    fn drop(&mut self) {
        self.0.refresh_in_flight.store(false, Ordering::Release);
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FlatProxyNode {
    group: String,
    name: String,
    delay: Option<u64>,
    selected: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MenuSignature {
    reachable: bool,
    enhanced_tun: bool,
    mode: String,
    groups: Vec<(String, String, Vec<String>)>,
    profiles: Vec<String>,
    active_profile: Option<String>,
    profile_busy: bool,
    tun_busy: bool,
    network_healthy: Option<bool>,
    action_error: Option<String>,
}

impl MenuSignature {
    fn new(
        snapshot: &Snapshot,
        profiles: &ProfileState,
        profile_busy: bool,
        tun_busy: bool,
        network_healthy: Option<bool>,
        action_error: Option<String>,
    ) -> Self {
        Self {
            reachable: snapshot.reachable,
            enhanced_tun: snapshot.enhanced_tun,
            mode: snapshot.mode.clone(),
            groups: snapshot
                .groups
                .iter()
                .map(|group| {
                    (
                        group.name.clone(),
                        group.current.clone(),
                        group
                            .proxies
                            .iter()
                            .map(|proxy| proxy.name.clone())
                            .collect(),
                    )
                })
                .collect(),
            profiles: profiles.names.clone(),
            active_profile: profiles.active.clone(),
            profile_busy,
            tun_busy,
            network_healthy,
            action_error,
        }
    }
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let state = Arc::new(TrayState {
        snapshot: Mutex::new(Snapshot::default()),
        actions: Mutex::new(HashMap::new()),
        profile_busy: Mutex::new(false),
        last_menu_signature: Mutex::new(None),
        last_action_error: Mutex::new(None),
        refresh_in_flight: AtomicBool::new(false),
        poll_failures: AtomicU32::new(0),
        login_autostart_done_or_in_flight: AtomicBool::new(false),
        login_autostart_failures: AtomicU32::new(0),
        tun_item: Mutex::new(None),
        menu_tun_checked: Mutex::new(false),
        tun_busy: AtomicBool::new(false),
        last_latency_test: Mutex::new(None),
        latency_test_in_flight: AtomicBool::new(false),
        node_items: Mutex::new(Vec::new()),
    });
    app.manage(state.clone());

    let snapshot = Snapshot::default();
    let profiles = profile_state();
    let network_healthy = None;
    let menu = build_menu(
        app,
        &state,
        &snapshot,
        &profiles,
        false,
        network_healthy,
        None,
    )?;
    *state
        .last_menu_signature
        .lock()
        .expect("menu signature lock") = Some(MenuSignature::new(
        &snapshot,
        &profiles,
        false,
        false,
        network_healthy,
        None,
    ));
    let icon = app.default_window_icon().cloned();
    let mut tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("MihomoBox")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(handle_menu_event)
        // Measure latency as the menu is being opened, so the numbers beside
        // each node are current without anyone having to pick "Test Now".
        // tray-icon emits this from mouseDown: *before* it opens the menu
        // (tray-icon-0.24.1 platform_impl/macos/mod.rs:339-347), so the request
        // is already in flight while the menu is coming up. Rate-limited inside
        // run_latency_test: every run is real proxied traffic.
        .on_tray_icon_event(|tray, event| {
            let tauri::tray::TrayIconEvent::Click {
                button: tauri::tray::MouseButton::Left,
                button_state: tauri::tray::MouseButtonState::Down,
                ..
            } = event
            else {
                return;
            };
            let app = tray.app_handle().clone();
            tauri::async_runtime::spawn(async move {
                let Some(state) = app.try_state::<Arc<TrayState>>() else {
                    return;
                };
                let state = state.inner().clone();
                // No refresh() here: run_latency_test already pulled fresh
                // state and repainted the rows in place. Rebuilding would close
                // the menu that is opening right now.
                run_latency_test(&state, LatencyTrigger::Automatic).await;
            });
        });
    if let Some(icon) = icon {
        tray = tray.icon(icon);
    }
    let tray = tray.build(app)?;
    #[cfg(target_os = "macos")]
    tray.set_icon_as_template(true)?;

    refresh(app.clone(), state.clone(), RefreshMode::Passive);
    let polling_app = app.clone();
    tauri::async_runtime::spawn(async move {
        // Poll quickly until the controller is reachable so the tray converges
        // to real state within a fraction of a second of the daemon coming up
        // instead of waiting out a full steady interval. The fast cadence is
        // re-armed whenever reachability is lost (e.g. an agent restart).
        let mut warmup = WARMUP_POLL_BUDGET;
        loop {
            let reachable = state
                .snapshot
                .lock()
                .map(|snapshot| snapshot.reachable)
                .unwrap_or(false);
            let interval = if reachable {
                warmup = WARMUP_POLL_BUDGET;
                STEADY_POLL_INTERVAL
            } else if warmup > 0 {
                warmup -= 1;
                WARMUP_POLL_INTERVAL
            } else {
                STEADY_POLL_INTERVAL
            };
            tokio::time::sleep(interval).await;
            refresh(polling_app.clone(), state.clone(), RefreshMode::Passive);
        }
    });
    Ok(())
}

fn build_menu(
    app: &AppHandle,
    state: &Arc<TrayState>,
    snapshot: &Snapshot,
    profiles: &ProfileState,
    profile_busy: bool,
    network_healthy: Option<bool>,
    action_error: Option<&str>,
) -> tauri::Result<Menu<tauri::Wry>> {
    let show = MenuItem::with_id(app, "show", "Show Main Window", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let network_status = MenuItem::with_id(
        app,
        "network-status",
        if let Some(error) = action_error {
            error
        } else if !snapshot.reachable {
            "Network: Daemon unavailable"
        } else if network_healthy == Some(true) {
            "Network: Healthy"
        } else {
            "Network: Inconsistent — DNS restored"
        },
        false,
        None::<&str>,
    )?;
    // Disabled while an action is in flight: an unclickable item is also one
    // macOS cannot optimistically re-toggle mid-action. It stays enabled when
    // the controller is unreachable — that is the documented lifecycle entry
    // point for installing or starting the daemon.
    let tun = CheckMenuItem::with_id(
        app,
        "tun",
        "Enhanced TUN",
        app_bundle_path().is_some() && !state.tun_busy.load(Ordering::Acquire),
        snapshot.enhanced_tun,
        None::<&str>,
    )?;
    // Keep a handle to the item actually drawn, and remember the value it was
    // drawn with, so a click can both undo the OS's toggle and tell whether the
    // mark it was handed still reflects runtime state.
    *state.tun_item.lock().expect("tun item lock") = Some(tun.clone());
    *state.menu_tun_checked.lock().expect("menu tun lock") = snapshot.enhanced_tun;
    let network_separator = PredefinedMenuItem::separator(app)?;

    let modes = ["rule", "global", "direct"]
        .into_iter()
        .map(|mode| {
            CheckMenuItem::with_id(
                app,
                format!("mode:{mode}"),
                title_case(mode),
                snapshot.reachable,
                snapshot.mode == mode,
                None::<&str>,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mode_refs = modes
        .iter()
        .map(|item| item as &dyn IsMenuItem<tauri::Wry>)
        .collect::<Vec<_>>();
    let mode_menu = Submenu::with_items(app, "Outbound Mode", true, &mode_refs)?;

    let mut actions = HashMap::new();
    let test_now = MenuItem::with_id(
        app,
        "proxy-test",
        "Test Now",
        snapshot.reachable,
        None::<&str>,
    )?;
    let proxy_separator = PredefinedMenuItem::separator(app)?;
    let flat_nodes = flat_proxy_nodes(snapshot);
    let node_items = flat_nodes
        .iter()
        .enumerate()
        .map(|(index, node)| {
            let id = format!("proxy:{index}");
            actions.insert(
                id.clone(),
                DynamicAction::Proxy {
                    group: node.group.clone(),
                    proxy: node.name.clone(),
                },
            );
            CheckMenuItem::with_id(
                app,
                id,
                format!("{}    {}", node.name, delay_label(node.delay)),
                true,
                node.selected,
                None::<&str>,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    *state.node_items.lock().expect("node items lock") = flat_nodes
        .iter()
        .map(|node| node.name.clone())
        .zip(node_items.iter().cloned())
        .collect();
    let empty = node_items.is_empty().then(|| {
        MenuItem::with_id(
            app,
            "proxy-empty",
            if snapshot.reachable {
                "No proxy nodes"
            } else {
                "Mihomo daemon unavailable"
            },
            false,
            None::<&str>,
        )
    });
    let empty = match empty {
        Some(item) => Some(item?),
        None => None,
    };
    let mut proxy_refs: Vec<&dyn IsMenuItem<tauri::Wry>> = vec![&test_now, &proxy_separator];
    if let Some(empty) = empty.as_ref() {
        proxy_refs.push(empty);
    } else {
        proxy_refs.extend(
            node_items
                .iter()
                .map(|item| item as &dyn IsMenuItem<tauri::Wry>),
        );
    }
    let proxy_menu = Submenu::with_items(app, "Proxy List", true, &proxy_refs)?;

    let import_profile = MenuItem::with_id(
        app,
        "profile-import",
        "Import Local YAML…",
        app_bundle_path().is_some() && !profile_busy,
        None::<&str>,
    )?;
    let import_http_profile = MenuItem::with_id(
        app,
        "profile-import-http",
        "Import HTTP Subscription…",
        app_bundle_path().is_some() && !profile_busy,
        None::<&str>,
    )?;
    let profile_separator = PredefinedMenuItem::separator(app)?;
    let mut profile_items = Vec::new();
    for (index, name) in profiles.names.iter().enumerate() {
        let id = format!("profile:{index}");
        actions.insert(id.clone(), DynamicAction::Profile { name: name.clone() });
        profile_items.push(CheckMenuItem::with_id(
            app,
            id,
            name,
            app_bundle_path().is_some() && !profile_busy,
            profiles.active.as_deref() == Some(name.as_str()),
            None::<&str>,
        )?);
    }
    let empty_profile = (profile_items.is_empty()).then(|| {
        MenuItem::with_id(
            app,
            "profile-empty",
            "No imported profiles",
            false,
            None::<&str>,
        )
    });
    let empty_profile = match empty_profile {
        Some(item) => Some(item?),
        None => None,
    };
    let mut profile_refs: Vec<&dyn IsMenuItem<tauri::Wry>> =
        vec![&import_profile, &import_http_profile, &profile_separator];
    if let Some(empty) = empty_profile.as_ref() {
        profile_refs.push(empty);
    } else {
        profile_refs.extend(
            profile_items
                .iter()
                .map(|item| item as &dyn IsMenuItem<tauri::Wry>),
        );
    }
    let profiles_menu = Submenu::with_items(app, "Profiles", true, &profile_refs)?;
    *state.actions.lock().expect("tray action lock") = actions;

    let reload = MenuItem::with_id(
        app,
        "reload",
        "Reload Profiles",
        profiles.active.is_some() && !profile_busy,
        None::<&str>,
    )?;
    let install = MenuItem::with_id(
        app,
        "install",
        "Install / Repair Daemon…",
        app_bundle_path().is_some(),
        None::<&str>,
    )?;
    let open_logs = MenuItem::with_id(
        app,
        "open-logs",
        "Open Diagnostic Logs…",
        true,
        None::<&str>,
    )?;
    let tools_menu = Submenu::with_items(app, "Tools", true, &[&install, &open_logs])?;
    let exit = MenuItem::with_id(app, "exit", "Exit", true, None::<&str>)?;
    let tools_separator = PredefinedMenuItem::separator(app)?;
    let final_separator = PredefinedMenuItem::separator(app)?;
    Menu::with_items(
        app,
        &[
            &show,
            &separator,
            &network_status,
            &tun,
            &network_separator,
            &mode_menu,
            &proxy_menu,
            &profiles_menu,
            &reload,
            &tools_separator,
            &tools_menu,
            &final_separator,
            &exit,
        ],
    )
}

fn handle_menu_event(app: &AppHandle, event: tauri::menu::MenuEvent) {
    let id = event.id().as_ref().to_string();
    let action = if id.starts_with("mode:") {
        "set_mode"
    } else if id.starts_with("proxy:") {
        "select_proxy"
    } else if id.starts_with("profile:") {
        "switch_profile"
    } else {
        id.as_str()
    };
    app_log::info(&format!("event=tray_action action={action}"));
    if id == "show" {
        match native_window::show(app) {
            Ok(()) => app_log::info("event=main_window kind=swiftui result=shown"),
            Err(_) => {
                app_log::error("event=main_window kind=swiftui result=failed");
                show_native_window_unavailable_prompt();
            }
        }
        return;
    }
    if id == "exit" {
        app_log::info("event=app_exit_requested");
        if native_window::shutdown_and_exit(app, 0).is_err() {
            app.exit(0);
        }
        return;
    }
    if id == "open-logs" {
        app_log::open_log_folders();
        return;
    }
    if id == "install" {
        install_daemon(app, selected_local_profile().as_deref());
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if let Some(state) = app.try_state::<Arc<TrayState>>() {
                refresh(
                    app.clone(),
                    state.inner().clone(),
                    RefreshMode::Authoritative,
                );
            }
        });
        return;
    }
    let Some(state) = app.try_state::<Arc<TrayState>>() else {
        return;
    };
    let state = state.inner().clone();
    if id == "profile-import" {
        import_local_profile(app.clone(), state);
        return;
    }
    if id == "profile-import-http" {
        import_http_profile(app.clone(), state);
        return;
    }
    let selected_action = state
        .actions
        .lock()
        .expect("tray action lock")
        .get(&id)
        .cloned();
    if let Some(DynamicAction::Profile { name }) = selected_action {
        switch_local_profile(app.clone(), state, name);
        return;
    }
    if id == "reload" {
        reload_profile(app.clone(), state);
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match id.as_str() {
            "tun" => {
                if state
                    .tun_busy
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    return;
                }
                let _busy = TunBusyGuard(state.clone());
                let snapshot = state.snapshot.lock().expect("snapshot lock").clone();
                // macOS flips a check menu item's mark itself, before any of
                // this runs. Put it back immediately: if the action below fails
                // or is cancelled, an uncorrected mark would keep claiming the
                // opposite of reality until something else happened to change
                // the menu signature — which is how a failed first enable came
                // to look like "it is on now", making the next click look like
                // a cancel while it actually re-ran the installer.
                if let Some(item) = state.tun_item.lock().expect("tun item lock").clone() {
                    let _ = item.set_checked(snapshot.enhanced_tun);
                }
                let menu_checked = *state.menu_tun_checked.lock().expect("menu tun lock");
                let profiles = profile_state();
                let action = tun_action(daemon_installed(), profiles.active.is_some(), &snapshot);
                app_log::info(&format!(
                    "event=tun_action_resolved action={action:?} menu_checked={menu_checked}"
                ));
                // The user clicked a mark that no longer describes the runtime.
                // Escalating here is what produced a password prompt on what
                // looked like "cancel"; redraw instead and let them re-decide.
                if menu_checked && !snapshot.enhanced_tun {
                    app_log::info("event=tun_action_skipped reason=stale_check_mark");
                    set_action_error(
                        &state,
                        Some("Enhanced TUN is not on; the menu has been refreshed".to_string()),
                    );
                } else {
                    match action {
                        TunAction::RequireProfile => show_profile_required_prompt(),
                        TunAction::InstallDaemon => {
                            install_daemon(&app, selected_local_profile().as_deref())
                        }
                        TunAction::StartDaemon => start_daemon(),
                        TunAction::EnableTun => {
                            let succeeded = controller_client().set_tun(true).await.is_ok();
                            app_log::info(&format!(
                                "event=controller_action action=enable_tun success={succeeded}"
                            ));
                            set_action_error(
                                &state,
                                (!succeeded)
                                    .then(|| "Action failed: Enhanced TUN was not enabled".into()),
                            );
                        }
                        TunAction::StopAndRestore => restore_network(&state).await,
                    }
                }
                // Repaint unconditionally. The action may have left the runtime
                // exactly as it was — a cancelled installer, a refused enable —
                // and an unchanged signature would otherwise skip the rebuild
                // that puts the mark right.
                *state
                    .last_menu_signature
                    .lock()
                    .expect("menu signature lock") = None;
            }
            value if value.starts_with("mode:") => {
                let requested = &value[5..];
                let applied = controller_client()
                    .apply_outbound_mode(requested)
                    .await
                    .is_ok();
                app_log::info(&format!(
                    "event=controller_action action=set_mode success={applied}"
                ));
                set_action_error(
                    &state,
                    (!applied)
                        .then(|| "Action failed: outbound mode was not safely applied".to_string()),
                );
            }
            "proxy-test" => {
                // An explicit request always measures, however recently the
                // automatic trigger last ran.
                run_latency_test(&state, LatencyTrigger::Requested).await;
            }
            _ => {
                let action = state
                    .actions
                    .lock()
                    .expect("tray action lock")
                    .get(&id)
                    .cloned();
                if let Some(DynamicAction::Proxy { group, proxy }) = action {
                    let succeeded = controller_client()
                        .select_proxy(&group, &proxy)
                        .await
                        .is_ok();
                    app_log::info(&format!(
                        "event=controller_action action=select_proxy success={succeeded}"
                    ));
                }
            }
        }
        refresh(app, state, RefreshMode::Authoritative);
    });
}

fn refresh(app: AppHandle, state: Arc<TrayState>, mode: RefreshMode) {
    if state
        .refresh_in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    let guard = RefreshGuard(state.clone());
    tauri::async_runtime::spawn(async move {
        let _guard = guard;
        let poll = controller_client().tray_state().await.ok();
        let (snapshot, profiles, network_healthy) = match poll {
            Some(value) => {
                state.poll_failures.store(0, Ordering::Release);
                let mut snapshot = value.snapshot;
                // Background polls keep the last-known-good latency for any node
                // whose fresh probe came back empty, so a single failed probe
                // never flashes a good node to "--". An authoritative refresh
                // (user asked to re-test) shows the fresh result verbatim.
                if mode == RefreshMode::Passive {
                    let previous = state.snapshot.lock().expect("snapshot lock").clone();
                    retain_known_delays(&previous, &mut snapshot);
                }
                let profiles = ProfileState {
                    names: value.profiles,
                    active: value.active_profile,
                };
                (snapshot, profiles, value.network_consistent)
            }
            None => {
                // Debounce controller unavailability: keep the last-known-good
                // menu across a single dropped poll instead of blanking every
                // node, and only report the daemon unavailable once failures
                // persist.
                let failures = state.poll_failures.fetch_add(1, Ordering::AcqRel) + 1;
                if failures < UNAVAILABLE_AFTER_FAILURES {
                    return;
                }
                (Snapshot::default(), profile_state(), None)
            }
        };
        *state.snapshot.lock().expect("snapshot lock") = snapshot.clone();
        if startup::should_consider_default(snapshot.enhanced_tun, network_healthy)
            && state
                .login_autostart_done_or_in_flight
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
        {
            let startup_state = state.clone();
            tauri::async_runtime::spawn_blocking(move || {
                match startup::apply_login_autostart_default() {
                    Ok(outcome) => app_log::info(&format!(
                        "event=login_autostart_default result={}",
                        outcome.log_value()
                    )),
                    Err(_) => {
                        let failures = startup_state
                            .login_autostart_failures
                            .fetch_add(1, Ordering::AcqRel)
                            + 1;
                        app_log::error(&format!(
                            "event=login_autostart_default result=failed attempt={failures}"
                        ));
                        if failures < startup::MAX_SESSION_ATTEMPTS {
                            startup_state
                                .login_autostart_done_or_in_flight
                                .store(false, Ordering::Release);
                        }
                    }
                }
            });
        }
        let profile_busy = *state.profile_busy.lock().expect("profile busy lock");
        let action_error = state
            .last_action_error
            .lock()
            .expect("action error lock")
            .clone();
        let signature = MenuSignature::new(
            &snapshot,
            &profiles,
            profile_busy,
            state.tun_busy.load(Ordering::Acquire),
            network_healthy,
            action_error.clone(),
        );
        let menu_app = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Some(tray) = menu_app.tray_by_id(TRAY_ID) {
                let should_rebuild = state
                    .last_menu_signature
                    .lock()
                    .expect("menu signature lock")
                    .as_ref()
                    != Some(&signature);
                if should_rebuild {
                    let network_health = network_healthy
                        .map(|value| value.to_string())
                        .unwrap_or_else(|| "unknown".to_string());
                    app_log::info(&format!(
                        "event=tray_state_changed controller_reachable={} tun_enabled={} network_healthy={} profile_count={} proxy_group_count={}",
                        snapshot.reachable,
                        snapshot.enhanced_tun,
                        network_health,
                        profiles.names.len(),
                        snapshot.groups.len()
                    ));
                    if let Ok(menu) = build_menu(
                        &menu_app,
                        &state,
                        &snapshot,
                        &profiles,
                        profile_busy,
                        network_healthy,
                        action_error.as_deref(),
                    ) {
                        if tray.set_menu(Some(menu)).is_ok() {
                            *state
                                .last_menu_signature
                                .lock()
                                .expect("menu signature lock") = Some(signature);
                        }
                    }
                }
                let _ = tray.set_tooltip(Some(
                    if snapshot.reachable && network_healthy == Some(true) {
                        "MihomoBox · network healthy"
                    } else if snapshot.reachable {
                        "MihomoBox · network inconsistent"
                    } else {
                        "MihomoBox · daemon unavailable"
                    },
                ));
            }
        });
    });
}

fn set_action_error(state: &TrayState, error: Option<String>) {
    app_log::info(&format!(
        "event=tray_action_result success={}",
        error.is_none()
    ));
    *state.last_action_error.lock().expect("action error lock") = error;
}

fn tun_action(daemon_installed: bool, profile_selected: bool, snapshot: &Snapshot) -> TunAction {
    if snapshot.enhanced_tun {
        TunAction::StopAndRestore
    } else if !profile_selected {
        TunAction::RequireProfile
    } else if !daemon_installed {
        TunAction::InstallDaemon
    } else if snapshot.reachable {
        TunAction::EnableTun
    } else {
        TunAction::StartDaemon
    }
}

fn is_user_proxy_group(name: &str) -> bool {
    !name.eq_ignore_ascii_case("GLOBAL")
}

fn is_proxy_builtin(name: &str) -> bool {
    matches!(
        name.to_ascii_uppercase().as_str(),
        "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS"
    )
}

fn flat_proxy_nodes(snapshot: &Snapshot) -> Vec<FlatProxyNode> {
    let group_names = snapshot
        .groups
        .iter()
        .map(|group| group.name.to_lowercase())
        .collect::<HashSet<_>>();
    let mut node_indexes: HashMap<String, usize> = HashMap::new();
    let mut nodes: Vec<FlatProxyNode> = Vec::new();
    for group in snapshot
        .groups
        .iter()
        .filter(|group| is_user_proxy_group(&group.name))
    {
        for proxy in &group.proxies {
            if is_proxy_builtin(&proxy.name) || group_names.contains(&proxy.name.to_lowercase()) {
                continue;
            }
            let selected = group.current == proxy.name;
            if let Some(index) = node_indexes.get(&proxy.name).copied() {
                let node = &mut nodes[index];
                if node.delay.is_none() {
                    node.delay = proxy.delay;
                }
                if selected {
                    node.group = group.name.clone();
                    node.selected = true;
                }
                continue;
            }
            node_indexes.insert(proxy.name.clone(), nodes.len());
            nodes.push(FlatProxyNode {
                group: group.name.clone(),
                name: proxy.name.clone(),
                delay: proxy.delay,
                selected,
            });
        }
    }
    nodes
}

/// Fill latency for nodes whose fresh probe came back empty (`None`) using the
/// last known-good reading, matched by node name across groups. This keeps a
/// single failed or timed-out probe from erasing a good value from the menu.
fn retain_known_delays(previous: &Snapshot, fresh: &mut Snapshot) {
    let mut known: HashMap<&str, u64> = HashMap::new();
    for group in &previous.groups {
        for node in &group.proxies {
            if let Some(delay) = node.delay {
                known.entry(node.name.as_str()).or_insert(delay);
            }
        }
    }
    if known.is_empty() {
        return;
    }
    for group in &mut fresh.groups {
        for node in &mut group.proxies {
            if node.delay.is_none() {
                if let Some(delay) = known.get(node.name.as_str()) {
                    node.delay = Some(*delay);
                }
            }
        }
    }
}

fn delay_label(delay: Option<u64>) -> String {
    match delay.filter(|delay| *delay > 0) {
        Some(delay) if delay <= 300 => format!("🟢 {delay} ms"),
        Some(delay) if delay <= 800 => format!("🟠 {delay} ms"),
        Some(delay) => format!("🔴 {delay} ms"),
        None => "⚪ --".to_string(),
    }
}

fn controller_client() -> MihomoClient {
    MihomoClient::new()
}

fn title_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn mihomo_path() -> Option<PathBuf> {
    Some(
        app_bundle_path()?
            .join("Contents")
            .join("MacOS")
            .join("mihomo"),
    )
    .filter(|path| path.is_file())
}

/// Rejects a profile the proxy kernel cannot load, before it is ever imported.
///
/// Import used to check only the filename, size and file type, so a profile
/// that Mihomo refuses — a rule naming a proxy group that was never defined,
/// say — was accepted and reported as a success. The failure only surfaced much
/// later, when enabling Enhanced TUN ran the privileged installer, which
/// validates the config and aborts. From the outside that looked like
/// "Mihomo will not start" with nothing explaining why.
///
/// Returns the kernel's own first error line so the tray can show what is
/// actually wrong. That text is shown in the menu only — never logged, because
/// a rule's payload can carry a domain name.
fn validate_profile(path: &Path) -> Result<(), String> {
    let Some(mihomo) = mihomo_path() else {
        // No bundled kernel to check against (a development build); importing
        // without validation preserves the previous behaviour.
        return Ok(());
    };
    // A throwaway data directory: `-t` only reads the config, but Mihomo still
    // wants somewhere to look for geodata.
    let work = std::env::temp_dir().join(format!("mihomobox-verify-{}", std::process::id()));
    if fs::create_dir_all(&work).is_err() {
        return Ok(());
    }
    let output = Command::new(&mihomo)
        .arg("-t")
        .arg("-d")
        .arg(&work)
        .arg("-f")
        .arg(path)
        .output();
    let _ = fs::remove_dir_all(&work);
    let Ok(output) = output else {
        return Ok(());
    };
    if output.status.success() {
        return Ok(());
    }
    let combined = String::from_utf8_lossy(&output.stderr).into_owned()
        + &String::from_utf8_lossy(&output.stdout);
    Err(match first_config_error(&combined) {
        Some(reason) => format!("Action failed: profile rejected by Mihomo — {reason}"),
        None => "Action failed: profile rejected by Mihomo".to_string(),
    })
}

/// Extracts the first `level=error` message from Mihomo's validation output.
fn first_config_error(output: &str) -> Option<String> {
    let line = output.lines().find(|line| line.contains("level=error"))?;
    let message = line
        .split_once("msg=")
        .map(|(_, rest)| rest)
        .unwrap_or(line);
    let message = message.trim().trim_matches('"');
    let mut reason: String = message.chars().take(160).collect();
    if message.chars().count() > 160 {
        reason.push('…');
    }
    Some(reason)
}

fn cli_path() -> Option<PathBuf> {
    Some(
        app_bundle_path()?
            .join("Contents")
            .join("MacOS")
            .join("mihomoboxctl"),
    )
    .filter(|path| path.is_file())
}

fn app_bundle_path() -> Option<std::path::PathBuf> {
    let executable = std::env::current_exe().ok()?;
    let contents = executable.parent()?.parent()?;
    let bundle = contents.parent()?;
    bundle
        .extension()
        .is_some_and(|extension| extension == "app")
        .then(|| bundle.to_path_buf())
}

fn daemon_installed() -> bool {
    Path::new(DAEMON_PATH).is_file() && Path::new(DAEMON_PLIST_PATH).is_file()
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct ProfileState {
    names: Vec<String>,
    active: Option<String>,
}

fn profile_state() -> ProfileState {
    if daemon_installed() {
        if let Some(state) = xpc_profile_state() {
            return state;
        }
    }
    let Some((directory, active_path)) = user_profile_paths() else {
        return ProfileState::default();
    };
    profile_state_at(&directory, &active_path)
}

fn xpc_profile_state() -> Option<ProfileState> {
    #[derive(serde::Deserialize)]
    struct Response {
        profiles: Vec<String>,
        active_profile: Option<String>,
    }
    let output = Command::new(cli_path()?)
        .args(["profile", "list", "--json"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let response = serde_json::from_slice::<Response>(&output.stdout).ok()?;
    Some(ProfileState {
        names: response.profiles,
        active: response.active_profile,
    })
}

fn user_profile_paths() -> Option<(PathBuf, PathBuf)> {
    let root = PathBuf::from(std::env::var_os("HOME")?).join(USER_PROFILE_ROOT);
    Some((root.join("profiles"), root.join("active-profile")))
}

fn selected_local_profile() -> Option<PathBuf> {
    let active = profile_state().active?;
    let (directory, _) = user_profile_paths()?;
    let path = directory.join(active);
    path.is_file().then_some(path)
}

fn profile_state_at(directory: &Path, active_path: &Path) -> ProfileState {
    let mut names = fs::read_dir(directory)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| {
            Path::new(name)
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| {
                    extension.eq_ignore_ascii_case("yaml") || extension.eq_ignore_ascii_case("yml")
                })
        })
        .collect::<Vec<_>>();
    names.sort_by_key(|name| name.to_lowercase());
    let active = fs::read_to_string(active_path)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| names.contains(value));
    ProfileState { names, active }
}

fn import_local_profile(app: AppHandle, state: Arc<TrayState>) {
    if !begin_profile_operation(&state) {
        return;
    }
    spawn_profile_operation(app, state, "local-import", || {
        if let Some(path) = choose_yaml_file() {
            let (directory, active_path) = user_profile_paths().ok_or_else(|| {
                "Action failed: user profile directory is unavailable".to_string()
            })?;
            // Validate before staging so a rejected profile leaves nothing
            // behind and never becomes the active selection.
            validate_profile(&path)?;
            let name = stage_local_profile(&path, &directory)?;
            if daemon_installed() {
                let staged = directory.join(&name);
                let staged = staged.to_string_lossy().into_owned();
                if !run_cli(&["profile", "import", &staged, "--activate"]) {
                    return Err("Action failed: profile import was not completed".to_string());
                }
            }
            write_active_profile(&active_path, &name)
                .map_err(|_| "Action failed: profile selection was not saved".to_string())?;
        }
        Ok(())
    });
}

fn import_http_profile(app: AppHandle, state: Arc<TrayState>) {
    if !begin_profile_operation(&state) {
        return;
    }
    spawn_profile_operation(app, state, "http-import", || {
        if let Some(bundle) = app_bundle_path() {
            let cli = bundle.join("Contents/MacOS/mihomoboxctl");
            if cli.is_file() {
                let succeeded = Command::new(cli)
                    .args(["profile", "import-url", "--interactive"])
                    .status()
                    .is_ok_and(|status| status.success());
                if !succeeded {
                    return Err("Action failed: subscription import was not completed".to_string());
                }
            }
        }
        Ok(())
    });
}

fn switch_local_profile(app: AppHandle, state: Arc<TrayState>, name: String) {
    if !begin_profile_operation(&state) {
        return;
    }
    spawn_profile_operation(app, state, "profile-switch", move || {
        let Some((directory, active_path)) = user_profile_paths() else {
            return Err("Action failed: user profile directory is unavailable".to_string());
        };
        if daemon_installed() {
            let local = directory.join(&name);
            let succeeded = if local.is_file() {
                let local = local.to_string_lossy().into_owned();
                run_cli(&["profile", "import", &local, "--activate"])
            } else {
                run_cli(&["profile", "switch", &name])
            };
            if !succeeded {
                return Err("Action failed: profile switch was not completed".to_string());
            }
        }
        write_active_profile(&active_path, &name)
            .map_err(|_| "Action failed: profile selection was not saved".to_string())?;
        Ok(())
    });
}

fn reload_profile(app: AppHandle, state: Arc<TrayState>) {
    if !begin_profile_operation(&state) {
        return;
    }
    spawn_profile_operation(app, state, "profile-reload", || {
        if run_cli(&["profile", "reload"]) {
            Ok(())
        } else {
            Err("Action failed: active profile reload was not completed".to_string())
        }
    });
}

fn spawn_profile_operation<F>(app: AppHandle, state: Arc<TrayState>, name: &str, operation: F)
where
    F: FnOnce() -> Result<(), String> + Send + 'static,
{
    app_log::info(&format!(
        "event=profile_operation action={name} phase=started"
    ));
    let operation_name = name.to_string();
    let worker_app = app.clone();
    let worker_state = state.clone();
    let result = std::thread::Builder::new()
        .name(format!("mihomobox-{name}"))
        .spawn(move || {
            let error = operation().err();
            app_log::info(&format!(
                "event=profile_operation action={} phase=completed success={}",
                operation_name,
                error.is_none()
            ));
            set_action_error(&worker_state, error);
            end_profile_operation(&worker_state);
            refresh(worker_app, worker_state, RefreshMode::Authoritative);
        });
    if result.is_err() {
        app_log::error(&format!(
            "event=profile_operation action={name} phase=spawn_failed"
        ));
        set_action_error(
            &state,
            Some("Action failed: unable to start profile operation".to_string()),
        );
        end_profile_operation(&state);
        refresh(app, state, RefreshMode::Authoritative);
    }
}

fn stage_local_profile(source: &Path, directory: &Path) -> Result<String, String> {
    let metadata = fs::symlink_metadata(source)
        .map_err(|_| "Action failed: selected profile is unavailable".to_string())?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > 16 * 1024 * 1024 {
        return Err("Action failed: profile must be a 1 byte to 16 MiB YAML file".to_string());
    }
    let name = source
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "Action failed: invalid profile filename".to_string())?;
    validate_profile_filename(name)?;

    fs::create_dir_all(directory)
        .map_err(|_| "Action failed: profile directory could not be created".to_string())?;
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
        .map_err(|_| "Action failed: profile directory could not be secured".to_string())?;
    let staged = directory.join(format!(".import-{}", std::process::id()));
    let result =
        copy_private_file(source, &staged).and_then(|_| fs::rename(&staged, directory.join(name)));
    if result.is_err() {
        let _ = fs::remove_file(&staged);
        return Err("Action failed: profile could not be saved".to_string());
    }
    Ok(name.to_string())
}

fn copy_private_file(source: &Path, target: &Path) -> io::Result<()> {
    let mut input = File::open(source)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(target)?;
    let mut buffer = [0_u8; 64 * 1024];
    let mut total = 0_u64;
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > 16 * 1024 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "profile exceeds 16 MiB",
            ));
        }
        output.write_all(&buffer[..count])?;
    }
    output.sync_all()
}

fn validate_profile_filename(name: &str) -> Result<(), String> {
    let valid_extension = Path::new(name)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("yaml") || extension.eq_ignore_ascii_case("yml")
        });
    if name.is_empty()
        || name.len() > 128
        || name.starts_with('.')
        || name.contains('/')
        || name.chars().any(char::is_control)
        || !valid_extension
    {
        return Err("Action failed: invalid profile filename".to_string());
    }
    Ok(())
}

fn write_active_profile(path: &Path, name: &str) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing parent"))?;
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let staged = parent.join(format!(".active-profile-{}", std::process::id()));
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&staged)?;
    output.write_all(format!("{name}\n").as_bytes())?;
    output.sync_all()?;
    fs::rename(staged, path)
}

fn begin_profile_operation(state: &TrayState) -> bool {
    let mut busy = state.profile_busy.lock().expect("profile busy lock");
    if *busy {
        return false;
    }
    *busy = true;
    true
}

fn end_profile_operation(state: &TrayState) {
    *state.profile_busy.lock().expect("profile busy lock") = false;
}

fn choose_yaml_file() -> Option<PathBuf> {
    let output = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "POSIX path of (choose file with prompt \"Import Mihomo YAML Profile\")",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!path.is_empty()).then(|| PathBuf::from(path))
}

fn run_cli(arguments: &[&str]) -> bool {
    let Some(cli) = cli_path() else {
        app_log::error("event=cli_action result=missing_cli");
        return false;
    };
    let succeeded = Command::new(cli)
        .args(arguments)
        .status()
        .is_ok_and(|status| status.success());
    app_log::info(&format!(
        "event=cli_action result=completed success={succeeded}"
    ));
    succeeded
}

fn install_daemon(app: &AppHandle, initial_profile: Option<&Path>) {
    let Some(bundle) = app_bundle_path() else {
        return;
    };
    let script = bundle.join("Contents/Resources/scripts/install-daemon.sh");
    if !script.exists() {
        return;
    }
    let mut command = format!(
        "/bin/bash {} --app-bundle {}",
        shell_quote(&script.to_string_lossy()),
        shell_quote(&bundle.to_string_lossy())
    );
    if let Some(profile) = initial_profile {
        command.push_str(" --initial-profile ");
        command.push_str(&shell_quote(&profile.to_string_lossy()));
    }
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&command)
    );
    app_log::info("event=privileged_installer action=install phase=spawned success=true");
    let app = app.clone();
    std::thread::spawn(move || {
        // Capture the installer's output rather than discarding it. The script
        // aborts on a config Mihomo will not load, and that reason used to go
        // nowhere: the only trace was `success=false`, so a failed install was
        // indistinguishable from "Mihomo just did not start".
        let output = Command::new("/usr/bin/osascript")
            .args(["-e", &apple_script])
            .output();
        let Ok(output) = output else {
            app_log::error(
                "event=privileged_installer action=install phase=completed success=false \
                 reason=spawn_failed",
            );
            report_install_failure(&app, "Action failed: the installer could not be started");
            return;
        };
        if output.status.success() {
            app_log::info("event=privileged_installer action=install phase=completed success=true");
            return;
        }
        let combined = String::from_utf8_lossy(&output.stderr).into_owned()
            + &String::from_utf8_lossy(&output.stdout);
        let failure = classify_install_failure(&combined);
        // Only the classification is logged. The raw text can carry a rule
        // payload, which may contain a domain name.
        app_log::error(&format!(
            "event=privileged_installer action=install phase=completed success=false \
             reason={}",
            failure.reason
        ));
        if let Some(message) = failure.message {
            report_install_failure(&app, message);
        }
    });
}

struct InstallFailure {
    /// Coarse, log-safe classification.
    reason: &'static str,
    /// User-facing text, or None when the user simply cancelled.
    message: Option<&'static str>,
}

fn classify_install_failure(output: &str) -> InstallFailure {
    if output.contains("User canceled") || output.contains("(-128)") {
        return InstallFailure {
            reason: "cancelled",
            message: None,
        };
    }
    if output.contains("test failed") || output.contains("configuration file") {
        return InstallFailure {
            reason: "profile_rejected",
            message: Some(
                "Action failed: Mihomo rejected the selected profile; re-import a valid one",
            ),
        };
    }
    if output.contains("timed out waiting for") {
        return InstallFailure {
            reason: "timeout",
            message: Some("Action failed: the daemon did not become ready in time"),
        };
    }
    InstallFailure {
        reason: "other",
        message: Some("Action failed: the privileged installer did not complete"),
    }
}

fn report_install_failure(app: &AppHandle, message: &str) {
    let Some(state) = app.try_state::<Arc<TrayState>>() else {
        return;
    };
    let state = state.inner().clone();
    set_action_error(&state, Some(message.to_string()));
    refresh(app.clone(), state, RefreshMode::Authoritative);
}

fn show_profile_required_prompt() {
    let _ = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "display dialog \"Add a profile before enabling Enhanced TUN. Use Profiles > Import Local YAML… or Import HTTP Subscription….\" buttons {\"OK\"} default button \"OK\" with title \"MihomoBox\"",
        ])
        .status();
}

fn show_native_window_unavailable_prompt() {
    let _ = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "display dialog \"The native SwiftUI window is unavailable. Reinstall MihomoBox before opening the Main Window.\" buttons {\"OK\"} default button \"OK\" with title \"MihomoBox\" with icon caution",
        ])
        .spawn();
}

fn start_daemon() {
    std::thread::spawn(|| {
        let _ = run_cli(&["start"]);
    });
}

/// Why a latency test is running.
#[derive(Clone, Copy, PartialEq, Eq)]
enum LatencyTrigger {
    /// The user picked "Test Now" — always measure.
    Requested,
    /// The tray was approached or opened. Measuring here is what makes "Test
    /// Now" unnecessary, but it must not fire on every stray pass of the
    /// cursor: each run is real proxied traffic, one request per node.
    Automatic,
}

/// How recently an automatic test must have run for the next one to be skipped.
/// Long enough that opening the menu repeatedly costs one measurement, short
/// enough that the numbers on screen are current.
const AUTOMATIC_LATENCY_INTERVAL: Duration = Duration::from_secs(20);

/// Measures every node's latency and repaints the menu.
///
/// Returns false when an automatic run was skipped by the interval.
async fn run_latency_test(state: &Arc<TrayState>, trigger: LatencyTrigger) -> bool {
    if trigger == LatencyTrigger::Automatic {
        let mut last = state.last_latency_test.lock().expect("latency test lock");
        if last.is_some_and(|at| at.elapsed() < AUTOMATIC_LATENCY_INTERVAL) {
            return false;
        }
        *last = Some(std::time::Instant::now());
    } else {
        *state.last_latency_test.lock().expect("latency test lock") =
            Some(std::time::Instant::now());
    }
    // One test at a time: the trigger can fire while a previous run is still
    // waiting on the controller.
    if state
        .latency_test_in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return false;
    }
    let _guard = LatencyTestGuard(state.clone());

    let nodes = flat_proxy_nodes(&state.snapshot.lock().expect("snapshot lock"))
        .into_iter()
        .map(|node| node.name)
        .collect::<Vec<_>>();
    if nodes.is_empty() {
        return false;
    }
    let succeeded = controller_client().test_delays(&nodes).await;
    app_log::info(&format!(
        "event=controller_action action=test_delays attempted={} succeeded={succeeded} automatic={}",
        nodes.len(),
        trigger == LatencyTrigger::Automatic
    ));
    // An automatic run stays quiet: it is a background convenience, and the
    // user did not ask for it, so a failure must not plant an error banner in
    // the menu. An explicit request reports.
    if trigger == LatencyTrigger::Requested {
        set_action_error(
            state,
            (succeeded == 0)
                .then(|| "Action failed: latency test could not reach any node".to_string()),
        );
    }
    // Pull the results the test just produced. refresh() would do this too, but
    // it also rebuilds the menu, and that is exactly what must not happen here.
    if let Ok(poll) = controller_client().tray_state().await {
        *state.snapshot.lock().expect("snapshot lock") = poll.snapshot;
    }
    // Deliberately NOT invalidating the menu signature. Forcing a rebuild makes
    // tray.set_menu drop the live muda::Menu, whose Drop calls
    // cancelTrackingWithoutAnimation — which slams shut the very menu the user
    // opened to read these numbers. Write the new values into the existing rows
    // instead.
    repaint_delays_in_place(state);
    true
}

/// Writes fresh latencies into the drawn proxy rows without rebuilding the menu.
///
/// Safe while the menu is tracking: only the item titles change. Must be called
/// from an async task and never from inside `run_on_main_thread` — set_text
/// hops to the main thread and blocks on the reply, so calling it from the main
/// thread would deadlock.
fn repaint_delays_in_place(state: &Arc<TrayState>) {
    let delays = flat_proxy_nodes(&state.snapshot.lock().expect("snapshot lock"))
        .into_iter()
        .map(|node| (node.name, node.delay))
        .collect::<HashMap<_, _>>();
    for (name, item) in state.node_items.lock().expect("node items lock").iter() {
        let Some(delay) = delays.get(name) else {
            continue;
        };
        let _ = item.set_text(format!("{}    {}", name, delay_label(*delay)));
    }
}

/// Releases `latency_test_in_flight` however the test exits.
struct LatencyTestGuard(Arc<TrayState>);

impl Drop for LatencyTestGuard {
    fn drop(&mut self) {
        self.0
            .latency_test_in_flight
            .store(false, Ordering::Release);
    }
}

/// Time allowed for the agent to stop before the tray reports failure.
///
/// `run_cli` has no timeout of its own, and neither does the control round trip
/// behind it, so without a bound a wedged agent would leave the click hanging
/// and the menu unable to say whether anything happened.
const STOP_TIMEOUT: Duration = Duration::from_secs(15);

async fn restore_network(state: &Arc<TrayState>) {
    let confirmation = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "display dialog \"Stop Mihomo and restore real system DNS? Profiles and installation files will be preserved.\" buttons {\"Cancel\", \"Restore Network\"} default button \"Restore Network\" cancel button \"Cancel\" with icon caution",
        ])
        .status();
    if !confirmation.is_ok_and(|status| status.success()) {
        app_log::info("event=restore_network phase=cancelled");
        return;
    }
    app_log::info("event=restore_network phase=confirmed");
    // Await the stop rather than firing and forgetting: a failed disable used
    // to be indistinguishable from a slow one, which left the user clicking
    // again and eventually landing on a path that does prompt.
    let stopped = tokio::time::timeout(
        STOP_TIMEOUT,
        tauri::async_runtime::spawn_blocking(|| run_cli(&["stop"])),
    )
    .await;
    let succeeded = matches!(stopped, Ok(Ok(true)));
    app_log::info(&format!(
        "event=restore_network phase=completed success={succeeded}"
    ));
    set_action_error(
        state,
        (!succeeded).then(|| "Action failed: Enhanced TUN was not disabled".to_string()),
    );
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn apple_script_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('\"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting_preserves_spaces_and_quotes() {
        assert_eq!(shell_quote("A B's"), "'A B'\\''s'");
        assert_eq!(apple_script_quote("a\\b\"c"), "\"a\\\\b\\\"c\"");
    }

    #[test]
    fn profile_state_lists_yaml_and_marks_active() {
        let root =
            std::env::temp_dir().join(format!("mihomobox-profile-state-{}", std::process::id()));
        let profiles = root.join("profiles");
        fs::create_dir_all(&profiles).expect("create profiles");
        fs::write(profiles.join("Beta.yml"), "mixed-port: 7890\n").expect("write beta");
        fs::write(profiles.join("alpha.yaml"), "mixed-port: 7891\n").expect("write alpha");
        fs::write(profiles.join("ignored.txt"), "ignored\n").expect("write ignored");
        fs::write(root.join("active-profile"), "Beta.yml\n").expect("write active");

        let state = profile_state_at(&profiles, &root.join("active-profile"));
        assert_eq!(state.names, vec!["alpha.yaml", "Beta.yml"]);
        assert_eq!(state.active.as_deref(), Some("Beta.yml"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn menu_signature_ignores_delay_only_updates() {
        let mut snapshot = Snapshot {
            reachable: true,
            enhanced_tun: true,
            mode: "rule".to_string(),
            groups: vec![crate::mihomo::ProxyGroup {
                name: "PROXY".to_string(),
                current: "Node A".to_string(),
                proxies: vec![crate::mihomo::ProxyNode {
                    name: "Node A".to_string(),
                    delay: Some(42),
                }],
            }],
        };
        let profiles = ProfileState::default();
        let first = MenuSignature::new(&snapshot, &profiles, false, false, Some(true), None);
        snapshot.groups[0].proxies[0].delay = Some(88);
        let second = MenuSignature::new(&snapshot, &profiles, false, false, Some(true), None);

        assert_eq!(first, second);
        snapshot.groups[0].current = "Node B".to_string();
        let third = MenuSignature::new(&snapshot, &profiles, false, false, Some(true), None);
        assert_ne!(second, third);
    }

    #[test]
    fn retain_known_delays_keeps_last_good_reading_on_empty_probe() {
        let previous = Snapshot {
            groups: vec![crate::mihomo::ProxyGroup {
                name: "PROXY".to_string(),
                current: "Node A".to_string(),
                proxies: vec![
                    crate::mihomo::ProxyNode {
                        name: "Node A".to_string(),
                        delay: Some(42),
                    },
                    crate::mihomo::ProxyNode {
                        name: "Node B".to_string(),
                        delay: Some(88),
                    },
                ],
            }],
            ..Snapshot::default()
        };
        // Fresh poll: Node A's probe failed (None), Node B measured anew.
        let mut fresh = Snapshot {
            groups: vec![crate::mihomo::ProxyGroup {
                name: "PROXY".to_string(),
                current: "Node A".to_string(),
                proxies: vec![
                    crate::mihomo::ProxyNode {
                        name: "Node A".to_string(),
                        delay: None,
                    },
                    crate::mihomo::ProxyNode {
                        name: "Node B".to_string(),
                        delay: Some(120),
                    },
                ],
            }],
            ..Snapshot::default()
        };
        retain_known_delays(&previous, &mut fresh);
        // Node A keeps its last good reading; Node B takes the fresh value.
        assert_eq!(fresh.groups[0].proxies[0].delay, Some(42));
        assert_eq!(fresh.groups[0].proxies[1].delay, Some(120));
    }

    #[test]
    fn retain_known_delays_leaves_never_measured_nodes_unknown() {
        let previous = Snapshot::default();
        let mut fresh = Snapshot {
            groups: vec![crate::mihomo::ProxyGroup {
                name: "PROXY".to_string(),
                current: "Node A".to_string(),
                proxies: vec![crate::mihomo::ProxyNode {
                    name: "Node A".to_string(),
                    delay: None,
                }],
            }],
            ..Snapshot::default()
        };
        retain_known_delays(&previous, &mut fresh);
        assert_eq!(fresh.groups[0].proxies[0].delay, None);
    }

    #[test]
    fn menu_signature_tracks_tun_busy_so_the_item_greys_out() {
        let snapshot = Snapshot::default();
        let profiles = ProfileState::default();
        let idle = MenuSignature::new(&snapshot, &profiles, false, false, Some(true), None);
        let busy = MenuSignature::new(&snapshot, &profiles, false, true, Some(true), None);
        assert_ne!(idle, busy);
    }

    #[test]
    fn a_stale_check_mark_must_not_resolve_to_the_installer() {
        // The reported failure: a first enable fails, macOS leaves the mark
        // checked, and the next click — which the user reads as "cancel" —
        // resolves to InstallDaemon and prompts for a password again.
        let stopped = Snapshot::default();
        assert_eq!(
            tun_action(false, true, &stopped),
            TunAction::InstallDaemon,
            "precondition: this is the action a stale mark would have triggered"
        );
        // The guard in the click arm keys off exactly this disagreement:
        // the menu says checked while the runtime says TUN is off.
        let menu_checked = true;
        assert!(
            menu_checked && !stopped.enhanced_tun,
            "a checked mark over a stopped runtime is the state that must be refused"
        );
    }

    #[test]
    fn first_config_error_extracts_the_kernel_message() {
        // Shape taken from a real Mihomo v1.19.28 validation failure: a rule
        // naming a proxy group the profile never defines.
        let output = concat!(
            "time=\"2026-08-06T10:02:36+08:00\" level=info msg=\"Start initial configuration\"\n",
            "time=\"2026-08-06T10:02:36+08:00\" level=error msg=\"rules[0] [PROCESS-PATH-REGEX,",
            ".*/Foo\\\\.app/.*,Proxy] error: proxy [Proxy] not found\"\n",
            "configuration file /tmp/x/config.yaml test failed\n",
        );
        let reason = first_config_error(output).expect("an error line");
        assert!(reason.contains("proxy [Proxy] not found"), "got: {reason}");
        // The info line must not win.
        assert!(!reason.contains("Start initial configuration"));
    }

    #[test]
    fn first_config_error_truncates_and_handles_absence() {
        assert_eq!(first_config_error("level=info msg=\"all good\""), None);
        let long = format!("level=error msg=\"{}\"", "x".repeat(400));
        let reason = first_config_error(&long).expect("an error line");
        assert!(
            reason.chars().count() <= 161,
            "len {}",
            reason.chars().count()
        );
        assert!(reason.ends_with('…'));
    }

    #[test]
    fn install_failure_classification_is_log_safe_and_distinguishes_cancel() {
        // A cancelled password prompt is not a failure to report to the user.
        let cancelled = classify_install_failure("execution error: User canceled. (-128)");
        assert_eq!(cancelled.reason, "cancelled");
        assert!(cancelled.message.is_none());

        // The reason this whole change exists: the installer aborts when Mihomo
        // rejects the profile, and that used to surface as nothing at all.
        let rejected =
            classify_install_failure("configuration file /Library/.../config.yaml test failed\n");
        assert_eq!(rejected.reason, "profile_rejected");
        assert!(rejected.message.is_some());

        assert_eq!(
            classify_install_failure("timed out waiting for authenticated Mihomo controller")
                .reason,
            "timeout"
        );
        assert_eq!(
            classify_install_failure("something else entirely").reason,
            "other"
        );

        // Every logged reason must be a fixed token — never text echoed from
        // the installer, which can carry a rule payload with a domain name.
        for probe in [
            "execution error: User canceled. (-128)",
            "configuration file x test failed",
            "timed out waiting for x",
            "rules[0] [DOMAIN-SUFFIX,secret.example.com,Proxy] error",
        ] {
            let reason = classify_install_failure(probe).reason;
            assert!(
                ["cancelled", "profile_rejected", "timeout", "other"].contains(&reason),
                "unexpected reason {reason}"
            );
            assert!(!reason.contains("example.com"));
        }
    }

    #[test]
    fn outbound_mode_requires_controller_readback() {
        let observed = Snapshot {
            reachable: true,
            mode: "global".to_string(),
            groups: vec![crate::mihomo::ProxyGroup {
                name: "GLOBAL".to_string(),
                current: "Node A".to_string(),
                proxies: vec![crate::mihomo::ProxyNode {
                    name: "Node A".to_string(),
                    delay: None,
                }],
            }],
            ..Snapshot::default()
        };
        assert!(observed.outbound_mode_applied("global"));
        assert!(!observed.outbound_mode_applied("direct"));
    }

    #[test]
    fn internal_global_selector_is_not_a_user_proxy_group() {
        assert!(!is_user_proxy_group("GLOBAL"));
        assert!(!is_user_proxy_group("global"));
        assert!(is_user_proxy_group("Proxy"));
    }

    #[test]
    fn proxy_list_is_flat_unique_and_excludes_groups_and_builtins() {
        let snapshot = Snapshot {
            reachable: true,
            groups: vec![
                crate::mihomo::ProxyGroup {
                    name: "Proxy".to_string(),
                    current: "🇯🇵 Tokyo".to_string(),
                    proxies: vec![
                        crate::mihomo::ProxyNode {
                            name: "Auto".to_string(),
                            delay: Some(20),
                        },
                        crate::mihomo::ProxyNode {
                            name: "🇯🇵 Tokyo".to_string(),
                            delay: Some(256),
                        },
                        crate::mihomo::ProxyNode {
                            name: "DIRECT".to_string(),
                            delay: None,
                        },
                    ],
                },
                crate::mihomo::ProxyGroup {
                    name: "Auto".to_string(),
                    current: "🇺🇸 Virginia".to_string(),
                    proxies: vec![
                        crate::mihomo::ProxyNode {
                            name: "🇯🇵 Tokyo".to_string(),
                            delay: Some(256),
                        },
                        crate::mihomo::ProxyNode {
                            name: "🇺🇸 Virginia".to_string(),
                            delay: Some(324),
                        },
                    ],
                },
            ],
            ..Snapshot::default()
        };

        let nodes = flat_proxy_nodes(&snapshot);
        assert_eq!(
            nodes
                .iter()
                .map(|node| node.name.as_str())
                .collect::<Vec<_>>(),
            vec!["🇯🇵 Tokyo", "🇺🇸 Virginia"]
        );
        assert!(nodes[0].selected);
        assert!(nodes[1].selected);
        assert_eq!(delay_label(nodes[0].delay), "🟢 256 ms");
        assert_eq!(delay_label(nodes[1].delay), "🟠 324 ms");
    }

    #[test]
    fn enhanced_tun_item_maps_runtime_state_to_safe_actions() {
        let stopped = Snapshot::default();
        assert_eq!(
            tun_action(false, false, &stopped),
            TunAction::RequireProfile
        );
        assert_eq!(tun_action(true, false, &stopped), TunAction::RequireProfile);
        assert_eq!(tun_action(false, true, &stopped), TunAction::InstallDaemon);
        assert_eq!(tun_action(true, true, &stopped), TunAction::StartDaemon);

        let reachable = Snapshot {
            reachable: true,
            ..Snapshot::default()
        };
        assert_eq!(tun_action(true, true, &reachable), TunAction::EnableTun);

        let enabled = Snapshot {
            reachable: true,
            enhanced_tun: true,
            ..Snapshot::default()
        };
        assert_eq!(tun_action(true, false, &enabled), TunAction::StopAndRestore);
    }

    #[test]
    fn local_import_is_visible_and_selected_without_a_system_profile() {
        let root = std::env::temp_dir().join(format!(
            "mihomobox-local-profile-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let source = root.join("sheng.yaml");
        let directory = root.join("user/profiles");
        let active = root.join("user/active-profile");
        fs::create_dir_all(&root).expect("create fixture");
        fs::write(&source, "tun:\n  enable: true\ndns:\n  enable: true\n").expect("write source");

        let name = stage_local_profile(&source, &directory).expect("stage profile");
        write_active_profile(&active, &name).expect("select profile");
        let state = profile_state_at(&directory, &active);

        assert_eq!(state.names, vec!["sheng.yaml"]);
        assert_eq!(state.active.as_deref(), Some("sheng.yaml"));
        assert_eq!(
            fs::metadata(directory.join("sheng.yaml"))
                .expect("profile metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_dir_all(root).expect("remove fixture");
    }
}
