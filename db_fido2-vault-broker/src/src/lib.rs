//! fido2-vault-broker — library crate.
//!
//! Phase B.1 + B.2 only — TPM seal/unseal is real, the rest are stubs.
//! See `~/.claude/plans/da_browser-fido2-rbw-stack.md` for full plan.

pub mod config;
pub mod ctap2;
pub mod error;
pub mod store;
pub mod uhid_dev;
pub mod up_prompt;

pub use error::{BrokerError, Result};
