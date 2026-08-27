//! Type a string into the focused window via `wtype` (Wayland) or `xdotool` (X11).
//!
//! All text is fed through *stdin*, never through argv, so secrets never appear
//! in `/proc/<pid>/cmdline` or `ps -ef` output. The buffer is zeroized after
//! the typer subprocess exits.
//!
//! Public API
//! ----------
//!   pub async fn type_secret(s: &SecretString, display: Display, opts: &TyperOpts) -> Result<()>
//!   pub async fn type_plain (s: &str,         display: Display, opts: &TyperOpts) -> Result<()>
//!   pub async fn type_tab   (display: Display, opts: &TyperOpts) -> Result<()>
//!
//! Inter-key delay
//! ---------------
//! If the env var named by `TyperOpts::slow_env_var` (default
//! `DA_AUTOFILL_RBW_ROFI_SLOW`) is set to `"1"`, an inter-key delay flag is
//! added (`-d <ms>` for `wtype`, `--delay <ms>` for `xdotool`). Both name
//! and ms come from `build.json` via `TyperOpts`.
//!
//! Tests
//! -----
//! Four unit tests use fake-PATH binaries (`wtype` / `xdotool` shim shell
//! scripts) that record their argv and stdin into a tempfile, then assert on
//! the recorded contents. No secret data is used — all test inputs are
//! synthetic placeholders.

use anyhow::{Context, Result};
use secrecy::{ExposeSecret, SecretString};
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use zeroize::Zeroize;

use crate::env::Display;

/// Per-call typer options. Sourced from `build.json` by main.rs and threaded
/// through every typer call so this module never reaches into `Config`.
#[derive(Debug, Clone)]
pub struct TyperOpts {
    /// Env var name that, when set to "1", enables slow typing. Default in
    /// build.json: `DA_AUTOFILL_RBW_ROFI_SLOW`.
    pub slow_env_var: String,
    /// Inter-key delay in ms when slow typing is on.
    pub slow_delay_ms: u64,
}

impl TyperOpts {
    fn slow_enabled(&self) -> bool {
        std::env::var(&self.slow_env_var)
            .map(|v| v == "1")
            .unwrap_or(false)
    }
}

/// Type a secret string. The buffer is zeroized after typing.
pub async fn type_secret(s: &SecretString, display: Display, opts: &TyperOpts) -> Result<()> {
    let mut buf = s.expose_secret().to_string();
    let res = type_via_stdin(&buf, display, opts).await;
    buf.zeroize();
    res
}

/// Type plain (non-sensitive) text, e.g. a username. No zeroize needed but
/// we still feed via stdin so all callers go through one code path.
pub async fn type_plain(s: &str, display: Display, opts: &TyperOpts) -> Result<()> {
    type_via_stdin(s, display, opts).await
}

/// Send a single Tab key to the focused window.
pub async fn type_tab(display: Display, _opts: &TyperOpts) -> Result<()> {
    // _opts is accepted for API symmetry; Tab does not need a delay flag.
    let (bin, args): (&str, Vec<&str>) = match display {
        Display::Wayland => ("wtype", vec!["-k", "Tab"]),
        Display::X11 => ("xdotool", vec!["key", "Tab"]),
    };
    let status = Command::new(bin)
        .args(&args)
        .stdin(Stdio::null())
        .status()
        .await
        .with_context(|| format!("spawn {bin} for Tab"))?;
    if !status.success() {
        anyhow::bail!("{bin} (Tab) exited with {status}");
    }
    Ok(())
}

/// Internal: spawn the appropriate per-display typer with stdin = `text`.
async fn type_via_stdin(text: &str, display: Display, opts: &TyperOpts) -> Result<()> {
    let slow = opts.slow_enabled();
    let delay = opts.slow_delay_ms.to_string();

    let (bin, args): (&str, Vec<String>) = match display {
        Display::Wayland => {
            // wtype reads stdin when given `-`. With `-d N` it adds N ms
            // between keystrokes.
            let mut a: Vec<String> = Vec::new();
            if slow {
                a.push("-d".into());
                a.push(delay.clone());
            }
            a.push("-".into());
            ("wtype", a)
        }
        Display::X11 => {
            // `xdotool type --clearmodifiers --file -` reads from stdin.
            let mut a: Vec<String> = vec!["type".into(), "--clearmodifiers".into()];
            if slow {
                a.push("--delay".into());
                a.push(delay.clone());
            }
            a.push("--file".into());
            a.push("-".into());
            ("xdotool", a)
        }
    };

    let mut child = Command::new(bin)
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("spawn {bin}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(text.as_bytes())
            .await
            .with_context(|| format!("write to {bin} stdin"))?;
        // Drop the handle to close stdin; the typer will then process the
        // buffered text and exit.
    }

    let status = child.wait().await.with_context(|| format!("await {bin}"))?;
    if !status.success() {
        anyhow::bail!("{bin} exited with {status}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use tempfile::TempDir;

    /// Synthetic test opts. The slow-env-var name matches the production
    /// default so tests exercise the same code path; tests that don't want
    /// slow mode just `remove_var` it before running.
    fn opts() -> TyperOpts {
        TyperOpts {
            slow_env_var: "DA_AUTOFILL_RBW_ROFI_SLOW".into(),
            slow_delay_ms: 5,
        }
    }

    /// Build a temp PATH dir containing two shim scripts named `wtype` and
    /// `xdotool`. Each shim records its argv and stdin to `<dir>/record.log`
    /// (argv on first line, then a blank separator, then stdin).
    ///
    /// Returns (TempDir, original_path) — caller must restore PATH on drop.
    fn make_shim_path() -> (TempDir, PathBuf) {
        let dir = TempDir::new().expect("tempdir");
        let log = dir.path().join("record.log");
        let log_str = log.to_string_lossy().into_owned();

        // Each shim writes argv to log, then appends "---" + stdin.
        // We deliberately write into one shared log so the test can read
        // exactly one invocation per test (each test makes one call).
        let script = format!(
            "#!/bin/sh\n\
             {{\n\
               printf 'BIN=%s\\n' \"$(basename \"$0\")\"\n\
               for a in \"$@\"; do printf 'ARG=%s\\n' \"$a\"; done\n\
               printf -- '---STDIN---\\n'\n\
               cat\n\
             }} >> '{log}'\n\
             exit 0\n",
            log = log_str,
        );

        for name in ["wtype", "xdotool"] {
            let p = dir.path().join(name);
            let mut f = std::fs::File::create(&p).expect("create shim");
            f.write_all(script.as_bytes()).expect("write shim");
            let mut perms = std::fs::metadata(&p).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&p, perms).expect("chmod shim");
        }

        let original = std::env::var_os("PATH").unwrap_or_default();
        let mut new_path = std::ffi::OsString::from(dir.path());
        new_path.push(":");
        new_path.push(&original);
        // SAFETY: tests in this module run serially under one tokio
        // current-thread runtime; race against other tests in the same
        // process is what `serial_test`-style isolation would prevent.
        // Cargo runs them on separate threads by default — so each test
        // creates its own tempdir + sets PATH per-test, but PATH is
        // process-global. To avoid cross-test interference we serialize
        // via a Mutex (see TEST_LOCK below).
        std::env::set_var("PATH", &new_path);
        (dir, PathBuf::from(original))
    }

    fn restore_path(original: &std::path::Path) {
        std::env::set_var("PATH", original);
    }

    fn read_log(dir: &TempDir) -> String {
        let log = dir.path().join("record.log");
        std::fs::read_to_string(&log).unwrap_or_default()
    }

    // PATH is process-global. Rather than coordinating four parallel test
    // tasks via a Mutex (which can't be held across .await with std::sync,
    // and would require enabling tokio's `sync` feature), we collapse the
    // four logical sub-tests into one `#[tokio::test]` that runs them
    // sequentially. Each scenario is self-contained: it sets PATH +
    // env vars, makes one typer call, asserts on the recording log, and
    // restores PATH before the next scenario starts.

    async fn scenario_wayland_secret_via_stdin_no_argv_leak() {
        let o = opts();
        std::env::remove_var(&o.slow_env_var);
        let (dir, orig) = make_shim_path();

        let secret = SecretString::new("placeholder-secret-1".to_string());
        type_secret(&secret, Display::Wayland, &o)
            .await
            .expect("type_secret should succeed under fake wtype");

        let log = read_log(&dir);
        restore_path(&orig);

        assert!(log.contains("BIN=wtype"), "expected wtype shim, got: {log}");
        assert!(log.contains("ARG=-"), "expected '-' arg for stdin mode");
        // Secret must NOT appear in any ARG= line — only after the stdin
        // separator. This is the security invariant of the module.
        for line in log.lines() {
            if let Some(rest) = line.strip_prefix("ARG=") {
                assert!(
                    !rest.contains("placeholder-secret-1"),
                    "secret leaked into argv: {line}"
                );
            }
        }
        assert!(
            log.contains("placeholder-secret-1"),
            "secret should appear after ---STDIN--- separator"
        );
        let after = log.split("---STDIN---").nth(1).unwrap_or("");
        assert!(after.contains("placeholder-secret-1"));
    }

    async fn scenario_x11_plain_uses_xdotool_with_clearmodifiers() {
        let o = opts();
        std::env::remove_var(&o.slow_env_var);
        let (dir, orig) = make_shim_path();

        type_plain("user@example.test", Display::X11, &o)
            .await
            .expect("type_plain should succeed under fake xdotool");

        let log = read_log(&dir);
        restore_path(&orig);

        assert!(log.contains("BIN=xdotool"), "expected xdotool, got: {log}");
        assert!(log.contains("ARG=type"));
        assert!(log.contains("ARG=--clearmodifiers"));
        assert!(log.contains("ARG=--file"));
        assert!(log.contains("ARG=-"));
        // Plain text appears after the stdin separator
        let after = log.split("---STDIN---").nth(1).unwrap_or("");
        assert!(after.contains("user@example.test"));
    }

    async fn scenario_slow_env_adds_delay_flag_per_display() {
        let o = opts();
        std::env::set_var(&o.slow_env_var, "1");
        let (dir, orig) = make_shim_path();

        // Wayland path: `-d 5`
        type_plain("hello", Display::Wayland, &o).await.unwrap();
        // X11 path: `--delay 5`
        type_plain("hello", Display::X11, &o).await.unwrap();

        let log = read_log(&dir);
        std::env::remove_var(&o.slow_env_var);
        restore_path(&orig);

        assert!(log.contains("ARG=-d"), "wayland missing -d delay flag");
        assert!(log.contains("ARG=--delay"), "x11 missing --delay flag");
        assert!(log.contains("ARG=5"), "missing 5 ms delay value");
    }

    async fn scenario_tab_uses_correct_keysym_per_display() {
        let o = opts();
        std::env::remove_var(&o.slow_env_var);
        let (dir, orig) = make_shim_path();

        type_tab(Display::Wayland, &o).await.unwrap();
        type_tab(Display::X11, &o).await.unwrap();

        let log = read_log(&dir);
        restore_path(&orig);

        // Wayland: wtype -k Tab
        assert!(log.contains("BIN=wtype"));
        assert!(log.contains("ARG=-k"));
        // X11: xdotool key Tab
        assert!(log.contains("BIN=xdotool"));
        assert!(log.contains("ARG=key"));
        assert!(log.contains("ARG=Tab"));
    }

    /// Runs all four scenarios sequentially in one tokio runtime. This
    /// keeps PATH manipulation safe without any cross-thread synchronisation.
    #[tokio::test(flavor = "current_thread")]
    async fn typer_argv_recording_scenarios() {
        scenario_wayland_secret_via_stdin_no_argv_leak().await;
        scenario_x11_plain_uses_xdotool_with_clearmodifiers().await;
        scenario_slow_env_adds_delay_flag_per_display().await;
        scenario_tab_uses_correct_keysym_per_display().await;
    }
}
