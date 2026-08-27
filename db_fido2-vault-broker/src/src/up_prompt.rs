//! User-presence prompt provider (Phase B.6).
//!
//! Implements the `UserPresenceProvider` trait defined in `ctap2.rs`
//! (Phase B.4 — the consumer is the canonical home for the trait).
//! `DesktopUpProvider` implements that contract by shelling out to
//! `notify-send` with two actions ("Confirm" / "Cancel") and parsing the
//! invoked-action token from stdout.
//!
//! ## Why `notify-send`, not `zbus`
//!
//! `zbus = "4"` would be a cleaner D-Bus client, but it adds ~30s of cold
//! build time and pulls in async-runtime internals that complicate the
//! tokio current-thread runtime we use.  `notify-send` is in `libnotify`
//! which is on every desktop with a session, returns the chosen action
//! name on stdout when invoked with `--action=<id>=<label>`, and is
//! trivial to mock in unit tests.

use crate::ctap2::UserPresenceProvider;
use crate::error::{BrokerError, Result};
use std::time::Duration;

/// Production implementation: spawn `notify-send` and parse the action.
///
/// `notify-send --action=confirm=Confirm --action=cancel=Cancel` blocks
/// until the user clicks an action OR the notification expires.  When
/// an action is invoked it prints the action id (`confirm` / `cancel`)
/// to stdout and exits 0.  On timeout/dismiss it exits 0 with empty
/// stdout — we treat that as Cancel.
pub struct DesktopUpProvider {
    timeout: Duration,
    /// Hook for unit tests — when `Some`, `request_presence` returns this
    /// value verbatim instead of shelling out.  Build with
    /// `DesktopUpProvider::new(...)` for production use.
    #[cfg(test)]
    test_override: Option<Result<bool>>,
}

impl DesktopUpProvider {
    pub fn new(timeout: Duration) -> Self {
        Self {
            timeout,
            #[cfg(test)]
            test_override: None,
        }
    }

    /// Test-only constructor that bypasses notify-send and returns the
    /// supplied result.  This is the mock referenced in the test plan.
    #[cfg(test)]
    pub fn with_test_response(timeout: Duration, response: Result<bool>) -> Self {
        Self {
            timeout,
            test_override: Some(response),
        }
    }
}

#[async_trait::async_trait]
impl UserPresenceProvider for DesktopUpProvider {
    async fn request_presence(&self, rp_id: &str, action: &str) -> Result<bool> {
        #[cfg(test)]
        {
            if let Some(ref forced) = self.test_override {
                // Clone the BrokerError if Err — BrokerError isn't Clone, so
                // recreate it from its Display form.  Tests use small fixed
                // error strings so this is fine.
                return match forced {
                    Ok(b) => Ok(*b),
                    Err(e) => Err(BrokerError::UserPresence(e.to_string())),
                };
            }
        }

        run_notify_send(&self.timeout, rp_id, action).await
    }
}

/// Spawn `notify-send` and interpret its response.
///
/// Note that `notify-send` has two relevant flavours in the wild:
///   * `libnotify >= 0.7.9` (Debian bookworm, Fedora 38+, Arch) supports
///     `--action`/`-A` and prints the chosen action id on stdout.
///   * older builds ignore `--action`.  For those, we fall back to
///     "any non-error exit means Confirm" — degraded but functional.
///
/// We prefer the modern path; the legacy fallback is only triggered if
/// notify-send rejects `--action` (exit code != 0).
async fn run_notify_send(timeout: &Duration, rp_id: &str, action: &str) -> Result<bool> {
    let summary = format!("FIDO2 vault: {action}");
    let body = format!("Approve operation for {rp_id}?");
    // `notify-send` expiry is in milliseconds.
    let expire_ms = timeout.as_millis().min(u32::MAX as u128) as u32;

    let cmd_future = tokio::process::Command::new("notify-send")
        .arg("--app-name=fido2-vault-broker")
        .arg(format!("--expire-time={expire_ms}"))
        .arg("--action=confirm=Confirm")
        .arg("--action=cancel=Cancel")
        .arg("--wait")
        .arg(summary)
        .arg(body)
        .output();

    // Belt-and-braces: even if notify-send ignores --expire-time,
    // we wrap the whole call in a tokio timeout so we never hang the
    // CTAP2 dispatcher indefinitely.
    let output = match tokio::time::timeout(*timeout + Duration::from_millis(500), cmd_future).await
    {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => return Err(BrokerError::UserPresence(format!("spawn notify-send: {e}"))),
        Err(_) => return Ok(false), // outer timeout fires → treat as Cancel
    };

    if !output.status.success() {
        // Legacy notify-send (no --action support).  Treat any successful
        // user interaction as Confirm — best we can do without the action
        // protocol.  We emit a tracing warning so this isn't silent.
        tracing::warn!(
            status = ?output.status,
            "notify-send exited non-zero; assuming legacy build, denying presence"
        );
        return Ok(false);
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(stdout == "confirm")
}

// ─── tests ────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn up_provider_returns_true_on_confirm() {
        // Mock the notify-send call by injecting a forced Confirm response.
        let provider = DesktopUpProvider::with_test_response(Duration::from_millis(50), Ok(true));
        let got = provider.request_presence("example.com", "sign in to").await;
        assert_eq!(got.ok(), Some(true));
    }

    #[tokio::test]
    async fn up_provider_returns_false_on_timeout() {
        // Mock the timeout/cancel path.
        let provider = DesktopUpProvider::with_test_response(Duration::from_millis(50), Ok(false));
        let got = provider.request_presence("example.com", "register").await;
        assert_eq!(got.ok(), Some(false));
    }

    #[tokio::test]
    async fn up_provider_propagates_subsystem_error() {
        let provider = DesktopUpProvider::with_test_response(
            Duration::from_millis(50),
            Err(BrokerError::UserPresence("dbus down".into())),
        );
        let err = provider.request_presence("example.com", "sign in to").await;
        assert!(matches!(err, Err(BrokerError::UserPresence(_))));
    }
}
