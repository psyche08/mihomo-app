use crate::auth::TokenProvider;
use anyhow::{bail, Context, Result};
use reqwest::{Client, Method, StatusCode, Url};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

const MAX_ERROR_BODY_BYTES: usize = 64 * 1024;
const MAX_API_BODY_BYTES: usize = 2 * 1024 * 1024;
const MAX_LOG_BODY_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone)]
pub struct NotaryApi {
    base_url: Url,
    client: Client,
    token_provider: Arc<TokenProvider>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NewSubmissionRequest {
    pub submission_name: String,
    pub sha256: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notifications: Vec<Notification>,
}

#[derive(Debug, Serialize)]
pub struct Notification {
    pub channel: &'static str,
    pub target: String,
}

#[derive(Debug, Deserialize)]
pub struct NewSubmissionResponse {
    pub data: NewSubmissionData,
}

#[derive(Debug, Deserialize)]
pub struct NewSubmissionData {
    pub id: Uuid,
    pub attributes: UploadCredentials,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadCredentials {
    pub aws_access_key_id: String,
    pub aws_secret_access_key: String,
    pub aws_session_token: String,
    pub bucket: String,
    pub object: String,
}

impl Drop for UploadCredentials {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.aws_access_key_id.zeroize();
        self.aws_secret_access_key.zeroize();
        self.aws_session_token.zeroize();
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SubmissionData {
    pub id: Uuid,
    pub attributes: SubmissionAttributes,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmissionAttributes {
    pub created_date: String,
    pub name: String,
    pub status: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct SubmissionResponse {
    pub data: SubmissionData,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct SubmissionListResponse {
    pub data: Vec<SubmissionData>,
}

#[derive(Debug, Deserialize)]
pub struct SubmissionLogResponse {
    pub data: SubmissionLogData,
}

#[derive(Debug, Deserialize)]
pub struct SubmissionLogData {
    pub id: Uuid,
    pub attributes: SubmissionLogAttributes,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmissionLogAttributes {
    pub developer_log_url: String,
}

impl NotaryApi {
    pub fn new(base_url: &str, token_provider: TokenProvider) -> Result<Self> {
        let mut base_url = Url::parse(base_url).context("invalid Notary API base URL")?;
        if base_url.scheme() != "https" {
            bail!("Notary API base URL must use HTTPS");
        }
        if base_url.query().is_some() || base_url.fragment().is_some() {
            bail!("Notary API base URL must not contain a query or fragment");
        }
        if !base_url.path().ends_with('/') {
            base_url.set_path(&format!("{}/", base_url.path()));
        }
        let client = Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("notarytool-rs/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self {
            base_url,
            client,
            token_provider: Arc::new(token_provider),
        })
    }

    pub async fn submit(&self, request: &NewSubmissionRequest) -> Result<NewSubmissionResponse> {
        self.send_json(Method::POST, "submissions", Some(request))
            .await
    }

    pub async fn info(&self, id: Uuid) -> Result<SubmissionResponse> {
        self.send_json::<(), _>(Method::GET, &format!("submissions/{id}"), None)
            .await
    }

    pub async fn history(&self) -> Result<SubmissionListResponse> {
        self.send_json::<(), _>(Method::GET, "submissions", None)
            .await
    }

    pub async fn log_url(&self, id: Uuid) -> Result<SubmissionLogResponse> {
        self.send_json::<(), _>(Method::GET, &format!("submissions/{id}/logs"), None)
            .await
    }

    pub async fn download_log(&self, url: &str) -> Result<Vec<u8>> {
        let url = Url::parse(url).context("Notary API returned an invalid log URL")?;
        if url.scheme() != "https" {
            bail!("Notary API log URL must use HTTPS");
        }
        let response = self
            .client
            .get(url)
            .send()
            .await
            .context("log download failed")?;
        let status = response.status();
        let bytes = read_limited(response, MAX_LOG_BODY_BYTES, "developer log").await?;
        if !status.is_success() {
            bail!(
                "log download failed with HTTP {status}: {}",
                bounded_text(&bytes)
            );
        }
        Ok(bytes.to_vec())
    }

    async fn send_json<B, R>(&self, method: Method, path: &str, body: Option<&B>) -> Result<R>
    where
        B: Serialize + ?Sized,
        R: DeserializeOwned,
    {
        let url = self
            .base_url
            .join(path)
            .context("invalid Notary API request path")?;
        let token = self.token_provider.token()?;
        let mut request = self.client.request(method, url).bearer_auth(token);
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().await.context("Notary API request failed")?;
        let status = response.status();
        let request_id = response
            .headers()
            .get("x-request-id")
            .and_then(|value| value.to_str().ok())
            .map(ToOwned::to_owned);
        let bytes = read_limited(response, MAX_API_BODY_BYTES, "Notary API response").await?;
        if !status.is_success() {
            return Err(api_error(status, request_id.as_deref(), &bytes));
        }
        serde_json::from_slice(&bytes).context("Notary API returned malformed JSON")
    }
}

fn api_error(status: StatusCode, request_id: Option<&str>, bytes: &[u8]) -> anyhow::Error {
    let suffix = request_id.map_or_else(String::new, |id| format!(" request_id={id}"));
    anyhow::anyhow!("Notary API HTTP {status}{suffix}: {}", bounded_text(bytes))
}

fn bounded_text(bytes: &[u8]) -> String {
    let bounded = &bytes[..bytes.len().min(MAX_ERROR_BODY_BYTES)];
    String::from_utf8_lossy(bounded).replace(['\r', '\n'], " ")
}

async fn read_limited(
    mut response: reqwest::Response,
    maximum: usize,
    description: &str,
) -> Result<Vec<u8>> {
    if response
        .content_length()
        .is_some_and(|length| length > maximum as u64)
    {
        bail!("{description} exceeds the {maximum}-byte safety limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .with_context(|| format!("could not read {description}"))?
    {
        if bytes.len().saturating_add(chunk.len()) > maximum {
            bail!("{description} exceeds the {maximum}-byte safety limit");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
