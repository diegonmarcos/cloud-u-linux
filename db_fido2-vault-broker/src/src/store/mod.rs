//! Persistent + in-memory secret stores.
//!
//! - `tpm_seal` — seal/unseal bytes against the local TPM2 chip
//!   (or a machine-id-derived AES-GCM mock if the `tpm` feature is off;
//!   PoC convenience for CI).
//! - `bw_api` — Bitwarden REST client (stubbed; Phase B.5).

pub mod bw_api;
pub mod bw_keystore;
pub mod tpm_seal;
