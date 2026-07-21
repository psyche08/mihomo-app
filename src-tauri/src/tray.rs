use crate::dashboard::DashboardBridge;
use crate::mihomo::{MihomoClient, Snapshot};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

const TRAY_ID: &str = "mihomo-app-tray";
const USER_PROFILE_ROOT: &str = "Library/Application Support/MihomoBox";
const DAEMON_PATH: &str = "/Library/Application Support/Mihomo App/mihomo-daemon";
const DAEMON_PLIST_PATH: &str = "/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist";

#[derive(Default, serde::Deserialize)]
struct NetworkHealth {
    network_consistent: bool,
}

#[derive(Default, serde::Deserialize)]
struct ServiceStatus {
    health: Option<NetworkHealth>,
}

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
    dashboard: Option<DashboardBridge>,
    snapshot: Mutex<Snapshot>,
    actions: Mutex<HashMap<String, DynamicAction>>,
    profile_busy: Mutex<bool>,
    last_menu_signature: Mutex<Option<MenuSignature>>,
    last_action_error: Mutex<Option<String>>,
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
    network_healthy: Option<bool>,
    action_error: Option<String>,
}

impl MenuSignature {
    fn new(
        snapshot: &Snapshot,
        profiles: &ProfileState,
        profile_busy: bool,
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
            network_healthy,
            action_error,
        }
    }
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let dashboard = cli_path().and_then(|path| DashboardBridge::start(&path));
    let state = Arc::new(TrayState {
        dashboard,
        snapshot: Mutex::new(Snapshot::default()),
        actions: Mutex::new(HashMap::new()),
        profile_busy: Mutex::new(false),
        last_menu_signature: Mutex::new(None),
        last_action_error: Mutex::new(None),
    });
    app.manage(state.clone());

    let snapshot = Snapshot::default();
    let profiles = profile_state();
    let network_healthy = local_network_health().map(|health| health.network_consistent);
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
        network_healthy,
        None,
    ));
    let icon = app.default_window_icon().cloned();
    let mut tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("MihomoBox")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(handle_menu_event);
    if let Some(icon) = icon {
        tray = tray.icon(icon);
    }
    let tray = tray.build(app)?;
    #[cfg(target_os = "macos")]
    tray.set_icon_as_template(true)?;

    refresh(app.clone(), state.clone());
    let polling_app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            refresh(polling_app.clone(), state.clone());
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
    let tun = CheckMenuItem::with_id(
        app,
        "tun",
        "Enhanced TUN",
        app_bundle_path().is_some(),
        snapshot.enhanced_tun,
        None::<&str>,
    )?;
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
    let tools_menu = Submenu::with_items(app, "Tools", true, &[&install])?;
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
    if id == "show" {
        let Some(state) = app.try_state::<Arc<TrayState>>() else {
            return;
        };
        let state = state.inner().clone();
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let available = controller_client().controller_available().await;
            let main_app = app.clone();
            let _ = app.run_on_main_thread(move || {
                if !available {
                    show_service_unavailable_prompt();
                    return;
                }
                if let Some(window) = main_app.get_webview_window("main") {
                    prepare_main_window(&window, state.dashboard.as_ref());
                    let _ = window.unminimize();
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            });
        });
        return;
    }
    if id == "exit" {
        app.exit(0);
        return;
    }
    if id == "install" {
        install_daemon(selected_local_profile().as_deref());
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if let Some(state) = app.try_state::<Arc<TrayState>>() {
                refresh(app.clone(), state.inner().clone());
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
                let snapshot = state.snapshot.lock().expect("snapshot lock").clone();
                let profiles = profile_state();
                match tun_action(daemon_installed(), profiles.active.is_some(), &snapshot) {
                    TunAction::RequireProfile => show_profile_required_prompt(),
                    TunAction::InstallDaemon => install_daemon(selected_local_profile().as_deref()),
                    TunAction::StartDaemon => start_daemon(),
                    TunAction::EnableTun => {
                        let _ = controller_client().set_tun(true).await;
                    }
                    TunAction::StopAndRestore => restore_network(),
                }
            }
            value if value.starts_with("mode:") => {
                let requested = &value[5..];
                let applied = controller_client()
                    .apply_outbound_mode(requested)
                    .await
                    .is_ok();
                set_action_error(
                    &state,
                    (!applied)
                        .then(|| "Action failed: outbound mode was not safely applied".to_string()),
                );
            }
            "proxy-test" => {
                let nodes = flat_proxy_nodes(&state.snapshot.lock().expect("snapshot lock"))
                    .into_iter()
                    .map(|node| node.name)
                    .collect::<Vec<_>>();
                let succeeded = controller_client().test_delays(&nodes).await;
                set_action_error(
                    &state,
                    (!nodes.is_empty() && succeeded == 0).then(|| {
                        "Action failed: latency test could not reach any node".to_string()
                    }),
                );
                *state
                    .last_menu_signature
                    .lock()
                    .expect("menu signature lock") = None;
            }
            _ => {
                let action = state
                    .actions
                    .lock()
                    .expect("tray action lock")
                    .get(&id)
                    .cloned();
                if let Some(DynamicAction::Proxy { group, proxy }) = action {
                    let _ = controller_client().select_proxy(&group, &proxy).await;
                }
            }
        }
        refresh(app, state);
    });
}

fn refresh(app: AppHandle, state: Arc<TrayState>) {
    tauri::async_runtime::spawn(async move {
        let snapshot = controller_client().snapshot().await;
        *state.snapshot.lock().expect("snapshot lock") = snapshot.clone();
        let profiles = profile_state();
        let profile_busy = *state.profile_busy.lock().expect("profile busy lock");
        let network_healthy = local_network_health().map(|health| health.network_consistent);
        let action_error = state
            .last_action_error
            .lock()
            .expect("action error lock")
            .clone();
        let signature = MenuSignature::new(
            &snapshot,
            &profiles,
            profile_busy,
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

fn delay_label(delay: Option<u64>) -> String {
    match delay.filter(|delay| *delay > 0) {
        Some(delay) if delay <= 300 => format!("🟢 {delay} ms"),
        Some(delay) if delay <= 800 => format!("🟠 {delay} ms"),
        Some(delay) => format!("🔴 {delay} ms"),
        None => "⚪ --".to_string(),
    }
}

fn controller_client() -> MihomoClient {
    MihomoClient::new(cli_path().unwrap_or_else(|| PathBuf::from("/nonexistent/mihomoboxctl")))
}

fn prepare_main_window(
    window: &tauri::WebviewWindow<tauri::Wry>,
    dashboard: Option<&DashboardBridge>,
) {
    let Some(dashboard) = dashboard else {
        return;
    };
    let endpoint = serde_json::json!({
        "url": dashboard.url,
        "secret": dashboard.secret,
    });
    let script = format!(
        r#"(() => {{
            const endpoint = {endpoint};
            const managed = {{ id: 'local-mihomo', url: endpoint.url, secret: endpoint.secret, label: 'Local mihomo (XPC)' }};
            let list = [];
            try {{ list = JSON.parse(localStorage.getItem('endpointList') || '[]'); }} catch (_) {{}}
            if (!Array.isArray(list)) list = [];
            list = [managed, ...list.filter(item => item && item.id !== managed.id)];
            localStorage.setItem('endpointList', JSON.stringify(list));
            localStorage.setItem('selectedEndpoint', managed.id);
            window.metacubexd = {{ ...(window.metacubexd || {{}}), endpoint }};
            window.location.replace('/');
        }})()"#,
    );
    let _ = window.eval(&script);
}

fn title_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn local_network_health() -> Option<NetworkHealth> {
    let output = Command::new(cli_path()?)
        .args(["status", "--json"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice::<ServiceStatus>(&output.stdout)
        .ok()?
        .health
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
    let worker_app = app.clone();
    let worker_state = state.clone();
    let result = std::thread::Builder::new()
        .name(format!("mihomobox-{name}"))
        .spawn(move || {
            set_action_error(&worker_state, operation().err());
            end_profile_operation(&worker_state);
            refresh(worker_app, worker_state);
        });
    if result.is_err() {
        set_action_error(
            &state,
            Some("Action failed: unable to start profile operation".to_string()),
        );
        end_profile_operation(&state);
        refresh(app, state);
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
        return false;
    };
    Command::new(cli)
        .args(arguments)
        .status()
        .is_ok_and(|status| status.success())
}

fn install_daemon(initial_profile: Option<&Path>) {
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
    let _ = Command::new("/usr/bin/osascript")
        .args(["-e", &apple_script])
        .spawn();
}

fn show_profile_required_prompt() {
    let _ = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "display dialog \"Add a profile before enabling Enhanced TUN. Use Profiles > Import Local YAML… or Import HTTP Subscription….\" buttons {\"OK\"} default button \"OK\" with title \"MihomoBox\"",
        ])
        .status();
}

fn show_service_unavailable_prompt() {
    let _ = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "display dialog \"The current Mihomo service is unavailable. Start the service or repair the daemon before opening the Main Window.\" buttons {\"OK\"} default button \"OK\" with title \"MihomoBox\" with icon caution",
        ])
        .spawn();
}

fn start_daemon() {
    std::thread::spawn(|| {
        let _ = run_cli(&["start"]);
    });
}

fn restore_network() {
    let confirmation = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "display dialog \"Stop Mihomo and restore real system DNS? Profiles and installation files will be preserved.\" buttons {\"Cancel\", \"Restore Network\"} default button \"Restore Network\" cancel button \"Cancel\" with icon caution",
        ])
        .status();
    if !confirmation.is_ok_and(|status| status.success()) {
        return;
    }
    std::thread::spawn(|| {
        let _ = run_cli(&["stop"]);
    });
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
        let first = MenuSignature::new(&snapshot, &profiles, false, Some(true), None);
        snapshot.groups[0].proxies[0].delay = Some(88);
        let second = MenuSignature::new(&snapshot, &profiles, false, Some(true), None);

        assert_eq!(first, second);
        snapshot.groups[0].current = "Node B".to_string();
        let third = MenuSignature::new(&snapshot, &profiles, false, Some(true), None);
        assert_ne!(second, third);
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
