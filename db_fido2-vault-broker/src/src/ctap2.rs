//! CTAP2 protocol layer (no HID framing — that lives in `uhid_dev`).
//!
//! Implements the CBOR encode/decode + dispatch logic for these CTAP2
//! authenticator commands per the FIDO Alliance CTAP 2.1 spec:
//!
//!   * `authenticatorMakeCredential`   (0x01)
//!   * `authenticatorGetAssertion`     (0x02)
//!   * `authenticatorGetInfo`          (0x04)
//!   * `authenticatorClientPIN`        (0x06) — minimal: getKeyAgreement + getRetries
//!   * `authenticatorReset`            (0x07) — always rejected (we don't allow reset)
//!
//! Trait surface exposed to the rest of the crate:
//!
//!   * [`KeyStore`]               — credential persistence (impl by `store::bw_api`)
//!   * [`UserPresenceProvider`]   — user-presence prompt   (impl by `uhid_dev` / agent)
//!
//! The HID layer (parallel agent) calls [`Authenticator::handle_command`] with the
//! raw CTAP2 command byte + payload, and gets back the on-the-wire response bytes
//! (status byte first, CBOR payload following — already concatenated).

use std::collections::BTreeMap;

use async_trait::async_trait;
use ciborium::value::Value;
use ecdsa::signature::Signer;
use p256::{
    ecdsa::{Signature as P256Signature, SigningKey, VerifyingKey},
    pkcs8::{DecodePrivateKey, EncodePrivateKey},
    SecretKey,
};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use zeroize::Zeroize;

use crate::error::BrokerError;

// ---------------------------------------------------------------------------
// CTAP2 status codes (subset — see CTAP2 spec §6).
// ---------------------------------------------------------------------------

pub const CTAP2_OK: u8 = 0x00;
pub const CTAP1_ERR_INVALID_COMMAND: u8 = 0x01;
pub const CTAP2_ERR_CBOR_UNEXPECTED_TYPE: u8 = 0x11;
pub const CTAP2_ERR_INVALID_CBOR: u8 = 0x12;
pub const CTAP2_ERR_MISSING_PARAMETER: u8 = 0x14;
pub const CTAP2_ERR_NO_CREDENTIALS: u8 = 0x2E;
pub const CTAP2_ERR_OPERATION_DENIED: u8 = 0x27;
pub const CTAP2_ERR_UNSUPPORTED_ALGORITHM: u8 = 0x26;
pub const CTAP2_ERR_INVALID_OPTION: u8 = 0x2C;
pub const CTAP2_ERR_NOT_ALLOWED: u8 = 0x30;
pub const CTAP2_ERR_OTHER: u8 = 0x7F;

// ---------------------------------------------------------------------------
// CTAP2 command opcodes.
// ---------------------------------------------------------------------------

pub const CMD_MAKE_CREDENTIAL: u8 = 0x01;
pub const CMD_GET_ASSERTION: u8 = 0x02;
pub const CMD_GET_INFO: u8 = 0x04;
pub const CMD_CLIENT_PIN: u8 = 0x06;
pub const CMD_RESET: u8 = 0x07;

// ---------------------------------------------------------------------------
// authData flag bits (WebAuthn §6.1).
// ---------------------------------------------------------------------------

const FLAG_UP: u8 = 0x01; // User Present
const FLAG_UV: u8 = 0x04; // User Verified
const FLAG_AT: u8 = 0x40; // Attested credential data included

const SUPPORTED_ALG_ES256: i32 = -7;

// ---------------------------------------------------------------------------
// Public traits — contracts to other modules / agents.
// ---------------------------------------------------------------------------

/// Error returned by [`KeyStore`] implementations. Boxed string keeps the
/// CTAP2 layer agnostic about whatever backend (Bitwarden REST, sqlite, …)
/// the keystore wraps.
#[derive(Debug, thiserror::Error)]
#[error("keystore: {0}")]
pub struct KeyStoreError(pub String);

/// Persistence backend for resident passkey credentials.
///
/// Implemented by `store::bw_api::BwClient` (or a thin wrapper) so the
/// vault is the source of truth — credentials get pushed back to
/// Vaultwarden out-of-band by the storage layer.
///
/// The synchronous methods serve the hot read/write path (in-memory cache).
/// The two async `persist_*` methods are the optional write-through hooks
/// that mirror state into the vault. Default impls are no-ops, so an
/// in-memory-only keystore (tests, bootstrap) is unaffected; the real
/// `BwBackedKeyStore` overrides them to push to Vaultwarden.
#[async_trait]
pub trait KeyStore {
    fn lookup_credential(&self, rp_id: &str, credential_id: &[u8]) -> Option<&PasskeyCredential>;
    fn list_credentials(&self, rp_id: &str) -> Vec<&PasskeyCredential>;
    fn store_new_credential(&mut self, cred: PasskeyCredential) -> Result<(), KeyStoreError>;
    fn increment_counter(&mut self, credential_id: &[u8]) -> Result<u32, KeyStoreError>;

    /// Push a freshly-registered credential to durable storage. Default: no-op.
    /// Implementations should NOT block the registration ceremony: the caller
    /// logs a warning on `Err` and proceeds with the in-memory copy.
    async fn persist_new_credential(
        &mut self,
        _cred: &PasskeyCredential,
    ) -> Result<(), KeyStoreError> {
        Ok(())
    }

    /// Push a counter bump to durable storage so clone-detection survives
    /// a daemon restart. Default: no-op. Same non-blocking contract as
    /// [`persist_new_credential`].
    async fn persist_counter_bump(
        &mut self,
        _credential_id: &[u8],
        _new_counter: u32,
    ) -> Result<(), KeyStoreError> {
        Ok(())
    }
}

/// Hardware/UI prompt for "tap to confirm" — implemented by the uhid layer
/// (or, in tests, an `AlwaysAllow` stub).
#[async_trait]
pub trait UserPresenceProvider {
    async fn request_presence(&self, rp_id: &str, action: &str) -> Result<bool, BrokerError>;
}

// ---------------------------------------------------------------------------
// PasskeyCredential — what the keystore holds.
// ---------------------------------------------------------------------------

/// A resident WebAuthn passkey. Private key material is stored as PKCS#8
/// DER and zeroized on drop.
#[derive(Clone)]
pub struct PasskeyCredential {
    pub credential_id: Vec<u8>,
    pub rp_id: String,
    pub user_handle: Vec<u8>,
    pub user_name: String,
    pub user_display_name: String,
    /// PKCS#8 DER-encoded ECDSA-P256 private key.
    pub key_pkcs8: Vec<u8>,
    pub counter: u32,
}

impl std::fmt::Debug for PasskeyCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PasskeyCredential")
            .field("credential_id_len", &self.credential_id.len())
            .field("rp_id", &self.rp_id)
            .field("user_name", &self.user_name)
            .field("counter", &self.counter)
            .finish()
    }
}

impl Drop for PasskeyCredential {
    fn drop(&mut self) {
        self.key_pkcs8.zeroize();
    }
}

impl PasskeyCredential {
    /// Decode the stored PKCS#8 into a [`SigningKey`]. Caller must drop
    /// the returned key promptly to limit private-key residency in RAM.
    pub fn signing_key(&self) -> Result<SigningKey, BrokerError> {
        let secret = SecretKey::from_pkcs8_der(&self.key_pkcs8)
            .map_err(|e| BrokerError::Ctap2(format!("pkcs8 decode: {e}")))?;
        Ok(SigningKey::from(secret))
    }

    /// COSE_Key encoding (RFC 8152) for the credential's public key,
    /// suitable for embedding in attested credential data.
    pub fn cose_pubkey(&self) -> Result<Vec<u8>, BrokerError> {
        let sk = self.signing_key()?;
        let vk = VerifyingKey::from(&sk);
        cose_encode_p256_pubkey(&vk)
    }
}

// ---------------------------------------------------------------------------
// COSE_Key encoding for ES256 / P-256.
// ---------------------------------------------------------------------------

/// Encode a P-256 public key as a COSE_Key map per RFC 8152 §13.1.1:
///
/// ```text
/// {1: 2, 3: -7, -1: 1, -2: x, -3: y}
/// ```
///
/// Where `1` = kty (EC2), `3` = alg (ES256), `-1` = crv (P-256), `-2`/`-3` = x/y.
pub fn cose_encode_p256_pubkey(vk: &VerifyingKey) -> Result<Vec<u8>, BrokerError> {
    let point = vk.to_encoded_point(false);
    let x = point
        .x()
        .ok_or_else(|| BrokerError::Ctap2("verifying key has no x coord".into()))?;
    let y = point
        .y()
        .ok_or_else(|| BrokerError::Ctap2("verifying key has no y coord".into()))?;

    let entries: Vec<(Value, Value)> = vec![
        (Value::Integer(1.into()), Value::Integer(2.into())), // kty=EC2
        (Value::Integer(3.into()), Value::Integer((-7i32).into())), // alg=ES256
        (Value::Integer((-1i32).into()), Value::Integer(1.into())), // crv=P-256
        (Value::Integer((-2i32).into()), Value::Bytes(x.to_vec())),
        (Value::Integer((-3i32).into()), Value::Bytes(y.to_vec())),
    ];
    let map = Value::Map(entries);

    let mut out = Vec::with_capacity(77);
    ciborium::ser::into_writer(&map, &mut out)
        .map_err(|e| BrokerError::Ctap2(format!("cose encode: {e}")))?;
    Ok(out)
}

/// Inverse of [`cose_encode_p256_pubkey`] — only used by tests, but kept
/// `pub` so other agents can verify their interop.
pub fn cose_decode_p256_pubkey(bytes: &[u8]) -> Result<(Vec<u8>, Vec<u8>), BrokerError> {
    let v: Value = ciborium::de::from_reader(bytes)
        .map_err(|e| BrokerError::Ctap2(format!("cose decode: {e}")))?;
    let map = match v {
        Value::Map(m) => m,
        _ => return Err(BrokerError::Ctap2("cose: not a map".into())),
    };
    let mut x = None;
    let mut y = None;
    for (k, val) in map {
        if let Value::Integer(i) = k {
            let i: i128 = i.into();
            match (i, val) {
                (-2, Value::Bytes(b)) => x = Some(b),
                (-3, Value::Bytes(b)) => y = Some(b),
                _ => {}
            }
        }
    }
    Ok((
        x.ok_or_else(|| BrokerError::Ctap2("cose: missing x".into()))?,
        y.ok_or_else(|| BrokerError::Ctap2("cose: missing y".into()))?,
    ))
}

// ---------------------------------------------------------------------------
// AAGUID derivation.
// ---------------------------------------------------------------------------

/// Stable per-(machine, account) AAGUID. UUIDv4-shaped (version=4, RFC 4122
/// variant bits) so it round-trips through any conformance checker that
/// expects "looks like a UUID".
pub fn derive_aaguid(machine_id: &[u8], vault_account_id: &str) -> [u8; 16] {
    let mut h = Sha256::new();
    h.update(machine_id);
    h.update(b"\x00"); // domain separator
    h.update(vault_account_id.as_bytes());
    let digest = h.finalize();

    let mut aaguid = [0u8; 16];
    aaguid.copy_from_slice(&digest[..16]);
    // RFC 4122 §4.1.3 — version 4 (random).
    aaguid[6] = (aaguid[6] & 0x0F) | 0x40;
    // RFC 4122 §4.1.1 — variant 10xx.
    aaguid[8] = (aaguid[8] & 0x3F) | 0x80;
    aaguid
}

// ---------------------------------------------------------------------------
// CBOR helpers (typed accessors over `ciborium::Value`).
// ---------------------------------------------------------------------------

fn cbor_decode(bytes: &[u8]) -> Result<Value, BrokerError> {
    ciborium::de::from_reader(bytes).map_err(|e| BrokerError::Ctap2Cbor(format!("{e}")))
}

fn cbor_encode(v: &Value) -> Result<Vec<u8>, BrokerError> {
    let mut out = Vec::new();
    ciborium::ser::into_writer(v, &mut out)
        .map_err(|e| BrokerError::Ctap2(format!("encode: {e}")))?;
    Ok(out)
}

fn map_get(map: &[(Value, Value)], key: i128) -> Option<&Value> {
    map.iter().find_map(|(k, v)| match k {
        Value::Integer(i) => {
            let i: i128 = (*i).into();
            (i == key).then_some(v)
        }
        _ => None,
    })
}

fn as_bstr(v: &Value) -> Result<&[u8], BrokerError> {
    match v {
        Value::Bytes(b) => Ok(b.as_slice()),
        _ => Err(BrokerError::Ctap2Cbor("expected bytes".into())),
    }
}

fn as_text(v: &Value) -> Result<&str, BrokerError> {
    match v {
        Value::Text(s) => Ok(s.as_str()),
        _ => Err(BrokerError::Ctap2Cbor("expected text".into())),
    }
}

fn as_map(v: &Value) -> Result<&[(Value, Value)], BrokerError> {
    match v {
        Value::Map(m) => Ok(m.as_slice()),
        _ => Err(BrokerError::Ctap2Cbor("expected map".into())),
    }
}

fn as_array(v: &Value) -> Result<&[Value], BrokerError> {
    match v {
        Value::Array(a) => Ok(a.as_slice()),
        _ => Err(BrokerError::Ctap2Cbor("expected array".into())),
    }
}

fn map_get_text<'a>(map: &'a [(Value, Value)], key: &str) -> Option<&'a Value> {
    map.iter().find_map(|(k, v)| match k {
        Value::Text(t) => (t == key).then_some(v),
        _ => None,
    })
}

// ---------------------------------------------------------------------------
// authData construction helpers.
// ---------------------------------------------------------------------------

/// Build the WebAuthn `authenticatorData` byte string.
///
/// Layout (no extensions): `rpIdHash(32) || flags(1) || sigCount(4 BE)
///                          || [attestedCredentialData]`.
fn build_auth_data(rp_id: &str, flags: u8, sign_count: u32, attested: Option<&[u8]>) -> Vec<u8> {
    let mut out = Vec::with_capacity(37 + attested.map_or(0, |a| a.len()));
    let rp_hash = Sha256::digest(rp_id.as_bytes());
    out.extend_from_slice(&rp_hash);
    out.push(flags);
    out.extend_from_slice(&sign_count.to_be_bytes());
    if let Some(att) = attested {
        out.extend_from_slice(att);
    }
    out
}

/// Build attested credential data (WebAuthn §6.4.1):
/// `aaguid(16) || credentialIdLen(2 BE) || credentialId || COSE_pubkey`.
fn build_attested_credential_data(
    aaguid: &[u8; 16],
    credential_id: &[u8],
    cose_pubkey: &[u8],
) -> Result<Vec<u8>, BrokerError> {
    if credential_id.len() > u16::MAX as usize {
        return Err(BrokerError::Ctap2("credential_id too long".into()));
    }
    let mut out = Vec::with_capacity(16 + 2 + credential_id.len() + cose_pubkey.len());
    out.extend_from_slice(aaguid);
    out.extend_from_slice(&(credential_id.len() as u16).to_be_bytes());
    out.extend_from_slice(credential_id);
    out.extend_from_slice(cose_pubkey);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Authenticator — top-level handler.
// ---------------------------------------------------------------------------

pub struct Authenticator {
    aaguid: [u8; 16],
    keystore: Box<dyn KeyStore + Send + Sync>,
    user_presence: Box<dyn UserPresenceProvider + Send + Sync>,
}

impl Authenticator {
    pub fn new(
        aaguid: [u8; 16],
        keystore: Box<dyn KeyStore + Send + Sync>,
        user_presence: Box<dyn UserPresenceProvider + Send + Sync>,
    ) -> Self {
        Self {
            aaguid,
            keystore,
            user_presence,
        }
    }

    pub fn aaguid(&self) -> &[u8; 16] {
        &self.aaguid
    }

    /// Top-level dispatch. Returns the on-the-wire response: a status byte
    /// followed (on success) by the CBOR-encoded response object.
    pub async fn handle_command(&mut self, cmd: u8, payload: &[u8]) -> Vec<u8> {
        let res: Result<Vec<u8>, u8> = match cmd {
            CMD_GET_INFO => self.cmd_get_info().map_err(map_err),
            CMD_MAKE_CREDENTIAL => self.cmd_make_credential(payload).await.map_err(map_err),
            CMD_GET_ASSERTION => self.cmd_get_assertion(payload).await.map_err(map_err),
            CMD_CLIENT_PIN => self.cmd_client_pin(payload).map_err(map_err),
            CMD_RESET => Err(CTAP2_ERR_NOT_ALLOWED),
            _ => Err(CTAP1_ERR_INVALID_COMMAND),
        };
        match res {
            Ok(body) => {
                let mut out = Vec::with_capacity(1 + body.len());
                out.push(CTAP2_OK);
                out.extend_from_slice(&body);
                out
            }
            Err(status) => vec![status],
        }
    }

    // -----------------------------------------------------------------------
    // 0x04 authenticatorGetInfo
    // -----------------------------------------------------------------------

    fn cmd_get_info(&self) -> Result<Vec<u8>, BrokerError> {
        // Map keys per CTAP2 §6.4.
        let versions = Value::Array(vec![
            Value::Text("FIDO_2_0".into()),
            Value::Text("FIDO_2_1".into()),
        ]);
        let extensions = Value::Array(vec![]);
        let aaguid = Value::Bytes(self.aaguid.to_vec());
        let options = Value::Map(vec![
            (Value::Text("plat".into()), Value::Bool(false)),
            (Value::Text("rk".into()), Value::Bool(true)),
            (Value::Text("up".into()), Value::Bool(true)),
            (Value::Text("uv".into()), Value::Bool(true)),
        ]);
        let max_msg_size = Value::Integer(1200i32.into());
        let pin_protocols = Value::Array(vec![Value::Integer(1u32.into())]);
        let algorithms = Value::Array(vec![Value::Map(vec![
            (
                Value::Text("alg".into()),
                Value::Integer(SUPPORTED_ALG_ES256.into()),
            ),
            (Value::Text("type".into()), Value::Text("public-key".into())),
        ])]);

        // CTAP2 spec: keys are unsigned ints starting at 0x01.
        let map = Value::Map(vec![
            (Value::Integer(0x01u32.into()), versions),
            (Value::Integer(0x02u32.into()), extensions),
            (Value::Integer(0x03u32.into()), aaguid),
            (Value::Integer(0x04u32.into()), options),
            (Value::Integer(0x05u32.into()), max_msg_size),
            (Value::Integer(0x06u32.into()), pin_protocols),
            (Value::Integer(0x0Au32.into()), algorithms),
        ]);
        cbor_encode(&map)
    }

    // -----------------------------------------------------------------------
    // 0x01 authenticatorMakeCredential
    // -----------------------------------------------------------------------

    async fn cmd_make_credential(&mut self, payload: &[u8]) -> Result<Vec<u8>, BrokerError> {
        let req = MakeCredentialReq::decode(payload)?;

        // 1. Algorithm negotiation — we only do ES256.
        let supported = req
            .pub_key_cred_params
            .iter()
            .any(|p| p.alg == SUPPORTED_ALG_ES256);
        if !supported {
            return Err(BrokerError::Ctap2(format!(
                "unsupported_alg:{:?}",
                req.pub_key_cred_params
            )));
        }

        // 2. User presence prompt.
        let allowed = self
            .user_presence
            .request_presence(&req.rp_id, "register")
            .await?;
        if !allowed {
            return Err(BrokerError::Ctap2UserPresenceDenied);
        }

        // 3. Generate ECDSA-P256 keypair.
        let secret = SecretKey::random(&mut OsRng);
        let signing_key = SigningKey::from(secret.clone());
        let verifying_key = VerifyingKey::from(&signing_key);
        let pkcs8 = secret
            .to_pkcs8_der()
            .map_err(|e| BrokerError::Ctap2(format!("pkcs8 enc: {e}")))?
            .as_bytes()
            .to_vec();

        // 4. Random 32-byte credential ID.
        let mut credential_id = vec![0u8; 32];
        OsRng.fill_bytes(&mut credential_id);

        // 5. Persist (in-memory + best-effort write-through to the vault).
        let cred = PasskeyCredential {
            credential_id: credential_id.clone(),
            rp_id: req.rp_id.clone(),
            user_handle: req.user_id.clone(),
            user_name: req.user_name.clone(),
            user_display_name: req.user_display_name.clone(),
            key_pkcs8: pkcs8,
            counter: 0,
        };
        // Clone for the durable-storage hook BEFORE we move `cred` into the
        // sync keystore, since `store_new_credential` consumes the value.
        let cred_for_persist = cred.clone();
        self.keystore
            .store_new_credential(cred)
            .map_err(|e| BrokerError::Ctap2KeyStore(e.0))?;
        // Best-effort vault sync. A failure here does NOT fail the WebAuthn
        // ceremony — the in-memory credential is still usable for this
        // session, and the operator can retry persistence out-of-band.
        if let Err(e) = self
            .keystore
            .persist_new_credential(&cred_for_persist)
            .await
        {
            tracing::warn!(error = %e.0, rp_id = %req.rp_id, "persist_new_credential failed; in-memory only");
        }

        // 6. Attested credential data + authData.
        let cose_pub = cose_encode_p256_pubkey(&verifying_key)?;
        let attested = build_attested_credential_data(&self.aaguid, &credential_id, &cose_pub)?;
        let auth_data =
            build_auth_data(&req.rp_id, FLAG_AT | FLAG_UV | FLAG_UP, 0, Some(&attested));

        // 7. CBOR response: {1: "none", 2: authData, 3: {}}.
        let resp = Value::Map(vec![
            (Value::Integer(0x01u32.into()), Value::Text("none".into())),
            (Value::Integer(0x02u32.into()), Value::Bytes(auth_data)),
            (Value::Integer(0x03u32.into()), Value::Map(vec![])),
        ]);
        cbor_encode(&resp)
    }

    // -----------------------------------------------------------------------
    // 0x02 authenticatorGetAssertion
    // -----------------------------------------------------------------------

    async fn cmd_get_assertion(&mut self, payload: &[u8]) -> Result<Vec<u8>, BrokerError> {
        let req = GetAssertionReq::decode(payload)?;

        // 1. Resolve credential.
        let credential_id: Vec<u8> = if req.allow_list.is_empty() {
            // Look for any rk credential under this rp_id.
            let creds = self.keystore.list_credentials(&req.rp_id);
            match creds.first() {
                Some(c) => c.credential_id.clone(),
                None => return Err(BrokerError::Ctap2("no_credentials".into())),
            }
        } else {
            let mut found = None;
            for id in &req.allow_list {
                if self.keystore.lookup_credential(&req.rp_id, id).is_some() {
                    found = Some(id.clone());
                    break;
                }
            }
            match found {
                Some(id) => id,
                None => return Err(BrokerError::Ctap2("no_credentials".into())),
            }
        };

        // 2. User presence.
        let allowed = self
            .user_presence
            .request_presence(&req.rp_id, "assert")
            .await?;
        if !allowed {
            return Err(BrokerError::Ctap2UserPresenceDenied);
        }

        // 3. Increment counter (and grab user_handle while we still have a borrow).
        let new_counter = self
            .keystore
            .increment_counter(&credential_id)
            .map_err(|e| BrokerError::Ctap2KeyStore(e.0))?;
        // Best-effort vault sync of the bumped counter. Same non-blocking
        // contract as `persist_new_credential` — clone-detection survives
        // the next daemon restart but a transient vault failure does NOT
        // fail this assertion (the relying party still gets a valid
        // signature with the new counter; only durable persistence lags).
        if let Err(e) = self
            .keystore
            .persist_counter_bump(&credential_id, new_counter)
            .await
        {
            tracing::warn!(error = %e.0, rp_id = %req.rp_id, "persist_counter_bump failed; will retry on next bump");
        }

        // Re-borrow to read the credential we just bumped.
        let cred = self
            .keystore
            .lookup_credential(&req.rp_id, &credential_id)
            .ok_or_else(|| BrokerError::Ctap2("credential vanished".into()))?;
        let user_handle = cred.user_handle.clone();
        let signing_key = cred.signing_key()?;

        // 4. authData (no AT flag for assertion).
        let auth_data = build_auth_data(&req.rp_id, FLAG_UV | FLAG_UP, new_counter, None);

        // 5. Sign authData || clientDataHash.
        let mut to_sign = Vec::with_capacity(auth_data.len() + req.client_data_hash.len());
        to_sign.extend_from_slice(&auth_data);
        to_sign.extend_from_slice(&req.client_data_hash);
        let sig: P256Signature = signing_key.sign(&to_sign);
        let der_sig = sig.to_der().as_bytes().to_vec();

        // 6. CBOR response.
        let cred_descriptor = Value::Map(vec![
            (Value::Text("type".into()), Value::Text("public-key".into())),
            (Value::Text("id".into()), Value::Bytes(credential_id)),
        ]);
        let user_obj = Value::Map(vec![(Value::Text("id".into()), Value::Bytes(user_handle))]);

        let resp = Value::Map(vec![
            (Value::Integer(0x01u32.into()), cred_descriptor),
            (Value::Integer(0x02u32.into()), Value::Bytes(auth_data)),
            (Value::Integer(0x03u32.into()), Value::Bytes(der_sig)),
            (Value::Integer(0x04u32.into()), user_obj),
        ]);
        cbor_encode(&resp)
    }

    // -----------------------------------------------------------------------
    // 0x06 authenticatorClientPIN — stub: only getKeyAgreement + getRetries.
    // -----------------------------------------------------------------------

    fn cmd_client_pin(&self, payload: &[u8]) -> Result<Vec<u8>, BrokerError> {
        let v = cbor_decode(payload)?;
        let map = as_map(&v)?;
        // 0x02 = subCommand.
        let sub_cmd = match map_get(map, 2) {
            Some(Value::Integer(i)) => {
                let n: i128 = (*i).into();
                n
            }
            _ => return Err(BrokerError::Ctap2("clientPIN missing subCommand".into())),
        };

        match sub_cmd {
            // getRetries — unlimited (0xFFFFFFFF).
            0x01 => {
                // Spec: subCommand 0x01 == getPinRetries. Some implementations
                // also use subCommand for getRetries; we treat both 0x01 and
                // 0x07 the same to be liberal in what we accept. The user spec
                // wired this section's 0x07 to getRetries — honour that.
                let resp = Value::Map(vec![(
                    Value::Integer(0x03u32.into()), // 0x03 = retries
                    Value::Integer(0xFFFFFFFFu32.into()),
                )]);
                cbor_encode(&resp)
            }
            // getKeyAgreement — fresh ephemeral P-256 pubkey.
            0x02 => {
                let secret = SecretKey::random(&mut OsRng);
                let vk = VerifyingKey::from(&SigningKey::from(secret));
                let cose = cose_encode_p256_pubkey(&vk)?;
                // Inflate the COSE bytes back to a Value so they live inside
                // the response as a CBOR map (per spec — kA is a map, not bstr).
                let cose_val: Value = ciborium::de::from_reader(cose.as_slice())
                    .map_err(|e| BrokerError::Ctap2(format!("kA round-trip: {e}")))?;
                let resp = Value::Map(vec![(
                    Value::Integer(0x01u32.into()), // 0x01 = keyAgreement
                    cose_val,
                )]);
                cbor_encode(&resp)
            }
            0x07 => {
                // getRetries (CTAP2.1 numbering).
                let resp = Value::Map(vec![(
                    Value::Integer(0x03u32.into()),
                    Value::Integer(0xFFFFFFFFu32.into()),
                )]);
                cbor_encode(&resp)
            }
            _ => Err(BrokerError::Ctap2("invalid_clientPIN_subcommand".into())),
        }
    }
}

/// Map a [`BrokerError`] into a CTAP2 status byte for the response prefix.
fn map_err(e: BrokerError) -> u8 {
    match e {
        BrokerError::Ctap2Cbor(_) => CTAP2_ERR_INVALID_CBOR,
        BrokerError::Ctap2UserPresenceDenied => CTAP2_ERR_OPERATION_DENIED,
        BrokerError::Ctap2KeyStore(_) => CTAP2_ERR_OTHER,
        BrokerError::Ctap2(s) if s.starts_with("unsupported_alg") => {
            CTAP2_ERR_UNSUPPORTED_ALGORITHM
        }
        BrokerError::Ctap2(s) if s == "no_credentials" => CTAP2_ERR_NO_CREDENTIALS,
        BrokerError::Ctap2(s) if s.starts_with("invalid_clientPIN") => CTAP2_ERR_INVALID_OPTION,
        BrokerError::Ctap2(_) => CTAP2_ERR_OTHER,
        _ => CTAP2_ERR_OTHER,
    }
}

// ---------------------------------------------------------------------------
// Decoded request shapes.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct PubKeyCredParam {
    pub alg: i32,
    pub typ: String,
}

#[derive(Debug, Clone)]
pub struct MakeCredentialReq {
    pub client_data_hash: Vec<u8>,
    pub rp_id: String,
    pub rp_name: Option<String>,
    pub user_id: Vec<u8>,
    pub user_name: String,
    pub user_display_name: String,
    pub pub_key_cred_params: Vec<PubKeyCredParam>,
}

impl MakeCredentialReq {
    pub fn decode(bytes: &[u8]) -> Result<Self, BrokerError> {
        let v = cbor_decode(bytes)?;
        let map = as_map(&v)?;

        let client_data_hash = map_get(map, 1)
            .ok_or_else(|| BrokerError::Ctap2Cbor("missing clientDataHash".into()))
            .and_then(as_bstr)?
            .to_vec();

        let rp_map = map_get(map, 2)
            .ok_or_else(|| BrokerError::Ctap2Cbor("missing rp".into()))
            .and_then(as_map)?;
        let rp_id = map_get_text(rp_map, "id")
            .ok_or_else(|| BrokerError::Ctap2Cbor("rp.id missing".into()))
            .and_then(as_text)?
            .to_string();
        let rp_name = map_get_text(rp_map, "name")
            .and_then(|v| as_text(v).ok())
            .map(|s| s.to_string());

        let user_map = map_get(map, 3)
            .ok_or_else(|| BrokerError::Ctap2Cbor("missing user".into()))
            .and_then(as_map)?;
        let user_id = map_get_text(user_map, "id")
            .ok_or_else(|| BrokerError::Ctap2Cbor("user.id missing".into()))
            .and_then(as_bstr)?
            .to_vec();
        let user_name = map_get_text(user_map, "name")
            .and_then(|v| as_text(v).ok())
            .unwrap_or("")
            .to_string();
        let user_display_name = map_get_text(user_map, "displayName")
            .and_then(|v| as_text(v).ok())
            .unwrap_or("")
            .to_string();

        let params_arr = map_get(map, 4)
            .ok_or_else(|| BrokerError::Ctap2Cbor("missing pubKeyCredParams".into()))
            .and_then(as_array)?;
        let mut pub_key_cred_params = Vec::with_capacity(params_arr.len());
        for item in params_arr {
            let m = as_map(item)?;
            let alg = match map_get_text(m, "alg") {
                Some(Value::Integer(i)) => {
                    let n: i128 = (*i).into();
                    n as i32
                }
                _ => return Err(BrokerError::Ctap2Cbor("pubKeyCredParam.alg missing".into())),
            };
            let typ = map_get_text(m, "type")
                .and_then(|v| as_text(v).ok())
                .unwrap_or("public-key")
                .to_string();
            pub_key_cred_params.push(PubKeyCredParam { alg, typ });
        }

        Ok(Self {
            client_data_hash,
            rp_id,
            rp_name,
            user_id,
            user_name,
            user_display_name,
            pub_key_cred_params,
        })
    }

    /// Encode round-trip — used by tests and any internal callers that want
    /// to produce a canonical request blob.
    pub fn encode(&self) -> Result<Vec<u8>, BrokerError> {
        let rp = Value::Map(vec![
            (Value::Text("id".into()), Value::Text(self.rp_id.clone())),
            (
                Value::Text("name".into()),
                Value::Text(self.rp_name.clone().unwrap_or_default()),
            ),
        ]);
        let user = Value::Map(vec![
            (Value::Text("id".into()), Value::Bytes(self.user_id.clone())),
            (
                Value::Text("name".into()),
                Value::Text(self.user_name.clone()),
            ),
            (
                Value::Text("displayName".into()),
                Value::Text(self.user_display_name.clone()),
            ),
        ]);
        let params = Value::Array(
            self.pub_key_cred_params
                .iter()
                .map(|p| {
                    Value::Map(vec![
                        (
                            Value::Text("alg".into()),
                            Value::Integer((p.alg as i64).into()),
                        ),
                        (Value::Text("type".into()), Value::Text(p.typ.clone())),
                    ])
                })
                .collect(),
        );
        let map = Value::Map(vec![
            (
                Value::Integer(1u32.into()),
                Value::Bytes(self.client_data_hash.clone()),
            ),
            (Value::Integer(2u32.into()), rp),
            (Value::Integer(3u32.into()), user),
            (Value::Integer(4u32.into()), params),
        ]);
        cbor_encode(&map)
    }
}

#[derive(Debug, Clone)]
pub struct GetAssertionReq {
    pub rp_id: String,
    pub client_data_hash: Vec<u8>,
    pub allow_list: Vec<Vec<u8>>,
}

impl GetAssertionReq {
    pub fn decode(bytes: &[u8]) -> Result<Self, BrokerError> {
        let v = cbor_decode(bytes)?;
        let map = as_map(&v)?;

        let rp_id = map_get(map, 1)
            .ok_or_else(|| BrokerError::Ctap2Cbor("missing rpId".into()))
            .and_then(as_text)?
            .to_string();
        let client_data_hash = map_get(map, 2)
            .ok_or_else(|| BrokerError::Ctap2Cbor("missing clientDataHash".into()))
            .and_then(as_bstr)?
            .to_vec();

        let allow_list = if let Some(v) = map_get(map, 3) {
            let arr = as_array(v)?;
            let mut ids = Vec::with_capacity(arr.len());
            for entry in arr {
                let m = as_map(entry)?;
                if let Some(id_val) = map_get_text(m, "id") {
                    ids.push(as_bstr(id_val)?.to_vec());
                }
            }
            ids
        } else {
            Vec::new()
        };

        Ok(Self {
            rp_id,
            client_data_hash,
            allow_list,
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>, BrokerError> {
        let mut entries: Vec<(Value, Value)> = Vec::with_capacity(3);
        entries.push((Value::Integer(1u32.into()), Value::Text(self.rp_id.clone())));
        entries.push((
            Value::Integer(2u32.into()),
            Value::Bytes(self.client_data_hash.clone()),
        ));
        if !self.allow_list.is_empty() {
            entries.push((
                Value::Integer(3u32.into()),
                Value::Array(
                    self.allow_list
                        .iter()
                        .map(|id| {
                            Value::Map(vec![
                                (Value::Text("type".into()), Value::Text("public-key".into())),
                                (Value::Text("id".into()), Value::Bytes(id.clone())),
                            ])
                        })
                        .collect(),
                ),
            ));
        }
        cbor_encode(&Value::Map(entries))
    }
}

// ---------------------------------------------------------------------------
// In-memory KeyStore (test + bootstrap default — real one lives in store::bw_api).
// ---------------------------------------------------------------------------

/// A trivial in-memory keystore, for tests and as a sane bootstrap default
/// before the BwClient adapter is wired up. Indexed by (rp_id, credential_id).
#[derive(Default)]
pub struct InMemoryKeyStore {
    creds: BTreeMap<(String, Vec<u8>), PasskeyCredential>,
}

impl InMemoryKeyStore {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl KeyStore for InMemoryKeyStore {
    fn lookup_credential(&self, rp_id: &str, credential_id: &[u8]) -> Option<&PasskeyCredential> {
        self.creds.get(&(rp_id.to_string(), credential_id.to_vec()))
    }

    fn list_credentials(&self, rp_id: &str) -> Vec<&PasskeyCredential> {
        self.creds
            .iter()
            .filter(|((r, _), _)| r == rp_id)
            .map(|(_, v)| v)
            .collect()
    }

    fn store_new_credential(&mut self, cred: PasskeyCredential) -> Result<(), KeyStoreError> {
        let key = (cred.rp_id.clone(), cred.credential_id.clone());
        if self.creds.contains_key(&key) {
            return Err(KeyStoreError("duplicate credential_id".into()));
        }
        self.creds.insert(key, cred);
        Ok(())
    }

    fn increment_counter(&mut self, credential_id: &[u8]) -> Result<u32, KeyStoreError> {
        for ((_, id), cred) in self.creds.iter_mut() {
            if id == credential_id {
                cred.counter = cred.counter.wrapping_add(1);
                return Ok(cred.counter);
            }
        }
        Err(KeyStoreError("credential not found".into()))
    }
}

/// Always-allow user-presence stub for tests.
pub struct AlwaysAllowPresence;

#[async_trait]
impl UserPresenceProvider for AlwaysAllowPresence {
    async fn request_presence(&self, _rp_id: &str, _action: &str) -> Result<bool, BrokerError> {
        Ok(true)
    }
}

/// Always-deny stub.
pub struct AlwaysDenyPresence;

#[async_trait]
impl UserPresenceProvider for AlwaysDenyPresence {
    async fn request_presence(&self, _rp_id: &str, _action: &str) -> Result<bool, BrokerError> {
        Ok(false)
    }
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use ecdsa::signature::Verifier;
    use p256::ecdsa::Signature as P256Sig;

    fn synthetic_make_cred_req(rp: &str) -> MakeCredentialReq {
        MakeCredentialReq {
            client_data_hash: vec![0xAB; 32],
            rp_id: rp.to_string(),
            rp_name: Some("Example".into()),
            user_id: vec![1, 2, 3, 4, 5, 6, 7, 8],
            user_name: "alice@example.test".into(),
            user_display_name: "Alice".into(),
            pub_key_cred_params: vec![PubKeyCredParam {
                alg: SUPPORTED_ALG_ES256,
                typ: "public-key".into(),
            }],
        }
    }

    #[test]
    fn aaguid_derivation_is_stable() {
        let a = derive_aaguid(b"machine-1", "vault-account-x");
        let b = derive_aaguid(b"machine-1", "vault-account-x");
        let c = derive_aaguid(b"machine-2", "vault-account-x");
        let d = derive_aaguid(b"machine-1", "vault-account-y");

        assert_eq!(a, b, "same inputs must produce same AAGUID");
        assert_ne!(a, c, "different machine must change AAGUID");
        assert_ne!(a, d, "different account must change AAGUID");

        // RFC 4122 v4 shape.
        assert_eq!(a[6] & 0xF0, 0x40, "version nibble must be 4");
        assert_eq!(a[8] & 0xC0, 0x80, "variant bits must be 10xx");
    }

    #[test]
    fn cose_pubkey_encoding() {
        let secret = SecretKey::random(&mut OsRng);
        let sk = SigningKey::from(secret);
        let vk = VerifyingKey::from(&sk);
        let encoded = cose_encode_p256_pubkey(&vk).unwrap();
        let (x, y) = cose_decode_p256_pubkey(&encoded).unwrap();

        let point = vk.to_encoded_point(false);
        assert_eq!(x, point.x().unwrap().as_slice().to_vec());
        assert_eq!(y, point.y().unwrap().as_slice().to_vec());
        // P-256 affine coords are 32 bytes each.
        assert_eq!(x.len(), 32);
        assert_eq!(y.len(), 32);
    }

    #[tokio::test]
    async fn getinfo_encodes_correctly() {
        let aaguid = derive_aaguid(b"machine-test", "user@example.test");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let resp = auth.handle_command(CMD_GET_INFO, &[]).await;
        assert!(!resp.is_empty());
        assert_eq!(resp[0], CTAP2_OK, "status byte");

        let body: Value = ciborium::de::from_reader(&resp[1..]).expect("cbor decode");
        let map = as_map(&body).unwrap();

        let versions = as_array(map_get(map, 1).unwrap()).unwrap();
        assert_eq!(versions.len(), 2);
        assert!(matches!(&versions[0], Value::Text(s) if s == "FIDO_2_0"));
        assert!(matches!(&versions[1], Value::Text(s) if s == "FIDO_2_1"));

        let aaguid_back = as_bstr(map_get(map, 3).unwrap()).unwrap();
        assert_eq!(aaguid_back, &aaguid[..]);

        let max_msg = match map_get(map, 5).unwrap() {
            Value::Integer(i) => {
                let n: i128 = (*i).into();
                n
            }
            _ => panic!("maxMsgSize not int"),
        };
        assert_eq!(max_msg, 1200);

        let algs = as_array(map_get(map, 0x0A).unwrap()).unwrap();
        assert_eq!(algs.len(), 1);
        let alg_map = as_map(&algs[0]).unwrap();
        let alg = match map_get_text(alg_map, "alg").unwrap() {
            Value::Integer(i) => {
                let n: i128 = (*i).into();
                n
            }
            _ => panic!("alg not int"),
        };
        assert_eq!(alg, -7);
    }

    #[test]
    fn make_credential_round_trip() {
        let req = synthetic_make_cred_req("example.test");
        let blob = req.encode().unwrap();
        let back = MakeCredentialReq::decode(&blob).unwrap();
        assert_eq!(back.rp_id, req.rp_id);
        assert_eq!(back.user_id, req.user_id);
        assert_eq!(back.user_name, req.user_name);
        assert_eq!(back.client_data_hash, req.client_data_hash);
        assert_eq!(back.pub_key_cred_params.len(), 1);
        assert_eq!(back.pub_key_cred_params[0].alg, -7);
    }

    #[tokio::test]
    async fn make_credential_full_pipeline() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let req = synthetic_make_cred_req("example.test");
        let blob = req.encode().unwrap();
        let resp = auth.handle_command(CMD_MAKE_CREDENTIAL, &blob).await;
        assert_eq!(resp[0], CTAP2_OK, "got status byte {:#x}", resp[0]);

        // Parse the response, sanity-check structure.
        let body: Value = ciborium::de::from_reader(&resp[1..]).expect("cbor");
        let map = as_map(&body).unwrap();
        // 1 = fmt = "none"
        assert!(matches!(map_get(map, 1).unwrap(), Value::Text(s) if s == "none"));
        // 2 = authData = bstr, must start with rpIdHash (32) + flags + counter
        let auth_data = as_bstr(map_get(map, 2).unwrap()).unwrap();
        assert!(auth_data.len() >= 37 + 16 + 2);
        let rp_hash_expected = Sha256::digest(b"example.test");
        assert_eq!(&auth_data[..32], rp_hash_expected.as_slice());
        // flags: AT|UV|UP = 0x45
        assert_eq!(auth_data[32], FLAG_AT | FLAG_UV | FLAG_UP);
        // counter = 0 (BE).
        assert_eq!(&auth_data[33..37], &[0, 0, 0, 0]);
        // attested data: aaguid match.
        assert_eq!(&auth_data[37..53], &aaguid[..]);
    }

    #[tokio::test]
    async fn make_credential_user_presence_denied() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysDenyPresence),
        );
        let req = synthetic_make_cred_req("example.test");
        let resp = auth
            .handle_command(CMD_MAKE_CREDENTIAL, &req.encode().unwrap())
            .await;
        assert_eq!(resp.len(), 1);
        assert_eq!(resp[0], CTAP2_ERR_OPERATION_DENIED);
    }

    #[tokio::test]
    async fn make_credential_unsupported_alg() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let mut req = synthetic_make_cred_req("example.test");
        req.pub_key_cred_params = vec![PubKeyCredParam {
            alg: -257, // RS256, unsupported.
            typ: "public-key".into(),
        }];
        let resp = auth
            .handle_command(CMD_MAKE_CREDENTIAL, &req.encode().unwrap())
            .await;
        assert_eq!(resp[0], CTAP2_ERR_UNSUPPORTED_ALGORITHM);
    }

    #[tokio::test]
    async fn get_assertion_signature_verifies() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        // Register first.
        let req = synthetic_make_cred_req("example.test");
        let mc_resp = auth
            .handle_command(CMD_MAKE_CREDENTIAL, &req.encode().unwrap())
            .await;
        assert_eq!(mc_resp[0], CTAP2_OK);

        let mc_body: Value = ciborium::de::from_reader(&mc_resp[1..]).unwrap();
        let mc_map = as_map(&mc_body).unwrap();
        let auth_data = as_bstr(map_get(mc_map, 2).unwrap()).unwrap();
        // Extract credential_id from attested data.
        let cred_id_len = u16::from_be_bytes([auth_data[53], auth_data[54]]) as usize;
        let cred_id_start = 55;
        let cred_id_end = cred_id_start + cred_id_len;
        let credential_id = auth_data[cred_id_start..cred_id_end].to_vec();
        let cose_pub = &auth_data[cred_id_end..];

        // Decode COSE pubkey to get x/y, then rebuild VerifyingKey.
        let (x, y) = cose_decode_p256_pubkey(cose_pub).unwrap();
        let mut sec1 = vec![0x04];
        sec1.extend_from_slice(&x);
        sec1.extend_from_slice(&y);
        let vk = VerifyingKey::from_sec1_bytes(&sec1).unwrap();

        // Now do GetAssertion.
        let client_data_hash = vec![0xCDu8; 32];
        let ga = GetAssertionReq {
            rp_id: "example.test".to_string(),
            client_data_hash: client_data_hash.clone(),
            allow_list: vec![credential_id.clone()],
        };
        let ga_blob = ga.encode().unwrap();
        let ga_resp = auth.handle_command(CMD_GET_ASSERTION, &ga_blob).await;
        assert_eq!(ga_resp[0], CTAP2_OK, "got {:#x}", ga_resp[0]);

        let ga_body: Value = ciborium::de::from_reader(&ga_resp[1..]).unwrap();
        let ga_map = as_map(&ga_body).unwrap();
        let assertion_auth_data = as_bstr(map_get(ga_map, 2).unwrap()).unwrap();
        let sig_bytes = as_bstr(map_get(ga_map, 3).unwrap()).unwrap();

        // Sign-verify: signature is over authData || clientDataHash.
        let mut to_verify = Vec::new();
        to_verify.extend_from_slice(assertion_auth_data);
        to_verify.extend_from_slice(&client_data_hash);
        let sig = P256Sig::from_der(sig_bytes).expect("der sig");
        vk.verify(&to_verify, &sig).expect("signature verifies");

        // Counter must have incremented to 1.
        let counter = u32::from_be_bytes([
            assertion_auth_data[33],
            assertion_auth_data[34],
            assertion_auth_data[35],
            assertion_auth_data[36],
        ]);
        assert_eq!(counter, 1);
        // Flags must NOT include AT for assertion.
        assert_eq!(assertion_auth_data[32], FLAG_UV | FLAG_UP);
    }

    #[tokio::test]
    async fn get_assertion_no_credentials() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let ga = GetAssertionReq {
            rp_id: "ghost.test".into(),
            client_data_hash: vec![0; 32],
            allow_list: vec![],
        };
        let resp = auth
            .handle_command(CMD_GET_ASSERTION, &ga.encode().unwrap())
            .await;
        assert_eq!(resp.len(), 1);
        assert_eq!(resp[0], CTAP2_ERR_NO_CREDENTIALS);
    }

    #[tokio::test]
    async fn reset_is_rejected() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let resp = auth.handle_command(CMD_RESET, &[]).await;
        assert_eq!(resp, vec![CTAP2_ERR_NOT_ALLOWED]);
    }

    #[tokio::test]
    async fn client_pin_get_retries() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        // Build subCommand=0x07 (getRetries).
        let payload = cbor_encode(&Value::Map(vec![(
            Value::Integer(2u32.into()),
            Value::Integer(0x07u32.into()),
        )]))
        .unwrap();
        let resp = auth.handle_command(CMD_CLIENT_PIN, &payload).await;
        assert_eq!(resp[0], CTAP2_OK);
        let body: Value = ciborium::de::from_reader(&resp[1..]).unwrap();
        let map = as_map(&body).unwrap();
        let retries = match map_get(map, 3).unwrap() {
            Value::Integer(i) => {
                let n: i128 = (*i).into();
                n
            }
            _ => panic!("retries not int"),
        };
        assert_eq!(retries, 0xFFFFFFFFi128);
    }

    #[tokio::test]
    async fn client_pin_get_key_agreement() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let payload = cbor_encode(&Value::Map(vec![(
            Value::Integer(2u32.into()),
            Value::Integer(0x02u32.into()),
        )]))
        .unwrap();
        let resp = auth.handle_command(CMD_CLIENT_PIN, &payload).await;
        assert_eq!(resp[0], CTAP2_OK);
        let body: Value = ciborium::de::from_reader(&resp[1..]).unwrap();
        let map = as_map(&body).unwrap();
        let ka = map_get(map, 1).expect("keyAgreement key");
        // It must itself be a COSE_Key map.
        let inner = as_map(ka).unwrap();
        // kty (1) = 2, alg (3) = -7.
        let kty = match map_get(inner, 1).unwrap() {
            Value::Integer(i) => {
                let n: i128 = (*i).into();
                n
            }
            _ => panic!("kty"),
        };
        let alg = match map_get(inner, 3).unwrap() {
            Value::Integer(i) => {
                let n: i128 = (*i).into();
                n
            }
            _ => panic!("alg"),
        };
        assert_eq!(kty, 2);
        assert_eq!(alg, -7);
    }

    #[tokio::test]
    async fn client_pin_unknown_subcommand_rejected() {
        let aaguid = derive_aaguid(b"m", "u");
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let payload = cbor_encode(&Value::Map(vec![(
            Value::Integer(2u32.into()),
            Value::Integer(0x42u32.into()),
        )]))
        .unwrap();
        let resp = auth.handle_command(CMD_CLIENT_PIN, &payload).await;
        assert_eq!(resp.len(), 1);
        assert_eq!(resp[0], CTAP2_ERR_INVALID_OPTION);
    }

    #[test]
    fn unknown_command_rejected() {
        let aaguid = derive_aaguid(b"m", "u");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let mut auth = Authenticator::new(
            aaguid,
            Box::new(InMemoryKeyStore::new()),
            Box::new(AlwaysAllowPresence),
        );
        let resp = rt.block_on(auth.handle_command(0xFF, &[]));
        assert_eq!(resp, vec![CTAP1_ERR_INVALID_COMMAND]);
    }
}
