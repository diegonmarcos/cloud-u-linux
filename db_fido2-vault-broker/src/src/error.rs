//! Crate-wide error type. Thin `thiserror` enum; everything else uses `anyhow`
//! at the binary boundary.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum BrokerError {
    #[error("TPM2 device unavailable or inaccessible: {0}")]
    TpmUnavailable(String),

    #[error("sealed blob format invalid: {0}")]
    SealFormat(String),

    #[error("config error: {0}")]
    Config(String),

    #[error("vault API error: {0}")]
    Vault(String),

    #[error("vault HTTP error: {0}")]
    VaultHttp(String),

    #[error("vault auth error: {0}")]
    VaultAuth(String),

    #[error("vault crypto error: {0}")]
    VaultCrypto(String),

    #[error("vault decode error: {0}")]
    VaultDecode(String),

    #[error("ctap2 not yet implemented (Phase B.3)")]
    Ctap2NotImplemented,

    #[error("ctap2 protocol error: {0}")]
    Ctap2(String),

    #[error("ctap2 cbor decode error: {0}")]
    Ctap2Cbor(String),

    #[error("ctap2 user-presence denied")]
    Ctap2UserPresenceDenied,

    #[error("ctap2 keystore error: {0}")]
    Ctap2KeyStore(String),

    #[error("uhid not yet implemented (Phase B.4)")]
    UhidNotImplemented,

    #[error("uhid transport error: {0}")]
    Uhid(String),

    #[error("user-presence prompt error: {0}")]
    UserPresence(String),

    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("other: {0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, BrokerError>;
