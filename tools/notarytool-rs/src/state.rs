use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use uuid::Uuid;

const STATE_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmissionState {
    pub schema_version: u32,
    pub submission_id: Uuid,
    pub submission_name: String,
    pub artifact_sha256: String,
    pub artifact_size: u64,
    pub upload_complete: bool,
    pub status: String,
    pub updated_at: String,
}

impl SubmissionState {
    pub fn new(
        submission_id: Uuid,
        submission_name: String,
        artifact_sha256: String,
        artifact_size: u64,
    ) -> Self {
        Self {
            schema_version: STATE_SCHEMA_VERSION,
            submission_id,
            submission_name,
            artifact_sha256,
            artifact_size,
            upload_complete: false,
            status: "created".to_owned(),
            updated_at: Utc::now().to_rfc3339(),
        }
    }

    pub fn mark_uploaded(&mut self) {
        self.upload_complete = true;
        self.status = "uploaded".to_owned();
        self.updated_at = Utc::now().to_rfc3339();
    }

    pub fn update_status(&mut self, status: &str) {
        self.status = status.to_owned();
        self.updated_at = Utc::now().to_rfc3339();
    }

    pub fn load(path: &Path) -> Result<Self> {
        let metadata = std::fs::symlink_metadata(path)
            .with_context(|| format!("could not inspect state file: {}", path.display()))?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            bail!(
                "state path must be a regular, non-symlink file: {}",
                path.display()
            );
        }
        let bytes = std::fs::read(path)?;
        let mut value = None;
        for line in bytes
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
        {
            match serde_json::from_slice::<Self>(line) {
                Ok(record) => value = Some(record),
                Err(error)
                    if !bytes.ends_with(b"\n")
                        && line
                            == bytes
                                .rsplit(|byte| *byte == b'\n')
                                .next()
                                .unwrap_or_default() =>
                {
                    // A process can stop in the middle of the final append. The
                    // preceding fsync-complete record remains authoritative.
                    let _ = error;
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("invalid state record in {}", path.display()));
                }
            }
        }
        let value = value
            .with_context(|| format!("state file has no complete record: {}", path.display()))?;
        if value.schema_version != STATE_SCHEMA_VERSION {
            bail!("unsupported state schema version: {}", value.schema_version);
        }
        Ok(value)
    }

    pub fn write_new(&self, path: &Path) -> Result<()> {
        if path.exists() {
            bail!(
                "state file already exists; refusing a duplicate submission: {}",
                path.display()
            );
        }
        append_record(self, path, true)
    }

    pub fn replace(&self, path: &Path) -> Result<()> {
        if !path.exists() {
            bail!("state file disappeared: {}", path.display());
        }
        append_record(self, path, false)
    }
}

pub fn default_state_path(artifact: &Path) -> PathBuf {
    let mut value = artifact.as_os_str().to_os_string();
    value.push(".notary.json");
    PathBuf::from(value)
}

fn append_record(value: &SubmissionState, path: &Path, create_new: bool) -> Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    if !create_new {
        let metadata = std::fs::symlink_metadata(path)
            .with_context(|| format!("could not inspect state file: {}", path.display()))?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            bail!(
                "state path must remain a regular, non-symlink file: {}",
                path.display()
            );
        }
    }
    let mut options = std::fs::OpenOptions::new();
    options
        .write(true)
        .append(!create_new)
        .create_new(create_new);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    let mut record = serde_json::to_vec(value)?;
    record.push(b'\n');
    file.write_all(&record)?;
    file.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::SubmissionState;
    use uuid::Uuid;

    #[test]
    fn loads_last_complete_journal_record_after_partial_append() {
        let path = std::env::temp_dir().join(format!("notarytool-rs-{}.json", Uuid::new_v4()));
        let mut state =
            SubmissionState::new(Uuid::new_v4(), "Example.zip".to_owned(), "a".repeat(64), 42);
        state.write_new(&path).expect("initial state");
        state.mark_uploaded();
        state.replace(&path).expect("uploaded state");
        {
            use std::io::Write as _;
            let mut file = std::fs::OpenOptions::new()
                .append(true)
                .open(&path)
                .expect("append state");
            file.write_all(b"{\"partial\":").expect("partial record");
        }
        let recovered = SubmissionState::load(&path).expect("recovered state");
        assert!(recovered.upload_complete);
        assert_eq!(recovered.status, "uploaded");
        std::fs::remove_file(path).expect("remove test state");
    }
}
