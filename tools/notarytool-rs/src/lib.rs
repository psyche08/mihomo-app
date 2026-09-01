#![forbid(unsafe_code)]

pub mod api;
pub mod auth;
pub mod s3;
pub mod state;

use anyhow::{bail, Result};
use sha2::{Digest, Sha256};
use std::path::Path;
use tokio::io::AsyncReadExt;

pub const DEFAULT_API_BASE_URL: &str = "https://appstoreconnect.apple.com/notary/v2";

pub async fn sha256_file(path: &Path) -> Result<(String, u64)> {
    let mut file = tokio::fs::File::open(path).await?;
    let metadata = file.metadata().await?;
    if !metadata.is_file() {
        bail!(
            "submission artifact must be a regular file: {}",
            path.display()
        );
    }

    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok((hex::encode(digest.finalize()), metadata.len()))
}

pub fn is_terminal_status(status: &str) -> bool {
    matches!(
        status.to_ascii_lowercase().as_str(),
        "accepted" | "invalid" | "rejected"
    )
}

pub fn is_success_status(status: &str) -> bool {
    status.eq_ignore_ascii_case("accepted")
}

#[cfg(test)]
mod tests {
    use super::{is_success_status, is_terminal_status};

    #[test]
    fn recognizes_terminal_statuses_case_insensitively() {
        assert!(is_terminal_status("Accepted"));
        assert!(is_terminal_status("Invalid"));
        assert!(is_terminal_status("REJECTED"));
        assert!(!is_terminal_status("In Progress"));
        assert!(is_success_status("accepted"));
    }
}
