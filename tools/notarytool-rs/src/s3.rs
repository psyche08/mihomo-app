use crate::api::UploadCredentials;
use anyhow::{bail, Context, Result};
use chrono::Utc;
use hmac::{Hmac, Mac};
use percent_encoding::{utf8_percent_encode, AsciiSet, CONTROLS};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_LENGTH, HOST};
use reqwest::{Client, StatusCode, Url};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Duration;
use tokio_util::io::ReaderStream;

type HmacSha256 = Hmac<Sha256>;
const MAX_S3_ERROR_BODY_BYTES: usize = 64 * 1024;

const S3_PATH_ENCODE_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'!')
    .add(b'"')
    .add(b'#')
    .add(b'$')
    .add(b'%')
    .add(b'&')
    .add(b'\'')
    .add(b'(')
    .add(b')')
    .add(b'*')
    .add(b'+')
    .add(b',')
    .add(b':')
    .add(b';')
    .add(b'<')
    .add(b'=')
    .add(b'>')
    .add(b'?')
    .add(b'@')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

pub struct S3Uploader {
    client: Client,
    region: String,
    accelerate: bool,
}

struct SignedRequest {
    url: Url,
    headers: HeaderMap,
}

impl S3Uploader {
    pub fn new(region: String, accelerate: bool) -> Result<Self> {
        validate_region(&region)?;
        let client = Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(30))
            .timeout(Duration::from_secs(60 * 60))
            .build()?;
        Ok(Self {
            client,
            region,
            accelerate,
        })
    }

    pub async fn upload(
        &self,
        path: &Path,
        size: u64,
        sha256: &str,
        credentials: &UploadCredentials,
    ) -> Result<()> {
        validate_sha256(sha256)?;
        validate_bucket(&credentials.bucket)?;
        if self.accelerate && credentials.bucket.contains('.') {
            bail!("S3 Transfer Acceleration does not support bucket names containing periods");
        }
        if credentials.object.is_empty() {
            bail!("Notary API returned an empty S3 object key");
        }
        if credentials
            .object
            .split('/')
            .any(|segment| matches!(segment, "." | ".."))
        {
            bail!("Notary API returned an unsafe S3 object key");
        }

        let mut region = self.region.clone();
        for attempt in 1_u8..=4 {
            let signed = signed_request(credentials, sha256, &region, self.accelerate)?;
            let file = tokio::fs::File::open(path).await.with_context(|| {
                format!("could not reopen artifact for upload: {}", path.display())
            })?;
            let body = reqwest::Body::wrap_stream(ReaderStream::new(file));
            let response = self
                .client
                .put(signed.url)
                .headers(signed.headers)
                .header(CONTENT_LENGTH, size)
                .body(body)
                .send()
                .await;

            match response {
                Ok(response) if response.status().is_success() => return Ok(()),
                Ok(response) => {
                    let status = response.status();
                    let header_region = response
                        .headers()
                        .get("x-amz-bucket-region")
                        .and_then(|value| value.to_str().ok())
                        .map(ToOwned::to_owned);
                    let body = response.bytes().await.unwrap_or_default();
                    let bounded_body = &body[..body.len().min(MAX_S3_ERROR_BODY_BYTES)];
                    let error_code = safe_xml_value(bounded_body, "Code");
                    let body_region = safe_xml_value(bounded_body, "Region");
                    let next_region = header_region.or(body_region);
                    if let Some(next_region) = next_region.filter(|value| *value != region) {
                        validate_region(&next_region)?;
                        region = next_region;
                        continue;
                    }
                    if retryable_status(status) && attempt < 4 {
                        tokio::time::sleep(Duration::from_secs(u64::from(attempt) * 2)).await;
                        continue;
                    }
                    // S3 error bodies can echo canonical signed headers, including
                    // the temporary session token. Only an allowlisted short error
                    // code is retained; never include the body here.
                    if let Some(code) = error_code {
                        bail!("S3 upload failed with HTTP {status} code={code}");
                    }
                    bail!("S3 upload failed with HTTP {status} code=unknown");
                }
                Err(error) if attempt < 4 && (error.is_connect() || error.is_timeout()) => {
                    tokio::time::sleep(Duration::from_secs(u64::from(attempt) * 2)).await;
                }
                Err(error) => return Err(error).context("S3 upload failed"),
            }
        }
        bail!("S3 upload retry limit reached")
    }
}

fn signed_request(
    credentials: &UploadCredentials,
    payload_sha256: &str,
    region: &str,
    accelerate: bool,
) -> Result<SignedRequest> {
    let host = if accelerate {
        format!("{}.s3-accelerate.amazonaws.com", credentials.bucket)
    } else {
        format!("{}.s3.{region}.amazonaws.com", credentials.bucket)
    };
    let encoded_object = credentials
        .object
        .split('/')
        .map(|segment| utf8_percent_encode(segment, S3_PATH_ENCODE_SET).to_string())
        .collect::<Vec<_>>()
        .join("/");
    let canonical_uri = format!("/{encoded_object}");
    let url = Url::parse(&format!("https://{host}{canonical_uri}"))?;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let short_date = now.format("%Y%m%d").to_string();
    let canonical_headers = format!(
        "host:{host}\nx-amz-content-sha256:{payload_sha256}\nx-amz-date:{amz_date}\nx-amz-security-token:{}\n",
        credentials.aws_session_token
    );
    let signed_headers = "host;x-amz-content-sha256;x-amz-date;x-amz-security-token";
    let canonical_request =
        format!("PUT\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_sha256}");
    let scope = format!("{short_date}/{region}/s3/aws4_request");
    let canonical_hash = hex::encode(Sha256::digest(canonical_request.as_bytes()));
    let string_to_sign = format!("AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{canonical_hash}");
    let signature = signature(
        &credentials.aws_secret_access_key,
        &short_date,
        region,
        string_to_sign.as_bytes(),
    )?;
    let authorization = format!(
        "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
        credentials.aws_access_key_id
    );

    let mut headers = HeaderMap::new();
    headers.insert(HOST, HeaderValue::from_str(&host)?);
    headers.insert(
        "x-amz-content-sha256",
        HeaderValue::from_str(payload_sha256)?,
    );
    headers.insert("x-amz-date", HeaderValue::from_str(&amz_date)?);
    headers.insert(
        "x-amz-security-token",
        HeaderValue::from_str(&credentials.aws_session_token)?,
    );
    headers.insert(AUTHORIZATION, HeaderValue::from_str(&authorization)?);
    Ok(SignedRequest { url, headers })
}

fn signature(secret: &str, date: &str, region: &str, input: &[u8]) -> Result<String> {
    let date_key = hmac(format!("AWS4{secret}").as_bytes(), date.as_bytes())?;
    let region_key = hmac(&date_key, region.as_bytes())?;
    let service_key = hmac(&region_key, b"s3")?;
    let signing_key = hmac(&service_key, b"aws4_request")?;
    Ok(hex::encode(hmac(&signing_key, input)?))
}

fn hmac(key: &[u8], input: &[u8]) -> Result<Vec<u8>> {
    let mut mac = HmacSha256::new_from_slice(key).context("invalid HMAC key")?;
    mac.update(input);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn validate_sha256(value: &str) -> Result<()> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("artifact SHA-256 must contain exactly 64 hexadecimal digits");
    }
    Ok(())
}

fn validate_bucket(value: &str) -> Result<()> {
    if !(3..=63).contains(&value.len())
        || !value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'-')
        })
        || value.starts_with('.')
        || value.starts_with('-')
        || value.ends_with('.')
        || value.ends_with('-')
    {
        bail!("Notary API returned an invalid S3 bucket name");
    }
    Ok(())
}

fn validate_region(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        bail!("S3 region is invalid");
    }
    Ok(())
}

fn retryable_status(status: StatusCode) -> bool {
    status == StatusCode::REQUEST_TIMEOUT
        || status == StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
}

fn safe_xml_value(bytes: &[u8], tag: &str) -> Option<String> {
    if !matches!(tag, "Code" | "Region") {
        return None;
    }
    let body = std::str::from_utf8(bytes).ok()?;
    let opening = format!("<{tag}>");
    let closing = format!("</{tag}>");
    let start = body.find(&opening)? + opening.len();
    let end = body[start..].find(&closing)? + start;
    let value = &body[start..end];
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return None;
    }
    Some(value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::{safe_xml_value, signature, validate_bucket, validate_region, validate_sha256};

    #[test]
    fn validates_untrusted_s3_coordinates() {
        assert!(validate_bucket("apple-notary-bucket-1").is_ok());
        assert!(validate_bucket("UPPERCASE").is_err());
        assert!(validate_region("us-west-2").is_ok());
        assert!(validate_region("../bad").is_err());
        assert!(validate_sha256(&"a".repeat(64)).is_ok());
        assert!(validate_sha256("abc").is_err());
    }

    #[test]
    fn matches_aws_sigv4_published_put_example() {
        let value = signature(
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "20130524",
            "us-east-1",
            b"AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d",
        )
        .expect("signature");
        assert_eq!(
            value,
            "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        );
    }

    #[test]
    fn extracts_only_allowlisted_s3_error_fields() {
        let body = br#"<Error><Code>AuthorizationHeaderMalformed</Code><Region>us-west-2</Region><CanonicalRequest>secret-token</CanonicalRequest></Error>"#;
        assert_eq!(
            safe_xml_value(body, "Code").as_deref(),
            Some("AuthorizationHeaderMalformed")
        );
        assert_eq!(safe_xml_value(body, "Region").as_deref(), Some("us-west-2"));
        assert!(safe_xml_value(body, "CanonicalRequest").is_none());
    }
}
