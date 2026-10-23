//! Engine registry: my-ai is an orchestrator of routines ("engines").
//!
//! Every `engines/<name>/` folder carries a `manifest.json` (name, trigger,
//! inputs, outputs, run). The manifests are embedded here so the installed
//! binary can list and run engines without a checkout. Adding an engine means
//! adding its folder AND one line to `REGISTRY`; the unit test below and
//! `data/claude/test-claude-sot.sh` fail if either is missing.
use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, Deserialize, Clone)]
pub struct Run {
    /// `builtin` (Rust fn in the CLI), `embedded` (script baked into the
    /// binary), `checkout` (command relative to the da_my-ai checkout).
    pub kind: String,
    pub target: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Manifest {
    pub name: String,
    pub description: String,
    /// `daemon-start` | `timer` | `on-demand`
    pub trigger: String,
    pub inputs: Vec<String>,
    pub outputs: Vec<String>,
    pub run: Run,
}

pub const TRIGGERS: &[&str] = &["daemon-start", "timer", "on-demand"];

/// (folder name, manifest.json body)
pub const REGISTRY: &[(&str, &str)] = &[
    ("statusline-assets", include_str!("../../engines/statusline-assets/manifest.json")),
    ("scripts-assets", include_str!("../../engines/scripts-assets/manifest.json")),
    ("usage", include_str!("../../engines/usage/manifest.json")),
    ("dash", include_str!("../../engines/dash/manifest.json")),
    ("tray", include_str!("../../engines/tray/manifest.json")),
    ("claude-config", include_str!("../../engines/claude-config/manifest.json")),
    ("mcp-templates", include_str!("../../engines/mcp-templates/manifest.json")),
    ("dotfiles", include_str!("../../engines/dotfiles/manifest.json")),
];

/// (engine, script file name, body) for `run.kind == "embedded"`.
const EMBEDDED: &[(&str, &str, &str)] = &[(
    "dotfiles",
    "deploy-dotfiles.sh",
    include_str!("../../engines/dotfiles/deploy-dotfiles.sh"),
)];

pub fn list() -> Vec<Manifest> {
    REGISTRY
        .iter()
        .map(|(n, m)| serde_json::from_str(m).unwrap_or_else(|e| panic!("engine {n}: bad manifest: {e}")))
        .collect()
}

pub fn find(name: &str) -> Option<Manifest> {
    list().into_iter().find(|m| m.name == name)
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

fn state_file(name: &str) -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state"));
    base.join("my-ai/engines").join(format!("{name}.last"))
}

/// Record a run as `<unix-secs> <exit-code>`.
pub fn record_run(name: &str, code: i32) {
    let p = state_file(name);
    if let Some(d) = p.parent() {
        let _ = fs::create_dir_all(d);
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let _ = fs::write(p, format!("{now} {code}\n"));
}

/// Last recorded run, `(unix-secs, exit-code)`.
pub fn last_run(name: &str) -> Option<(u64, i32)> {
    let s = fs::read_to_string(state_file(name)).ok()?;
    let mut it = s.split_whitespace();
    Some((it.next()?.parse().ok()?, it.next()?.parse().ok()?))
}

/// Root of the da_my-ai checkout for `checkout` engines.
pub fn checkout_root() -> PathBuf {
    if let Some(p) = std::env::var_os("MY_AI_SRC") {
        return PathBuf::from(p);
    }
    let git = std::env::var_os("GIT_BASE").map(PathBuf::from).unwrap_or_else(|| home().join("git"));
    git.join("cloud-u-linux/da_my-ai")
}

/// Run a non-builtin engine; returns its exit code.
pub fn run_external(m: &Manifest, args: &[String]) -> Result<i32> {
    let status = match m.run.kind.as_str() {
        "embedded" => {
            let body = EMBEDDED
                .iter()
                .find(|(n, f, _)| *n == m.name && *f == m.run.target)
                .map(|(_, _, b)| *b)
                .ok_or_else(|| anyhow!("engine {}: no embedded script {}", m.name, m.run.target))?;
            let dir = std::env::var_os("XDG_CACHE_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home().join(".cache"))
                .join("my-ai/engines")
                .join(&m.name);
            fs::create_dir_all(&dir).with_context(|| format!("mkdir {}", dir.display()))?;
            let path = dir.join(&m.run.target);
            if fs::read_to_string(&path).ok().as_deref() != Some(body) {
                fs::write(&path, body)?;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
            }
            Command::new("sh").arg(&path).args(args).status()?
        }
        "checkout" => {
            let root = checkout_root();
            let mut parts = m.run.target.split_whitespace();
            let prog = parts.next().ok_or_else(|| anyhow!("engine {}: empty target", m.name))?;
            let script = root.join(prog);
            if !script.exists() {
                return Err(anyhow!("engine {}: {} not found (set MY_AI_SRC to the da_my-ai checkout)", m.name, script.display()));
            }
            Command::new("bash").arg(&script).args(parts).args(args).current_dir(&root).status()?
        }
        k => return Err(anyhow!("engine {}: kind {k} is not external", m.name)),
    };
    Ok(status.code().unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifests_parse_and_are_sane() {
        for m in list() {
            assert!(TRIGGERS.contains(&m.trigger.as_str()), "{}: trigger {}", m.name, m.trigger);
            assert!(["builtin", "embedded", "checkout"].contains(&m.run.kind.as_str()), "{}", m.name);
            assert!(!m.inputs.is_empty() && !m.outputs.is_empty(), "{}", m.name);
        }
    }

    #[test]
    fn every_engine_folder_has_a_registered_manifest() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../engines");
        for e in fs::read_dir(&root).unwrap() {
            let e = e.unwrap();
            if !e.file_type().unwrap().is_dir() {
                continue;
            }
            let name = e.file_name().to_string_lossy().into_owned();
            assert!(e.path().join("manifest.json").is_file(), "engines/{name}: manifest.json missing");
            assert!(e.path().join("README.md").is_file(), "engines/{name}: README.md missing");
            let m = find(&name).unwrap_or_else(|| panic!("engines/{name}: not in REGISTRY"));
            assert_eq!(m.name, name);
        }
        for (n, _) in REGISTRY {
            assert!(root.join(n).is_dir(), "REGISTRY entry {n} has no folder");
        }
    }
}
