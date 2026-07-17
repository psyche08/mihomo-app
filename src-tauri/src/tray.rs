use crate::mihomo::{MihomoClient, Snapshot};
use std::collections::HashMap;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

const TRAY_ID: &str = "mihomo-app-tray";

#[derive(Clone)]
enum DynamicAction {
    Proxy { group: String, proxy: String },
}

struct TrayState {
    client: MihomoClient,
    snapshot: Mutex<Snapshot>,
    actions: Mutex<HashMap<String, DynamicAction>>,
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let state = Arc::new(TrayState {
        client: MihomoClient::new("http://127.0.0.1:9090"),
        snapshot: Mutex::new(Snapshot::default()),
        actions: Mutex::new(HashMap::new()),
    });
    app.manage(state.clone());

    let menu = build_menu(app, &state, &Snapshot::default())?;
    let icon = app.default_window_icon().cloned();
    let mut tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("Mihomo App")
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
) -> tauri::Result<Menu<tauri::Wry>> {
    let show = MenuItem::with_id(app, "show", "Show Main Window", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let tun = CheckMenuItem::with_id(
        app,
        "tun",
        "Enhanced TUN",
        snapshot.reachable,
        snapshot.enhanced_tun,
        None::<&str>,
    )?;

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
    for (group_index, group) in snapshot.groups.iter().enumerate() {
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
    *state.actions.lock().expect("tray action lock") = actions;

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

    let reload = MenuItem::with_id(
        app,
        "reload",
        "Reload Profile",
        snapshot.reachable,
        None::<&str>,
    )?;
    let install = MenuItem::with_id(
        app,
        "install",
        "Install / Repair Daemon…",
        app_bundle_path().is_some(),
        None::<&str>,
    )?;
    let exit = MenuItem::with_id(app, "exit", "Exit", true, None::<&str>)?;
    let final_separator = PredefinedMenuItem::separator(app)?;
    Menu::with_items(
        app,
        &[
            &show,
            &separator,
            &tun,
            &mode_menu,
            &proxy_menu,
            &reload,
            &install,
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
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match id.as_str() {
            "tun" => {
                let enabled = state.snapshot.lock().expect("snapshot lock").enhanced_tun;
                let _ = state.client.set_tun(!enabled).await;
            }
            "reload" => {
                let _ = state.client.reload_profile().await;
            }
            value if value.starts_with("mode:") => {
                let _ = state.client.set_mode(&value[5..]).await;
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
        let menu_app = app.clone();
        let _ = app.run_on_main_thread(move || {
            let Ok(menu) = build_menu(&menu_app, &state, &snapshot) else {
                return;
            };
            if let Some(tray) = menu_app.tray_by_id(TRAY_ID) {
                let _ = tray.set_menu(Some(menu));
                let _ = tray.set_tooltip(Some(if snapshot.reachable {
                    "Mihomo App"
                } else {
                    "Mihomo App · daemon unavailable"
                }));
            }
        });
    });
}

fn title_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
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
}
