//! Thin wrapper around the local `rbw` CLI. We never link rbw as a
//! library — the agent already runs on the user's box. Loose coupling
//! also means the user can swap rbw for a fork without rebuilding us.

use anyhow::{anyhow, Context, Result};
use secrecy::{ExposeSecret, SecretString};
use std::time::Duration;
use thiserror::Error;
use tokio::process::Command;
use tokio::time::timeout;

use crate::config::RbwConfig;
use crate::env::shell_split;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultEntry {
    /// The rbw `name` (display name of the cipher)
    pub name: String,
    /// rbw `user` field — may be empty if the cipher has no username
    pub username: String,
}

impl VaultEntry {
    pub fn display(&self) -> String {
        if self.username.is_empty() {
            self.name.clone()
        } else {
            format!("{}  ({})", self.name, self.username)
        }
    }
}

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("rbw is locked or not configured — run `rbw unlock` and retry")]
    Locked,
    #[error("rbw command timed out after {0}s")]
    Timeout(u64),
    #[error("rbw failed (exit {code}): {stderr}")]
    Failed { code: i32, stderr: String },
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub struct Vault {
    cfg: RbwConfig,
}

impl Vault {
    pub fn new(cfg: RbwConfig) -> Self {
        Self { cfg }
    }

    pub async fn list(&self) -> Result<Vec<VaultEntry>, VaultError> {
        let out = self.run(&self.cfg.list_cmd, &[]).await?;
        Ok(parse_rbw_list_output(&out))
    }

    pub async fn get_password(&self, name: &str) -> Result<SecretString, VaultError> {
        let out = self.run(&self.cfg.get_cmd, &[name]).await?;
        Ok(SecretString::new(out.trim_end_matches('\n').to_string()))
    }

    pub async fn get_username(&self, name: &str) -> Result<String, VaultError> {
        // user_field is e.g. "--field user" — splits into 2 argv tokens.
        let mut argv: Vec<String> = shell_split(&self.cfg.user_field);
        argv.push(name.to_string());
        let argv_refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
        let out = self.run(&self.cfg.get_cmd, &argv_refs).await?;
        Ok(out.trim_end_matches('\n').to_string())
    }

    pub async fn get_totp(&self, name: &str) -> Result<SecretString, VaultError> {
        let out = self.run(&self.cfg.totp_cmd, &[name]).await?;
        Ok(SecretString::new(out.trim_end_matches('\n').to_string()))
    }

    /// Generic runner. `cmd_str` may itself contain space-separated args
    /// (e.g. "rbw list --fields name,user"); `extra_args` are appended
    /// verbatim.
    async fn run(&self, cmd_str: &str, extra_args: &[&str]) -> Result<String, VaultError> {
        let mut argv = shell_split(cmd_str);
        if argv.is_empty() {
            return Err(VaultError::Failed {
                code: -1,
                stderr: "empty rbw command in build.json".into(),
            });
        }
        let bin = argv.remove(0);
        let mut cmd = Command::new(&bin);
        cmd.args(&argv);
        for a in extra_args {
            cmd.arg(a);
        }
        cmd.stdin(std::process::Stdio::null());

        let timeout_secs = self.cfg.timeout_secs;
        let fut = cmd.output();
        let out = timeout(Duration::from_secs(timeout_secs), fut)
            .await
            .map_err(|_| VaultError::Timeout(timeout_secs))??;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            // rbw locked: stderr typically contains "agent" / "locked" / "not logged in"
            let lower = stderr.to_lowercase();
            if lower.contains("locked")
                || lower.contains("not logged in")
                || lower.contains("not configured")
                || lower.contains("agent")
            {
                return Err(VaultError::Locked);
            }
            return Err(VaultError::Failed {
                code: out.status.code().unwrap_or(-1),
                stderr,
            });
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

/// Helper so callers don't have to import secrecy. Kept on the public
/// surface for downstream callers that link this crate as a library; the
/// in-tree binary uses `secrecy::ExposeSecret` directly.
#[allow(dead_code)]
pub fn expose_secret_string(s: &SecretString) -> &str {
    s.expose_secret()
}

/// Parse `rbw list --fields name,user` output. Format is one entry per
/// line, fields tab-separated. A field can be empty.
///
/// We tolerate:
///   - missing trailing newline
///   - empty lines (skip)
///   - lines with fewer than 2 fields (treat user as empty)
pub fn parse_rbw_list_output(s: &str) -> Vec<VaultEntry> {
    s.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|line| {
            let mut parts = line.splitn(2, '\t');
            let name = parts.next().unwrap_or("").trim().to_string();
            let username = parts.next().unwrap_or("").trim().to_string();
            VaultEntry { name, username }
        })
        .filter(|e| !e.name.is_empty())
        .collect()
}

#[allow(dead_code)]
fn _unused_anyhow() -> Result<()> {
    // keep `anyhow` and `Context` referenced even if no caller uses them
    // directly within this module.
    Err(anyhow!("placeholder")).context("placeholder")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_two_field_lines() {
        let sample =
            "GitHub\tuser@example.test\nNetflix\tnetflix-acct@example.test\nNoUserCipher\t\n";
        let v = parse_rbw_list_output(sample);
        assert_eq!(v.len(), 3);
        assert_eq!(v[0].name, "GitHub");
        assert_eq!(v[0].username, "user@example.test");
        assert_eq!(v[1].name, "Netflix");
        assert_eq!(v[2].name, "NoUserCipher");
        assert_eq!(v[2].username, "");
    }

    #[test]
    fn parse_skips_blank_lines() {
        let sample = "\nGitHub\tdiego\n\n\nNetflix\tme\n";
        let v = parse_rbw_list_output(sample);
        assert_eq!(v.len(), 2);
    }

    #[test]
    fn parse_handles_missing_user_column() {
        let sample = "OnlyName\nAnother\tu\n";
        let v = parse_rbw_list_output(sample);
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].username, "");
        assert_eq!(v[1].username, "u");
    }

    #[test]
    fn display_with_and_without_username() {
        let a = VaultEntry {
            name: "A".into(),
            username: "u".into(),
        };
        assert_eq!(a.display(), "A  (u)");
        let b = VaultEntry {
            name: "B".into(),
            username: "".into(),
        };
        assert_eq!(b.display(), "B");
    }
}
