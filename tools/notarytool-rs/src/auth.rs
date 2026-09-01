use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::Utc;
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use p256::pkcs8::DecodePrivateKey;
use serde::Serialize;
use std::path::{Path, PathBuf};
use zeroize::Zeroize;

const TOKEN_LIFETIME_SECONDS: i64 = 10 * 60;

#[derive(Clone)]
pub enum Principal {
    Team { issuer_id: String },
    Individual,
}

#[derive(Clone)]
pub struct TokenProvider {
    key_id: String,
    signing_key: SigningKey,
    principal: Principal,
}

#[derive(Serialize)]
struct Header<'a> {
    alg: &'static str,
    kid: &'a str,
    typ: &'static str,
}

#[derive(Serialize)]
struct Claims<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    iss: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sub: Option<&'static str>,
    iat: i64,
    exp: i64,
    aud: &'static str,
}

impl TokenProvider {
    pub fn from_file(key_id: String, path: PathBuf, principal: Principal) -> Result<Self> {
        validate_key_id(&key_id)?;
        validate_key_file(&path)?;

        let mut pem = std::fs::read_to_string(&path)
            .with_context(|| format!("could not read API private key: {}", path.display()))?;
        let result = SigningKey::from_pkcs8_pem(&pem)
            .context("API private key is not a valid P-256 PKCS#8 PEM file");
        pem.zeroize();

        Ok(Self {
            key_id,
            signing_key: result?,
            principal,
        })
    }

    pub fn token(&self) -> Result<String> {
        self.token_at(Utc::now().timestamp())
    }

    fn token_at(&self, now: i64) -> Result<String> {
        let (issuer, subject) = match &self.principal {
            Principal::Team { issuer_id } => (Some(issuer_id.as_str()), None),
            Principal::Individual => (None, Some("user")),
        };
        let header = Header {
            alg: "ES256",
            kid: &self.key_id,
            typ: "JWT",
        };
        let claims = Claims {
            iss: issuer,
            sub: subject,
            iat: now,
            exp: now + TOKEN_LIFETIME_SECONDS,
            aud: "appstoreconnect-v1",
        };
        let header = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header)?);
        let claims = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims)?);
        let signing_input = format!("{header}.{claims}");
        let signature: Signature = self.signing_key.sign(signing_input.as_bytes());
        let signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
        Ok(format!("{signing_input}.{signature}"))
    }
}

fn validate_key_id(value: &str) -> Result<()> {
    if !(10..=64).contains(&value.len()) || !value.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        bail!("API key ID must contain 10 to 64 ASCII letters or digits");
    }
    Ok(())
}

fn validate_key_file(path: &Path) -> Result<()> {
    let metadata = std::fs::symlink_metadata(path)
        .with_context(|| format!("could not inspect API private key: {}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!(
            "API private key must be a regular, non-symlink file: {}",
            path.display()
        );
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            bail!("API private key permissions must not grant group or other access (use 0600 or 0400)");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Principal, TokenProvider};
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    use p256::ecdsa::SigningKey;
    use serde_json::Value;

    fn provider(principal: Principal) -> TokenProvider {
        TokenProvider {
            key_id: "ABCDEFGHIJ".to_owned(),
            signing_key: SigningKey::from_slice(&[7_u8; 32]).expect("test key"),
            principal,
        }
    }

    fn payload(token: &str) -> Value {
        let encoded = token.split('.').nth(1).expect("payload");
        let bytes = URL_SAFE_NO_PAD.decode(encoded).expect("base64url");
        serde_json::from_slice(&bytes).expect("json")
    }

    #[test]
    fn team_token_uses_issuer_and_ten_minute_lifetime() {
        let token = provider(Principal::Team {
            issuer_id: "00000000-0000-0000-0000-000000000000".to_owned(),
        })
        .token_at(1000)
        .expect("token");
        let claims = payload(&token);
        assert_eq!(claims["iss"], "00000000-0000-0000-0000-000000000000");
        assert!(claims.get("sub").is_none());
        assert_eq!(claims["iat"], 1000);
        assert_eq!(claims["exp"], 1600);
        assert_eq!(claims["aud"], "appstoreconnect-v1");
    }

    #[test]
    fn individual_token_uses_user_subject() {
        let token = provider(Principal::Individual)
            .token_at(1000)
            .expect("token");
        let claims = payload(&token);
        assert_eq!(claims["sub"], "user");
        assert!(claims.get("iss").is_none());
    }
}
