//! Bitwarden / Vaultwarden REST client — Phase B.5.
//!
//! Implements the subset of the Bitwarden Mobile/CLI auth + sync protocol
//! needed to mirror passkey ciphers into the broker.
//!
//! Flow:
//!   1. `POST /identity/accounts/prelogin` -> KDF parameters.
//!   2. Derive `master_key` (PBKDF2-SHA256 or Argon2id).
//!   3. Derive `master_password_hash` = PBKDF2(master_key, master_password, 1).
//!   4. `POST /identity/connect/token` (password grant) -> bearer token + Key.
//!   5. HKDF-Expand `master_key` -> 64-byte stretched key (enc||mac).
//!   6. Decrypt `Key` (CipherString type 2 / AES-256-CBC + HMAC-SHA256) -> 64-byte user_key.
//!   7. `GET /api/sync` -> walk ciphers, filter logins with `fido2Credentials`.
//!   8. For each cipher: optionally decrypt the per-cipher `key` field
//!      (CipherString type 4 — AES-256-CBC + HMAC, key wrapped with user_key)
//!      then decrypt every passkey field with the resulting per-cipher (or
//!      user) key.
//!
//! NOTE on the per-cipher key step:
//!   In recent Bitwarden data models, ciphers can carry an optional `key`
//!   field which is itself an EncString containing a fresh 64-byte
//!   AES+HMAC key wrapped under the user_key. When present, ALL of that
//!   cipher's other EncStrings (`name`, `notes`, `login.uri`, fido2
//!   credential fields, ...) are encrypted under the unwrapped per-cipher
//!   key, NOT the user_key. When absent, the user_key is used directly.
//!   Bitwarden's official docs are sparse on this — the implementation
//!   here mirrors what `rbw` and the Bitwarden mobile clients do.
//!
//! Master-password sourcing:
//!   - This module only takes `SecretString` from the caller.
//!   - For PoC, `main` reads `FVB_MASTER_PASSWORD` env var.
//!   - Phase B.6 will source it from the TPM-unsealed blob.

#![allow(clippy::too_many_lines)]

use crate::error::{BrokerError, Result};
use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use zeroize::{Zeroize, Zeroizing};

// ─── Constants ─────────────────────────────────────────────────────────

/// HTTP request timeout (seconds).
const HTTP_TIMEOUT_SECS: u64 = 30;

/// Bitwarden CLI client identifier (used in `connect/token`).
const CLIENT_ID: &str = "connector";

/// Device type 14 = "SDK" (closest to a CLI broker).
const DEVICE_TYPE: u8 = 14;

/// HKDF info strings used by Bitwarden to stretch the master key.
const HKDF_INFO_ENC: &[u8] = b"enc";
const HKDF_INFO_MAC: &[u8] = b"mac";

/// AES-256 CBC IV length (bytes).
const AES_IV_LEN: usize = 16;
/// HMAC-SHA256 tag length (bytes).
const HMAC_LEN: usize = 32;
/// Stretched key length: 32 enc + 32 mac.
const STRETCHED_KEY_LEN: usize = 64;
/// Master key length (output of KDF).
const MASTER_KEY_LEN: usize = 32;

// ─── Public types ──────────────────────────────────────────────────────

/// One decrypted passkey credential, ready for the CTAP2 layer to surface.
#[derive(Debug, Clone)]
pub struct PasskeyCipher {
    /// Server-assigned cipher row ID this passkey was synced from, when known.
    /// Populated by [`BwClient::sync`] so the daemon can pre-seed the
    /// credential_id → cipher_id index and address the right row on a later
    /// counter bump. `None` for freshly-minted (not-yet-pushed) credentials —
    /// the server assigns the ID on `create_passkey_cipher`.
    pub cipher_id: Option<String>,
    /// Raw credential ID bytes (typically 16-byte UUID, sometimes longer).
    pub credential_id: Vec<u8>,
    pub rp_id: String,
    pub rp_name: Option<String>,
    pub user_handle: Vec<u8>,
    pub user_name: Option<String>,
    pub user_display_name: Option<String>,
    /// Algorithm string, e.g. `"ECDSA"`.
    pub key_algorithm: String,
    /// Curve string, e.g. `"P-256"`.
    pub key_curve: String,
    /// PKCS#8 DER-encoded private key, zeroized on drop.
    pub private_key_pkcs8: Zeroizing<Vec<u8>>,
    pub counter: u32,
    pub discoverable: bool,
}

/// HTTP transport abstraction. Production uses [`ReqwestTransport`] (which
/// wraps a real `reqwest::Client`); tests can substitute a recording mock so
/// they never hit a real Vaultwarden. The trait surface is intentionally
/// minimal: just the verbs we actually use.
#[async_trait]
pub trait HttpTransport: Send + Sync {
    /// `POST <url>` with `application/json` body.
    async fn post_json(&self, url: &str, body: serde_json::Value) -> Result<HttpReply>;
    /// `POST <url>` with `application/x-www-form-urlencoded` body.
    async fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<HttpReply>;
    /// `GET <url>` with optional `Authorization: Bearer <token>`.
    async fn get_bearer(&self, url: &str, bearer: Option<&str>) -> Result<HttpReply>;
    /// `POST <url>` with JSON body and `Authorization: Bearer <token>`.
    async fn post_json_bearer(
        &self,
        url: &str,
        body: serde_json::Value,
        bearer: &str,
    ) -> Result<HttpReply>;
    /// `PUT <url>` with JSON body and `Authorization: Bearer <token>`.
    async fn put_json_bearer(
        &self,
        url: &str,
        body: serde_json::Value,
        bearer: &str,
    ) -> Result<HttpReply>;
}

/// Generic HTTP response: status + body text.
#[derive(Debug, Clone)]
pub struct HttpReply {
    pub status: u16,
    pub body: String,
}

impl HttpReply {
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

/// `reqwest`-backed implementation of [`HttpTransport`].
pub struct ReqwestTransport {
    http: reqwest::Client,
}

impl ReqwestTransport {
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
            .build()
            .expect("reqwest client builder cannot fail with these options");
        Self { http }
    }
}

impl Default for ReqwestTransport {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl HttpTransport for ReqwestTransport {
    async fn post_json(&self, url: &str, body: serde_json::Value) -> Result<HttpReply> {
        let resp = self
            .http
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("POST {url}: {e}")))?;
        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read body {url}: {e}")))?;
        Ok(HttpReply { status, body })
    }

    async fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<HttpReply> {
        let resp = self
            .http
            .post(url)
            .form(form)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("POST(form) {url}: {e}")))?;
        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read body {url}: {e}")))?;
        Ok(HttpReply { status, body })
    }

    async fn get_bearer(&self, url: &str, bearer: Option<&str>) -> Result<HttpReply> {
        let mut req = self.http.get(url);
        if let Some(t) = bearer {
            req = req.bearer_auth(t);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("GET {url}: {e}")))?;
        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read body {url}: {e}")))?;
        Ok(HttpReply { status, body })
    }

    async fn post_json_bearer(
        &self,
        url: &str,
        body: serde_json::Value,
        bearer: &str,
    ) -> Result<HttpReply> {
        let resp = self
            .http
            .post(url)
            .bearer_auth(bearer)
            .json(&body)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("POST(bearer) {url}: {e}")))?;
        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read body {url}: {e}")))?;
        Ok(HttpReply { status, body })
    }

    async fn put_json_bearer(
        &self,
        url: &str,
        body: serde_json::Value,
        bearer: &str,
    ) -> Result<HttpReply> {
        let resp = self
            .http
            .put(url)
            .bearer_auth(bearer)
            .json(&body)
            .send()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("PUT(bearer) {url}: {e}")))?;
        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| BrokerError::VaultHttp(format!("read body {url}: {e}")))?;
        Ok(HttpReply { status, body })
    }
}

/// Bitwarden-API client.
pub struct BwClient {
    endpoint: String,
    email: String,
    http: Arc<dyn HttpTransport>,

    // Populated by `login()`.
    access_token: Option<SecretString>,
    refresh_token: Option<SecretString>,
    /// 64-byte user key (32 enc + 32 mac), unwrapped from the response `Key`.
    user_key: Option<SecretBytes>,
}

impl BwClient {
    /// Build a client backed by the production `reqwest` transport. Does not
    /// perform any network I/O.
    pub fn new(endpoint: &str, email: &str) -> Self {
        Self::with_transport(endpoint, email, Arc::new(ReqwestTransport::new()))
    }

    /// Build a client with a caller-supplied transport (used by tests to
    /// substitute a recording mock).
    pub fn with_transport(endpoint: &str, email: &str, http: Arc<dyn HttpTransport>) -> Self {
        Self {
            endpoint: endpoint.trim_end_matches('/').to_string(),
            email: email.to_lowercase(),
            http,
            access_token: None,
            refresh_token: None,
            user_key: None,
        }
    }

    /// Test-only helper: stuff a synthetic auth + key state into the client
    /// without going through `login()`. The 64-byte `user_key` MUST be
    /// `STRETCHED_KEY_LEN` bytes (enc[32] || mac[32]).
    #[cfg(test)]
    pub(crate) fn inject_session(&mut self, access_token: &str, user_key64: Vec<u8>) {
        assert_eq!(user_key64.len(), STRETCHED_KEY_LEN);
        self.access_token = Some(SecretString::new(access_token.into()));
        self.user_key = Some(SecretBytes::new(user_key64));
    }

    /// Authenticate against the vault and unwrap the user key.
    pub async fn login(&mut self, master_password: SecretString) -> Result<()> {
        let prelogin = self.prelogin().await?;
        let master_key = derive_master_key(
            master_password.expose_secret().as_bytes(),
            self.email.as_bytes(),
            &prelogin,
        )?;
        let master_pw_hash = master_password_hash(
            master_key.as_ref(),
            master_password.expose_secret().as_bytes(),
        )?;

        let token = self.connect_token(&master_pw_hash).await?;

        // Stretch master_key -> 64 bytes (enc+mac), then decrypt the response Key.
        let stretched = hkdf_stretch(master_key.as_ref())?;
        let user_key = decrypt_enc_string(&token.key, &stretched)?;
        if user_key.len() != STRETCHED_KEY_LEN {
            return Err(BrokerError::VaultCrypto(format!(
                "decrypted user_key has unexpected length {} (want {STRETCHED_KEY_LEN})",
                user_key.len()
            )));
        }

        self.access_token = Some(SecretString::new(token.access_token));
        self.refresh_token = Some(SecretString::new(token.refresh_token));
        self.user_key = Some(SecretBytes::new(user_key));
        Ok(())
    }

    /// Refresh the bearer token using the stored refresh token.
    pub async fn refresh_token(&mut self) -> Result<()> {
        let refresh = self
            .refresh_token
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("no refresh token available".into()))?
            .expose_secret()
            .to_string();

        let url = format!("{}/identity/connect/token", self.endpoint);
        let form: Vec<(&str, &str)> = vec![
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh),
            ("client_id", CLIENT_ID),
        ];

        let reply = self.http.post_form(&url, &form).await?;
        if !reply.is_success() {
            return Err(BrokerError::VaultAuth(format!(
                "connect/token refresh failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        let parsed: RefreshResponse = serde_json::from_str(&reply.body).map_err(|e| {
            BrokerError::VaultDecode(format!("refresh response: {e}: {}", reply.body))
        })?;
        self.access_token = Some(SecretString::new(parsed.access_token));
        if let Some(rt) = parsed.refresh_token {
            self.refresh_token = Some(SecretString::new(rt));
        }
        Ok(())
    }

    /// Fetch the vault and return all decrypted passkey ciphers.
    pub async fn sync(&mut self) -> Result<Vec<PasskeyCipher>> {
        let token = self
            .access_token
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("not logged in".into()))?
            .expose_secret()
            .to_string();
        let user_key = self
            .user_key
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("user key missing".into()))?
            .as_slice()
            .to_vec();

        let url = format!("{}/api/sync", self.endpoint);
        let reply = self.http.get_bearer(&url, Some(&token)).await?;
        if !reply.is_success() {
            return Err(BrokerError::Vault(format!(
                "sync failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        let sync: SyncResponse = serde_json::from_str(&reply.body)
            .map_err(|e| BrokerError::VaultDecode(format!("sync response: {e}")))?;

        let mut out = Vec::new();
        for cipher in sync.ciphers.unwrap_or_default() {
            if cipher.cipher_type != 1 {
                continue; // Only "login" ciphers can carry passkeys.
            }
            let login = match &cipher.login {
                Some(l) => l,
                None => continue,
            };
            let creds = match &login.fido2_credentials {
                Some(c) if !c.is_empty() => c,
                _ => continue,
            };

            // Per-cipher key: if cipher.key is present, unwrap it with user_key
            // and use it for the rest of this cipher's fields. Otherwise the
            // user_key is used directly.
            let cipher_key_bytes = if let Some(ks) = cipher.key.as_deref() {
                let unwrapped = decrypt_enc_string(ks, &user_key)
                    .map_err(|e| BrokerError::VaultCrypto(format!("unwrap cipher.key: {e}")))?;
                if unwrapped.len() != STRETCHED_KEY_LEN {
                    return Err(BrokerError::VaultCrypto(format!(
                        "per-cipher key has length {} (want {STRETCHED_KEY_LEN})",
                        unwrapped.len()
                    )));
                }
                Some(unwrapped)
            } else {
                None
            };
            let working_key: &[u8] = cipher_key_bytes.as_deref().unwrap_or(&user_key);

            for fc in creds {
                match build_passkey_cipher(fc, working_key, cipher.id.as_deref()) {
                    Ok(p) => out.push(p),
                    Err(e) => {
                        tracing::warn!(error = %e, "skipping passkey credential that failed to decrypt");
                    }
                }
            }
        }
        Ok(out)
    }

    /// Drop in-memory secrets. Subsequent `sync()` will fail until next `login()`.
    pub async fn lock(&mut self) {
        self.access_token = None;
        self.refresh_token = None;
        if let Some(uk) = self.user_key.take() {
            drop(uk); // SecretBytes zeroizes on drop.
        }
    }

    /// Push a freshly-registered passkey into Vaultwarden so it survives
    /// daemon restart. Posts to `/api/ciphers` with a Login-typed cipher
    /// (`type=1`) carrying a single `fido2Credentials` entry. Every
    /// user-visible field is encrypted under the user key as a
    /// CipherString-2; binary fields (`credentialId`, `userHandle`,
    /// `keyValue`) are base64url-encoded first per Vaultwarden's wire shape.
    /// Returns the cipher ID assigned by the server.
    pub async fn create_passkey_cipher(&mut self, cred: &PasskeyCipher) -> Result<String> {
        let token = self
            .access_token
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("not logged in".into()))?
            .expose_secret()
            .to_string();
        let user_key = self
            .user_key
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("user key missing".into()))?
            .as_slice()
            .to_vec();

        // Bitwarden serialises credentialId / userHandle / keyValue as
        // base64-url-no-pad strings *inside* the CipherString plaintext.
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let cred_id_b64 = URL_SAFE_NO_PAD.encode(&cred.credential_id);
        let user_handle_b64 = URL_SAFE_NO_PAD.encode(&cred.user_handle);
        let key_value_b64 = URL_SAFE_NO_PAD.encode(cred.private_key_pkcs8.as_slice());

        // Encrypt every field under the user key (we don't issue a
        // per-cipher key — server will accept this for new ciphers).
        let enc = |s: &str| encrypt_text(s, &user_key);
        let name_enc = enc(cred.user_name.as_deref().unwrap_or("Passkey"))?;
        let cred_id_enc = enc(&cred_id_b64)?;
        let user_handle_enc = enc(&user_handle_b64)?;
        let key_value_enc = enc(&key_value_b64)?;
        let key_type_enc = enc("public-key")?;
        let key_alg_enc = enc(&cred.key_algorithm)?;
        let key_curve_enc = enc(&cred.key_curve)?;
        let rp_id_enc = enc(&cred.rp_id)?;
        let counter_enc = enc(&cred.counter.to_string())?;
        let discoverable_enc = enc(if cred.discoverable { "true" } else { "false" })?;
        let user_name_enc_opt = match cred.user_name.as_deref() {
            Some(s) if !s.is_empty() => Some(enc(s)?),
            _ => None,
        };
        let user_display_name_enc_opt = match cred.user_display_name.as_deref() {
            Some(s) if !s.is_empty() => Some(enc(s)?),
            _ => None,
        };
        let rp_name_enc_opt = match cred.rp_name.as_deref() {
            Some(s) if !s.is_empty() => Some(enc(s)?),
            _ => None,
        };

        let mut fido2_entry = serde_json::Map::new();
        fido2_entry.insert(
            "credentialId".into(),
            serde_json::Value::String(cred_id_enc),
        );
        fido2_entry.insert("keyType".into(), serde_json::Value::String(key_type_enc));
        fido2_entry.insert(
            "keyAlgorithm".into(),
            serde_json::Value::String(key_alg_enc),
        );
        fido2_entry.insert("keyCurve".into(), serde_json::Value::String(key_curve_enc));
        fido2_entry.insert("keyValue".into(), serde_json::Value::String(key_value_enc));
        fido2_entry.insert("rpId".into(), serde_json::Value::String(rp_id_enc));
        fido2_entry.insert(
            "userHandle".into(),
            serde_json::Value::String(user_handle_enc),
        );
        fido2_entry.insert("counter".into(), serde_json::Value::String(counter_enc));
        fido2_entry.insert(
            "discoverable".into(),
            serde_json::Value::String(discoverable_enc),
        );
        if let Some(v) = user_name_enc_opt {
            fido2_entry.insert("userName".into(), serde_json::Value::String(v));
        }
        if let Some(v) = user_display_name_enc_opt {
            fido2_entry.insert("userDisplayName".into(), serde_json::Value::String(v));
        }
        if let Some(v) = rp_name_enc_opt {
            fido2_entry.insert("rpName".into(), serde_json::Value::String(v));
        }
        // Bitwarden expects an ISO-8601 creationDate string, plain (not encrypted).
        fido2_entry.insert(
            "creationDate".into(),
            serde_json::Value::String(rfc3339_now()),
        );

        let body = serde_json::json!({
            "type": 1u8,                       // CipherType.Login
            "name": name_enc,
            "notes": serde_json::Value::Null,
            "favorite": false,
            "reprompt": 0u8,
            "login": {
                "username": serde_json::Value::Null,
                "password": serde_json::Value::Null,
                "totp": serde_json::Value::Null,
                "uris": serde_json::Value::Array(vec![]),
                "fido2Credentials": [serde_json::Value::Object(fido2_entry)],
            },
        });

        let url = format!("{}/api/ciphers", self.endpoint);
        let reply = self.http.post_json_bearer(&url, body, &token).await?;
        if !reply.is_success() {
            return Err(BrokerError::Vault(format!(
                "create cipher failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        let parsed: CipherIdResponse = serde_json::from_str(&reply.body)
            .map_err(|e| BrokerError::VaultDecode(format!("create cipher response: {e}")))?;
        Ok(parsed.id)
    }

    /// Bump the signature counter on an existing passkey cipher. Vaultwarden
    /// stores the counter inside the encrypted `fido2Credentials[0].counter`
    /// field; clone-detection per WebAuthn requires it to monotonically
    /// increase. We GET the current cipher, replace just the `counter` field
    /// (re-encrypted under the user key), then PUT it back. Other fields are
    /// passed through untouched so we don't need to decrypt them.
    pub async fn update_passkey_counter(
        &mut self,
        cipher_id: &str,
        new_counter: u32,
    ) -> Result<()> {
        let token = self
            .access_token
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("not logged in".into()))?
            .expose_secret()
            .to_string();
        let user_key = self
            .user_key
            .as_ref()
            .ok_or_else(|| BrokerError::VaultAuth("user key missing".into()))?
            .as_slice()
            .to_vec();

        // Fetch the existing cipher.
        let url = format!("{}/api/ciphers/{}", self.endpoint, cipher_id);
        let reply = self.http.get_bearer(&url, Some(&token)).await?;
        if !reply.is_success() {
            return Err(BrokerError::Vault(format!(
                "GET cipher {cipher_id} failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        let mut existing: serde_json::Value = serde_json::from_str(&reply.body)
            .map_err(|e| BrokerError::VaultDecode(format!("get cipher response: {e}")))?;

        // Replace the encrypted counter in fido2Credentials[0]. Server
        // returns either { "login": {...}, ... } at the top level (Vaultwarden
        // PascalCase) or wrapped — accept both.
        let new_counter_enc = encrypt_text(&new_counter.to_string(), &user_key)?;
        if !patch_first_passkey_counter(&mut existing, &new_counter_enc) {
            return Err(BrokerError::Vault(format!(
                "cipher {cipher_id} has no fido2Credentials to bump"
            )));
        }

        let reply = self.http.put_json_bearer(&url, existing, &token).await?;
        if !reply.is_success() {
            return Err(BrokerError::Vault(format!(
                "PUT cipher {cipher_id} failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        Ok(())
    }

    // ─── Private helpers ───────────────────────────────────────────────

    async fn prelogin(&self) -> Result<PreloginResponse> {
        let url = format!("{}/identity/accounts/prelogin", self.endpoint);
        let body = serde_json::json!({ "email": self.email });
        let reply = self.http.post_json(&url, body).await?;
        if !reply.is_success() {
            return Err(BrokerError::VaultAuth(format!(
                "prelogin failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        parse_prelogin(&reply.body)
    }

    async fn connect_token(&self, master_pw_hash: &str) -> Result<TokenResponse> {
        let url = format!("{}/identity/connect/token", self.endpoint);
        let device_id = uuid::Uuid::new_v4().to_string();
        let device_type = DEVICE_TYPE.to_string();

        let form: Vec<(&str, &str)> = vec![
            ("grant_type", "password"),
            ("username", &self.email),
            ("password", master_pw_hash),
            ("scope", "api offline_access"),
            ("client_id", CLIENT_ID),
            ("deviceType", &device_type),
            ("deviceIdentifier", &device_id),
            ("deviceName", "fido2-vault-broker"),
        ];

        let reply = self.http.post_form(&url, &form).await?;
        if !reply.is_success() {
            return Err(BrokerError::VaultAuth(format!(
                "connect/token failed: HTTP {}: {}",
                reply.status, reply.body
            )));
        }
        let parsed: TokenResponse = serde_json::from_str(&reply.body)
            .map_err(|e| BrokerError::VaultDecode(format!("token response: {e}")))?;
        Ok(parsed)
    }
}

// ─── Wire types ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub(crate) struct PreloginResponse {
    /// 0 = PBKDF2-SHA256, 1 = Argon2id.
    #[serde(rename = "kdf", alias = "Kdf")]
    pub kdf: u32,
    #[serde(rename = "kdfIterations", alias = "KdfIterations")]
    pub kdf_iterations: u32,
    #[serde(default, rename = "kdfMemory", alias = "KdfMemory")]
    pub kdf_memory: Option<u32>,
    #[serde(default, rename = "kdfParallelism", alias = "KdfParallelism")]
    pub kdf_parallelism: Option<u32>,
}

fn parse_prelogin(text: &str) -> Result<PreloginResponse> {
    serde_json::from_str(text)
        .map_err(|e| BrokerError::VaultDecode(format!("prelogin response: {e}: {text}")))
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    #[serde(rename = "Key", alias = "key")]
    key: String,
    #[allow(dead_code)]
    #[serde(default, rename = "PrivateKey", alias = "privateKey")]
    private_key: Option<String>,
    #[allow(dead_code)]
    #[serde(default)]
    expires_in: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct RefreshResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CipherIdResponse {
    #[serde(rename = "id", alias = "Id")]
    id: String,
}

/// Walk a (Vaultwarden or upstream-Bitwarden) cipher JSON object and overwrite
/// the encrypted `counter` field on the first FIDO2 credential entry. Tolerates
/// the two case styles Vaultwarden alternates between (camelCase + PascalCase),
/// and tolerates the `login` object being at the top level.
/// Returns `true` if a counter field was rewritten.
fn patch_first_passkey_counter(root: &mut serde_json::Value, new_counter_enc: &str) -> bool {
    let obj = match root.as_object_mut() {
        Some(o) => o,
        None => return false,
    };
    // Pick whichever case the server emitted, then borrow-mutably exactly once.
    let login_key = if obj.contains_key("login") {
        "login"
    } else if obj.contains_key("Login") {
        "Login"
    } else {
        return false;
    };
    let login_obj = match obj.get_mut(login_key).and_then(|v| v.as_object_mut()) {
        Some(o) => o,
        None => return false,
    };
    let creds_key = if login_obj.contains_key("fido2Credentials") {
        "fido2Credentials"
    } else if login_obj.contains_key("Fido2Credentials") {
        "Fido2Credentials"
    } else {
        return false;
    };
    let arr = match login_obj.get_mut(creds_key).and_then(|v| v.as_array_mut()) {
        Some(a) => a,
        None => return false,
    };
    let first = match arr.get_mut(0).and_then(|v| v.as_object_mut()) {
        Some(o) => o,
        None => return false,
    };
    // Drop both casings if present, then insert the camelCase form (matches
    // what /api/ciphers ingests). Vaultwarden re-emits whichever style the
    // server prefers on the next sync — both decrypt cleanly.
    first.remove("Counter");
    first.insert(
        "counter".into(),
        serde_json::Value::String(new_counter_enc.to_string()),
    );
    true
}

/// RFC-3339 / ISO-8601 timestamp (UTC, second precision). Used for the
/// `creationDate` field on freshly-minted passkey ciphers. We avoid pulling
/// in `chrono` for one timestamp.
fn rfc3339_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    format_unix_secs_as_rfc3339(secs)
}

/// Format a UNIX timestamp (seconds) as `YYYY-MM-DDTHH:MM:SSZ`. Pure
/// arithmetic — no external deps, valid 1970..=9999.
fn format_unix_secs_as_rfc3339(mut secs: i64) -> String {
    let mut days = secs / 86_400;
    secs -= days * 86_400;
    let hour = (secs / 3_600) as u32;
    let min = ((secs % 3_600) / 60) as u32;
    let sec = (secs % 60) as u32;
    // Civil-from-days (Howard Hinnant's algorithm).
    days += 719_468;
    let era = days.div_euclid(146_097);
    let doe = days - era * 146_097; // [0, 146097)
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = (if m <= 2 { y + 1 } else { y }) as i32;
    format!("{y:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}Z")
}

#[derive(Debug, Deserialize)]
struct SyncResponse {
    #[serde(rename = "ciphers", alias = "Ciphers", default)]
    ciphers: Option<Vec<Cipher>>,
}

#[derive(Debug, Deserialize)]
struct Cipher {
    #[serde(default, rename = "id", alias = "Id")]
    id: Option<String>,
    #[serde(rename = "type", alias = "Type")]
    cipher_type: u32,
    #[serde(default, rename = "key", alias = "Key")]
    key: Option<String>,
    #[serde(default, rename = "login", alias = "Login")]
    login: Option<CipherLogin>,
}

#[derive(Debug, Deserialize)]
struct CipherLogin {
    #[serde(default, rename = "fido2Credentials", alias = "Fido2Credentials")]
    fido2_credentials: Option<Vec<Fido2Credential>>,
}

#[derive(Debug, Deserialize)]
struct Fido2Credential {
    #[serde(default, rename = "credentialId", alias = "CredentialId")]
    credential_id: Option<String>,
    #[serde(default, rename = "keyType", alias = "KeyType")]
    #[allow(dead_code)]
    key_type: Option<String>,
    #[serde(default, rename = "keyAlgorithm", alias = "KeyAlgorithm")]
    key_algorithm: Option<String>,
    #[serde(default, rename = "keyCurve", alias = "KeyCurve")]
    key_curve: Option<String>,
    #[serde(default, rename = "keyValue", alias = "KeyValue")]
    key_value: Option<String>,
    #[serde(default, rename = "rpId", alias = "RpId")]
    rp_id: Option<String>,
    #[serde(default, rename = "userHandle", alias = "UserHandle")]
    user_handle: Option<String>,
    #[serde(default, rename = "userName", alias = "UserName")]
    user_name: Option<String>,
    #[serde(default, rename = "counter", alias = "Counter")]
    counter: Option<String>,
    #[serde(default, rename = "rpName", alias = "RpName")]
    rp_name: Option<String>,
    #[serde(default, rename = "userDisplayName", alias = "UserDisplayName")]
    user_display_name: Option<String>,
    #[serde(default, rename = "discoverable", alias = "Discoverable")]
    discoverable: Option<String>,
}

// ─── Crypto primitives ─────────────────────────────────────────────────

/// PBKDF2-SHA256 of `master_key` over `password`, 1 iteration -> base64.
/// (Bitwarden's "master_password_hash" used as the password-grant password.)
fn master_password_hash(master_key: &[u8], password: &[u8]) -> Result<String> {
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(master_key, password, 1, &mut out);
    Ok(B64.encode(out))
}

/// Derive the 32-byte master key from prelogin parameters.
pub(crate) fn derive_master_key(
    password: &[u8],
    email: &[u8],
    p: &PreloginResponse,
) -> Result<Zeroizing<[u8; MASTER_KEY_LEN]>> {
    let mut out = Zeroizing::new([0u8; MASTER_KEY_LEN]);
    match p.kdf {
        0 => {
            if p.kdf_iterations < 5_000 {
                return Err(BrokerError::VaultCrypto(format!(
                    "PBKDF2 iterations {} below floor 5000",
                    p.kdf_iterations
                )));
            }
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password, email, p.kdf_iterations, out.as_mut());
        }
        1 => {
            // Argon2id parameters per Bitwarden:
            //   time_cost     = kdfIterations
            //   memory_cost   = kdfMemory * 1024  (KiB)
            //   parallelism   = kdfParallelism
            //   salt          = SHA-256(email)
            //   output length = 32
            let memory_mib = p
                .kdf_memory
                .ok_or_else(|| BrokerError::VaultCrypto("argon2: missing kdfMemory".into()))?;
            let parallelism = p
                .kdf_parallelism
                .ok_or_else(|| BrokerError::VaultCrypto("argon2: missing kdfParallelism".into()))?;

            // SHA-256(email) is the required salt for Argon2id in BW.
            use sha2::Digest;
            let salt = sha2::Sha256::digest(email);

            let params = argon2::Params::new(
                memory_mib.saturating_mul(1024),
                p.kdf_iterations,
                parallelism,
                Some(MASTER_KEY_LEN),
            )
            .map_err(|e| BrokerError::VaultCrypto(format!("argon2 params: {e}")))?;
            let argon =
                argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
            argon
                .hash_password_into(password, salt.as_slice(), out.as_mut())
                .map_err(|e| BrokerError::VaultCrypto(format!("argon2 hash: {e}")))?;
        }
        other => {
            return Err(BrokerError::VaultCrypto(format!(
                "unsupported KDF type {other}"
            )));
        }
    }
    Ok(out)
}

/// HKDF-Expand the 32-byte master_key to 64 bytes (enc||mac).
fn hkdf_stretch(master_key: &[u8]) -> Result<Vec<u8>> {
    use hkdf::Hkdf;
    let prk = Hkdf::<sha2::Sha256>::from_prk(master_key)
        .map_err(|e| BrokerError::VaultCrypto(format!("hkdf from_prk: {e}")))?;
    let mut enc = [0u8; 32];
    let mut mac = [0u8; 32];
    prk.expand(HKDF_INFO_ENC, &mut enc)
        .map_err(|e| BrokerError::VaultCrypto(format!("hkdf expand enc: {e}")))?;
    prk.expand(HKDF_INFO_MAC, &mut mac)
        .map_err(|e| BrokerError::VaultCrypto(format!("hkdf expand mac: {e}")))?;
    let mut out = Vec::with_capacity(64);
    out.extend_from_slice(&enc);
    out.extend_from_slice(&mac);
    enc.zeroize();
    mac.zeroize();
    Ok(out)
}

/// Parsed Bitwarden CipherString (`"<type>.<iv_b64>|<ct_b64>|<mac_b64>"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CipherString {
    pub enc_type: u8,
    pub iv: Vec<u8>,
    pub ct: Vec<u8>,
    pub mac: Vec<u8>,
}

pub(crate) fn parse_cipher_string(s: &str) -> Result<CipherString> {
    let (enc_type_str, rest) = s
        .split_once('.')
        .ok_or_else(|| BrokerError::VaultDecode("cipher string missing '.' separator".into()))?;
    let enc_type: u8 = enc_type_str
        .parse()
        .map_err(|_| BrokerError::VaultDecode(format!("bad enc type '{enc_type_str}'")))?;

    let parts: Vec<&str> = rest.split('|').collect();
    let (iv_b64, ct_b64, mac_b64) = match parts.as_slice() {
        [iv, ct, mac] => (*iv, *ct, *mac),
        _ => {
            return Err(BrokerError::VaultDecode(format!(
                "cipher string has {} parts, expected 3",
                parts.len()
            )));
        }
    };
    let iv = B64
        .decode(iv_b64)
        .map_err(|e| BrokerError::VaultDecode(format!("cipher iv b64: {e}")))?;
    let ct = B64
        .decode(ct_b64)
        .map_err(|e| BrokerError::VaultDecode(format!("cipher ct b64: {e}")))?;
    let mac = B64
        .decode(mac_b64)
        .map_err(|e| BrokerError::VaultDecode(format!("cipher mac b64: {e}")))?;
    Ok(CipherString {
        enc_type,
        iv,
        ct,
        mac,
    })
}

/// Decrypt a Bitwarden CipherString (`enc_type` 2 = AES-256-CBC + HMAC-SHA256)
/// with a 64-byte stretched key (32 enc + 32 mac).
pub(crate) fn decrypt_enc_string(s: &str, key64: &[u8]) -> Result<Vec<u8>> {
    if key64.len() != STRETCHED_KEY_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "stretched key length {} (want {STRETCHED_KEY_LEN})",
            key64.len()
        )));
    }
    let cs = parse_cipher_string(s)?;
    // Types 2 (user-key) and 4 (per-cipher rsa-wrapped) both use AES-CBC+HMAC
    // when the wrapping key is symmetric. We accept 2 for direct use here.
    if cs.enc_type != 2 {
        return Err(BrokerError::VaultCrypto(format!(
            "unsupported EncString type {} (only 2 = AesCbc256_HmacSha256_B64 supported)",
            cs.enc_type
        )));
    }
    if cs.iv.len() != AES_IV_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "iv length {} (want {AES_IV_LEN})",
            cs.iv.len()
        )));
    }
    if cs.mac.len() != HMAC_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "mac length {} (want {HMAC_LEN})",
            cs.mac.len()
        )));
    }
    let (enc_key, mac_key) = key64.split_at(32);

    // Verify HMAC over iv||ct first.
    use hmac::{Hmac, Mac};
    let mut hm = <Hmac<sha2::Sha256> as Mac>::new_from_slice(mac_key)
        .map_err(|e| BrokerError::VaultCrypto(format!("hmac init: {e}")))?;
    hm.update(&cs.iv);
    hm.update(&cs.ct);
    hm.verify_slice(&cs.mac)
        .map_err(|_| BrokerError::VaultCrypto("HMAC verification failed".into()))?;

    // Then AES-256-CBC decrypt.
    use cbc::cipher::block_padding::Pkcs7;
    use cbc::cipher::{BlockDecryptMut, KeyIvInit};
    type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;
    let dec = Aes256CbcDec::new_from_slices(enc_key, &cs.iv)
        .map_err(|e| BrokerError::VaultCrypto(format!("aes init: {e}")))?;
    let plain = dec
        .decrypt_padded_vec_mut::<Pkcs7>(&cs.ct)
        .map_err(|e| BrokerError::VaultCrypto(format!("aes decrypt: {e}")))?;
    Ok(plain)
}

fn decrypt_to_string(s: &str, key64: &[u8]) -> Result<String> {
    let raw = decrypt_enc_string(s, key64)?;
    String::from_utf8(raw).map_err(|e| BrokerError::VaultDecode(format!("non-utf8 plaintext: {e}")))
}

/// Encrypt `plaintext` under a 64-byte stretched key (32 enc + 32 mac) and
/// produce a Bitwarden CipherString of type 2 (`AesCbc256_HmacSha256_B64`),
/// which is the only symmetric EncString flavour Vaultwarden ingests for
/// per-field cipher data. The IV is freshly random per call (16 bytes).
pub(crate) fn encrypt_string(plaintext: &[u8], key64: &[u8]) -> Result<String> {
    if key64.len() != STRETCHED_KEY_LEN {
        return Err(BrokerError::VaultCrypto(format!(
            "stretched key length {} (want {STRETCHED_KEY_LEN})",
            key64.len()
        )));
    }
    let (enc_key, mac_key) = key64.split_at(32);

    let mut iv = [0u8; AES_IV_LEN];
    use rand::RngCore;
    rand::rngs::OsRng.fill_bytes(&mut iv);

    use cbc::cipher::block_padding::Pkcs7;
    use cbc::cipher::{BlockEncryptMut, KeyIvInit};
    type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;
    let ct = Aes256CbcEnc::new_from_slices(enc_key, &iv)
        .map_err(|e| BrokerError::VaultCrypto(format!("aes init: {e}")))?
        .encrypt_padded_vec_mut::<Pkcs7>(plaintext);

    use hmac::{Hmac, Mac};
    let mut hm = <Hmac<sha2::Sha256> as Mac>::new_from_slice(mac_key)
        .map_err(|e| BrokerError::VaultCrypto(format!("hmac init: {e}")))?;
    hm.update(&iv);
    hm.update(&ct);
    let mac = hm.finalize().into_bytes();

    Ok(format!(
        "2.{}|{}|{}",
        B64.encode(iv),
        B64.encode(&ct),
        B64.encode(mac)
    ))
}

/// Convenience: encrypt a UTF-8 string field under the user/cipher key.
fn encrypt_text(plain: &str, key64: &[u8]) -> Result<String> {
    encrypt_string(plain.as_bytes(), key64)
}

fn decrypt_optional_string(opt: Option<&str>, key64: &[u8]) -> Result<Option<String>> {
    match opt {
        Some(s) if !s.is_empty() => Ok(Some(decrypt_to_string(s, key64)?)),
        _ => Ok(None),
    }
}

fn build_passkey_cipher(
    fc: &Fido2Credential,
    key64: &[u8],
    cipher_id: Option<&str>,
) -> Result<PasskeyCipher> {
    let credential_id_str = fc
        .credential_id
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: credentialId missing".into()))?;
    let credential_id_plain = decrypt_to_string(credential_id_str, key64)?;
    // Bitwarden serialises credentialId as a base64url string (no padding).
    let credential_id = decode_b64url_loose(&credential_id_plain)
        .or_else(|_| B64.decode(&credential_id_plain))
        .map_err(|e| BrokerError::VaultDecode(format!("credentialId b64: {e}")))?;

    let rp_id = fc
        .rp_id
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: rpId missing".into()))?;
    let rp_id = decrypt_to_string(rp_id, key64)?;

    let user_handle_str = fc
        .user_handle
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: userHandle missing".into()))?;
    let user_handle_plain = decrypt_to_string(user_handle_str, key64)?;
    let user_handle = decode_b64url_loose(&user_handle_plain)
        .or_else(|_| B64.decode(&user_handle_plain))
        .map_err(|e| BrokerError::VaultDecode(format!("userHandle b64: {e}")))?;

    let key_value_str = fc
        .key_value
        .as_deref()
        .ok_or_else(|| BrokerError::VaultDecode("passkey: keyValue missing".into()))?;
    let key_value_plain = decrypt_to_string(key_value_str, key64)?;
    // Bitwarden stores the PKCS#8 DER private key as base64.
    let pkcs8 = decode_b64url_loose(&key_value_plain)
        .or_else(|_| B64.decode(&key_value_plain))
        .map_err(|e| BrokerError::VaultDecode(format!("keyValue b64: {e}")))?;

    let key_algorithm = decrypt_optional_string(fc.key_algorithm.as_deref(), key64)?
        .unwrap_or_else(|| "ECDSA".to_string());
    let key_curve = decrypt_optional_string(fc.key_curve.as_deref(), key64)?
        .unwrap_or_else(|| "P-256".to_string());

    let counter = match decrypt_optional_string(fc.counter.as_deref(), key64)? {
        Some(s) => s.parse::<u32>().unwrap_or(0),
        None => 0,
    };
    let discoverable = match decrypt_optional_string(fc.discoverable.as_deref(), key64)? {
        Some(s) => matches!(s.as_str(), "true" | "True" | "1"),
        None => false,
    };

    let user_name = decrypt_optional_string(fc.user_name.as_deref(), key64)?;
    let user_display_name = decrypt_optional_string(fc.user_display_name.as_deref(), key64)?;
    let rp_name = decrypt_optional_string(fc.rp_name.as_deref(), key64)?;

    Ok(PasskeyCipher {
        cipher_id: cipher_id.map(str::to_string),
        credential_id,
        rp_id,
        rp_name,
        user_handle,
        user_name,
        user_display_name,
        key_algorithm,
        key_curve,
        private_key_pkcs8: Zeroizing::new(pkcs8),
        counter,
        discoverable,
    })
}

/// Decode either base64url (with optional `=` padding) — Bitwarden uses both
/// flavours in different fields and across versions.
fn decode_b64url_loose(s: &str) -> std::result::Result<Vec<u8>, base64::DecodeError> {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    URL_SAFE_NO_PAD.decode(s.trim_end_matches('='))
}

// ─── In-memory secret container with mlock + zeroize ───────────────────

/// Owned byte buffer that mlocks itself on construction (best-effort),
/// zeroes on drop. Used for the unwrapped 64-byte user key.
struct SecretBytes {
    inner: Zeroizing<Vec<u8>>,
    locked: bool,
}

impl SecretBytes {
    fn new(bytes: Vec<u8>) -> Self {
        let inner = Zeroizing::new(bytes);
        let locked = unsafe {
            // SAFETY: ptr+len are valid for the lifetime of `inner` while we
            // hold it; mlock is documented safe to call on any mapped region.
            libc::mlock(inner.as_ptr().cast(), inner.len()) == 0
        };
        if !locked {
            tracing::debug!(
                "mlock failed (errno={}); secret will not be page-locked",
                std::io::Error::last_os_error()
            );
        }
        Self { inner, locked }
    }

    fn as_slice(&self) -> &[u8] {
        &self.inner
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        if self.locked {
            unsafe {
                libc::munlock(self.inner.as_ptr().cast(), self.inner.len());
            }
        }
        // Zeroizing<Vec<u8>> handles the wipe.
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prelogin_response_parses() {
        let json = r#"{"kdf":0,"kdfIterations":600000,"kdfMemory":null,"kdfParallelism":null}"#;
        let p = parse_prelogin(json).unwrap();
        assert_eq!(p.kdf, 0);
        assert_eq!(p.kdf_iterations, 600_000);
        assert!(p.kdf_memory.is_none());

        let json2 = r#"{"Kdf":1,"KdfIterations":3,"KdfMemory":64,"KdfParallelism":4}"#;
        let p2 = parse_prelogin(json2).unwrap();
        assert_eq!(p2.kdf, 1);
        assert_eq!(p2.kdf_iterations, 3);
        assert_eq!(p2.kdf_memory, Some(64));
        assert_eq!(p2.kdf_parallelism, Some(4));
    }

    #[test]
    fn pbkdf2_master_key_is_deterministic() {
        // Same email + password + KDF params -> same master key (asserts
        // PBKDF2 wiring is stable; no published BW vector required).
        let p = PreloginResponse {
            kdf: 0,
            kdf_iterations: 100_000,
            kdf_memory: None,
            kdf_parallelism: None,
        };
        let pw = b"correct horse battery staple";
        let email = b"user@example.com";
        let a = derive_master_key(pw, email, &p).unwrap();
        let b = derive_master_key(pw, email, &p).unwrap();
        assert_eq!(a.as_slice(), b.as_slice());
        assert_eq!(a.len(), 32);

        // Different password -> different key.
        let c = derive_master_key(b"different", email, &p).unwrap();
        assert_ne!(a.as_slice(), c.as_slice());

        // Master password hash also deterministic.
        let h1 = master_password_hash(a.as_ref(), pw).unwrap();
        let h2 = master_password_hash(a.as_ref(), pw).unwrap();
        assert_eq!(h1, h2);
    }

    #[test]
    fn pbkdf2_floor_rejects_low_iterations() {
        let p = PreloginResponse {
            kdf: 0,
            kdf_iterations: 1_000,
            kdf_memory: None,
            kdf_parallelism: None,
        };
        let err = derive_master_key(b"pw", b"e@x", &p).unwrap_err();
        assert!(
            matches!(err, BrokerError::VaultCrypto(_)),
            "expected VaultCrypto, got {err:?}"
        );
    }

    #[test]
    fn cipher_string_parses_three_fields() {
        let iv = [0xAAu8; 16];
        let ct = [0xBBu8; 32];
        let mac = [0xCCu8; 32];
        let s = format!(
            "2.{}|{}|{}",
            B64.encode(iv),
            B64.encode(ct),
            B64.encode(mac)
        );
        let cs = parse_cipher_string(&s).unwrap();
        assert_eq!(cs.enc_type, 2);
        assert_eq!(cs.iv, iv);
        assert_eq!(cs.ct, ct);
        assert_eq!(cs.mac, mac);
    }

    #[test]
    fn cipher_string_rejects_wrong_part_count() {
        let bad = "2.aGVsbG8=|d29ybGQ=";
        assert!(parse_cipher_string(bad).is_err());
    }

    /// Round-trip test: encrypt a known plaintext with a known 64-byte
    /// stretched key, format as a CipherString, decrypt, assert match.
    #[test]
    fn decrypt_known_test_vector() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        use hmac::{Hmac, Mac};
        type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;

        // Deterministic 64-byte key (32 enc + 32 mac).
        let mut key64 = [0u8; 64];
        for (i, b) in key64.iter_mut().enumerate() {
            *b = i as u8;
        }
        let (enc_key, mac_key) = key64.split_at(32);
        let iv = [7u8; 16];
        let plain = b"fido2-vault-broker-test-vector\x00\x00\x00";

        let ct = Aes256CbcEnc::new_from_slices(enc_key, &iv)
            .unwrap()
            .encrypt_padded_vec_mut::<Pkcs7>(plain);

        let mut hm = <Hmac<sha2::Sha256> as Mac>::new_from_slice(mac_key).unwrap();
        hm.update(&iv);
        hm.update(&ct);
        let mac = hm.finalize().into_bytes();

        let cs = format!(
            "2.{}|{}|{}",
            B64.encode(iv),
            B64.encode(&ct),
            B64.encode(mac)
        );
        let got = decrypt_enc_string(&cs, &key64).unwrap();
        assert_eq!(got.as_slice(), plain);
    }

    #[test]
    fn decrypt_rejects_bad_mac() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;

        let key64 = [9u8; 64];
        let (enc_key, _) = key64.split_at(32);
        let iv = [3u8; 16];
        let ct = Aes256CbcEnc::new_from_slices(enc_key, &iv)
            .unwrap()
            .encrypt_padded_vec_mut::<Pkcs7>(b"hello");
        let bad_mac = [0u8; 32];
        let cs = format!(
            "2.{}|{}|{}",
            B64.encode(iv),
            B64.encode(&ct),
            B64.encode(bad_mac)
        );
        let err = decrypt_enc_string(&cs, &key64).unwrap_err();
        assert!(
            matches!(err, BrokerError::VaultCrypto(_)),
            "expected VaultCrypto, got {err:?}"
        );
    }

    #[test]
    fn decrypt_rejects_unsupported_type() {
        let cs = "1.AAAA|BBBB|CCCC";
        let key64 = [0u8; 64];
        let err = decrypt_enc_string(cs, &key64).unwrap_err();
        assert!(matches!(err, BrokerError::VaultCrypto(_)));
    }

    #[test]
    fn bw_client_new_normalises_email_and_endpoint() {
        let c = BwClient::new("https://vault.example.com/", "USER@Example.COM");
        assert_eq!(c.endpoint, "https://vault.example.com");
        assert_eq!(c.email, "user@example.com");
        assert!(c.access_token.is_none());
        assert!(c.user_key.is_none());
    }

    // ─── encrypt/decrypt round-trip + cipher push/update mock tests ────

    #[test]
    fn encrypt_string_round_trips_with_decrypt() {
        // Random key + plaintext; encrypt then decrypt must give back the same bytes.
        let mut key64 = [0u8; 64];
        for (i, b) in key64.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(31).wrapping_add(7);
        }
        let plain = b"counter=42 user=alice@example.test";
        let enc = encrypt_string(plain, &key64).unwrap();
        assert!(enc.starts_with("2."), "must be CipherString type 2");
        assert_eq!(enc.split('|').count(), 3);
        let dec = decrypt_enc_string(&enc, &key64).unwrap();
        assert_eq!(dec.as_slice(), plain);
    }

    #[test]
    fn encrypt_string_uses_fresh_iv() {
        // Same plaintext twice must produce different ciphertexts (random IV).
        let key64 = [9u8; 64];
        let a = encrypt_string(b"same", &key64).unwrap();
        let b = encrypt_string(b"same", &key64).unwrap();
        assert_ne!(a, b, "two encrypts of the same plaintext must differ");
    }

    #[test]
    fn rfc3339_format_is_well_formed() {
        // Epoch.
        let s = format_unix_secs_as_rfc3339(0);
        assert_eq!(s, "1970-01-01T00:00:00Z");
        // Y2K boundary check.
        let s = format_unix_secs_as_rfc3339(946_684_800);
        assert_eq!(s, "2000-01-01T00:00:00Z");
    }

    #[test]
    fn patch_counter_walks_both_cases() {
        let mut v: serde_json::Value = serde_json::json!({
            "id": "abc",
            "Login": {
                "Fido2Credentials": [
                    {"Counter": "old", "RpId": "x"}
                ]
            }
        });
        assert!(patch_first_passkey_counter(&mut v, "NEW"));
        let new_val = v
            .pointer("/Login/Fido2Credentials/0/counter")
            .and_then(|x| x.as_str())
            .unwrap();
        assert_eq!(new_val, "NEW");
        // PascalCase Counter must have been removed.
        assert!(v.pointer("/Login/Fido2Credentials/0/Counter").is_none());
    }

    // ─── Mock transport for offline create/update tests ────────────────

    /// One recorded HTTP exchange.
    #[derive(Debug, Clone)]
    struct Recorded {
        method: &'static str,
        url: String,
        body: Option<serde_json::Value>,
    }

    /// Mock transport that returns canned replies in FIFO order and records
    /// every call. Tests use this in place of `ReqwestTransport` so they
    /// never touch a real Vaultwarden.
    struct MockTransport {
        replies: tokio::sync::Mutex<std::collections::VecDeque<HttpReply>>,
        recorded: tokio::sync::Mutex<Vec<Recorded>>,
    }

    impl MockTransport {
        fn new(replies: Vec<HttpReply>) -> Self {
            Self {
                replies: tokio::sync::Mutex::new(replies.into_iter().collect()),
                recorded: tokio::sync::Mutex::new(Vec::new()),
            }
        }
        async fn pop(&self) -> HttpReply {
            self.replies
                .lock()
                .await
                .pop_front()
                .expect("MockTransport: no canned reply available")
        }
        async fn snapshot(&self) -> Vec<Recorded> {
            self.recorded.lock().await.clone()
        }
    }

    #[async_trait]
    impl HttpTransport for MockTransport {
        async fn post_json(&self, url: &str, body: serde_json::Value) -> Result<HttpReply> {
            self.recorded.lock().await.push(Recorded {
                method: "POST",
                url: url.into(),
                body: Some(body),
            });
            Ok(self.pop().await)
        }
        async fn post_form(&self, url: &str, _form: &[(&str, &str)]) -> Result<HttpReply> {
            self.recorded.lock().await.push(Recorded {
                method: "POST_FORM",
                url: url.into(),
                body: None,
            });
            Ok(self.pop().await)
        }
        async fn get_bearer(&self, url: &str, _bearer: Option<&str>) -> Result<HttpReply> {
            self.recorded.lock().await.push(Recorded {
                method: "GET",
                url: url.into(),
                body: None,
            });
            Ok(self.pop().await)
        }
        async fn post_json_bearer(
            &self,
            url: &str,
            body: serde_json::Value,
            _bearer: &str,
        ) -> Result<HttpReply> {
            self.recorded.lock().await.push(Recorded {
                method: "POST_BEARER",
                url: url.into(),
                body: Some(body),
            });
            Ok(self.pop().await)
        }
        async fn put_json_bearer(
            &self,
            url: &str,
            body: serde_json::Value,
            _bearer: &str,
        ) -> Result<HttpReply> {
            self.recorded.lock().await.push(Recorded {
                method: "PUT_BEARER",
                url: url.into(),
                body: Some(body),
            });
            Ok(self.pop().await)
        }
    }

    fn synthetic_passkey_cipher() -> PasskeyCipher {
        PasskeyCipher {
            cipher_id: None,
            credential_id: vec![0x11; 16],
            rp_id: "example.test".into(),
            rp_name: Some("Example Test".into()),
            user_handle: vec![0x22; 8],
            user_name: Some("alice".into()),
            user_display_name: Some("Alice".into()),
            key_algorithm: "ECDSA".into(),
            key_curve: "P-256".into(),
            private_key_pkcs8: Zeroizing::new(vec![0x33; 138]),
            counter: 0,
            discoverable: true,
        }
    }

    #[tokio::test]
    async fn create_passkey_cipher_posts_encrypted_payload() {
        let mock = Arc::new(MockTransport::new(vec![HttpReply {
            status: 200,
            body: r#"{"id":"new-cipher-uuid-1234"}"#.into(),
        }]));
        let mut bw = BwClient::with_transport(
            "https://vault.example.test/",
            "alice@example.test",
            mock.clone(),
        );
        bw.inject_session("test-access-token", vec![0xCDu8; 64]);

        let cipher = synthetic_passkey_cipher();
        let id = bw.create_passkey_cipher(&cipher).await.expect("create ok");
        assert_eq!(id, "new-cipher-uuid-1234");

        let snap = mock.snapshot().await;
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].method, "POST_BEARER");
        assert_eq!(snap[0].url, "https://vault.example.test/api/ciphers");
        let body = snap[0].body.as_ref().expect("body");

        // type=1 (Login).
        assert_eq!(body.get("type").and_then(|v| v.as_u64()), Some(1));
        // Encrypted name field is a CipherString-2.
        let name = body.get("name").and_then(|v| v.as_str()).unwrap();
        assert!(name.starts_with("2."));
        // fido2Credentials present, encrypted.
        let fc = body
            .pointer("/login/fido2Credentials/0")
            .and_then(|v| v.as_object())
            .unwrap();
        for k in [
            "credentialId",
            "keyType",
            "keyAlgorithm",
            "keyCurve",
            "keyValue",
            "rpId",
            "userHandle",
            "counter",
            "discoverable",
        ] {
            let s = fc.get(k).and_then(|v| v.as_str()).unwrap();
            assert!(s.starts_with("2."), "{k} must be encrypted");
        }
        // creationDate is plain (server expects ISO-8601 string, not encrypted).
        let cd = fc.get("creationDate").and_then(|v| v.as_str()).unwrap();
        assert!(cd.ends_with('Z'));
    }

    #[tokio::test]
    async fn update_passkey_counter_get_then_put_with_bumped_field() {
        // First reply = current cipher GET; second reply = PUT 200 OK.
        let existing = serde_json::json!({
            "id": "cipher-id-x",
            "type": 1,
            "name": "2.AAAA|BBBB|CCCC",
            "login": {
                "fido2Credentials": [
                    {
                        "credentialId": "2.AAAA|BBBB|CCCC",
                        "counter": "2.OLDOLD|OLDOLD|OLDOLD",
                        "rpId": "2.AAAA|BBBB|CCCC"
                    }
                ]
            }
        });
        let mock = Arc::new(MockTransport::new(vec![
            HttpReply {
                status: 200,
                body: existing.to_string(),
            },
            HttpReply {
                status: 200,
                body: "{}".into(),
            },
        ]));
        let mut bw = BwClient::with_transport(
            "https://vault.example.test",
            "alice@example.test",
            mock.clone(),
        );
        bw.inject_session("tok", vec![0xEEu8; 64]);

        bw.update_passkey_counter("cipher-id-x", 7)
            .await
            .expect("update ok");

        let snap = mock.snapshot().await;
        assert_eq!(snap.len(), 2);
        assert_eq!(snap[0].method, "GET");
        assert_eq!(
            snap[0].url,
            "https://vault.example.test/api/ciphers/cipher-id-x"
        );
        assert_eq!(snap[1].method, "PUT_BEARER");
        let put_body = snap[1].body.as_ref().expect("PUT body");
        let bumped = put_body
            .pointer("/login/fido2Credentials/0/counter")
            .and_then(|v| v.as_str())
            .unwrap();
        // Must be a fresh CipherString-2 distinct from the old one.
        assert!(bumped.starts_with("2."));
        assert_ne!(bumped, "2.OLDOLD|OLDOLD|OLDOLD");
    }

    #[tokio::test]
    async fn update_passkey_counter_propagates_get_failure() {
        let mock = Arc::new(MockTransport::new(vec![HttpReply {
            status: 404,
            body: r#"{"error":"not found"}"#.into(),
        }]));
        let mut bw =
            BwClient::with_transport("https://vault.example.test", "alice@example.test", mock);
        bw.inject_session("tok", vec![0u8; 64]);
        let err = bw
            .update_passkey_counter("missing", 1)
            .await
            .expect_err("must fail");
        assert!(matches!(err, BrokerError::Vault(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn sync_carries_cipher_id_on_passkeys() {
        // A passkey synced from the vault must carry its server cipher_id so
        // the daemon can pre-seed the counter-bump index. Build an encrypted
        // /api/sync fixture under a known user key, then assert sync() both
        // decrypts the fields AND threads the cipher's `id` through.
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let key64 = [0x5Au8; 64];
        let enc = |s: &str| encrypt_string(s.as_bytes(), &key64).unwrap();

        let cred_id_raw = vec![0x11u8; 16];
        let user_handle_raw = vec![0x22u8; 8];
        let pkcs8_raw = vec![0x33u8; 138];

        let sync_json = serde_json::json!({
            "ciphers": [{
                "id": "server-cipher-77",
                "type": 1,
                "login": {
                    "fido2Credentials": [{
                        "credentialId": enc(&URL_SAFE_NO_PAD.encode(&cred_id_raw)),
                        "keyType": enc("public-key"),
                        "keyAlgorithm": enc("ECDSA"),
                        "keyCurve": enc("P-256"),
                        "keyValue": enc(&URL_SAFE_NO_PAD.encode(&pkcs8_raw)),
                        "rpId": enc("example.test"),
                        "userHandle": enc(&URL_SAFE_NO_PAD.encode(&user_handle_raw)),
                        "counter": enc("5"),
                        "discoverable": enc("true"),
                    }]
                }
            }]
        });

        let mock = Arc::new(MockTransport::new(vec![HttpReply {
            status: 200,
            body: sync_json.to_string(),
        }]));
        let mut bw = BwClient::with_transport(
            "https://vault.example.test",
            "alice@example.test",
            mock.clone(),
        );
        bw.inject_session("tok", key64.to_vec());

        let out = bw.sync().await.expect("sync ok");
        assert_eq!(out.len(), 1, "exactly one passkey cipher decoded");
        assert_eq!(
            out[0].cipher_id.as_deref(),
            Some("server-cipher-77"),
            "server cipher_id must be threaded onto the decoded passkey"
        );
        assert_eq!(out[0].credential_id, cred_id_raw);
        assert_eq!(out[0].user_handle, user_handle_raw);
        assert_eq!(out[0].private_key_pkcs8.as_slice(), pkcs8_raw.as_slice());
        assert_eq!(out[0].counter, 5);
        assert!(out[0].discoverable);

        // GET /api/sync was the one and only call.
        let snap = mock.snapshot().await;
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].method, "GET");
        assert_eq!(snap[0].url, "https://vault.example.test/api/sync");
    }

    /// Manual integration test against a real Vaultwarden — opt-in only.
    /// Requires `FVB_VAULT_ENDPOINT`, `FVB_VAULT_EMAIL`, `FVB_MASTER_PASSWORD`.
    /// Run with: `cargo test --ignored login_real_server -- --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn login_real_server() {
        let endpoint = std::env::var("FVB_VAULT_ENDPOINT")
            .expect("set FVB_VAULT_ENDPOINT for ignored real-server test");
        let email = std::env::var("FVB_VAULT_EMAIL")
            .expect("set FVB_VAULT_EMAIL for ignored real-server test");
        let pw = std::env::var("FVB_MASTER_PASSWORD")
            .expect("set FVB_MASTER_PASSWORD for ignored real-server test");
        let mut c = BwClient::new(&endpoint, &email);
        c.login(SecretString::new(pw)).await.unwrap();
        let creds = c.sync().await.unwrap();
        eprintln!("synced {} passkey credentials", creds.len());
        c.lock().await;
    }
}
