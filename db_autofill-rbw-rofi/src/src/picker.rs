//! Thin wrapper around an external dmenu-style picker (rofi/wofi).
//!
//! `pick(items, prompt) -> Option<usize>` spawns the picker, writes
//! `\n`-joined items to stdin, reads one line of stdout, and returns
//! the matching index. None on cancel/EOF.

use anyhow::{Context, Result};
use std::fmt::Display;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

/// Picker command + args, e.g. `["wofi", "--dmenu", "--prompt", "Vault"]`.
#[derive(Debug, Clone)]
pub struct PickerCmd(pub Vec<String>);

impl PickerCmd {
    pub fn from_argv(argv: Vec<String>) -> Self {
        Self(argv)
    }
}

/// Pick one item from `items`. Returns the index or None on cancel.
///
/// `prompt_override`, if Some, replaces the last positional flag-value of
/// the command (best-effort) — but the caller is normally expected to
/// have baked the prompt into the picker argv from build.json.
pub async fn pick<T: Display>(
    cmd: &PickerCmd,
    items: &[T],
    _prompt: &str,
) -> Result<Option<usize>> {
    if items.is_empty() {
        return Ok(None);
    }
    let argv = &cmd.0;
    if argv.is_empty() {
        anyhow::bail!("picker command is empty");
    }

    let mut child = Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .with_context(|| format!("spawn picker `{}`", argv.join(" ")))?;

    // Build the input string from item displays.
    let mut input = String::new();
    let displays: Vec<String> = items.iter().map(|i| i.to_string()).collect();
    for (i, d) in displays.iter().enumerate() {
        if i > 0 {
            input.push('\n');
        }
        input.push_str(d);
    }
    input.push('\n');

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(input.as_bytes())
            .await
            .context("write picker stdin")?;
        // Drop -> close stdin so picker can render.
    }

    let out = child
        .wait_with_output()
        .await
        .context("await picker exit")?;

    // dmenu/rofi/wofi convention: cancel => non-zero exit, empty stdout.
    if !out.status.success() {
        return Ok(None);
    }
    let raw = String::from_utf8_lossy(&out.stdout);
    let chosen = raw.lines().next().unwrap_or("").trim_end_matches('\n');
    if chosen.is_empty() {
        return Ok(None);
    }

    // First exact match by display string.
    if let Some(idx) = displays.iter().position(|d| d == chosen) {
        return Ok(Some(idx));
    }
    // Fuzzy fallback: first display that starts with the picked string,
    // useful if the picker is configured to print the typed query rather
    // than the highlighted entry.
    if let Some(idx) = displays.iter().position(|d| d.starts_with(chosen)) {
        return Ok(Some(idx));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;
    use tempfile::TempDir;

    /// Write a shim script into `dir` and chmod +x. Returns the script
    /// path. We deliberately use a fresh File that is dropped (and thus
    /// closed) before the path is handed back, otherwise Linux rejects
    /// exec'ing a still-open-for-write file with ETXTBSY (os error 26).
    fn write_shim(dir: &TempDir, name: &str, body: &[u8]) -> PathBuf {
        let path = dir.path().join(name);
        {
            let mut f = std::fs::File::create(&path).expect("create shim");
            f.write_all(body).expect("write shim");
            f.flush().expect("flush shim");
        } // file handle drops here, closing the write FD
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut p = std::fs::metadata(&path).unwrap().permissions();
            p.set_mode(0o755);
            std::fs::set_permissions(&path, p).unwrap();
        }
        path
    }

    /// Picker that echoes its first stdin line. Stand-in for rofi/wofi.
    fn fake_picker_first_line(dir: &TempDir) -> PathBuf {
        write_shim(
            dir,
            "picker_first_line",
            b"#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' \"$line\"\n",
        )
    }

    /// Picker that always exits non-zero with empty stdout (= cancel).
    fn fake_picker_cancel(dir: &TempDir) -> PathBuf {
        write_shim(dir, "picker_cancel", b"#!/bin/sh\nexit 1\n")
    }

    #[tokio::test(flavor = "current_thread")]
    async fn picks_first_item_via_fake_dmenu() {
        let dir = TempDir::new().unwrap();
        let fake = fake_picker_first_line(&dir);
        let cmd = PickerCmd(vec![fake.to_string_lossy().into_owned()]);
        let items = vec!["Alpha", "Bravo", "Charlie"];
        let idx = pick(&cmd, &items, "p").await.unwrap();
        assert_eq!(idx, Some(0));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancel_returns_none() {
        let dir = TempDir::new().unwrap();
        let fake = fake_picker_cancel(&dir);
        let cmd = PickerCmd(vec![fake.to_string_lossy().into_owned()]);
        let items = vec!["A", "B"];
        let idx = pick(&cmd, &items, "p").await.unwrap();
        assert_eq!(idx, None);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn empty_items_returns_none() {
        let dir = TempDir::new().unwrap();
        let fake = fake_picker_first_line(&dir);
        let cmd = PickerCmd(vec![fake.to_string_lossy().into_owned()]);
        let items: Vec<&str> = vec![];
        let idx = pick(&cmd, &items, "p").await.unwrap();
        assert_eq!(idx, None);
    }
}
