use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

const LOGIN_AGENT_LABEL: &str = "dev.linsheng.mihomo-app";
const LOGIN_AGENT_FILE: &str = "dev.linsheng.mihomo-app.plist";
const APP_BUNDLE_IDENTIFIER: &str = "dev.linsheng.mihomo-app";
const USER_SUPPORT_ROOT: &str = "Library/Application Support/MihomoBox";
const DEFAULT_STATE_FILE: &str = ".login-autostart-default.json";
const DEFAULT_STATE_VERSION: u32 = 1;
pub(crate) const MAX_SESSION_ATTEMPTS: u32 = 3;
static TEMP_FILE_SEQUENCE: AtomicU32 = AtomicU32::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ApplyOutcome {
    Applied,
    AlreadyApplied,
    RepairedMovedApp,
    UserDisabled,
    UserConfigured,
    NotInstalled,
}

impl ApplyOutcome {
    pub(crate) fn log_value(self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::AlreadyApplied => "already_applied",
            Self::RepairedMovedApp => "repaired_moved_app",
            Self::UserDisabled => "user_disabled",
            Self::UserConfigured => "user_configured",
            Self::NotInstalled => "not_installed",
        }
    }
}

#[derive(Debug)]
enum AgentStatus {
    Missing,
    Valid { executable: String },
    Invalid,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct LaunchAgent {
    #[serde(rename = "Label")]
    label: String,
    #[serde(rename = "ProgramArguments")]
    program_arguments: Vec<String>,
    #[serde(rename = "RunAtLoad")]
    run_at_load: bool,
    #[serde(rename = "AssociatedBundleIdentifiers")]
    associated_bundle_identifiers: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct AppliedDefault {
    format_version: u32,
    executable: String,
}

#[derive(Debug)]
struct AutostartPaths {
    agent: PathBuf,
    state: PathBuf,
}

#[derive(Debug)]
struct AgentBackup {
    contents: Vec<u8>,
    mode: u32,
}

impl AutostartPaths {
    fn for_home(home: &Path) -> Self {
        Self {
            agent: home.join("Library/LaunchAgents").join(LOGIN_AGENT_FILE),
            state: home.join(USER_SUPPORT_ROOT).join(DEFAULT_STATE_FILE),
        }
    }
}

pub(crate) fn should_consider_default(
    enhanced_tun: bool,
    network_consistent: Option<bool>,
) -> bool {
    enhanced_tun && network_consistent == Some(true)
}

/// Applies the one-time login-start default for a healthy Enhanced TUN
/// installation. Only Apps in /Applications or ~/Applications are eligible;
/// a DMG, App Translocation, Downloads copy, or target smoke build can never
/// consume the default with an ephemeral executable path.
pub(crate) fn apply_login_autostart_default() -> io::Result<ApplyOutcome> {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Ok(ApplyOutcome::NotInstalled);
    };
    let home = fs::canonicalize(&home).unwrap_or(home);
    let Some(executable) = std::env::current_exe()
        .ok()
        .and_then(|path| fs::canonicalize(path).ok())
        .filter(|path| is_installed_app_executable(path, &home))
    else {
        return Ok(ApplyOutcome::NotInstalled);
    };
    reconcile_at(&AutostartPaths::for_home(&home), &executable)
}

fn is_installed_app_executable(executable: &Path, home: &Path) -> bool {
    let Some(macos) = executable.parent() else {
        return false;
    };
    let Some(contents) = macos.parent() else {
        return false;
    };
    let Some(bundle) = contents.parent() else {
        return false;
    };
    if !macos.file_name().is_some_and(|name| name == "MacOS")
        || !contents.file_name().is_some_and(|name| name == "Contents")
        || !bundle
            .extension()
            .is_some_and(|extension| extension == "app")
    {
        return false;
    }
    bundle.starts_with("/Applications") || bundle.starts_with(home.join("Applications"))
}

fn reconcile_at(paths: &AutostartPaths, executable: &Path) -> io::Result<ApplyOutcome> {
    let executable = executable
        .to_str()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "non-Unicode App path"))?;
    let state = read_state(&paths.state)?;
    let status = read_agent_status(&paths.agent)?;

    if let Some(state) = state {
        if state.format_version != DEFAULT_STATE_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported login autostart state",
            ));
        }
        return match status {
            AgentStatus::Missing => Ok(ApplyOutcome::UserDisabled),
            AgentStatus::Valid {
                executable: current,
            } if current == executable => {
                if state.executable == executable {
                    Ok(ApplyOutcome::AlreadyApplied)
                } else {
                    // The LaunchAgent rename may have reached disk immediately
                    // before a prior process exited. Complete that transaction
                    // so a later App move can still be reconciled safely.
                    write_state(&paths.state, executable)?;
                    Ok(ApplyOutcome::RepairedMovedApp)
                }
            }
            AgentStatus::Valid {
                executable: current,
            } if current == state.executable => {
                replace_agent_and_state(paths, executable)?;
                Ok(ApplyOutcome::RepairedMovedApp)
            }
            AgentStatus::Valid { .. } | AgentStatus::Invalid => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "login autostart entry was modified",
            )),
        };
    }

    match status {
        AgentStatus::Missing => replace_agent_and_state(paths, executable)?,
        AgentStatus::Valid {
            executable: current,
        } if current == executable => write_state(&paths.state, executable)?,
        // This release is the first owner of this label. A different or
        // malformed pre-existing file is therefore user-managed; a default
        // must not overwrite it.
        AgentStatus::Valid { .. } | AgentStatus::Invalid => {
            return Ok(ApplyOutcome::UserConfigured)
        }
    }
    Ok(ApplyOutcome::Applied)
}

fn replace_agent_and_state(paths: &AutostartPaths, executable: &str) -> io::Result<()> {
    let previous = match fs::symlink_metadata(&paths.agent) {
        Ok(metadata) if metadata.file_type().is_file() => Some(AgentBackup {
            contents: fs::read(&paths.agent)?,
            mode: metadata.permissions().mode() & 0o777,
        }),
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "login autostart entry is not a regular file",
            ))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };

    write_agent(&paths.agent, executable)?;
    let readback = read_agent_status(&paths.agent);
    if !matches!(
        readback,
        Ok(AgentStatus::Valid {
            executable: ref current
        }) if current == executable
    ) {
        restore_agent(&paths.agent, previous.as_ref())?;
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "login autostart readback failed",
        ));
    }
    if let Err(error) = write_state(&paths.state, executable) {
        restore_agent(&paths.agent, previous.as_ref())?;
        return Err(error);
    }
    Ok(())
}

fn read_agent_status(path: &Path) -> io::Result<AgentStatus> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(AgentStatus::Missing),
        Err(error) => Err(error),
        Ok(metadata) if !metadata.file_type().is_file() => Ok(AgentStatus::Invalid),
        Ok(_) => {
            let Ok(agent) = plist::from_file::<_, LaunchAgent>(path) else {
                return Ok(AgentStatus::Invalid);
            };
            if agent.label != LOGIN_AGENT_LABEL
                || !agent.run_at_load
                || agent.program_arguments.len() != 1
                || agent.associated_bundle_identifiers != [APP_BUNDLE_IDENTIFIER.to_string()]
            {
                return Ok(AgentStatus::Invalid);
            }
            Ok(AgentStatus::Valid {
                executable: agent.program_arguments[0].clone(),
            })
        }
    }
}

fn read_state(path: &Path) -> io::Result<Option<AppliedDefault>> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
        Ok(metadata) if !metadata.file_type().is_file() => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "login autostart state is not a regular file",
        )),
        Ok(_) => serde_json::from_slice(&fs::read(path)?)
            .map(Some)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
    }
}

fn write_agent(path: &Path, executable: &str) -> io::Result<()> {
    let agent = LaunchAgent {
        label: LOGIN_AGENT_LABEL.to_string(),
        program_arguments: vec![executable.to_string()],
        run_at_load: true,
        associated_bundle_identifiers: vec![APP_BUNDLE_IDENTIFIER.to_string()],
    };
    let mut contents = Vec::new();
    plist::to_writer_xml(&mut contents, &agent)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    create_parent(path, None)?;
    atomic_write(path, &contents, 0o644)
}

fn write_state(path: &Path, executable: &str) -> io::Result<()> {
    let state = AppliedDefault {
        format_version: DEFAULT_STATE_VERSION,
        executable: executable.to_string(),
    };
    let mut contents = serde_json::to_vec_pretty(&state)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    contents.push(b'\n');
    create_parent(path, Some(0o700))?;
    atomic_write(path, &contents, 0o600)
}

fn create_parent(path: &Path, mode: Option<u32>) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing parent directory"))?;
    fs::create_dir_all(parent)?;
    if let Some(mode) = mode {
        fs::set_permissions(parent, fs::Permissions::from_mode(mode))?;
    }
    Ok(())
}

fn atomic_write(path: &Path, contents: &[u8], mode: u32) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing parent directory"))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid filename"))?;
    let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let staged = parent.join(format!(".{name}.{}.{sequence}.tmp", std::process::id()));
    let result = (|| {
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&staged)?;
        output.write_all(contents)?;
        output.sync_all()?;
        fs::rename(&staged, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&staged);
    }
    result
}

fn restore_agent(path: &Path, previous: Option<&AgentBackup>) -> io::Result<()> {
    match previous {
        Some(backup) => atomic_write(path, &backup.contents, backup.mode),
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> (PathBuf, AutostartPaths) {
        let root = std::env::temp_dir().join(format!(
            "mihomobox-autostart-{name}-{}-{}",
            std::process::id(),
            TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let paths = AutostartPaths {
            agent: root.join("LaunchAgents").join(LOGIN_AGENT_FILE),
            state: root.join("support").join(DEFAULT_STATE_FILE),
        };
        (root, paths)
    }

    #[test]
    fn login_autostart_waits_for_a_healthy_tunnel() {
        assert!(!should_consider_default(false, Some(true)));
        assert!(!should_consider_default(true, None));
        assert!(!should_consider_default(true, Some(false)));
        assert!(should_consider_default(true, Some(true)));
    }

    #[test]
    fn only_an_installed_app_is_eligible() {
        let home = Path::new("/Users/example");
        assert!(is_installed_app_executable(
            Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app"),
            home
        ));
        assert!(is_installed_app_executable(
            Path::new("/Users/example/Applications/MihomoBox.app/Contents/MacOS/mihomo-app"),
            home
        ));
        assert!(!is_installed_app_executable(
            Path::new("/Volumes/MihomoBox/MihomoBox.app/Contents/MacOS/mihomo-app"),
            home
        ));
        assert!(!is_installed_app_executable(
            Path::new(
                "/private/var/folders/AppTranslocation/MihomoBox.app/Contents/MacOS/mihomo-app"
            ),
            home
        ));
        assert!(!is_installed_app_executable(
            Path::new("/Users/example/project/target/MihomoBox.app/Contents/MacOS/mihomo-app"),
            home
        ));
    }

    #[test]
    fn initial_default_is_private_valid_and_idempotent() {
        let (root, paths) = fixture("initial");
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");

        assert_eq!(
            reconcile_at(&paths, executable).unwrap(),
            ApplyOutcome::Applied
        );
        assert_eq!(
            reconcile_at(&paths, executable).unwrap(),
            ApplyOutcome::AlreadyApplied
        );
        assert!(matches!(
            read_agent_status(&paths.agent).unwrap(),
            AgentStatus::Valid { executable: value } if value == executable.to_str().unwrap()
        ));
        assert_eq!(
            fs::metadata(&paths.agent).unwrap().permissions().mode() & 0o777,
            0o644
        );
        assert_eq!(
            fs::metadata(&paths.state).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_removed_login_item_is_a_user_override() {
        let (root, paths) = fixture("disabled");
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");
        reconcile_at(&paths, executable).unwrap();
        fs::remove_file(&paths.agent).unwrap();

        assert_eq!(
            reconcile_at(&paths, executable).unwrap(),
            ApplyOutcome::UserDisabled
        );
        assert!(!paths.agent.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn moving_an_enabled_app_repairs_the_recorded_target() {
        let (root, paths) = fixture("moved");
        let original = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");
        let moved = Path::new("/Applications/Network/MihomoBox.app/Contents/MacOS/mihomo-app");
        reconcile_at(&paths, original).unwrap();

        assert_eq!(
            reconcile_at(&paths, moved).unwrap(),
            ApplyOutcome::RepairedMovedApp
        );
        assert!(matches!(
            read_agent_status(&paths.agent).unwrap(),
            AgentStatus::Valid { executable } if executable == moved.to_str().unwrap()
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_partial_move_transaction_repairs_its_state_record() {
        let (root, paths) = fixture("partial-move");
        let original = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");
        let moved = Path::new("/Applications/Network/MihomoBox.app/Contents/MacOS/mihomo-app");
        let moved_again =
            Path::new("/Applications/Network/Tools/MihomoBox.app/Contents/MacOS/mihomo-app");
        reconcile_at(&paths, original).unwrap();

        // Simulate termination after the new LaunchAgent was committed but
        // before the state record was updated.
        write_agent(&paths.agent, moved.to_str().unwrap()).unwrap();
        assert_eq!(
            reconcile_at(&paths, moved).unwrap(),
            ApplyOutcome::RepairedMovedApp
        );
        assert_eq!(
            reconcile_at(&paths, moved_again).unwrap(),
            ApplyOutcome::RepairedMovedApp
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn state_failure_rolls_back_a_new_login_item() {
        let (root, mut paths) = fixture("rollback");
        let blocked = root.join("blocked");
        fs::create_dir_all(paths.agent.parent().unwrap()).unwrap();
        fs::write(&blocked, b"not a directory").unwrap();
        paths.state = blocked.join(DEFAULT_STATE_FILE);
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");

        assert!(reconcile_at(&paths, executable).is_err());
        assert!(!paths.agent.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_preexisting_invalid_entry_is_not_overwritten_by_a_default() {
        let (root, paths) = fixture("corrupt");
        fs::create_dir_all(paths.agent.parent().unwrap()).unwrap();
        fs::write(&paths.agent, b"not a plist").unwrap();
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");

        assert_eq!(
            reconcile_at(&paths, executable).unwrap(),
            ApplyOutcome::UserConfigured
        );
        assert_eq!(fs::read(&paths.agent).unwrap(), b"not a plist");
        assert!(!paths.state.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn generated_entry_is_associated_with_the_app_bundle() {
        let (root, paths) = fixture("associated-bundle");
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");
        reconcile_at(&paths, executable).unwrap();

        let agent: LaunchAgent = plist::from_file(&paths.agent).unwrap();
        assert_eq!(
            agent.associated_bundle_identifiers,
            [APP_BUNDLE_IDENTIFIER.to_string()]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_extra_program_key_cannot_override_the_validated_executable() {
        let (root, paths) = fixture("extra-program");
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");
        write_agent(&paths.agent, executable.to_str().unwrap()).unwrap();
        let mut value = plist::Value::from_file(&paths.agent).unwrap();
        value
            .as_dictionary_mut()
            .unwrap()
            .insert("Program".into(), "/usr/bin/false".into());
        value.to_file_xml(&paths.agent).unwrap();

        assert!(matches!(
            read_agent_status(&paths.agent).unwrap(),
            AgentStatus::Invalid
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn restoring_an_existing_entry_preserves_its_mode() {
        let (root, paths) = fixture("restore-mode");
        fs::create_dir_all(paths.agent.parent().unwrap()).unwrap();
        fs::write(&paths.agent, b"original").unwrap();
        fs::set_permissions(&paths.agent, fs::Permissions::from_mode(0o600)).unwrap();
        let metadata = fs::metadata(&paths.agent).unwrap();
        let backup = AgentBackup {
            contents: fs::read(&paths.agent).unwrap(),
            mode: metadata.permissions().mode() & 0o777,
        };
        fs::write(&paths.agent, b"replacement").unwrap();

        restore_agent(&paths.agent, Some(&backup)).unwrap();
        assert_eq!(fs::read(&paths.agent).unwrap(), b"original");
        assert_eq!(
            fs::metadata(&paths.agent).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn plist_serialization_preserves_special_characters_in_the_app_path() {
        let (root, paths) = fixture("escaped-path");
        let executable = Path::new("/Applications/A&B Network.app/Contents/MacOS/mihomo-app");

        reconcile_at(&paths, executable).unwrap();
        assert!(matches!(
            read_agent_status(&paths.agent).unwrap(),
            AgentStatus::Valid { executable: value } if value == executable.to_str().unwrap()
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_user_modified_entry_is_not_overwritten_after_default_application() {
        let (root, paths) = fixture("modified");
        let executable = Path::new("/Applications/MihomoBox.app/Contents/MacOS/mihomo-app");
        reconcile_at(&paths, executable).unwrap();
        fs::write(&paths.agent, b"user-managed contents").unwrap();

        assert!(reconcile_at(&paths, executable).is_err());
        assert_eq!(fs::read(&paths.agent).unwrap(), b"user-managed contents");
        fs::remove_dir_all(root).unwrap();
    }
}
