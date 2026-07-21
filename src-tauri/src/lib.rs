mod component_sync;
mod dashboard;
mod mihomo;
mod tray;
mod updater;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            tray::setup(app.handle())?;
            component_sync::start();
            updater::start(app.handle().clone());
            if std::env::var_os("MIHOMO_APP_SMOKE_SHOW_WINDOW").is_some() {
                use tauri::Manager;
                if let Some(window) = app.get_webview_window("main") {
                    window.show()?;
                    window.set_focus()?;
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run MihomoBox");
}
