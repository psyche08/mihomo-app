use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::fd::IntoRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_FILE_BYTES: u64 = 100 * 1024 * 1024;
const RETAINED_FILES: usize = 3;
const APP_LOG_NAME: &str = "mihomobox.log";
const CRASH_LOG_NAME: &str = "mihomobox-crash.log";

static WRITE_LOCK: Mutex<()> = Mutex::new(());
static LOG_DIRECTORY: OnceLock<Option<PathBuf>> = OnceLock::new();
static CRASH_FD: AtomicI32 = AtomicI32::new(-1);

pub fn install_crash_logging() {
    let Some(directory) = log_directory() else {
        return;
    };
    let crash_path = directory.join(CRASH_LOG_NAME);
    let _guard = WRITE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if prepare_directory(&directory).is_err() || rotate_if_needed(&crash_path, 1_024).is_err() {
        return;
    }
    let Ok(file) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&crash_path)
    else {
        return;
    };
    CRASH_FD.store(file.into_raw_fd(), Ordering::Release);

    std::panic::set_hook(Box::new(|info| {
        let location = info
            .location()
            .map(|value| format!("{}:{}", value.file(), value.line()))
            .unwrap_or_else(|| "unknown".to_string());
        let record = format!("event=app_panicked location={location}");
        write_crash_record(
            format!("{} level=error {record}\n", timestamp_milliseconds()).as_bytes(),
        );
        let _ = std::io::stderr().write_all(format!("level=error {record}\n").as_bytes());
    }));

    unsafe {
        for signal in [
            libc::SIGABRT,
            libc::SIGBUS,
            libc::SIGFPE,
            libc::SIGILL,
            libc::SIGSEGV,
        ] {
            libc::signal(
                signal,
                crash_signal_handler as *const () as libc::sighandler_t,
            );
        }
    }
}

pub fn info(message: &str) {
    write("info", message);
}

pub fn error(message: &str) {
    write("error", message);
}

pub fn open_log_folders() {
    if let Some(directory) = log_directory() {
        let _ = std::process::Command::new("/usr/bin/open")
            .arg(directory)
            .spawn();
    }
    let _ = std::process::Command::new("/usr/bin/open")
        .arg("/Library/Logs/Mihomo App")
        .spawn();
}

fn write(level: &str, message: &str) {
    let Some(directory) = log_directory() else {
        return;
    };
    let path = directory.join(APP_LOG_NAME);
    let data = format!("{} level={} {}\n", timestamp_milliseconds(), level, message);
    let _guard = WRITE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if prepare_directory(&directory).is_err()
        || append_rotating(&path, data.as_bytes(), MAX_FILE_BYTES).is_err()
    {
        let _ = std::io::stderr().write_all(data.as_bytes());
    }
}

fn append_rotating(path: &Path, mut data: &[u8], maximum_file_bytes: u64) -> std::io::Result<()> {
    while !data.is_empty() {
        let mut size = fs::metadata(path).map(|value| value.len()).unwrap_or(0);
        if size >= maximum_file_bytes {
            rotate(path)?;
            size = 0;
        }
        let writable = usize::try_from((maximum_file_bytes - size).min(data.len() as u64))
            .unwrap_or(data.len());
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(path)?;
        file.write_all(&data[..writable])?;
        file.sync_data()?;
        data = &data[writable..];
    }
    Ok(())
}

fn rotate_if_needed(path: &Path, reserving_bytes: u64) -> std::io::Result<()> {
    if fs::metadata(path).map(|value| value.len()).unwrap_or(0)
        > MAX_FILE_BYTES.saturating_sub(reserving_bytes)
    {
        rotate(path)?;
    }
    Ok(())
}

fn rotate(path: &Path) -> std::io::Result<()> {
    let oldest = rotated_path(path, RETAINED_FILES);
    if oldest.exists() {
        fs::remove_file(oldest)?;
    }
    for index in (1..RETAINED_FILES).rev() {
        let source = rotated_path(path, index);
        if source.exists() {
            fs::rename(source, rotated_path(path, index + 1))?;
        }
    }
    if path.exists() {
        fs::rename(path, rotated_path(path, 1))?;
    }
    Ok(())
}

fn rotated_path(path: &Path, index: usize) -> PathBuf {
    PathBuf::from(format!("{}.{}", path.display(), index))
}

fn prepare_directory(directory: &Path) -> std::io::Result<()> {
    fs::create_dir_all(directory)?;
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
}

fn log_directory() -> Option<PathBuf> {
    LOG_DIRECTORY
        .get_or_init(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .map(|path| path.join("Library/Logs/MihomoBox"))
        })
        .clone()
}

fn timestamp_milliseconds() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis())
        .unwrap_or(0)
}

fn write_crash_record(data: &[u8]) {
    let descriptor = CRASH_FD.load(Ordering::Acquire);
    if descriptor < 0 {
        return;
    }
    unsafe {
        libc::write(descriptor, data.as_ptr().cast(), data.len());
        libc::fsync(descriptor);
    }
}

extern "C" fn crash_signal_handler(signal: libc::c_int) {
    let data: &[u8] = match signal {
        libc::SIGABRT => b"level=error event=app_crashed signal=SIGABRT\n",
        libc::SIGBUS => b"level=error event=app_crashed signal=SIGBUS\n",
        libc::SIGFPE => b"level=error event=app_crashed signal=SIGFPE\n",
        libc::SIGILL => b"level=error event=app_crashed signal=SIGILL\n",
        libc::SIGSEGV => b"level=error event=app_crashed signal=SIGSEGV\n",
        _ => b"level=error event=app_crashed signal=unknown\n",
    };
    write_crash_record(data);
    unsafe {
        libc::signal(signal, libc::SIG_DFL);
        libc::raise(signal);
        libc::_exit(128 + signal);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotating_path_uses_numbered_suffix() {
        assert_eq!(
            rotated_path(Path::new("/tmp/test.log"), 2),
            PathBuf::from("/tmp/test.log.2")
        );
    }

    #[test]
    fn writer_caps_and_rotates_each_file() {
        let root = std::env::temp_dir().join(format!(
            "mihomobox-log-test-{}-{}",
            std::process::id(),
            timestamp_milliseconds()
        ));
        fs::create_dir_all(&root).expect("create log test directory");
        let path = root.join("app.log");

        append_rotating(&path, &[1; 7], 10).expect("first write");
        append_rotating(&path, &[2; 7], 10).expect("rotating write");

        assert_eq!(fs::metadata(&path).expect("current log").len(), 4);
        assert_eq!(
            fs::metadata(rotated_path(&path, 1))
                .expect("rotated log")
                .len(),
            10
        );
        fs::remove_dir_all(root).expect("remove log test directory");
    }
}
