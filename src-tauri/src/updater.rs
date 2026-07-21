use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

const STARTUP_CHECK_DELAY: Duration = Duration::from_secs(30);
const UPDATE_TIMEOUT: Duration = Duration::from_secs(30);

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(STARTUP_CHECK_DELAY).await;
        if let Err(error) = check_install_and_restart(app).await {
            eprintln!("automatic update failed: {error}");
        }
    });
}

async fn check_install_and_restart(app: AppHandle) -> Result<(), tauri_plugin_updater::Error> {
    let updater = app.updater_builder().timeout(UPDATE_TIMEOUT).build()?;
    let Some(update) = updater.check().await? else {
        return Ok(());
    };

    eprintln!("installing MihomoBox update {}", update.version);
    update.download_and_install(|_, _| {}, || {}).await?;
    app.restart();
}
