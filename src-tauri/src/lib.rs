mod app_log;
mod component_sync;
mod control;
mod mihomo;
mod native_window;
mod startup;
mod tray;
mod updater;

pub fn run() {
    app_log::install_crash_logging();
    app_log::info("event=app_started");
    let result = tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            tray::setup(app.handle())?;
            component_sync::start();
            updater::start(app.handle().clone());
            let smoke_window = std::env::var_os("MIHOMO_APP_SMOKE_SHOW_WINDOW").is_some()
                || std::env::args_os().any(|argument| argument == "--smoke-show-window");
            if smoke_window {
                native_window::show(app.handle())?;
            }
            app_log::info("event=app_setup_completed");
            Ok(())
        })
        .run(tauri::generate_context!());
    match result {
        Ok(()) => app_log::info("event=app_stopped reason=normal"),
        Err(_) => app_log::error("event=app_stopped reason=tauri_error"),
    }
    app_log::flush();
}
