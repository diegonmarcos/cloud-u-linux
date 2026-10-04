//! Entrypoint — orchestrates picker -> vault -> typer.
//!
//! Flow:
//!   1. Init tracing
//!   2. Load `build.json` via [`config::Config::load`]
//!   3. Detect display server (Wayland | X11)
//!   4. List vault entries (rbw)
//!   5. Show entry picker -> selected entry
//!   6. Show action picker -> selected action (default = build.json default_action)
//!   7. Dispatch:
//!        - "user"          : type username
//!        - "pass"          : type password (zeroized after)
//!        - "totp"          : copy TOTP to clipboard, schedule clear after N seconds
//!        - "user_tab_pass" : user, Tab, pass
//!   8. Exit 0
//!
//! All control data — picker/typer/clipboard commands, action list, default
//! action, TOTP clipboard timeout, slow-typing env var name — comes from
//! `build.json` (loaded by `config.rs`). No values are hardcoded here.

use anyhow::{Context, Result};
use std::process::Stdio;
use tokio::process::Command;
use tokio::signal::unix::{signal, SignalKind};
use tracing_subscriber::EnvFilter;

mod config;
mod env;
mod picker;
mod typer;
mod vault;

use crate::config::Config;
use crate::env::{Display, DisplayCommands};
use crate::picker::{pick, PickerCmd};
use crate::typer::TyperOpts;
use crate::vault::{Vault, VaultEntry, VaultError};

/// Wrapper around a `VaultEntry` so the picker prints the human-readable
/// `display()` (name + username) without us needing to add a `Display` impl
/// to the public type (which would change its semantics for other callers).
struct EntryDisplay<'a>(&'a VaultEntry);
impl std::fmt::Display for EntryDisplay<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0.display())
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    // 1. Tracing first so any later error is captured.
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    // Install signal handlers. On SIGINT/SIGTERM we just exit 0 — the
    // current_thread runtime drops outstanding futures cleanly and the
    // child processes (picker / typer) propagate SIGHUP via stdin EOF.
    install_signal_handlers();

    // 2. Config from build.json
    let cfg = Config::load().context("load build.json")?;
    tracing::debug!(
        project = %cfg.project.name,
        version = %cfg.project.version,
        "config loaded"
    );

    // Build per-call typer opts from build.json — typer module never reads
    // `Config` itself, keeping it loosely coupled.
    let typer_opts = TyperOpts {
        slow_env_var: cfg.runtime.slow_typing_env_var.clone(),
        slow_delay_ms: cfg.runtime.slow_typing_delay_ms,
    };

    // 3. Display server
    let disp = Display::detect();
    let dc = DisplayCommands::from_config(&cfg, disp);
    tracing::debug!(?disp, "display detected");

    // 4. Vault list. If locked, notify and exit 0.
    let v = Vault::new(cfg.runtime.rbw.clone());
    let entries: Vec<VaultEntry> = match v.list().await {
        Ok(e) => e,
        Err(VaultError::Locked) => {
            notify_user(&cfg.runtime.notifier, "Vault locked — run `rbw unlock`").await;
            tracing::warn!("vault locked");
            return Ok(());
        }
        Err(e) => return Err(e).context("vault list"),
    };
    if entries.is_empty() {
        notify_user(&cfg.runtime.notifier, "Vault is empty — nothing to pick").await;
        return Ok(());
    }

    // 5. Entry picker
    let entry_picker = PickerCmd::from_argv(dc.picker.clone());
    let entry_views: Vec<EntryDisplay<'_>> = entries.iter().map(EntryDisplay).collect();
    let chosen_idx = match pick(&entry_picker, &entry_views, "Vault").await? {
        Some(i) => i,
        None => {
            tracing::debug!("entry pick cancelled");
            return Ok(());
        }
    };
    let chosen = &entries[chosen_idx];
    tracing::debug!(name = %chosen.name, "entry chosen");

    // 6. Action selection. The action list and default come from build.json.
    let actions: &[String] = &cfg.runtime.actions;
    if actions.is_empty() {
        anyhow::bail!("build.json runtime.actions is empty");
    }

    // An optional first positional arg lets a caller (e.g. a qutebrowser
    // keybinding) force a specific action and skip the interactive action
    // picker. No arg (or "pick") keeps the interactive flow.
    let requested = std::env::args().nth(1);
    let forced = resolve_requested_action(requested.as_deref(), actions)?;

    let action: String = match forced {
        Some(a) => {
            tracing::debug!(action = %a, "action forced via CLI arg (skipping action picker)");
            a
        }
        None => {
            // Default action comes first so the user can hit Enter on the
            // first line for the common case.
            let default_action = &cfg.runtime.default_action;
            let mut ordered: Vec<String> = Vec::with_capacity(actions.len());
            if let Some(d) = actions.iter().find(|a| *a == default_action) {
                ordered.push(d.clone());
            }
            for a in actions {
                if a != default_action {
                    ordered.push(a.clone());
                }
            }
            let action_picker = PickerCmd::from_argv(dc.picker.clone());
            match pick(&action_picker, &ordered, "Action").await? {
                Some(i) => ordered[i].clone(),
                None => {
                    tracing::debug!("action pick cancelled");
                    return Ok(());
                }
            }
        }
    };
    tracing::info!(action = %action, name = %chosen.name, "dispatching");

    // 7. Dispatch
    dispatch(&action, chosen, &v, disp, &dc, &cfg, &typer_opts).await?;

    Ok(())
}

/// Resolve the optional CLI action argument (the first positional arg).
///
/// This is what lets a qutebrowser keybinding (or any caller) target a
/// specific action without going through the second, interactive picker:
///
///   * `None` or `Some("pick")` → `Ok(None)` — show the interactive action
///     picker (the default `systemctl start` behaviour, unchanged).
///   * `Some(a)` where `a` is one of build.json `runtime.actions`
///     → `Ok(Some(a))` — dispatch that action directly.
///   * anything else → `Err` — unknown action, surfaced to the caller.
///
/// `pick` is a reserved meta-action meaning "ask me"; it is intentionally
/// NOT a member of `runtime.actions`.
fn resolve_requested_action(requested: Option<&str>, actions: &[String]) -> Result<Option<String>> {
    match requested {
        None | Some("pick") => Ok(None),
        Some(a) if actions.iter().any(|x| x == a) => Ok(Some(a.to_string())),
        Some(a) => {
            anyhow::bail!("unknown action {a:?} — valid: pick, {}", actions.join(", "))
        }
    }
}

async fn dispatch(
    action: &str,
    entry: &VaultEntry,
    vault: &Vault,
    display: Display,
    dc: &DisplayCommands,
    cfg: &Config,
    typer_opts: &TyperOpts,
) -> Result<()> {
    match action {
        "user" => {
            let u = vault
                .get_username(&entry.name)
                .await
                .context("get_username")?;
            typer::type_plain(&u, display, typer_opts)
                .await
                .context("type_plain user")?;
        }
        "pass" => {
            let p = vault
                .get_password(&entry.name)
                .await
                .context("get_password")?;
            typer::type_secret(&p, display, typer_opts)
                .await
                .context("type_secret pass")?;
        }
        "totp" => {
            let t = vault.get_totp(&entry.name).await.context("get_totp")?;
            copy_to_clipboard(&dc.clipboard, &t)
                .await
                .context("copy totp to clipboard")?;
            schedule_clipboard_clear(display, cfg.runtime.totp_to_clipboard_seconds)?;
            notify_user(
                &cfg.runtime.notifier,
                &format!(
                    "TOTP for {} copied — clears in {}s",
                    entry.name, cfg.runtime.totp_to_clipboard_seconds
                ),
            )
            .await;
        }
        "user_tab_pass" => {
            let u = vault
                .get_username(&entry.name)
                .await
                .context("get_username")?;
            typer::type_plain(&u, display, typer_opts)
                .await
                .context("type_plain user")?;
            typer::type_tab(display, typer_opts)
                .await
                .context("type_tab")?;
            let p = vault
                .get_password(&entry.name)
                .await
                .context("get_password")?;
            typer::type_secret(&p, display, typer_opts)
                .await
                .context("type_secret pass")?;
        }
        other => {
            anyhow::bail!("unknown action {other:?} — must be one of build.json runtime.actions");
        }
    }
    Ok(())
}

/// Copy a secret to the clipboard via the configured clipboard command
/// (e.g. `wl-copy` or `xclip -selection clipboard -in`). The secret is fed
/// through stdin to avoid leaking it in argv.
async fn copy_to_clipboard(argv: &[String], secret: &secrecy::SecretString) -> Result<()> {
    use secrecy::ExposeSecret;
    use tokio::io::AsyncWriteExt;
    if argv.is_empty() {
        anyhow::bail!("clipboard command is empty in build.json");
    }
    let mut child = Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("spawn clipboard `{}`", argv.join(" ")))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(secret.expose_secret().as_bytes())
            .await
            .context("write to clipboard stdin")?;
    }
    let status = child.wait().await.context("await clipboard")?;
    if !status.success() {
        anyhow::bail!("clipboard command exited with {status}");
    }
    Ok(())
}

/// Spawn a detached background process that sleeps for `secs` then clears
/// the clipboard. Uses `wl-copy --clear` on Wayland (best-effort) and an
/// empty piped `xclip -selection clipboard` on X11.
///
/// We `Command::spawn()` then drop the handle so the child is detached —
/// we do not await it, and the parent process exits normally.
fn schedule_clipboard_clear(display: Display, secs: u64) -> Result<()> {
    let cmd = match display {
        Display::Wayland => format!(
            "sleep {secs}; wl-copy --clear 2>/dev/null || (printf '' | xclip -selection clipboard -in 2>/dev/null) || true",
        ),
        Display::X11 => format!(
            "sleep {secs}; (printf '' | xclip -selection clipboard -in 2>/dev/null) || (wl-copy --clear 2>/dev/null) || true",
        ),
    };
    // Detach: spawn with closed std fds, then drop the handle. The child
    // outlives us because we never call .wait() / .kill().
    let _child = std::process::Command::new("bash")
        .arg("-c")
        .arg(&cmd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| "spawn clipboard-clear shell")?;
    // Intentionally drop without wait so the child is reaped by init.
    std::mem::drop(_child);
    Ok(())
}

/// Best-effort desktop notification. If the configured notifier (default
/// `notify-send`, set in `build.json::runtime.notifier`) is missing the call
/// is silently ignored — nothing else in the pipeline depends on it.
async fn notify_user(notifier: &str, msg: &str) {
    let _ = Command::new(notifier)
        .arg("da_autofill-rbw-rofi")
        .arg(msg)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await;
}

/// Spawn signal-handler tasks that exit the process gracefully on
/// SIGINT/SIGTERM. We don't try to roll back partially-typed text — the
/// OS-level keyboard input is not transactional.
fn install_signal_handlers() {
    tokio::spawn(async {
        if let Ok(mut s) = signal(SignalKind::interrupt()) {
            if s.recv().await.is_some() {
                tracing::info!("SIGINT — exiting");
                std::process::exit(0);
            }
        }
    });
    tokio::spawn(async {
        if let Ok(mut s) = signal(SignalKind::terminate()) {
            if s.recv().await.is_some() {
                tracing::info!("SIGTERM — exiting");
                std::process::exit(0);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_actions() -> Vec<String> {
        ["user", "pass", "totp", "user_tab_pass"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    #[test]
    fn no_arg_is_interactive() {
        // The default `systemctl start` path passes no arg → action picker.
        assert_eq!(
            resolve_requested_action(None, &sample_actions()).unwrap(),
            None
        );
    }

    #[test]
    fn pick_meta_action_is_interactive() {
        // The qutebrowser <Ctrl-Shift-p> binding passes "pick".
        assert_eq!(
            resolve_requested_action(Some("pick"), &sample_actions()).unwrap(),
            None
        );
    }

    #[test]
    fn known_action_is_forced() {
        // <Ctrl-Shift-{u,l,o}> pass user / pass / totp → skip the picker.
        for a in ["user", "pass", "totp", "user_tab_pass"] {
            assert_eq!(
                resolve_requested_action(Some(a), &sample_actions()).unwrap(),
                Some(a.to_string()),
                "action {a:?} should be forced"
            );
        }
    }

    #[test]
    fn unknown_action_errors() {
        let err = resolve_requested_action(Some("rm-rf"), &sample_actions()).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("unknown action"), "got: {msg}");
        // Error lists the valid choices so the operator can self-correct.
        assert!(msg.contains("pick"), "got: {msg}");
        assert!(msg.contains("user_tab_pass"), "got: {msg}");
    }
}
