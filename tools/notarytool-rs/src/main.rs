#![forbid(unsafe_code)]

use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand, ValueEnum};
use notarytool_rs::api::{NewSubmissionRequest, NotaryApi, Notification, SubmissionData};
use notarytool_rs::auth::{Principal, TokenProvider};
use notarytool_rs::s3::S3Uploader;
use notarytool_rs::state::{default_state_path, SubmissionState};
use notarytool_rs::{is_success_status, is_terminal_status, sha256_file, DEFAULT_API_BASE_URL};
use serde::Serialize;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::time::Instant;
use uuid::Uuid;

#[derive(Parser)]
#[command(
    name = "notarytool-rs",
    version,
    about = "Cross-platform Apple Notary API client"
)]
struct Cli {
    #[arg(long, env = "APPLE_NOTARY_KEY_ID")]
    key_id: String,

    #[arg(long, env = "APPLE_NOTARY_PRIVATE_KEY")]
    private_key: PathBuf,

    #[arg(long, env = "APPLE_NOTARY_ISSUER_ID")]
    issuer_id: Option<String>,

    #[arg(long, env = "APPLE_NOTARY_INDIVIDUAL_KEY")]
    individual_key: bool,

    #[arg(long, value_enum, default_value_t = OutputFormat::Normal)]
    output_format: OutputFormat,

    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Copy, ValueEnum)]
enum OutputFormat {
    Normal,
    Json,
}

#[derive(Subcommand)]
enum Command {
    /// Create a submission, upload the artifact, and optionally wait.
    Submit(SubmitArgs),
    /// Fetch one submission.
    Info { submission_id: Uuid },
    /// Wait for a submission to reach a terminal state.
    Wait(WaitArgs),
    /// List the team's 100 most recent submissions.
    History,
    /// Download the JSON developer log for a completed submission.
    Log(LogArgs),
    /// Resume status polling from a durable state file without resubmitting.
    Resume(ResumeArgs),
}

#[derive(Args)]
struct SubmitArgs {
    artifact: PathBuf,

    #[arg(long)]
    name: Option<String>,

    #[arg(long)]
    webhook: Option<String>,

    #[arg(long)]
    state: Option<PathBuf>,

    #[arg(long)]
    wait: bool,

    #[command(flatten)]
    polling: PollingArgs,

    #[arg(long, env = "APPLE_NOTARY_S3_REGION", default_value = "us-east-1")]
    s3_region: String,

    #[arg(long)]
    no_s3_acceleration: bool,
}

#[derive(Clone, Args)]
struct PollingArgs {
    #[arg(long, value_parser = parse_duration, default_value = "30m")]
    timeout: Duration,

    #[arg(long, value_parser = parse_duration, default_value = "15s")]
    poll_interval: Duration,
}

#[derive(Args)]
struct WaitArgs {
    submission_id: Uuid,

    #[command(flatten)]
    polling: PollingArgs,
}

#[derive(Args)]
struct LogArgs {
    submission_id: Uuid,

    #[arg(long)]
    output: Option<PathBuf>,
}

#[derive(Args)]
struct ResumeArgs {
    #[arg(long)]
    state: PathBuf,

    #[command(flatten)]
    polling: PollingArgs,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SubmitOutput {
    id: Uuid,
    name: String,
    sha256: String,
    size: u64,
    uploaded: bool,
    status: String,
    state_file: PathBuf,
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("error: {error:#}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();
    let principal = principal(&cli)?;
    let token_provider = TokenProvider::from_file(cli.key_id, cli.private_key, principal)?;
    let api = NotaryApi::new(DEFAULT_API_BASE_URL, token_provider)?;

    match cli.command {
        Command::Submit(args) => submit(&api, args, cli.output_format).await,
        Command::Info { submission_id } => {
            let response = api.info(submission_id).await?;
            print_submission(&response.data, cli.output_format)
        }
        Command::Wait(args) => {
            let submission =
                wait_for_terminal(&api, args.submission_id, &args.polling, None).await?;
            print_submission(&submission, cli.output_format)?;
            require_accepted(&submission)
        }
        Command::History => {
            let response = api.history().await?;
            print_history(&response.data, cli.output_format)
        }
        Command::Log(args) => download_log(&api, args).await,
        Command::Resume(args) => resume(&api, args, cli.output_format).await,
    }
}

fn principal(cli: &Cli) -> Result<Principal> {
    match (&cli.issuer_id, cli.individual_key) {
        (Some(issuer_id), false) => {
            Uuid::parse_str(issuer_id).context("issuer ID must be a UUID")?;
            Ok(Principal::Team {
                issuer_id: issuer_id.clone(),
            })
        }
        (None, true) => Ok(Principal::Individual),
        (Some(_), true) => bail!("--issuer-id and --individual-key are mutually exclusive"),
        (None, false) => bail!("provide --issuer-id for a team key or --individual-key"),
    }
}

async fn submit(api: &NotaryApi, args: SubmitArgs, format: OutputFormat) -> Result<()> {
    let artifact = canonical_regular_file(&args.artifact)?;
    let name = args.name.unwrap_or_else(|| {
        artifact.file_name().map_or_else(
            || "submission".to_owned(),
            |value| value.to_string_lossy().into_owned(),
        )
    });
    if name.trim().is_empty() || name.contains(['\r', '\n']) {
        bail!("submission name must be nonempty and single-line");
    }
    let state_path = args.state.unwrap_or_else(|| default_state_path(&artifact));
    if state_path.exists() {
        bail!(
            "state file already exists; inspect or resume it instead of creating a duplicate: {}",
            state_path.display()
        );
    }

    let (sha256, size) = sha256_file(&artifact).await?;
    let notifications = args.webhook.map_or_else(Vec::new, |target| {
        vec![Notification {
            channel: "webhook",
            target,
        }]
    });
    if let Some(notification) = notifications.first() {
        let webhook = reqwest::Url::parse(&notification.target).context("invalid webhook URL")?;
        if webhook.scheme() != "https" {
            bail!("webhook URL must use HTTPS");
        }
    }
    let response = api
        .submit(&NewSubmissionRequest {
            submission_name: name.clone(),
            sha256: sha256.clone(),
            notifications,
        })
        .await?;

    let mut state = SubmissionState::new(response.data.id, name.clone(), sha256.clone(), size);
    eprintln!("submission_id={}", response.data.id);
    io::stderr().flush()?;
    state.write_new(&state_path).with_context(|| {
        format!(
            "Apple created submission {}, but its recovery state could not be persisted",
            response.data.id
        )
    })?;
    eprintln!(
        "submission_id={} state={}",
        response.data.id,
        state_path.display()
    );
    io::stderr().flush()?;

    let uploader = S3Uploader::new(args.s3_region, !args.no_s3_acceleration)?;
    uploader
        .upload(&artifact, size, &sha256, &response.data.attributes)
        .await?;
    state.mark_uploaded();
    state.replace(&state_path)?;
    eprintln!("upload=complete submission_id={}", response.data.id);

    let final_status = if args.wait {
        let submission = wait_for_terminal(
            api,
            response.data.id,
            &args.polling,
            Some((&mut state, &state_path)),
        )
        .await?;
        require_accepted(&submission)?;
        submission.attributes.status
    } else {
        state.status.clone()
    };
    print_submit(
        &SubmitOutput {
            id: response.data.id,
            name,
            sha256,
            size,
            uploaded: true,
            status: final_status,
            state_file: state_path,
        },
        format,
    )
}

async fn resume(api: &NotaryApi, args: ResumeArgs, format: OutputFormat) -> Result<()> {
    let mut state = SubmissionState::load(&args.state)?;
    if !state.upload_complete {
        let current = api.info(state.submission_id).await?;
        if current
            .data
            .attributes
            .status
            .eq_ignore_ascii_case("created")
        {
            bail!(
                "submission upload was not confirmed and temporary S3 credentials are not persisted; create a new submission only after reconciliation"
            );
        }
    }
    let submission = wait_for_terminal(
        api,
        state.submission_id,
        &args.polling,
        Some((&mut state, &args.state)),
    )
    .await?;
    print_submission(&submission, format)?;
    require_accepted(&submission)
}

async fn wait_for_terminal(
    api: &NotaryApi,
    id: Uuid,
    polling: &PollingArgs,
    mut state: Option<(&mut SubmissionState, &Path)>,
) -> Result<SubmissionData> {
    if polling.poll_interval < Duration::from_secs(2) {
        bail!("poll interval must be at least 2 seconds");
    }
    let deadline = Instant::now()
        .checked_add(polling.timeout)
        .context("timeout is too large")?;
    let mut last_status = String::new();
    loop {
        let response = api.info(id).await?;
        let status = response.data.attributes.status.clone();
        if status != last_status {
            eprintln!("status={status} submission_id={id}");
            last_status.clone_from(&status);
        }
        if let Some((value, path)) = state.as_mut() {
            value.update_status(&status);
            value.replace(path)?;
        }
        if is_terminal_status(&status) {
            return Ok(response.data);
        }
        if Instant::now() >= deadline {
            bail!("timed out waiting for submission {id}; Apple continues processing it");
        }
        tokio::time::sleep(polling.poll_interval).await;
    }
}

async fn download_log(api: &NotaryApi, args: LogArgs) -> Result<()> {
    let response = api.log_url(args.submission_id).await?;
    let bytes = api
        .download_log(&response.data.attributes.developer_log_url)
        .await?;
    if let Some(path) = args.output {
        write_new_file(&path, &bytes)?;
        println!("{}", path.display());
    } else {
        io::stdout().write_all(&bytes)?;
        if !bytes.ends_with(b"\n") {
            println!();
        }
    }
    Ok(())
}

fn canonical_regular_file(path: &Path) -> Result<PathBuf> {
    let metadata = std::fs::symlink_metadata(path)
        .with_context(|| format!("could not inspect artifact: {}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!(
            "artifact must be a regular, non-symlink file: {}",
            path.display()
        );
    }
    path.canonicalize()
        .context("could not resolve artifact path")
}

fn write_new_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .with_context(|| format!("refusing to replace log output: {}", path.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn require_accepted(submission: &SubmissionData) -> Result<()> {
    if !is_success_status(&submission.attributes.status) {
        bail!(
            "submission {} finished with status {}; fetch its developer log",
            submission.id,
            submission.attributes.status
        );
    }
    Ok(())
}

fn print_submission(value: &SubmissionData, format: OutputFormat) -> Result<()> {
    match format {
        OutputFormat::Json => println!("{}", serde_json::to_string_pretty(value)?),
        OutputFormat::Normal => {
            println!("id: {}", value.id);
            println!("name: {}", value.attributes.name);
            println!("createdDate: {}", value.attributes.created_date);
            println!("status: {}", value.attributes.status);
        }
    }
    Ok(())
}

fn print_history(values: &[SubmissionData], format: OutputFormat) -> Result<()> {
    match format {
        OutputFormat::Json => println!("{}", serde_json::to_string_pretty(values)?),
        OutputFormat::Normal => {
            for value in values {
                println!(
                    "{}\t{}\t{}\t{}",
                    value.id,
                    value.attributes.status,
                    value.attributes.created_date,
                    value.attributes.name
                );
            }
        }
    }
    Ok(())
}

fn print_submit(value: &SubmitOutput, format: OutputFormat) -> Result<()> {
    match format {
        OutputFormat::Json => println!("{}", serde_json::to_string_pretty(value)?),
        OutputFormat::Normal => {
            println!("id: {}", value.id);
            println!("name: {}", value.name);
            println!("sha256: {}", value.sha256);
            println!("size: {}", value.size);
            println!("uploaded: {}", value.uploaded);
            println!("status: {}", value.status);
            println!("stateFile: {}", value.state_file.display());
        }
    }
    Ok(())
}

fn parse_duration(value: &str) -> std::result::Result<Duration, String> {
    let (digits, multiplier) = match value.as_bytes().last().copied() {
        Some(b's') => (&value[..value.len() - 1], 1_u64),
        Some(b'm') => (&value[..value.len() - 1], 60_u64),
        Some(b'h') => (&value[..value.len() - 1], 60_u64 * 60),
        Some(byte) if byte.is_ascii_digit() => (value, 1_u64),
        _ => return Err("duration must be an integer followed by s, m, or h".to_owned()),
    };
    let amount = digits
        .parse::<u64>()
        .map_err(|_| "duration must contain a positive integer".to_owned())?;
    let seconds = amount
        .checked_mul(multiplier)
        .ok_or_else(|| "duration is too large".to_owned())?;
    if seconds == 0 {
        return Err("duration must be greater than zero".to_owned());
    }
    Ok(Duration::from_secs(seconds))
}

#[cfg(test)]
mod tests {
    use super::{parse_duration, Cli, Command};
    use clap::Parser;
    use std::time::Duration;

    #[test]
    fn parses_cli_durations() {
        assert_eq!(
            parse_duration("30").expect("seconds"),
            Duration::from_secs(30)
        );
        assert_eq!(
            parse_duration("2m").expect("minutes"),
            Duration::from_secs(120)
        );
        assert_eq!(
            parse_duration("1h").expect("hours"),
            Duration::from_secs(3600)
        );
        assert!(parse_duration("0s").is_err());
        assert!(parse_duration("1d").is_err());
    }

    #[test]
    fn accepts_root_authentication_arguments_once() {
        let cli = Cli::try_parse_from([
            "notarytool-rs",
            "--key-id",
            "SDXB7C5K2W",
            "--private-key",
            "/private/key.p8",
            "--issuer-id",
            "69a6de86-bb09-47e3-e053-5b8c7c11a4d1",
            "history",
        ])
        .expect("CLI arguments");
        assert!(matches!(cli.command, Command::History));
    }
}
