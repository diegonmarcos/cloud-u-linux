//! OFFLINE data — instant fs reads at startup (nothing hits the wire on open).
//! Port of the loadMcps/loadPlugins/hooks/loadLocalSessions/claudeConfig section.
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}
fn cfg_dir() -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|| home().join(".claude"))
}
fn read_json(p: &PathBuf) -> Option<Value> {
    serde_json::from_str(&fs::read_to_string(p).ok()?).ok()
}

pub struct Mcp {
    pub name: String,
    pub kind: String, // http | stdio
    pub url: Option<String>,
}
pub fn load_mcps() -> Vec<Mcp> {
    let j = read_json(&home().join(".mcp.json"))
        .or_else(|| read_json(&home().join(".claude.json")))
        .unwrap_or(Value::Null);
    let servers = j.get("mcpServers").and_then(|v| v.as_object());
    let mut out = Vec::new();
    if let Some(servers) = servers {
        for (name, v) in servers {
            let url = v.get("url").and_then(|u| u.as_str()).map(|s| s.to_string());
            let kind = v
                .get("type")
                .and_then(|t| t.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| if url.is_some() { "http".into() } else { "stdio".into() });
            out.push(Mcp { name: name.clone(), kind, url });
        }
    }
    out
}

pub struct Plugin {
    pub label: String,
    pub detail: String,
    pub on: bool,
}
pub fn load_plugins() -> Vec<Plugin> {
    let cfg = cfg_dir();
    let j = read_json(&cfg.join("claude-plugins.json")).unwrap_or(Value::Null);
    let plugins = j.get("plugins").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    plugins
        .iter()
        .map(|p| {
            let label = p
                .get("label")
                .and_then(|v| v.as_str())
                .or_else(|| p.get("id").and_then(|v| v.as_str()))
                .unwrap_or("?")
                .to_string();
            let d = p.get("detect").cloned().unwrap_or(Value::Null);
            let dtype = d.get("type").and_then(|v| v.as_str()).unwrap_or("");
            let mut on = false;
            let mut detail = String::new();
            match dtype {
                "env_set" => {
                    if let Some(e) = d.get("env").and_then(|v| v.as_str()) {
                        on = std::env::var_os(e).is_some();
                    }
                }
                "env_value" => {
                    if let Some(e) = d.get("env").and_then(|v| v.as_str()) {
                        if let Ok(v) = std::env::var(e) {
                            on = !v.is_empty();
                            detail = v;
                        }
                    }
                }
                "flag_file" => {
                    if let Some(rel) = d.get("path").and_then(|v| v.as_str()) {
                        let p = cfg.join(rel);
                        on = p.exists();
                        if on && d.get("show_content").and_then(|v| v.as_bool()).unwrap_or(false) {
                            detail = fs::read_to_string(&p).unwrap_or_default().trim().to_string();
                        }
                    }
                }
                _ => {}
            }
            Plugin { label, detail, on }
        })
        .collect()
}

pub struct Hook {
    pub name: String,
    pub kb: u64,
}
pub fn load_hooks() -> Vec<Hook> {
    let d = cfg_dir().join("hooks");
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(&d) {
        for e in entries.flatten() {
            let fname = e.file_name().to_string_lossy().into_owned();
            if fname.starts_with('.') {
                continue;
            }
            let sz = e.metadata().map(|m| m.len()).unwrap_or(0);
            let name = fname
                .trim_end_matches(".sh")
                .trim_end_matches(".json")
                .trim_end_matches(".md")
                .to_string();
            out.push(Hook { name, kb: (sz / 1024).max(1) });
        }
    }
    out
}

pub struct Session {
    pub title: String,
    pub age: String,
    pub kb: u64,
    pub msgs: u32,
    pub cwd: String,
}
pub struct Sessions {
    pub list: Vec<Session>,
    pub total: usize,
    pub bytes: u64,
}

pub fn ago(mtime_ms: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let s = now.saturating_sub(mtime_ms) as f64 / 1000.0;
    if s < 90.0 {
        format!("{}s", s.round())
    } else if s < 5400.0 {
        format!("{}m", (s / 60.0).round())
    } else if s < 172_800.0 {
        format!("{}h", (s / 3600.0).round())
    } else {
        format!("{}d", (s / 86400.0).round())
    }
}

pub fn load_sessions() -> Sessions {
    let all = my_ai_core::local_sessions(); // newest-first {id,file,mtime}
    let total = all.len();
    let mut bytes = 0u64;
    for s in &all {
        bytes += fs::metadata(&s.file).map(|m| m.len()).unwrap_or(0);
    }
    let home = my_ai_core::home();
    let home_s = home.to_string_lossy().into_owned();
    let list = all
        .iter()
        .take(10)
        .map(|s| {
            let text = fs::read_to_string(&s.file).unwrap_or_default();
            let (cwd, title) = my_ai_core::inspect(&text, &s.id);
            let msgs = text
                .lines()
                .filter(|l| {
                    serde_json::from_str::<Value>(l)
                        .ok()
                        .and_then(|o| o.get("type").and_then(|t| t.as_str()).map(|t| t == "user" || t == "assistant"))
                        .unwrap_or(false)
                })
                .count() as u32;
            let size = fs::metadata(&s.file).map(|m| m.len()).unwrap_or(0);
            let cwd = cwd.unwrap_or_default().replace(&home_s, "~");
            let title: String = title.chars().take(30).collect();
            Session { title, age: ago(s.mtime), kb: (size / 1024).max(1), msgs, cwd }
        })
        .collect();
    Sessions { list, total, bytes }
}

pub struct Cfg {
    pub model: String,
    pub statusline: bool,
    pub skills: Vec<String>,
    pub mcp_count: usize,
}
pub fn claude_config(mcp_count: usize) -> Cfg {
    let s = read_json(&cfg_dir().join("settings.json")).unwrap_or(Value::Null);
    let model = s.get("model").and_then(|v| v.as_str()).unwrap_or("(default)").to_string();
    let statusline = s.get("statusLine").map(|v| !v.is_null()).unwrap_or(false);
    let mut skills = Vec::new();
    if let Ok(entries) = fs::read_dir(cfg_dir().join("skills")) {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if !n.starts_with('.') {
                skills.push(n);
            }
        }
    }
    skills.sort();
    Cfg { model, statusline, skills, mcp_count }
}
