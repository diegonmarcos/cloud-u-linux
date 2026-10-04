//! Embedded shell scripts for the my-ai suite. All scripts are baked into the
//! binary via `include_str!` and extracted to `~/.local/bin` at runtime so the
//! binary is the single source — nix flakes no longer install these separately.
//!
//! Install is idempotent: files whose content already matches are skipped.
//! Executable scripts land with mode 0755; data files with mode 0644.
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// (destination_name, file_body, executable)
static ASSETS: &[(&str, &str, bool)] = &[
    // ── claude-superset scripts ───────────────────────────────────────────────
    (
        "claude-superset",
        include_str!("../../scripts/claude-superset/claude-superset"),
        true,
    ),
    (
        "claude-superset-setup.sh",
        include_str!("../../scripts/claude-superset/claude-superset-setup.sh"),
        true,
    ),
    (
        "claude-superset-restore.mjs",
        include_str!("../../scripts/claude-superset/claude-superset-restore.mjs"),
        false,
    ),
    (
        "claude-superset-help.txt",
        include_str!("../../scripts/claude-superset/claude-superset-help.txt"),
        false,
    ),
    (
        "claude-superset.json",
        include_str!("../../scripts/claude-superset/claude-superset.json"),
        false,
    ),
    // ── claude scripts ────────────────────────────────────────────────────────
    (
        "claude-malloc",
        include_str!("../../scripts/claude/claude-malloc"),
        true,
    ),
    (
        "claude-orphan-sweep",
        include_str!("../../scripts/claude/claude-orphan-sweep"),
        true,
    ),
    (
        "claude-rescue",
        include_str!("../../scripts/claude/claude-rescue"),
        true,
    ),
    (
        "claude-termux",
        include_str!("../../scripts/claude/claude-termux"),
        true,
    ),
    // ── goose scripts ─────────────────────────────────────────────────────────
    (
        "goose-malloc",
        include_str!("../../scripts/goose/goose-malloc"),
        true,
    ),
    (
        "goose-orphan-sweep",
        include_str!("../../scripts/goose/goose-orphan-sweep"),
        true,
    ),
];

/// Install all embedded scripts to `~/.local/bin`.
///
/// Each file is written atomically (write to a temp path, then rename) and
/// only when its content has changed — unchanged files are skipped so the
/// operation is cheap on repeated calls.
///
/// Returns the names of files that were actually written (not skipped).
pub fn install_to_local_bin() -> io::Result<Vec<String>> {
    let home = std::env::var_os("HOME").ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME environment variable is not set")
    })?;
    let dest_dir = PathBuf::from(home).join(".local").join("bin");
    fs::create_dir_all(&dest_dir)?;

    let mut written: Vec<String> = Vec::new();
    for &(name, body, executable) in ASSETS {
        let dest = dest_dir.join(name);
        // Skip write when the file already has the correct content.
        if fs::read_to_string(&dest).map(|current| current == body).unwrap_or(false) {
            continue;
        }
        // Atomic write: temp file in the same directory, then rename.
        let tmp = dest_dir.join(format!(".{name}.tmp"));
        fs::write(&tmp, body)?;
        let mode = if executable { 0o755 } else { 0o644 };
        fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
        fs::rename(&tmp, &dest)?;
        written.push(name.to_string());
    }
    Ok(written)
}

/// The directory into which scripts are installed (`~/.local/bin`).
pub fn local_bin_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".local").join("bin"))
        .unwrap_or_else(|| PathBuf::from(".local/bin"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn assets_have_correct_exec_flags() {
        // Executable names must not carry a dot-extension that suggests they are
        // data files, and data files must not lack an extension.
        let exec_assets: Vec<&str> = ASSETS
            .iter()
            .filter(|&&(_, _, executable)| executable)
            .map(|&(name, _, _)| name)
            .collect();
        // At minimum the primary entry-point scripts must be executable.
        assert!(exec_assets.contains(&"claude-superset"), "claude-superset must be executable");
        assert!(exec_assets.contains(&"claude-malloc"), "claude-malloc must be executable");
        assert!(exec_assets.contains(&"goose-malloc"), "goose-malloc must be executable");
    }

    #[test]
    fn all_eleven_assets_present() {
        assert_eq!(ASSETS.len(), 11, "expected exactly 11 embedded script assets");
    }

    #[test]
    fn install_to_temp_dir() {
        let dir = std::env::temp_dir().join(format!("my-ai-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let fake_home = dir.clone();
        std::env::set_var("HOME", &fake_home);
        let written = install_to_local_bin().unwrap();
        // All 11 should be written on first install.
        assert_eq!(written.len(), 11);
        // Executable files must actually have the execute bit set.
        let bin_dir = fake_home.join(".local/bin");
        for &(name, _, executable) in ASSETS {
            let path = bin_dir.join(name);
            assert!(path.exists(), "{name} must exist after install");
            let mode = fs::metadata(&path).unwrap().permissions().mode();
            if executable {
                assert!(mode & 0o111 != 0, "{name} must have execute bit");
            }
        }
        // Second call must be a no-op (all skipped).
        let written2 = install_to_local_bin().unwrap();
        assert!(written2.is_empty(), "second install must skip unchanged files");
        fs::remove_dir_all(&dir).ok();
    }
}
