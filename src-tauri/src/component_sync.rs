use crate::app_log;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const SYNC_DELAY: Duration = Duration::from_secs(2);
const INSTALLED_DAEMON: &str = "/Library/Application Support/Mihomo App/mihomo-daemon";

pub fn start() {
    app_log::info("event=component_sync phase=scheduled");
    std::thread::spawn(|| {
        std::thread::sleep(SYNC_DELAY);
        if !Path::new(INSTALLED_DAEMON).is_file() {
            app_log::info("event=component_sync result=skipped_not_installed");
            return;
        }
        let Some(cli) = std::env::current_exe()
            .ok()
            .and_then(|executable| cli_path(&executable))
        else {
            app_log::error("event=component_sync result=cli_path_unavailable");
            return;
        };
        if !cli.is_file() {
            app_log::error("event=component_sync result=cli_missing");
            return;
        }
        let succeeded = Command::new(cli)
            .args(["components", "update"])
            .output()
            .is_ok_and(|output| output.status.success());
        if !succeeded {
            app_log::error("event=component_sync result=failed");
        } else {
            app_log::info("event=component_sync result=success");
        }
    });
}

fn cli_path(executable: &Path) -> Option<PathBuf> {
    let macos = executable.parent()?;
    let contents = macos.parent()?;
    let bundle = contents.parent()?;
    if macos.file_name()? != "MacOS"
        || contents.file_name()? != "Contents"
        || bundle.extension()? != "app"
    {
        return None;
    }
    Some(macos.join("mihomoboxctl"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_is_resolved_only_from_a_macos_app_bundle() {
        assert_eq!(
            cli_path(Path::new(
                "/Applications/MihomoBox.app/Contents/MacOS/mihomo-app"
            )),
            Some(PathBuf::from(
                "/Applications/MihomoBox.app/Contents/MacOS/mihomoboxctl"
            ))
        );
        assert!(cli_path(Path::new("/tmp/mihomo-app")).is_none());
    }
}
