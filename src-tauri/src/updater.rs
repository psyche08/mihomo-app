use crate::app_log;
use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

const STARTUP_CHECK_DELAY: Duration = Duration::from_secs(30);
const UPDATE_TIMEOUT: Duration = Duration::from_secs(30);
const PERIODIC_CHECK_DELAY: Duration = Duration::from_secs(6 * 60 * 60);
const MAXIMUM_RETRY_DELAY: Duration = Duration::from_secs(30 * 60);

pub fn start(app: AppHandle) {
    app_log::info("event=app_update phase=scheduled");
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(STARTUP_CHECK_DELAY).await;
        let mut failures = 0_u32;
        loop {
            match check_install_and_restart(app.clone()).await {
                Ok(()) => {
                    failures = 0;
                    tokio::time::sleep(PERIODIC_CHECK_DELAY).await;
                }
                Err(_) => {
                    failures = failures.saturating_add(1);
                    let delay = retry_delay(failures);
                    app_log::error(&format!(
                        "event=app_update result=failed kind=updater_error failures={} retry_ms={}",
                        failures,
                        delay.as_millis()
                    ));
                    tokio::time::sleep(delay).await;
                }
            }
        }
    });
}

fn retry_delay(failures: u32) -> Duration {
    let exponent = failures.saturating_sub(1).min(10);
    let seconds = 30_u64.saturating_mul(1_u64 << exponent);
    Duration::from_secs(seconds.min(MAXIMUM_RETRY_DELAY.as_secs()))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn updater_retry_delay_is_exponential_and_capped() {
        assert_eq!(retry_delay(1), Duration::from_secs(30));
        assert_eq!(retry_delay(2), Duration::from_secs(60));
        assert_eq!(retry_delay(4), Duration::from_secs(240));
        assert_eq!(retry_delay(20), MAXIMUM_RETRY_DELAY);
    }
}
