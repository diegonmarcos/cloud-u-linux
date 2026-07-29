//! Dashboard interactive state + row/focus model + launch-arg composer.
//! Port of the `st` / buildRows / selArgs logic in claude-superset-tui.mjs.

pub const PONY: [&str; 3] = ["lite", "full", "ultra"];
pub const PRESETS_COUNT: [u64; 6] = [1, 3, 5, 10, 20, 50];
pub const PRESETS_HOURS: [u64; 6] = [1, 4, 8, 24, 72, 168];
pub const FOCT: [&str; 5] = ["radio", "check", "checklevel", "number", "action"];

/// The agent my-ai wraps. Selection surfaced in the TUI AGENT section.
///   goose      — Block's goose (default; routes my-ai-api → OpenRouter)
///   claude-cli — Anthropic's Claude Code CLI (routes my-ai-api anthropic shim)
///   hermes     — Nous Research Hermes (goose shim pinned to a Hermes model on
///                OpenRouter via my-ai-api — no standalone hermes CLI exists)
pub const AGENTS: [&str; 3] = ["goose", "claude-cli", "hermes"];

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
}

impl Default for St {
    fn default() -> Self {
        St {
            agent: "goose".into(),
            face: "remote".into(),
            headroom: true,
            ponytail: true,
            pony: 1,
            rtk: true,
            caveman: true,
            restore: "off".into(),
            restore_n: 5,
        }
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

pub fn build_rows(st: &St) -> Vec<Row> {
    let mut r = Vec::new();
    r.push(row("sec", "", "", "", "AGENT", ""));
    r.push(row("radio", "agent", "goose", "", "goose", "Block goose → my-ai-api (OpenRouter)"));
    r.push(row("radio", "agent", "claude-cli", "", "claude-cli", "Claude Code CLI → my-ai-api (anthropic shim)"));
    r.push(row("radio", "agent", "hermes", "", "hermes", "Nous Research Hermes → my-ai-api (OpenRouter)"));
    r.push(row("sec", "", "", "", "FACE", ""));
    r.push(row("radio", "face", "remote", "", "remote", "WG compression proxy"));
    r.push(row("radio", "face", "local", "", "local", "container on THIS host"));
    r.push(row("radio", "face", "claude", "", "claude", "plain claude (restore still works)"));
    if st.face != "claude" {
        r.push(row("sec", "", "", "", "PLUGINS", ""));
        r.push(row("check", "", "", "headroom", "Headroom", "compression proxy"));
        r.push(row("checklevel", "", "", "ponytail", "Ponytail", "Left/Right level"));
        r.push(row("check", "", "", "rtk", "RTK", "strip CLI/test noise pre-Headroom"));
        r.push(row("check", "", "", "caveman", "Caveman", "linguistic compression"));
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
pub fn sel_args(st: &St) -> Vec<String> {
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
