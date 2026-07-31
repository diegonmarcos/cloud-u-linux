//! my-ai shared core — data-driven config, session discovery, and the
//! cross-device session-hub client. Faithful port of the data + logic in
//! claude-superset.json + claude-superset-restore.mjs.
use anyhow::{Context, Result};
use serde::{Deserialize, Deserializer};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub mod usage;

/// Endpoints are compiled in from src/data/endpoints.json (data-driven, single source).
pub const ENDPOINTS_JSON: &str = include_str!("../../src/data/endpoints.json");

#[derive(Debug, Clone, Deserialize)]
pub struct Ports {
    pub app: u16,
    pub ollama: u16,
    pub headroom: u16,
    #[serde(default)]
    /// my-ai-api has no transparent-proxy face (it routes OpenRouter directly),
    /// so `proxy` is optional; 0 = no proxy port. claude-superset-api keeps 8789.
    pub proxy: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LocalCfg {
    pub proxy: String,
    pub api: String,
    #[serde(default)]
    pub ollama: String,
    pub image: String,
    pub container_name: String,
    #[serde(default = "default_project")]
    pub project: String,
    pub volume: String,
    pub ports: Ports,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub max_concurrency: u32,
    #[serde(default)]
    pub call_timeout_ms: u64,
    #[serde(default)]
    pub savings_profile: String,
    #[serde(default)]
    pub min_tokens_to_compress: u32,
}
fn default_project() -> String {
    "my-ai-local".into()
}

#[derive(Debug, Clone, Deserialize)]
pub struct Setup {
    pub installer_url: String,
    pub channel: String,
    pub rescue_pkg: String,
}

/// One Claude Code context profile from `claude_profiles` in endpoints.json.
/// `tokens` is the session preload measured with `/context`; `measured` says
/// whether that number came off a real run or is derived from a known delta.
#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeProfile {
    #[serde(default)]
    pub tokens: u32,
    #[serde(default)]
    pub measured: bool,
    #[serde(default)]
    pub desc: String,
    /// Env vars exported before exec'ing `claude`. Empty = ship everything.
    #[serde(default)]
    pub flags: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Endpoints {
    pub proxy: String,
    pub api: String,
    pub ollama: String,
    pub dashboard: String,
    pub anthropic: String,
    /// goosed ACP agent server (goose serve, X-Secret-Key auth). Port 3227, WG-only.
    /// Secret: GOOSE_SERVER__SECRET_KEY env var (same key the container reads from sops).
    #[serde(default)]
    pub goosed: String,
    #[serde(default = "default_keep")]
    pub sync_keep: u32,
    #[serde(default)]
    pub mesh: BTreeMap<String, String>,
    #[serde(default)]
    pub public: BTreeMap<String, String>,
    #[serde(default)]
    pub mcps: BTreeMap<String, String>,
    #[serde(default)]
    pub image: String,
    pub setup: Setup,
    pub local: LocalCfg,
    #[serde(default, deserialize_with = "de_claude_profiles")]
    pub claude_profiles: BTreeMap<String, ClaudeProfile>,
}

/// Deserialize `claude_profiles`, keeping only entries whose value is a real
/// profile object. endpoints.json intentionally carries noise keys in this map
/// (`_comment` docs, `default: "<name>"` pointer) — those are strings, not
/// profiles, so drop them here rather than fail the whole parse. The CLI's
/// valid-names listing already skips `_`/`default` keys, so this keeps the
/// typed map in sync with that intent.
fn de_claude_profiles<'de, D>(d: D) -> std::result::Result<BTreeMap<String, ClaudeProfile>, D::Error>
where
    D: Deserializer<'de>,
{
    let raw: BTreeMap<String, serde_json::Value> = BTreeMap::deserialize(d)?;
    Ok(raw
        .into_iter()
        .filter_map(|(k, v)| serde_json::from_value::<ClaudeProfile>(v).ok().map(|p| (k, p)))
        .collect())
}
fn default_keep() -> u32 {
    20
}

pub fn endpoints() -> Result<Endpoints> {
    serde_json::from_str(ENDPOINTS_JSON).context("parse endpoints.json")
}

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

// ── paths / identity ─────────────────────────────────────────────────────────
pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}
pub fn projects_dir() -> PathBuf {
    home().join(".claude").join("projects")
}
/// $STORE from build.json's `runtime.store_subdir` (".local/share/my-ai") —
/// same path main.rs's local-face compose writer uses.
pub fn store_dir() -> PathBuf {
    home().join(".local/share/my-ai")
}
/// This device's id: CAS_DEVICE override, else hostname (matches restore.mjs).
pub fn device() -> String {
    std::env::var("CAS_DEVICE")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| gethostname::gethostname().to_string_lossy().into_owned())
}
/// Claude encodes a session's project dir as its cwd with every "/" → "-".
pub fn encode_cwd(cwd: &str) -> String {
    cwd.replace('/', "-")
}

// ── local session discovery ──────────────────────────────────────────────────
#[derive(Debug, Clone)]
pub struct SessionFile {
    pub id: String,
    pub file: PathBuf,
    pub mtime: u64, // ms since epoch
}

fn mtime_ms(p: &Path) -> u64 {
    fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// All local sessions, newest first (mirror of restore.mjs localSessions()).
pub fn local_sessions() -> Vec<SessionFile> {
    let mut out = Vec::new();
    let base = projects_dir();
    let dirs = match fs::read_dir(&base) {
        Ok(d) => d,
        Err(_) => return out,
    };
    for de in dirs.flatten() {
        let dir = de.path();
        if !dir.is_dir() {
            continue;
        }
        let names = match fs::read_dir(&dir) {
            Ok(n) => n,
            Err(_) => continue,
        };
        for f in names.flatten() {
            let p = f.path();
            if p.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let id = p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
            if id.is_empty() {
                continue;
            }
            out.push(SessionFile { id, mtime: mtime_ms(&p), file: p });
        }
    }
    out.sort_by(|a, b| b.mtime.cmp(&a.mtime));
    out
}

pub enum Selector {
    Count(u64),
    Hours(u64),
}
pub fn by_selector(list: Vec<SessionFile>, sel: &Selector) -> Vec<SessionFile> {
    match sel {
        Selector::Count(n) => list.into_iter().take(*n as usize).collect(),
        Selector::Hours(h) => {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let cutoff = now.saturating_sub(h * 3_600_000);
            list.into_iter().filter(|s| s.mtime >= cutoff).collect()
        }
    }
}

/// Pull (cwd, title) out of a session jsonl body — mirror of restore.mjs inspect().
/// title = customTitle → slug → aiTitle → first user prompt → id[:8], cleaned to 40.
pub fn inspect(text: &str, id: &str) -> (Option<String>, String) {
    let mut cwd = None;
    let mut custom = None;
    let mut slug = None;
    let mut ai = None;
    let mut first = None;
    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        let o: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if cwd.is_none() {
            if let Some(c) = o.get("cwd").and_then(|v| v.as_str()) {
                cwd = Some(c.to_string());
            }
        }
        if let Some(c) = o.get("customTitle").and_then(|v| v.as_str()) {
            custom = Some(c.to_string());
        }
        if let Some(a) = o.get("aiTitle").and_then(|v| v.as_str()) {
            ai = Some(a.to_string());
        }
        if slug.is_none() {
            if let Some(s) = o.get("slug").and_then(|v| v.as_str()) {
                slug = Some(s.to_string());
            }
        }
        if first.is_none() && o.get("type").and_then(|v| v.as_str()) == Some("user") {
            let content = o.get("message").and_then(|m| m.get("content"));
            let t = match content {
                Some(serde_json::Value::String(s)) => Some(s.clone()),
                Some(serde_json::Value::Array(arr)) => arr
                    .iter()
                    .find(|b| b.get("type").and_then(|v| v.as_str()) == Some("text"))
                    .and_then(|b| b.get("text").and_then(|v| v.as_str()))
                    .map(|s| s.to_string()),
                _ => None,
            };
            if let Some(t) = t {
                if !t.starts_with('<') {
                    first = Some(t);
                }
            }
        }
    }
    let id8: String = id.chars().take(8).collect();
    let raw = custom.or(slug).or(ai).or(first).unwrap_or_else(|| id8.clone());
    let cleaned: String = raw.replace(['\r', '\n', ';'], " ");
    let cleaned = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    let title: String = cleaned.chars().take(40).collect();
    let title = if title.trim().is_empty() { id8 } else { title };
    (cwd, title)
}

// ── cross-device session hub (GET/PUT /sessions) — mirror of restore.mjs ─────
#[derive(Debug, Clone, Deserialize)]
pub struct RemoteSession {
    pub device: String,
    pub id: String,
    #[serde(default)]
    pub mtime: u64,
}

pub struct Hub {
    base: String,
}
impl Hub {
    pub fn new(api: &str) -> Self {
        Hub { base: api.trim_end_matches('/').to_string() }
    }
    pub fn put_session(&self, device: &str, id: &str, body: &[u8]) -> Result<()> {
        ureq::put(&format!("{}/sessions/{}/{}", self.base, device, id))
            .set("content-type", "application/x-ndjson")
            .send_bytes(body)?;
        Ok(())
    }
    pub fn list(&self) -> Result<Vec<RemoteSession>> {
        Ok(ureq::get(&format!("{}/sessions", self.base)).call()?.into_json()?)
    }
    pub fn get_session(&self, device: &str, id: &str) -> Result<String> {
        Ok(ureq::get(&format!("{}/sessions/{}/{}", self.base, device, id))
            .call()?
            .into_string()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endpoints_parse() {
        let e = endpoints().expect("endpoints.json must parse");
        assert!(e.api.starts_with("http"));
        assert_eq!(e.sync_keep, 20);
        // my-ai-api (sibling of claude-superset-api): routes OpenRouter, no proxy face.
        assert_eq!(e.local.container_name, "my-ai-api-local");
        assert_eq!(e.local.ports.proxy, 0); // no proxy port in the my-ai stack
        assert_eq!(e.setup.installer_url, "https://github.com/block/goose/releases");
        // goosed ACP server: port 3227, WG-only.
        assert_eq!(e.goosed, "http://10.0.0.6:3227");
    }
    #[test]
    fn inspect_title_fallback() {
        let (cwd, title) = inspect("", "abcdef1234");
        assert!(cwd.is_none());
        assert_eq!(title, "abcdef12");
    }
    #[test]
    fn inspect_custom_title_wins() {
        let body = r#"{"cwd":"/home/x"}
{"customTitle":"my title","type":"user"}"#;
        let (cwd, title) = inspect(body, "id0");
        assert_eq!(cwd.as_deref(), Some("/home/x"));
        assert_eq!(title, "my title");
    }
}
