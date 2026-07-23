use crate::app_log;
use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

const STARTUP_CHECK_DELAY: Duration = Duration::from_secs(30);
const UPDATE_TIMEOUT: Duration = Duration::from_secs(30);

pub fn start(app: AppHandle) {
    app_log::info("event=app_update phase=scheduled");
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(STARTUP_CHECK_DELAY).await;
        if let Err(error) = check_install_and_restart(app).await {
            let _ = error;
            app_log::error("event=app_update result=failed");
        }
    });
}

async fn check_install_and_restart(app: AppHandle) -> Result<(), tauri_plugin_updater::Error> {
    let updater = app.updater_builder().timeout(UPDATE_TIMEOUT).build()?;
    let Some(update) = updater.check().await? else {
        app_log::info("event=app_update result=up_to_date");
        return Ok(());
    };

    app_log::info("event=app_update phase=installing");
    update.download_and_install(|_, _| {}, || {}).await?;
    app_log::info("event=app_update result=installed action=restart");
    app.restart();
}
