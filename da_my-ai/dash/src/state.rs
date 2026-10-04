//! Dashboard interactive state + row/focus model + launch-arg composer.
//! Port of the `st` / buildRows / selArgs logic in claude-superset-tui.mjs.
use std::collections::BTreeMap;

pub const PONY: [&str; 3] = ["lite", "full", "ultra"];
pub const PRESETS_COUNT: [u64; 6] = [1, 3, 5, 10, 20, 50];
pub const PRESETS_HOURS: [u64; 6] = [1, 4, 8, 24, 72, 168];
pub const FOCT: [&str; 5] = ["radio", "check", "checklevel", "number", "action"];

/// The agent my-ai wraps. Selection surfaced in the TUI AGENT section.
///   goose            — Block's goose (routes my-ai-api → OpenRouter)
///   claude-cli       — Anthropic's Claude Code CLI (routes my-ai-api anthropic shim)
///   claude-cli-ghost — claude-cli in a throwaway, login-only HOME (no history/MCP)
///   hermes           — Nous Research Hermes (goose shim pinned to a Hermes model
///                      on OpenRouter via my-ai-api — no standalone hermes CLI exists)
///   claude-superset  — the full claude-superset wrapper (proxy face select +
///                      Headroom/RTK/Caveman/Ponytail + session restore), default.
pub const AGENTS: [&str; 5] = ["goose", "claude-cli", "claude-cli-ghost", "hermes", "claude-superset"];

pub struct St {
    pub agent: String,
    pub face: String,
    pub headroom: bool,
    pub ponytail: bool,
    pub pony: usize, // index into PONY (default 1 = full)
    pub rtk: bool,
    pub caveman: bool,
    pub restore: String, // off | count | hours
    pub restore_n: u64,
    pub claude_flags: BTreeMap<String, bool>, // claude-flags.json key -> on
    pub statusline: bool,                     // claude statusline
    pub mcp_on: BTreeMap<String, bool>,       // mcp name -> auto-enable (missing = on)
}

impl Default for St {
    fn default() -> Self {
        St {
            agent: "claude-superset".into(),
            face: "remote".into(),
            headroom: true,
            ponytail: true,
            pony: 1,
            rtk: true,
            caveman: true,
            restore: "off".into(),
            restore_n: 5,
            // Filled from claude-flags.json defaults at startup (see main.rs).
            claude_flags: BTreeMap::new(),
            statusline: true,
            // Empty = every MCP starts enabled; mcp_is_on() treats "missing" as on.
            mcp_on: BTreeMap::new(),
        }
    }
}

impl St {
    pub fn flag_on(&self, key: &str) -> bool {
        self.claude_flags.get(key).copied().unwrap_or(false)
    }
    pub fn mcp_is_on(&self, name: &str) -> bool {
        self.mcp_on.get(name).copied().unwrap_or(true)
    }
}

pub struct Row {
    pub kind: &'static str, // sec|radio|check|checklevel|number|action
    pub grp: &'static str,
    pub val: &'static str,
    pub key: &'static str,
    pub label: String,
    pub note: &'static str,
}

fn row(kind: &'static str, grp: &'static str, val: &'static str, key: &'static str, label: &str, note: &'static str) -> Row {
    Row { kind, grp, val, key, label: label.into(), note }
}

pub fn build_rows(
    st: &St,
    mesh: &BTreeMap<String, String>,
    is_termux: bool,
    mcps: &[crate::offline::Mcp],
    flags: &[crate::offline::ClaudeFlag],
) -> Vec<Row> {
    let mut r = Vec::new();
    r.push(row("sec", "", "", "", "AGENT", ""));
    r.push(row("radio", "agent", "goose", "", "goose", "Block goose → my-ai-api (OpenRouter)"));
    r.push(row("radio", "agent", "claude-cli", "", "claude-cli", "Claude Code CLI → my-ai-api (anthropic shim)"));
    r.push(row("radio", "agent", "claude-cli-ghost", "", "claude-cli-ghost", "Claude Code CLI, throwaway ~/.claude-ghost (login-only, wiped each launch)"));
    r.push(row("radio", "agent", "hermes", "", "hermes", "Nous Research Hermes → my-ai-api (OpenRouter)"));
    r.push(row("radio", "agent", "claude-superset", "", "claude-superset", "full wrapper: face select + Headroom/RTK/Caveman/Ponytail + restore (default)"));
    r.push(row("sec", "", "", "", "FACE", ""));
    r.push(row("radio", "face", "remote", "", "remote", "WG compression proxy"));
    if !is_termux {
        r.push(row("radio", "face", "local", "", "local", "container on THIS host"));
    }
    r.push(row("radio", "face", "claude", "", "claude", "plain claude (restore still works)"));
    for vm in mesh.keys() {
        let face = format!("remote-tmux_{vm}");
        // ponytail: Box::leak — one small string per VM, lives for process lifetime (TUI session)
        let val: &'static str = Box::leak(face.clone().into_boxed_str());
        r.push(Row { kind: "radio", grp: "face", val, key: "", label: face, note: "1 SSH conn, tmux session on the VM" });
    }
    if st.face != "claude" {
        r.push(row("sec", "", "", "", "PLUGINS", ""));
        r.push(row("check", "", "", "headroom", "Headroom", "compression proxy"));
        r.push(row("checklevel", "", "", "ponytail", "Ponytail", "Left/Right level"));
        r.push(row("check", "", "", "rtk", "RTK", "strip CLI/test noise pre-Headroom"));
        r.push(row("check", "", "", "caveman", "Caveman", "linguistic compression"));
    }
    let is_claude = st.agent.starts_with("claude");
    if is_claude {
        r.push(row("sec", "", "", "", "CLAUDE FLAGS", ""));
        for f in flags {
            // ponytail: Box::leak — data-driven flags come from claude-flags.json,
            // so the &'static str keys/notes don't exist until runtime; leaking
            // is fine, they live for the TUI's process lifetime same as VM faces above.
            let key: &'static str = Box::leak(f.key.clone().into_boxed_str());
            let note: &'static str = Box::leak(f.note.clone().into_boxed_str());
            r.push(Row { kind: "check", grp: "", val: "", key, label: f.flag.clone(), note });
        }
        r.push(row("sec", "", "", "", "CLAUDE STATUSLINE", ""));
        r.push(row("check", "", "", "statusline", "statusline", "segments in claude prompt"));
    }
    r.push(row("sec", "", "", "", "MCP", ""));
    for m in mcps {
        let key: &'static str = Box::leak(format!("mcp:{}", m.name).into_boxed_str());
        let note_s = m.url.clone().or_else(|| m.command.clone()).unwrap_or_else(|| "stdio".to_string());
        let note: &'static str = Box::leak(note_s.into_boxed_str());
        r.push(Row { kind: "check", grp: "", val: "", key, label: m.name.clone(), note });
    }
    r.push(row("sec", "", "", "", "RESTORE", ""));
    r.push(row("radio", "restore", "off", "", "off", "fresh session"));
    r.push(row("radio", "restore", "count", "", "count", "last N sessions"));
    r.push(row("radio", "restore", "hours", "", "hours", "sessions from last N hours"));
    if st.restore != "off" {
        r.push(row("number", "", "", "restoreN", "N", "type digits or Left/Right"));
    }
    r.push(row("sec", "", "", "", "ACTION", ""));
    r.push(row("action", "", "", "refresh", "", ""));
    r.push(row("action", "", "", "launch", "", ""));
    r.push(row("action", "", "", "quit", "", ""));
    r
}

pub fn focusable(rows: &[Row]) -> Vec<usize> {
    rows.iter()
        .enumerate()
        .filter(|(_, r)| FOCT.contains(&r.kind))
        .map(|(i, _)| i)
        .collect()
}

/// The launch command args (the token stream passed to `my-ai`).
pub fn sel_args(st: &St, mcps: &[crate::offline::Mcp], flags: &[crate::offline::ClaudeFlag]) -> Vec<String> {
    let n = st.restore_n.max(1).to_string();
    debug_assert!(AGENTS.contains(&st.agent.as_str()), "invalid agent: {}", st.agent);
    let mut a = vec!["--agent".into(), st.agent.clone(), st.face.clone()];
    if st.face != "claude" {
        if !st.headroom {
            a.push("headroom".into());
            a.push("off".into());
        }
        a.push("ponytail".into());
        a.push(if st.ponytail { PONY[st.pony].to_string() } else { "off".into() });
        if !st.rtk {
            a.push("rtk".into());
            a.push("off".into());
        }
        if !st.caveman {
            a.push("caveman".into());
            a.push("off".into());
        }
    }
    if st.agent.starts_with("claude") {
        for f in flags {
            if st.flag_on(&f.key) {
                a.push(f.flag.clone());
            }
        }
    }
    a.push("statusline".into());
    a.push(if st.statusline { "on".into() } else { "off".into() });
    if !mcps.is_empty() && mcps.iter().any(|m| !st.mcp_is_on(&m.name)) {
        let enabled: Vec<&str> = mcps.iter().filter(|m| st.mcp_is_on(&m.name)).map(|m| m.name.as_str()).collect();
        a.push("--mcp-enable".into());
        a.push(enabled.join(","));
    }
    match st.restore.as_str() {
        "count" => {
            a.push("restore".into());
            a.push(n);
        }
        "hours" => {
            a.push("restore-hours".into());
            a.push(n);
        }
        _ => {}
    }
    a
}
