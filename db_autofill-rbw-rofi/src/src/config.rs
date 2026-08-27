//! Parse the project's `build.json` at runtime so the binary stays
//! data-driven. Only the `runtime` section matters at run time; the
//! `build` and `paths` sections are for the build engine.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub project: Project,
    pub runtime: Runtime,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Project {
    pub name: String,
    pub version: String,
    // Mirrored from build.json for diagnostics / future --version output.
    // Not consumed by the orchestrator yet; kept on the struct so the
    // serde model stays one-to-one with build.json.
    #[allow(dead_code)]
    #[serde(default)]
    pub description: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Runtime {
    pub picker: PerDisplay,
    pub typer: PerDisplay,
    pub clipboard: PerDisplay,
    #[serde(default = "default_notifier")]
    pub notifier: String,
    pub rbw: RbwConfig,
    pub actions: Vec<String>,
    pub default_action: String,
    #[serde(default = "default_totp_clip_secs")]
    pub totp_to_clipboard_seconds: u64,
    #[serde(default = "default_slow_env")]
    pub slow_typing_env_var: String,
    #[serde(default = "default_slow_delay")]
    pub slow_typing_delay_ms: u64,
}

fn default_notifier() -> String {
    "notify-send".into()
}
fn default_totp_clip_secs() -> u64 {
    20
}
fn default_slow_env() -> String {
    "DA_AUTOFILL_RBW_ROFI_SLOW".into()
}
fn default_slow_delay() -> u64 {
    8
}

#[derive(Debug, Clone, Deserialize)]
pub struct PerDisplay {
    pub wayland: String,
    pub x11: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RbwConfig {
    pub list_cmd: String,
    pub get_cmd: String,
    pub user_field: String,
    pub totp_cmd: String,
    #[serde(default = "default_rbw_timeout")]
    pub timeout_secs: u64,
}

fn default_rbw_timeout() -> u64 {
    5
}

impl Config {
    /// Load build.json by walking up from `start` until found, or fall
    /// back to a list of well-known install locations.
    pub fn load() -> Result<Self> {
        let path = Self::locate()
            .context("could not locate build.json (set DA_AUTOFILL_RBW_ROFI_CONFIG to override)")?;
        Self::load_from(&path)
    }

    pub fn load_from(path: &Path) -> Result<Self> {
        let raw =
            std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        let cfg: Config =
            serde_json::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
        Ok(cfg)
    }

    fn locate() -> Result<PathBuf> {
        if let Ok(p) = std::env::var("DA_AUTOFILL_RBW_ROFI_CONFIG") {
            return Ok(PathBuf::from(p));
        }
        // Walk up from CWD looking for build.json
        let cwd = std::env::current_dir()?;
        let mut cur: Option<&Path> = Some(&cwd);
        while let Some(dir) = cur {
            let candidate = dir.join("build.json");
            if candidate.exists() {
                return Ok(candidate);
            }
            cur = dir.parent();
        }
        // Walk up from the binary
        if let Ok(exe) = std::env::current_exe() {
            let mut cur: Option<&Path> = exe.parent();
            while let Some(dir) = cur {
                let candidate = dir.join("build.json");
                if candidate.exists() {
                    return Ok(candidate);
                }
                cur = dir.parent();
            }
        }
        // Common install location: $XDG_CONFIG_HOME/da_autofill-rbw-rofi/build.json
        if let Some(cfg_dir) = std::env::var_os("XDG_CONFIG_HOME") {
            let p = PathBuf::from(cfg_dir).join("da_autofill-rbw-rofi/build.json");
            if p.exists() {
                return Ok(p);
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            let p = PathBuf::from(home).join(".config/da_autofill-rbw-rofi/build.json");
            if p.exists() {
                return Ok(p);
            }
        }
        anyhow::bail!("no build.json found in CWD/exe ancestors or $XDG_CONFIG_HOME");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
    {
      "project": { "name": "x", "version": "0.0.0" },
      "runtime": {
        "picker":    { "wayland": "wofi --dmenu", "x11": "rofi -dmenu" },
        "typer":     { "wayland": "wtype",       "x11": "xdotool type --clearmodifiers" },
        "clipboard": { "wayland": "wl-copy",     "x11": "xclip -selection clipboard -in" },
        "rbw": {
          "list_cmd":   "rbw list --fields name,user",
          "get_cmd":    "rbw get",
          "user_field": "--field user",
          "totp_cmd":   "rbw code"
        },
        "actions": ["user","pass","totp","user_tab_pass"],
        "default_action": "user_tab_pass"
      }
    }
    "#;

    #[test]
    fn parse_minimal() {
        let cfg: Config = serde_json::from_str(SAMPLE).unwrap();
        assert_eq!(cfg.project.name, "x");
        assert_eq!(cfg.runtime.actions.len(), 4);
        assert_eq!(cfg.runtime.totp_to_clipboard_seconds, 20);
        assert_eq!(cfg.runtime.rbw.timeout_secs, 5);
        assert_eq!(cfg.runtime.notifier, "notify-send");
    }
}
