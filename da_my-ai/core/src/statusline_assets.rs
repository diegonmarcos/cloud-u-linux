//! The status line's assets, owned by this binary rather than by the flake.
//!
//! WHY THIS EXISTS
//!
//! These files used to be `home.file` entries in ba_flakes_desktop. That split
//! ownership of one feature across two release cadences: the `05h-T` label was a
//! Rust format string needing a full GHA round-trip, while the `All-S` and
//! `05h-S` labels next to it were a file copy. Worse, the daemon shells out to
//! `claude-mcp-status.sh` and friends to build `.blocks` — an undeclared runtime
//! dependency on files a *different* component shipped, where upgrading one
//! without the other leaves `.blocks` silently empty and every session quietly
//! goes back to spawning five scripts per render.
//!
//! So the binary carries them. `install()` writes them out, and the daemon calls
//! it at startup, which makes the dependency self-healing: whatever `my-ai` is
//! running is guaranteed to be running against the assets that shipped with it.
//! The flake keeps exactly one thing — `settings.json`, which decides WHERE the
//! status line appears. This file decides WHAT it is.
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// (destination filename, contents, executable)
const ASSETS: &[(&str, &str, bool)] = &[
    ("statusline-command.sh", include_str!("../../src/data/statusline/statusline-command.sh"), true),
    ("claude-mcp-status.sh", include_str!("../../src/data/statusline/claude-mcp-status.sh"), true),
    ("claude-plugins-status.sh", include_str!("../../src/data/statusline/claude-plugins-status.sh"), true),
    ("claude-hooks-status.sh", include_str!("../../src/data/statusline/claude-hooks-status.sh"), true),
    ("claude-flags-status.sh", include_str!("../../src/data/statusline/claude-flags-status.sh"), true),
    ("claude-pricing.json", include_str!("../../src/data/pricing.json"), false),
];

/// Where the assets are installed (`~/.claude`, or `$CLAUDE_CONFIG_DIR`).
pub fn claude_dir() -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".claude")))
        .unwrap_or_else(|| PathBuf::from(".claude"))
}

/// Write every asset whose content differs from what is already on disk.
///
/// Returns the names actually written. Content-compared rather than
/// unconditionally overwritten: this runs on every daemon start, and rewriting
/// a status line script that N sessions are executing right now is worth
/// avoiding when nothing changed.
pub fn install(dir: &Path) -> io::Result<Vec<String>> {
    fs::create_dir_all(dir)?;
    let mut written = Vec::new();
    for (name, body, exec) in ASSETS {
        let dest = dir.join(name);
        // A home-manager generation leaves these as read-only symlinks into the
        // store. Compare through the link, but always replace the link itself —
        // writing through it would try to modify the store.
        if fs::read_to_string(&dest).map(|cur| cur == *body).unwrap_or(false) && !dest.is_symlink() {
            continue;
        }
        // Write-temp + rename: a session painting right now reads the old file
        // or the new one, never a half-written script.
        let tmp = dir.join(format!(".{name}.tmp"));
        fs::write(&tmp, body)?;
        if *exec {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755))?;
            }
        }
        let _ = fs::remove_file(&dest);
        fs::rename(&tmp, &dest)?;
        written.push((*name).to_string());
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_writes_then_is_idempotent() {
        let dir = std::env::temp_dir().join(format!("my-ai-assets-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);

        let first = install(&dir).unwrap();
        assert_eq!(first.len(), ASSETS.len(), "first install must write everything");

        // Second run changes nothing: the daemon calls this on every start, and
        // rewriting scripts that live sessions are executing is not free.
        let second = install(&dir).unwrap();
        assert!(second.is_empty(), "re-install rewrote unchanged files: {second:?}");

        // Drifted file is repaired.
        fs::write(dir.join("claude-pricing.json"), "{}").unwrap();
        let third = install(&dir).unwrap();
        assert_eq!(third, vec!["claude-pricing.json".to_string()]);

        // Scripts must land executable, or the status line silently loses rows.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let m = fs::metadata(dir.join("statusline-command.sh")).unwrap();
            assert_eq!(m.permissions().mode() & 0o111, 0o111);
        }

        fs::remove_dir_all(&dir).unwrap();
    }
}
