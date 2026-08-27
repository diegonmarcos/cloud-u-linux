//! Configuration loader.
//!
//! Two layers, merged at startup:
//!   1. Compile-time defaults from this crate.
//!   2. `$XDG_CONFIG_HOME/fido2-vault-broker/config.toml` (per-user override).
//!
//! `build.json` is the deploy-time source of truth — its values are
//! propagated into `default_*` constants by the home-manager flake at
//! build time. For now the defaults are inlined; flip to compile-time
//! include when the HM module lands.

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// XDG ProjectDirs qualifier/organization/application triple.
/// Generic — operator may override `org` via env var if forking.
const XDG_QUALIFIER: &str = "org";
const XDG_ORGANIZATION: &str = "fido2-vault-broker";
const XDG_APPLICATION: &str = "fido2-vault-broker";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Bitwarden API endpoint (Vaultwarden URL).
    /// No default — operator MUST set in user config.toml.
    #[serde(default = "default_endpoint")]
    pub vault_endpoint: String,

    /// Vault account identifier (email used to log into the vault).
    /// Required at runtime, no default.
    #[serde(default)]
    pub vault_email: String,

    /// Sealed blob path — default `$XDG_DATA_HOME/fido2-vault-broker/sealed.bin`.
    #[serde(default = "default_sealed_path")]
    pub sealed_path: PathBuf,

    /// TPM-sealed master password blob path —
    /// default `$XDG_DATA_HOME/fido2-vault-broker/master.tpm-sealed`.
    /// Created by `build.sh seal-master`. When this file exists the daemon
    /// unseals it via `tpm_seal::unseal_from_path` and the operator never
    /// has to set `FVB_MASTER_PASSWORD` in the environment.
    #[serde(default = "default_master_blob_path")]
    pub master_blob_path: PathBuf,

    /// `/dev/uhid` path. Override only for tests.
    #[serde(default = "default_uhid_path")]
    pub uhid_path: PathBuf,
}

fn default_endpoint() -> String {
    // No default in public source. Operator MUST set vault_endpoint in
    // ~/.config/fido2-vault-broker/config.toml.
    String::new()
}

fn default_sealed_path() -> PathBuf {
    if let Some(dirs) = ProjectDirs::from(XDG_QUALIFIER, XDG_ORGANIZATION, XDG_APPLICATION) {
        dirs.data_dir().join("sealed.bin")
    } else {
        PathBuf::from("/tmp/fido2-vault-broker-sealed.bin")
    }
}

fn default_master_blob_path() -> PathBuf {
    if let Some(dirs) = ProjectDirs::from(XDG_QUALIFIER, XDG_ORGANIZATION, XDG_APPLICATION) {
        dirs.data_dir().join("master.tpm-sealed")
    } else {
        PathBuf::from("/tmp/fido2-vault-broker-master.tpm-sealed")
    }
}

fn default_uhid_path() -> PathBuf {
    PathBuf::from("/dev/uhid")
}

impl Default for Config {
    fn default() -> Self {
        Self {
            vault_endpoint: default_endpoint(),
            vault_email: String::new(),
            sealed_path: default_sealed_path(),
            master_blob_path: default_master_blob_path(),
            uhid_path: default_uhid_path(),
        }
    }
}

impl Config {
    /// Resolve the user-config path. Doesn't read it.
    pub fn user_config_path() -> Option<PathBuf> {
        ProjectDirs::from(XDG_QUALIFIER, XDG_ORGANIZATION, XDG_APPLICATION)
            .map(|d| d.config_dir().join("config.toml"))
    }

    /// Load config: defaults overlaid with the user TOML if present.
    pub fn load() -> crate::Result<Self> {
        let mut cfg = Self::default();
        if let Some(path) = Self::user_config_path() {
            if path.exists() {
                let raw = std::fs::read_to_string(&path)?;
                let parsed: Config = toml::from_str(&raw)
                    .map_err(|e| crate::BrokerError::Config(format!("{path:?}: {e}")))?;
                cfg = parsed;
            }
        }
        Ok(cfg)
    }
}
