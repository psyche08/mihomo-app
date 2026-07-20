use crate::mihomo::{MihomoClient, Snapshot};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

const TRAY_ID: &str = "mihomo-app-tray";
const PROFILES_DIR: &str = "/Library/Application Support/Mihomo App/profiles";
const ACTIVE_PROFILE_PATH: &str = "/Library/Application Support/Mihomo App/active-profile";
const DAEMON_PATH: &str = "/Library/Application Support/Mihomo App/mihomo-daemon";
const DAEMON_CONFIG_PATH: &str = "/Library/Application Support/Mihomo App/daemon.json";
const DAEMON_PLIST_PATH: &str = "/Library/LaunchDaemons/dev.linsheng.mihomo.daemon.plist";

#[derive(Default, serde::Deserialize)]
struct NetworkHealth {
    network_consistent: bool,
}

#[derive(Clone)]
enum DynamicAction {
    Proxy { group: String, proxy: String },
    Profile { name: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TunAction {
    InstallDaemon,
    StartDaemon,
    EnableTun,
    StopAndRestore,
}

struct TrayState {
    client: MihomoClient,
    snapshot: Mutex<Snapshot>,
    actions: Mutex<HashMap<String, DynamicAction>>,
    profile_busy: Mutex<bool>,
    last_menu_signature: Mutex<Option<MenuSignature>>,
    last_action_error: Mutex<Option<String>>,
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
    let state = Arc::new(TrayState {
        client: MihomoClient::new("http://127.0.0.1:9090"),
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
    let mut group_menus = Vec::new();
    for (group_index, group) in snapshot
        .groups
        .iter()
        .filter(|group| is_user_proxy_group(&group.name))
        .enumerate()
    {
        let nodes = group
            .proxies
            .iter()
            .enumerate()
            .map(|(node_index, node)| {
                let id = format!("proxy:{group_index}:{node_index}");
                actions.insert(
                    id.clone(),
                    DynamicAction::Proxy {
                        group: group.name.clone(),
                        proxy: node.name.clone(),
                    },
                );
                let label = match node.delay {
                    Some(delay) => format!("{}  {} ms", node.name, delay),
                    None => format!("{}  --", node.name),
                };
                CheckMenuItem::with_id(
                    app,
                    id,
                    label,
                    true,
                    group.current == node.name,
                    None::<&str>,
                )
            })
            .collect::<Result<Vec<_>, _>>()?;
        let node_refs = nodes
            .iter()
            .map(|item| item as &dyn IsMenuItem<tauri::Wry>)
            .collect::<Vec<_>>();
        group_menus.push(Submenu::with_items(app, &group.name, true, &node_refs)?);
    }
    let proxy_menu = if group_menus.is_empty() {
        let empty = MenuItem::with_id(
            app,
            "proxy-empty",
            if snapshot.reachable {
                "No proxy groups"
            } else {
                "Mihomo daemon unavailable"
            },
            false,
            None::<&str>,
        )?;
        Submenu::with_items(app, "Proxy List", true, &[&empty])?
    } else {
        let group_refs = group_menus
            .iter()
            .map(|item| item as &dyn IsMenuItem<tauri::Wry>)
            .collect::<Vec<_>>();
        Submenu::with_items(app, "Proxy List", true, &group_refs)?
    };

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
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.unminimize();
            let _ = window.show();
            let _ = window.set_focus();
        }
        return;
    }
    if id == "exit" {
        app.exit(0);
        return;
    }
    if id == "install" {
        install_daemon();
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
        if let Some(name) = profile_state().active {
            switch_local_profile(app.clone(), state, name);
        }
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match id.as_str() {
            "tun" => {
                let snapshot = state.snapshot.lock().expect("snapshot lock").clone();
                match tun_action(daemon_installed(), &snapshot) {
                    TunAction::InstallDaemon => install_daemon(),
                    TunAction::StartDaemon => start_daemon(),
                    TunAction::EnableTun => {
                        let _ = state.client.set_tun(true).await;
                    }
                    TunAction::StopAndRestore => restore_network(),
                }
            }
            value if value.starts_with("mode:") => {
                let requested = &value[5..];
                let applied = state.client.apply_outbound_mode(requested).await.is_ok();
                set_action_error(
                    &state,
                    (!applied)
                        .then(|| "Action failed: outbound mode was not safely applied".to_string()),
                );
            }
            _ => {
                let action = state
                    .actions
                    .lock()
                    .expect("tray action lock")
                    .get(&id)
                    .cloned();
                if let Some(DynamicAction::Proxy { group, proxy }) = action {
                    let _ = state.client.select_proxy(&group, &proxy).await;
                }
            }
        }
        refresh(app, state);
    });
}

fn refresh(app: AppHandle, state: Arc<TrayState>) {
    tauri::async_runtime::spawn(async move {
        let snapshot = state.client.snapshot().await;
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

fn tun_action(daemon_installed: bool, snapshot: &Snapshot) -> TunAction {
    if !daemon_installed {
        TunAction::InstallDaemon
    } else if snapshot.enhanced_tun {
        TunAction::StopAndRestore
    } else if snapshot.reachable {
        TunAction::EnableTun
    } else {
        TunAction::StartDaemon
    }
}

fn is_user_proxy_group(name: &str) -> bool {
    !name.eq_ignore_ascii_case("GLOBAL")
}

fn title_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn local_network_health() -> Option<NetworkHealth> {
    let output = Command::new(DAEMON_PATH)
        .args(["--config", DAEMON_CONFIG_PATH, "--health"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice(&output.stdout).ok()
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
    profile_state_at(Path::new(PROFILES_DIR), Path::new(ACTIVE_PROFILE_PATH))
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
            let path = path.to_string_lossy().into_owned();
            let _ = run_profile_installer(&["--import-profile", &path, "--activate"]);
        }
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
                let _ = Command::new(cli)
                    .args(["profile", "import-url", "--interactive"])
                    .status();
            }
        }
    });
}

fn switch_local_profile(app: AppHandle, state: Arc<TrayState>, name: String) {
    if !begin_profile_operation(&state) {
        return;
    }
    spawn_profile_operation(app, state, "profile-switch", move || {
        let _ = run_profile_installer(&["--switch-profile", &name]);
    });
}

fn spawn_profile_operation<F>(app: AppHandle, state: Arc<TrayState>, name: &str, operation: F)
where
    F: FnOnce() + Send + 'static,
{
    let worker_app = app.clone();
    let worker_state = state.clone();
    let result = std::thread::Builder::new()
        .name(format!("mihomobox-{name}"))
        .spawn(move || {
            operation();
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

fn run_profile_installer(arguments: &[&str]) -> bool {
    let Some(bundle) = app_bundle_path() else {
        return false;
    };
    let script = bundle.join("Contents/Resources/scripts/install-daemon.sh");
    if !script.exists() {
        return false;
    }
    let mut command = format!(
        "/bin/bash {} --app-bundle {}",
        shell_quote(&script.to_string_lossy()),
        shell_quote(&bundle.to_string_lossy())
    );
    for argument in arguments {
        command.push(' ');
        command.push_str(&shell_quote(argument));
    }
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&command)
    );
    Command::new("/usr/bin/osascript")
        .args(["-e", &apple_script])
        .status()
        .is_ok_and(|status| status.success())
}

fn install_daemon() {
    let Some(bundle) = app_bundle_path() else {
        return;
    };
    let script = bundle.join("Contents/Resources/scripts/install-daemon.sh");
    if !script.exists() {
        return;
    }
    let command = format!(
        "/bin/bash {} --app-bundle {}",
        shell_quote(&script.to_string_lossy()),
        shell_quote(&bundle.to_string_lossy())
    );
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&command)
    );
    let _ = Command::new("/usr/bin/osascript")
        .args(["-e", &apple_script])
        .spawn();
}

fn start_daemon() {
    let Some(bundle) = app_bundle_path() else {
        return;
    };
    let script = bundle.join("Contents/Resources/scripts/install-daemon.sh");
    if !script.exists() {
        return;
    }
    let command = format!(
        "/bin/bash {} --app-bundle {} --start",
        shell_quote(&script.to_string_lossy()),
        shell_quote(&bundle.to_string_lossy())
    );
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&command)
    );
    let _ = Command::new("/usr/bin/osascript")
        .args(["-e", &apple_script])
        .spawn();
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
        let _ = run_profile_installer(&["--restore-network"]);
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
    fn enhanced_tun_item_maps_runtime_state_to_safe_actions() {
        let stopped = Snapshot::default();
        assert_eq!(tun_action(false, &stopped), TunAction::InstallDaemon);
        assert_eq!(tun_action(true, &stopped), TunAction::StartDaemon);

        let reachable = Snapshot {
            reachable: true,
            ..Snapshot::default()
        };
        assert_eq!(tun_action(true, &reachable), TunAction::EnableTun);

        let enabled = Snapshot {
            reachable: true,
            enhanced_tun: true,
            ..Snapshot::default()
        };
        assert_eq!(tun_action(true, &enabled), TunAction::StopAndRestore);
    }
}
