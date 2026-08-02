//! Native ccusage-equivalent token-usage counter — shared by the `my-ai usage`
//! CLI subcommand (and, later, dash/GUI). Reads every `*.jsonl` transcript under
//! `~/.claude/projects/`, dedups by `message.id:requestId`, buckets entries into
//! ccusage-style 5-hour billing blocks, and prices them against a longest-prefix
//! model-pricing table (user override at `~/.claude/claude-pricing.json`, else
//! the bundled default table).
use anyhow::Result;
use serde::Deserialize;
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Bundled fallback pricing (src/data/pricing.json), used when the user has no
/// `~/.claude/claude-pricing.json`.
pub const DEFAULT_PRICING_JSON: &str = include_str!("../../src/data/pricing.json");

/// ccusage block size: 5 hours, in milliseconds.
pub const BLOCK_MS: i64 = 5 * 3_600_000;

/// Statusline cache TTL (tunable) — `my-ai usage --statusline` reuses a cached
/// line if it's younger than this, so the per-render cost of a fresh scan is
/// paid at most once per TTL window.
pub const STATUSLINE_CACHE_TTL_SECS: u64 = 30;

/// Default publish interval for `my-ai usage --daemon`.
pub const DAEMON_INTERVAL_SECS: u64 = 30;

/// Where the daemon publishes the ready-to-print statusline segment.
///
/// This is the contract with the status line: it *only* reads this file, never
/// spawning anything on its paint path. An in-process TTL cache cannot serve
/// that role — a cache *hit* still costs a full process start, which is what
/// previously drove the status line to ~296MB per render and let systemd-oomd
/// kill the desktop. $XDG_RUNTIME_DIR is tmpfs (no disk I/O for the reader) and
/// is wiped on logout, so a stale segment can never outlive the session.
pub fn seg_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("my-ai-usage.seg")
}

/// Publish a segment atomically: write a sibling temp file, then rename. Rename
/// is atomic within a filesystem, so a concurrently-painting status line reads
/// either the old segment or the new one — never a half-written line.
pub fn publish_seg(line: &str) -> std::io::Result<()> {
    let path = seg_path();
    let tmp = path.with_extension("seg.tmp");
    fs::write(&tmp, line)?;
    fs::rename(&tmp, &path)
}

/// Read the published segment, if a daemon has written one.
pub fn read_seg() -> Option<String> {
    fs::read_to_string(seg_path()).ok().filter(|s| !s.trim().is_empty())
}

/// Where the daemon publishes the structured snapshot (`Scanner::snapshot_json`).
///
/// The `.seg` file above is a pre-rendered line for one specific row; this is the
/// DATA behind every row the status line draws, so the status line can format
/// what it likes without parsing transcripts itself.
pub fn snapshot_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("my-ai-usage.json")
}

/// The machine-global status-line rows, rendered ONCE per interval.
///
/// MCP health, plugin/skill state, hook rules and CLI flags are properties of
/// the MACHINE, not of a session — every session was computing the identical
/// five strings, every second, by spawning five shell scripts each (~0.43s of
/// work per render). At ten sessions that is fifty processes a second to
/// produce five strings that are the same for all of them.
///
/// The daemon runs them once and publishes the output. A status line then
/// prints these verbatim: no spawn, no computation, no per-session duplication.
pub fn global_blocks(home: &Path, cwd: &str) -> serde_json::Map<String, Value> {
    let claude = home.join(".claude");
    // (json key, script, args) — the exact invocations the status line used.
    let jobs: [(&str, &str, &[&str]); 5] = [
        ("mcp", "claude-mcp-status.sh", &[]),
        ("flags", "claude-flags-status.sh", &["--format", "ansi"]),
        ("skl", "claude-plugins-status.sh", &["--part", "skl", "--format", "ansi"]),
        ("sys", "claude-plugins-status.sh", &["--part", "sys", "--format", "ansi"]),
        ("rul", "claude-hooks-status.sh", &["--format", "ansi"]),
    ];
    let mut out = serde_json::Map::new();
    for (key, script, args) in jobs {
        let path = claude.join(script);
        if !path.exists() {
            continue;
        }
        let mut cmd = std::process::Command::new("bash");
        cmd.arg(&path);
        if key == "mcp" {
            cmd.arg(cwd); // this one takes the working dir as its only argument
        }
        cmd.args(args);
        if let Ok(o) = cmd.output() {
            let s = String::from_utf8_lossy(&o.stdout).trim_end().to_string();
            if !s.is_empty() {
                out.insert(key.to_string(), Value::String(s));
            }
        }
    }
    out
}

/// Publish the snapshot atomically (write-temp + rename), same contract as
/// `publish_seg`: a concurrent reader sees the old document or the new one.
pub fn publish_snapshot(json: &str) -> std::io::Result<()> {
    let path = snapshot_path();
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, json)?;
    fs::rename(&tmp, &path)
}

/// Strip ANSI SGR escapes. The published segment is coloured for the terminal
/// status line; tray tooltips and menu labels must be plain text or they render
/// the escapes as visible garbage.
///
/// Handles BOTH forms. The segment carries the literal four characters `\033`,
/// not byte 0x1b: the status line assembles its rows as plain text and only
/// converts them with `printf %b` at the very end, so the escapes travel as text
/// for their whole life. Stripping only 0x1b would leave `\033[37m` on screen.
pub fn strip_ansi(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let mut chunk = 0;
    while i < b.len() {
        let esc = if b[i] == 0x1b {
            1
        } else if b[i..].starts_with(br"\033") {
            4
        } else {
            i += 1;
            continue;
        };
        // `i` sits on ASCII (0x1b or '\\'), so this slice is on a char boundary
        // even though the segment contains multi-byte glyphs like '│'.
        out.push_str(&s[chunk..i]);
        i += esc;
        // CSI: '[' then parameters, terminated by a byte in @..~ .
        if b.get(i) == Some(&b'[') {
            i += 1;
            while i < b.len() && !(0x40..=0x7e).contains(&b[i]) {
                i += 1;
            }
            if i < b.len() {
                i += 1;
            }
        }
        chunk = i;
    }
    out.push_str(&s[chunk..]);
    out
}

/// Compute the current statusline segment from the transcripts on disk.
pub fn current_statusline(projects: &Path) -> Result<String> {
    let pricing = Pricing::load();
    let entries = collect_entries(projects)?;
    let blocks = bucket_blocks(&entries, &pricing);
    Ok(format_statusline(&blocks, now_ms()).unwrap_or_default())
}

// ── one usage event, after dedup ──────────────────────────────────────────────
#[derive(Debug, Clone)]
pub struct UsageEntry {
    pub ts_ms: i64,
    pub model: String,
    pub input: u64,
    pub output: u64,
    pub cache_write: u64,
    pub cache_read: u64,
    /// Transcript file stem = Claude Code's session id. Carried per entry so the
    /// active 5h block can be split per session (the `5h-S` row) rather than only
    /// summed across all of them (`5h-T`).
    pub session: String,
}

impl UsageEntry {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_write + self.cache_read
    }
}

// ── pricing ────────────────────────────────────────────────────────────────────
#[derive(Debug, Clone, Deserialize)]
pub struct ModelPrice {
    #[serde(default)]
    pub input: f64,
    #[serde(default)]
    pub output: f64,
    #[serde(default)]
    pub cache_read: f64,
    #[serde(default)]
    pub cache_write: f64,
}

#[derive(Debug, Clone, Deserialize)]
struct PricingFile {
    models: BTreeMap<String, ModelPrice>,
    default: ModelPrice,
}

#[derive(Debug, Clone)]
pub struct Pricing {
    models: Vec<(String, ModelPrice)>,
    default: ModelPrice,
}

impl Pricing {
    /// `~/.claude/claude-pricing.json` if present and valid, else the bundled
    /// default table (src/data/pricing.json).
    pub fn load() -> Self {
        let user_path = crate::home().join(".claude").join("claude-pricing.json");
        let text = fs::read_to_string(&user_path).ok();
        let parsed: PricingFile = text
            .as_deref()
            .and_then(|t| serde_json::from_str(t).ok())
            .or_else(|| serde_json::from_str(DEFAULT_PRICING_JSON).ok())
            .expect("bundled pricing.json must parse");
        Pricing { models: parsed.models.into_iter().collect(), default: parsed.default }
    }

    /// Longest-prefix match of `model` against the table's keys (mirrors the
    /// jq-based statusline scripts: keyed by model-id prefix, longest wins).
    pub fn price_for(&self, model: &str) -> &ModelPrice {
        self.models
            .iter()
            .filter(|(k, _)| model.starts_with(k.as_str()))
            .max_by_key(|(k, _)| k.len())
            .map(|(_, p)| p)
            .unwrap_or(&self.default)
    }
}

pub fn cost(e: &UsageEntry, pricing: &Pricing) -> f64 {
    let p = pricing.price_for(&e.model);
    (e.input as f64 / 1e6) * p.input
        + (e.output as f64 / 1e6) * p.output
        + (e.cache_write as f64 / 1e6) * p.cache_write
        + (e.cache_read as f64 / 1e6) * p.cache_read
}

// ── timestamp parsing (RFC3339 UTC, e.g. "2026-07-31T11:31:04.123Z") ─────────
// chrono isn't a workspace dep; hand-parsed to avoid adding a crate for this.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = (m + 9) % 12; // [0, 11]
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Parse an RFC3339 UTC timestamp into epoch milliseconds. Only the subset
/// actually emitted by Claude Code transcripts is supported (`Z` suffix,
/// optional fractional seconds) — not a general RFC3339 parser.
pub fn parse_rfc3339_ms(s: &str) -> Option<i64> {
    if s.len() < 20 {
        return None;
    }
    let get = |a: usize, b: usize| s.get(a..b)?.parse::<i64>().ok();
    let year = get(0, 4)?;
    let month = get(5, 7)?;
    let day = get(8, 10)?;
    let hour = get(11, 13)?;
    let min = get(14, 16)?;
    let sec = get(17, 19)?;
    let bytes = s.as_bytes();
    let mut millis: i64 = 0;
    if bytes.get(19) == Some(&b'.') {
        let start = 20;
        let mut end = start;
        while end < bytes.len() && bytes[end].is_ascii_digit() {
            end += 1;
        }
        let mut digits: String = s[start..end].chars().take(3).collect();
        while digits.len() < 3 {
            digits.push('0');
        }
        millis = digits.parse().unwrap_or(0);
    }
    let days = days_from_civil(year, month, day);
    Some(days * 86_400_000 + hour * 3_600_000 + min * 60_000 + sec * 1000 + millis)
}

/// Inverse of `days_from_civil` (Howard Hinnant's algorithm): days-since-epoch -> (y, m, d).
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// Format epoch-ms as a UTC `YYYY-MM-DD HH:MM` string (block-start display).
pub fn fmt_utc(ts_ms: i64) -> String {
    let days = ts_ms.div_euclid(86_400_000);
    let rem = ts_ms.rem_euclid(86_400_000);
    let (y, m, d) = civil_from_days(days);
    let hour = rem / 3_600_000;
    let min = (rem % 3_600_000) / 60_000;
    format!("{y:04}-{m:02}-{d:02} {hour:02}:{min:02}")
}

pub fn floor_to_hour(ts_ms: i64) -> i64 {
    ts_ms - ts_ms.rem_euclid(3_600_000)
}

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

// ── collection: walk ~/.claude/projects/**/*.jsonl, parse + dedup ────────────
fn visit_jsonl(dir: &Path, f: &mut impl FnMut(&str)) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for de in entries.flatten() {
        let p = de.path();
        if p.is_dir() {
            visit_jsonl(&p, f);
        } else if p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            if let Ok(text) = fs::read_to_string(&p) {
                for line in text.lines() {
                    if !line.trim().is_empty() {
                        f(line);
                    }
                }
            }
        }
    }
}

fn parse_line_in(v: &Value, session: &str) -> Option<(String, UsageEntry)> {
    let (key, mut e) = parse_line(v)?;
    e.session = session.to_string();
    Some((key, e))
}

fn parse_line(v: &Value) -> Option<(String, UsageEntry)> {
    let usage = v.get("message")?.get("usage")?;
    let ts_ms = parse_rfc3339_ms(v.get("timestamp")?.as_str()?)?;
    let model = v.get("message")?.get("model").and_then(|m| m.as_str()).unwrap_or("unknown").to_string();
    let msg_id = v.get("message")?.get("id").and_then(|m| m.as_str()).unwrap_or("");
    let req_id = v.get("requestId").and_then(|r| r.as_str()).unwrap_or("");
    let key = format!("{msg_id}:{req_id}");
    let n = |k: &str| usage.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
    Some((
        key,
        UsageEntry {
            ts_ms,
            model,
            input: n("input_tokens"),
            output: n("output_tokens"),
            cache_write: n("cache_creation_input_tokens"),
            cache_read: n("cache_read_input_tokens"),
            session: String::new(),
        },
    ))
}

// ── incremental scanner (the daemon's engine) ────────────────────────────────

/// How far back the scanner keeps individual entries. Only the ACTIVE 5h block
/// is ever rendered, and a block can only start after a >5h idle gap, so a 24h
/// tail is far more history than the active block can reach back into.
const RETAIN_MS: i64 = 24 * 3_600_000;

/// All-time token + cost totals for ONE session (one transcript file).
#[derive(Debug, Clone, Default)]
pub struct SessionTotals {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub cost_input: f64,
    pub cost_output: f64,
    pub cost_cache_read: f64,
    pub cost_cache_write: f64,
    /// Timestamp of the newest `user` / `assistant` record seen for this session.
    /// The status line's Usr:/Agt: idle timers are `now - these`, so it never has
    /// to open a transcript to draw them.
    pub last_user_ms: i64,
    pub last_assistant_ms: i64,
}

impl SessionTotals {
    pub fn total_tokens(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
    pub fn cost(&self) -> f64 {
        self.cost_input + self.cost_output + self.cost_cache_read + self.cost_cache_write
    }
}

/// Append-only incremental scanner over `~/.claude/projects/**/*.jsonl`.
///
/// The daemon holds ONE of these for its lifetime. Transcripts only ever grow,
/// so each tick reads just the bytes appended since the last tick — the first
/// tick pays for the whole corpus (~618 MB here), every tick after it pays for
/// a few hundred KB. Re-reading everything on a 30s timer was ~27% of a core,
/// permanently.
///
/// This is deliberately the ONLY place transcripts get parsed. The status line
/// renders `snapshot_json()` and computes nothing itself; a second incremental
/// scanner living in the status line's shell script was the wrong shape (same
/// work, done per render, per session).
#[derive(Default)]
pub struct Scanner {
    offsets: BTreeMap<PathBuf, u64>,
    seen: HashSet<String>,
    sessions: BTreeMap<String, SessionTotals>,
    entries: Vec<UsageEntry>,
}

impl Scanner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Session id = transcript file stem, which is what Claude Code puts in the
    /// status line's `session_id` / `transcript_path`, so the status line can
    /// look its own row up directly.
    fn session_id_of(path: &Path) -> String {
        path.file_stem().and_then(|s| s.to_str()).unwrap_or("unknown").to_string()
    }

    /// Read only the appended bytes of every transcript, folding them into the
    /// per-session totals and the rolling entry window.
    pub fn tick(&mut self, root: &Path, pricing: &Pricing) {
        let mut files = Vec::new();
        collect_jsonl_paths(root, &mut files);
        let mut alive: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
        for path in files {
            alive.insert(path.clone());
            let len = match fs::metadata(&path) {
                Ok(m) => m.len(),
                Err(_) => continue,
            };
            let off = self.offsets.entry(path.clone()).or_insert(0);
            // Shrunk => rewritten, not appended. Re-read it whole; the dedup set
            // keeps the already-counted entries from being counted twice.
            if len < *off {
                *off = 0;
            }
            if len == *off {
                continue;
            }
            let start_off = *off;
            let sid = Self::session_id_of(&path);
            // Stream the appended range line-by-line (BufReader, ~8KB internal
            // buffer) instead of reading it into one big String. The old
            // read_from() buffered [off, len) whole AND `into_owned()`'d a copy
            // of it — on a daemon's first tick, `off` is 0, so a single large
            // transcript (a live session can be tens to hundreds of MB) was
            // loaded into memory roughly twice over. That is the spike that hit
            // the unit's 128M MemoryMax and got it oom-killed: 12s of CPU and a
            // single peak, not a slow climb across many ticks.
            let consumed = stream_tail(&path, start_off, len, |line| {
                let Ok(v) = serde_json::from_str::<Value>(line) else { return };
                // Idle timers first: they care about EVERY user/assistant record,
                // including the ones with no usage{} for parse_line to find.
                if let (Some(kind), Some(ts)) = (
                    v.get("type").and_then(|t| t.as_str()),
                    v.get("timestamp").and_then(|t| t.as_str()).and_then(parse_rfc3339_ms),
                ) {
                    if kind == "user" || kind == "assistant" {
                        let s = self.sessions.entry(sid.clone()).or_default();
                        let slot = if kind == "user" { &mut s.last_user_ms } else { &mut s.last_assistant_ms };
                        if ts > *slot {
                            *slot = ts;
                        }
                    }
                }
                let Some((key, entry)) = parse_line_in(&v, &sid) else { return };
                if !self.seen.insert(key) {
                    return;
                }
                let p = pricing.price_for(&entry.model);
                let s = self.sessions.entry(sid.clone()).or_default();
                s.input += entry.input;
                s.output += entry.output;
                s.cache_read += entry.cache_read;
                s.cache_write += entry.cache_write;
                s.cost_input += (entry.input as f64 / 1e6) * p.input;
                s.cost_output += (entry.output as f64 / 1e6) * p.output;
                s.cost_cache_read += (entry.cache_read as f64 / 1e6) * p.cache_read;
                s.cost_cache_write += (entry.cache_write as f64 / 1e6) * p.cache_write;
                self.entries.push(entry);
            });
            if let Some(c) = consumed {
                *self.offsets.get_mut(&path).unwrap() = start_off + c;
            }
        }
        self.entries.sort_by_key(|e| e.ts_ms);
        let cutoff = now_ms() - RETAIN_MS;
        self.entries.retain(|e| e.ts_ms >= cutoff);
        // `seen` is only needed to dedup within what we still hold; letting it
        // grow for the process lifetime would be a slow leak.
        if self.seen.len() > 200_000 {
            self.seen.clear();
        }
        // `sessions` has no natural retention of its own — unlike `entries` it
        // isn't a rolling window, it's an `.entry().or_default()` on every
        // session id ever seen. A session that goes idle (transcript file
        // untouched) would sit there forever. Bound it on the same RETAIN_MS
        // clock `entries` uses: a session with no user/assistant record in the
        // window is not going to show up in a `5h` row anyway.
        self.sessions.retain(|_, s| s.last_user_ms.max(s.last_assistant_ms) >= cutoff);
        // `offsets` grows one entry per transcript file ever seen. Projects get
        // renamed/deleted (or transcripts pruned by Claude Code itself); a file
        // that's gone from disk is never going to be tailed again, so drop it
        // rather than carry a dead PathBuf key for the process lifetime.
        self.offsets.retain(|p, _| alive.contains(p));
    }

    pub fn sessions(&self) -> &BTreeMap<String, SessionTotals> {
        &self.sessions
    }

    /// The pre-rendered 5h-T line for the tray and the `.seg` file. Empty when
    /// no block is active.
    pub fn statusline(&self, pricing: &Pricing, now: i64) -> String {
        let blocks = bucket_blocks(&self.entries, pricing);
        format_statusline(&blocks, now).unwrap_or_default()
    }

    /// Everything the status line needs, as one JSON document:
    ///
    /// * `block` — the active 5h window summed across ALL projects (`5h-T`),
    ///   absent when idle;
    /// * `block_sessions` — the SAME window split per session (`5h-S`), so a
    ///   session's row is directly comparable to the total above it;
    /// * `sessions` — all-time per-session totals, for rows that are meant to
    ///   cover the whole session rather than the billing window.
    ///
    /// The status line does one `jq` read of this and formats. It performs no
    /// scanning and no arithmetic over transcripts.
    pub fn snapshot_json(&self, pricing: &Pricing, now: i64) -> String {
        let blocks = bucket_blocks(&self.entries, pricing);
        let active = active_block_index(&blocks, now);

        // 5h-S: per-session totals restricted to the active block's window.
        // Summing a session's whole history here would print numbers far larger
        // than the 5h-T line above it and read as a bug.
        let mut block_sessions: BTreeMap<String, SessionTotals> = BTreeMap::new();
        if let Some(i) = active {
            let (start, end) = (blocks[i].start_ms, blocks[i].end_ms());
            for e in self.entries.iter().filter(|e| e.ts_ms >= start && e.ts_ms < end) {
                let p = pricing.price_for(&e.model);
                let s = block_sessions.entry(e.session.clone()).or_default();
                s.input += e.input;
                s.output += e.output;
                s.cache_read += e.cache_read;
                s.cache_write += e.cache_write;
                s.cost_input += (e.input as f64 / 1e6) * p.input;
                s.cost_output += (e.output as f64 / 1e6) * p.output;
                s.cost_cache_read += (e.cache_read as f64 / 1e6) * p.cache_read;
                s.cost_cache_write += (e.cache_write as f64 / 1e6) * p.cache_write;
            }
        }

        let block = active.map(|i| {
            let b = &blocks[i];
            let t = &b.totals;
            serde_json::json!({
                "input": t.input, "output": t.output,
                "cache_read": t.cache_read, "cache_write": t.cache_write,
                "total_tokens": t.total_tokens(),
                "cost_input": t.cost_input, "cost_output": t.cost_output,
                "cost_cache_read": t.cost_cache_read, "cost_cache_write": t.cost_cache_write,
                "cost": t.cost(),
                "reset_in": fmt_duration(b.end_ms() - now),
                "burn_per_min": burn_rate(b, now),
            })
        });
        let sessions: serde_json::Map<String, Value> = self
            .sessions
            .iter()
            .map(|(id, s)| {
                (
                    id.clone(),
                    serde_json::json!({
                        "input": s.input, "output": s.output,
                        "cache_read": s.cache_read, "cache_write": s.cache_write,
                        "total_tokens": s.total_tokens(),
                        "cost_input": s.cost_input, "cost_output": s.cost_output,
                        "cost_cache_read": s.cost_cache_read, "cost_cache_write": s.cost_cache_write,
                        "cost": s.cost(),
                        "last_user_ms": s.last_user_ms,
                        "last_assistant_ms": s.last_assistant_ms,
                    }),
                )
            })
            .collect();
        let block_sessions: serde_json::Map<String, Value> = block_sessions
            .iter()
            .map(|(id, s)| {
                (
                    id.clone(),
                    serde_json::json!({
                        "input": s.input, "output": s.output,
                        "cache_read": s.cache_read, "cache_write": s.cache_write,
                        "total_tokens": s.total_tokens(),
                        "cost_input": s.cost_input, "cost_output": s.cost_output,
                        "cost_cache_read": s.cost_cache_read, "cost_cache_write": s.cost_cache_write,
                        "cost": s.cost(),
                    }),
                )
            })
            .collect();
        // Machine-global rows, computed once here instead of once per session
        // per second. `blocks` is what makes a status line a pure reader.
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| home.to_string_lossy().into_owned());
        serde_json::json!({
            "generated_ms": now,
            "block": block,
            "block_sessions": block_sessions,
            "sessions": sessions,
            "blocks": global_blocks(&home, &cwd),
        })
        .to_string()
    }
}

/// Stream `[off, len)` of `path` line-by-line, calling `on_line` for each
/// complete (non-empty) line, and return how many bytes were consumed — or
/// `None` if nothing but a half-written trailing line is available yet (left
/// alone for the next tick to pick up whole).
///
/// This replaces a version that read the whole `[off, len)` range into one
/// `Vec<u8>` and then `.into_owned()`'d a `String` copy of it — on a fresh
/// daemon (`off` always 0) that is up to 2x a single transcript's size held
/// live at once, same principle as the `jq -rs` (slurp) -> `jq -rn 'reduce
/// inputs'` (streaming) rewrite the status line itself went through. A
/// `BufReader` here keeps only one line resident at a time.
fn stream_tail(path: &Path, off: u64, len: u64, mut on_line: impl FnMut(&str)) -> Option<u64> {
    use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
    let mut f = fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(off)).ok()?;
    let mut reader = BufReader::new(f.take(len - off));
    let mut consumed: u64 = 0;
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf).ok()? as u64;
        if n == 0 {
            break; // hit `len` (Take's limit) with nothing left to read
        }
        if buf.last() != Some(&b'\n') {
            break; // half-written trailing line — don't count it, don't emit it
        }
        consumed += n;
        let line = String::from_utf8_lossy(&buf[..buf.len() - 1]);
        if !line.trim().is_empty() {
            on_line(&line);
        }
    }
    (consumed > 0).then_some(consumed)
}

fn collect_jsonl_paths(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for de in entries.flatten() {
        let p = de.path();
        if p.is_dir() {
            collect_jsonl_paths(&p, out);
        } else if p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(p);
        }
    }
}

/// Deduped, ascending-by-timestamp usage entries from every `*.jsonl` under `root`
/// (recursively). Dedup key: `message.id:requestId`.
pub fn collect_entries(root: &Path) -> Result<Vec<UsageEntry>> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    if root.exists() {
        visit_jsonl(root, &mut |line| {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if let Some((key, entry)) = parse_line(&v) {
                    if seen.insert(key) {
                        out.push(entry);
                    }
                }
            }
        });
    }
    out.sort_by_key(|e| e.ts_ms);
    Ok(out)
}

// ── 5-hour block bucketing (ccusage semantics) ────────────────────────────────
#[derive(Debug, Clone, Default)]
pub struct BlockTotals {
    pub input: u64,
    pub output: u64,
    pub cache_write: u64,
    pub cache_read: u64,
    /// Per-category cost (USD), tracked separately so both the report and the
    /// statusline can show a `$` breakdown next to each token category.
    pub cost_input: f64,
    pub cost_output: f64,
    pub cost_cache_write: f64,
    pub cost_cache_read: f64,
    pub entries: usize,
}
impl BlockTotals {
    pub fn total_tokens(&self) -> u64 {
        self.input + self.output + self.cache_write + self.cache_read
    }
    pub fn cost(&self) -> f64 {
        self.cost_input + self.cost_output + self.cost_cache_write + self.cost_cache_read
    }
}

#[derive(Debug, Clone)]
pub struct Block {
    pub start_ms: i64,
    pub totals: BlockTotals,
}
impl Block {
    pub fn end_ms(&self) -> i64 {
        self.start_ms + BLOCK_MS
    }
}

/// Entries MUST already be sorted ascending by timestamp (as returned by
/// `collect_entries`). Opens a new block when either the entry falls outside
/// the current block's 5h window, or the gap since the previous entry exceeds
/// 5h (an idle gap always forces a new block even if still inside the window).
pub fn bucket_blocks(entries: &[UsageEntry], pricing: &Pricing) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut prev_ts: Option<i64> = None;
    for e in entries {
        let need_new = match blocks.last() {
            None => true,
            Some(b) => {
                let within_block = e.ts_ms < b.end_ms();
                let within_gap = prev_ts.map(|p| e.ts_ms - p <= BLOCK_MS).unwrap_or(true);
                !(within_block && within_gap)
            }
        };
        if need_new {
            blocks.push(Block { start_ms: floor_to_hour(e.ts_ms), totals: BlockTotals::default() });
        }
        let b = blocks.last_mut().expect("just pushed if needed");
        let p = pricing.price_for(&e.model);
        b.totals.input += e.input;
        b.totals.output += e.output;
        b.totals.cache_write += e.cache_write;
        b.totals.cache_read += e.cache_read;
        b.totals.cost_input += (e.input as f64 / 1e6) * p.input;
        b.totals.cost_output += (e.output as f64 / 1e6) * p.output;
        b.totals.cost_cache_write += (e.cache_write as f64 / 1e6) * p.cache_write;
        b.totals.cost_cache_read += (e.cache_read as f64 / 1e6) * p.cache_read;
        b.totals.entries += 1;
        prev_ts = Some(e.ts_ms);
    }
    blocks
}

/// Index of the ACTIVE block (the one whose `[start, start+5h)` contains `now_ms`),
/// or `None` if idle (only the most recent block can ever be active).
pub fn active_block_index(blocks: &[Block], now_ms: i64) -> Option<usize> {
    let last = blocks.len().checked_sub(1)?;
    (now_ms < blocks[last].end_ms()).then_some(last)
}

// ── human formatting ──────────────────────────────────────────────────────────
/// Human-readable token count: `12.3k`, `1.2M`, or a bare integer under 1000.
pub fn fmt_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

fn fmt_duration(ms: i64) -> String {
    let total_min = ms.max(0) / 60_000;
    format!("{}h {}m", total_min / 60, total_min % 60)
}

/// Burn rate in tokens/minute for the active block (0 if just started).
pub fn burn_rate(active: &Block, now_ms: i64) -> f64 {
    let elapsed_min = ((now_ms - active.start_ms) as f64 / 60_000.0).max(1.0);
    active.totals.total_tokens() as f64 / elapsed_min
}

/// Build the exact `--statusline` line, or `None` if there's no active block
/// (idle) — the caller should then print nothing.
/// Format:
/// `05h-T [ \033[1mΣ<tot>($<total>)\033[0m New:<in>($<c>) CchW:<cw>($<c>) CchR:<cr>($<c>) Out:<out>($<c>) ] \033[37m│\033[0m Reset:<Xh Ym> Burn:<k>k/m`
///
/// `-T` = Total across every project in the active 5h block. The statusline
/// renders `All-S` above and `05h-S` below, so the three rows read as a stack:
/// same fields, same order, different scope. Two details exist purely so that
/// stack lines up: the label is zero-padded to the width of `All-S`, and Σ —
/// the field being compared between rows — leads instead of trailing a
/// variable-width list.
/// (Literal backslash-escapes, not raw ESC bytes — the statusline host prints
/// this via `printf %b`.)
pub fn format_statusline(blocks: &[Block], now_ms: i64) -> Option<String> {
    let idx = active_block_index(blocks, now_ms)?;
    let b = &blocks[idx];
    let t = &b.totals;
    let reset_in = fmt_duration(b.end_ms() - now_ms);
    let burn = burn_rate(b, now_ms);
    Some(format!(
        "05h-T \\033[37m[\\033[0m \\033[1mΣ{}(${:.2})\\033[0m New:{}(${:.2}) CchW:{}(${:.2}) CchR:{}(${:.2}) Out:{}(${:.2}) \\033[37m]\\033[0m \\033[37m│\\033[0m Reset:{} Burn:{:.1}k/m",
        fmt_tokens(t.total_tokens()), t.cost(),
        fmt_tokens(t.input), t.cost_input,
        fmt_tokens(t.cache_write), t.cost_cache_write,
        fmt_tokens(t.cache_read), t.cost_cache_read,
        fmt_tokens(t.output), t.cost_output,
        reset_in,
        burn / 1000.0,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(ts: &str, model: &str, msg_id: &str, req_id: &str, input: u64, output: u64) -> Value {
        serde_json::json!({
            "type": "assistant",
            "timestamp": ts,
            "requestId": req_id,
            "message": {
                "id": msg_id,
                "model": model,
                "usage": {
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0
                }
            }
        })
    }

    #[test]
    fn parse_timestamp() {
        let ms = parse_rfc3339_ms("2026-07-31T11:31:04.123Z").unwrap();
        // sanity: round-trips through days_from_civil consistently with a second call
        let ms2 = parse_rfc3339_ms("2026-07-31T11:31:04.123Z").unwrap();
        assert_eq!(ms, ms2);
        // one hour later differs by exactly 3_600_000 ms
        let later = parse_rfc3339_ms("2026-07-31T12:31:04.123Z").unwrap();
        assert_eq!(later - ms, 3_600_000);
    }

    #[test]
    fn dedup_and_blocks_and_active_sum() {
        let pricing = Pricing { models: vec![], default: ModelPrice { input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0 } };

        // Block A: two entries close together, starting at an arbitrary hour.
        let a1 = e("2026-07-31T10:00:00.000Z", "claude-opus-4-x", "msg_1", "req_1", 100, 50);
        let a2 = e("2026-07-31T10:10:00.000Z", "claude-opus-4-x", "msg_2", "req_2", 200, 20);
        // Duplicate of a2 (same message.id:requestId) — must be dropped by dedup.
        let a2_dup = e("2026-07-31T10:10:00.000Z", "claude-opus-4-x", "msg_2", "req_2", 200, 20);
        // Gap > 5h after a2 (10:10 + 6h = 16:10) forces a new block.
        let b1 = e("2026-07-31T16:10:00.000Z", "claude-opus-4-x", "msg_3", "req_3", 10, 5);
        let b2 = e("2026-07-31T16:20:00.000Z", "claude-opus-4-x", "msg_4", "req_4", 30, 15);

        // Build raw jsonl lines, deliberately out of order to also exercise the sort.
        let lines = [&a2_dup, &b2, &a1, &b1, &a2];
        let mut seen = HashSet::new();
        let mut entries = Vec::new();
        for v in lines {
            if let Some((key, entry)) = parse_line(v) {
                if seen.insert(key) {
                    entries.push(entry);
                }
            }
        }
        entries.sort_by_key(|x| x.ts_ms);

        // 5 lines in, 1 duplicate dropped -> 4 counted entries.
        assert_eq!(entries.len(), 4);

        let blocks = bucket_blocks(&entries, &pricing);
        // Two distinct blocks: the >5h gap must force a split.
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].totals.entries, 2);
        assert_eq!(blocks[1].totals.entries, 2);

        // Dedup actually dropped the duplicate: block A's token sum reflects
        // a1 + a2 exactly once (not twice).
        assert_eq!(blocks[0].totals.input, 100 + 200);
        assert_eq!(blocks[0].totals.output, 50 + 20);

        // Inject "now" deterministically: 30 minutes into block B's window.
        let now = parse_rfc3339_ms("2026-07-31T16:50:00.000Z").unwrap();
        let active = active_block_index(&blocks, now);
        assert_eq!(active, Some(1));
        let ab = &blocks[active.unwrap()];
        assert_eq!(ab.totals.input, 10 + 30);
        assert_eq!(ab.totals.output, 5 + 15);

        // "now" far beyond the last block's window -> idle (no active block).
        let idle_now = parse_rfc3339_ms("2026-08-01T00:00:00.000Z").unwrap();
        assert_eq!(active_block_index(&blocks, idle_now), None);
    }

    /// The scanner's whole point: appending to a transcript and ticking again
    /// must equal reading the file once, and re-ticking with nothing appended
    /// must change nothing. A half-written trailing line is skipped, then
    /// counted exactly once when its newline arrives.
    #[test]
    fn scanner_is_incremental_and_never_double_counts() {
        use std::io::Write;
        let dir = std::env::temp_dir().join(format!("my-ai-scan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("sess-a.jsonl");

        let rec = |id: &str, inp: u64, out: u64| {
            format!(
                r#"{{"type":"assistant","timestamp":"2026-08-01T10:00:00.000Z","requestId":"{id}","message":{{"id":"{id}","model":"claude-opus-5","usage":{{"input_tokens":{inp},"output_tokens":{out},"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}}}}"#
            )
        };
        let pricing = Pricing::load();
        let mut s = Scanner::new();

        fs::write(&f, format!("{}\n{}\n", rec("m1", 10, 1), rec("m2", 20, 2))).unwrap();
        s.tick(&dir, &pricing);
        assert_eq!(s.sessions()["sess-a"].input, 30);
        assert_eq!(s.sessions()["sess-a"].output, 3);

        // Idle tick: nothing appended, nothing may change.
        s.tick(&dir, &pricing);
        assert_eq!(s.sessions()["sess-a"].input, 30, "idle tick double-counted");

        // Append: only the new bytes are read, totals accumulate.
        let mut h = fs::OpenOptions::new().append(true).open(&f).unwrap();
        writeln!(h, "{}", rec("m3", 5, 4)).unwrap();
        s.tick(&dir, &pricing);
        assert_eq!(s.sessions()["sess-a"].input, 35);
        assert_eq!(s.sessions()["sess-a"].output, 7);

        // A partial line (still being written) is ignored...
        write!(h, "{}", &rec("m4", 100, 9)[..40]).unwrap();
        h.flush().unwrap();
        s.tick(&dir, &pricing);
        assert_eq!(s.sessions()["sess-a"].input, 35, "counted a half-written line");

        // ...and counted once the rest of it, plus the newline, lands.
        write!(h, "{}\n", &rec("m4", 100, 9)[40..]).unwrap();
        h.flush().unwrap();
        s.tick(&dir, &pricing);
        assert_eq!(s.sessions()["sess-a"].input, 135);

        // A second session is tracked under its own file stem.
        fs::write(dir.join("sess-b.jsonl"), format!("{}\n", rec("n1", 7, 0))).unwrap();
        s.tick(&dir, &pricing);
        assert_eq!(s.sessions()["sess-b"].input, 7);
        assert_eq!(s.sessions()["sess-a"].input, 135, "sessions leaked into each other");

        // The snapshot must expose those sessions by id.
        let snap: Value = serde_json::from_str(&s.snapshot_json(&pricing, now_ms())).unwrap();
        assert_eq!(snap["sessions"]["sess-a"]["input"], 135);
        assert_eq!(snap["sessions"]["sess-b"]["total_tokens"], 7);

        // `block_sessions` must actually be SERIALISED. It was computed and then
        // left out of the JSON, so the status line read null, dropped the 5h-S
        // row, and the only version on screen was the stale one showing
        // session-cumulative numbers.
        assert!(
            snap["block_sessions"].is_object(),
            "block_sessions missing from snapshot: {snap}"
        );

        // Whenever a block is active, a session's slice of it can never exceed
        // that session's all-time total — that inversion is the bug 5h-S had.
        let entry_time = parse_rfc3339_ms("2026-08-01T10:00:00.000Z").unwrap();
        let snap: Value =
            serde_json::from_str(&s.snapshot_json(&pricing, entry_time + 60_000)).unwrap();
        assert!(snap["block"].is_object(), "block should be active at entry time");
        let in_block = snap["block_sessions"]["sess-a"]["total_tokens"].as_u64().unwrap();
        let all_time = snap["sessions"]["sess-a"]["total_tokens"].as_u64().unwrap();
        assert!(in_block > 0, "active block must attribute usage to sess-a");
        assert!(in_block <= all_time, "5h-S ({in_block}) exceeded session total ({all_time})");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn strip_ansi_removes_sgr_keeps_text() {
        // Real 0x1b form.
        assert_eq!(strip_ansi("\x1b[37m|\x1b[0m 5h: 1.2M"), "| 5h: 1.2M");
        assert_eq!(strip_ansi("\x1b[1;33mwarn\x1b[0m"), "warn");
        // No escapes -> unchanged.
        assert_eq!(strip_ansi("plain"), "plain");
        // Truncated escapes must not panic or emit garbage.
        assert_eq!(strip_ansi("abc\x1b["), "abc");
        assert_eq!(strip_ansi("abc\x1b"), "abc");
    }

    #[test]
    fn strip_ansi_removes_literal_backslash_033_form() {
        // This is what publish_seg actually writes — verified against a live
        // segment, which contained zero 0x1b bytes and only the literal form.
        let seg = r"5h \033[37m│\033[0m New:2.3k($0.03) \033[1mΣ119.4M\033[0m";
        assert_eq!(strip_ansi(seg), "5h │ New:2.3k($0.03) Σ119.4M");
        // Multi-byte glyph adjacent to an escape must survive intact.
        assert_eq!(strip_ansi(r"\033[37m│\033[0m"), "│");
        // Truncated literal form.
        assert_eq!(strip_ansi(r"abc\033["), "abc");
        // A lone backslash is not an escape.
        assert_eq!(strip_ansi(r"a\b"), r"a\b");
    }

    /// `sessions`, `offsets` and `entries` must all stay bounded, not grow one
    /// slot per session/file/entry ever observed. Feed the scanner many more
    /// stale sessions than the retention window would ever keep live, plus a
    /// couple of files that get deleted out from under it, and assert the
    /// stale/dead entries are actually evicted rather than merely "small so
    /// far" — a smoke test wouldn't catch a collection that grows but just
    /// hasn't grown enough yet to notice.
    #[test]
    fn stale_sessions_and_dead_files_are_evicted_not_accumulated() {
        let dir = std::env::temp_dir().join(format!("my-ai-scan-bound-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let rec = |ts: &str, id: &str| {
            format!(
                r#"{{"type":"assistant","timestamp":"{ts}","requestId":"{id}","message":{{"id":"{id}","model":"claude-opus-5","usage":{{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}}}}"#
            )
        };

        // 300 sessions, each in its own file, all timestamped 30h in the past —
        // well outside RETAIN_MS (24h). Far more than any real 5h-window use
        // could ever keep alive, which is the point: boundedness must come from
        // eviction, not from the test happening to stay under some threshold.
        const STALE: usize = 300;
        let stale_ts = "2026-07-01T00:00:00.000Z"; // fixed, ancient relative to now_ms()
        for i in 0..STALE {
            let sid = format!("stale-{i}");
            fs::write(dir.join(format!("{sid}.jsonl")), format!("{}\n", rec(stale_ts, &sid))).unwrap();
        }
        // Two live sessions, timestamped now — must survive eviction.
        let live_rec = |id: &str| {
            format!(
                r#"{{"type":"assistant","timestamp":"{}","requestId":"{id}","message":{{"id":"{id}","model":"claude-opus-5","usage":{{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}}}}"#,
                chrono_now_rfc3339()
            )
        };
        fs::write(dir.join("live-a.jsonl"), format!("{}\n", live_rec("live-a"))).unwrap();
        fs::write(dir.join("live-b.jsonl"), format!("{}\n", live_rec("live-b"))).unwrap();

        let pricing = Pricing::load();
        let mut s = Scanner::new();
        s.tick(&dir, &pricing);

        // `entries` (RETAIN_MS window): only the 2 live entries remain.
        assert_eq!(s.entries.len(), 2, "stale entries were not pruned by RETAIN_MS");
        // `sessions`: the 300 stale sessions must be evicted, not retained
        // forever just because they were once seen.
        assert_eq!(s.sessions.len(), 2, "stale sessions were not evicted: {}", s.sessions.len());
        assert!(s.sessions.contains_key("live-a") && s.sessions.contains_key("live-b"));

        // Now delete every file (stale AND live) and tick again: `offsets` must
        // drop the dead paths rather than carry ~302 dead PathBuf keys forever.
        fs::remove_dir_all(&dir).unwrap();
        fs::create_dir_all(&dir).unwrap();
        s.tick(&dir, &pricing);
        assert_eq!(s.offsets.len(), 0, "offsets kept entries for files no longer on disk");

        fs::remove_dir_all(&dir).unwrap();
    }

    // Minimal RFC3339-now for the boundedness test above — avoids pulling in
    // chrono (this crate hand-parses RFC3339 already; see parse_rfc3339_ms /
    // civil_from_days) just to format the current instant for one test.
    fn chrono_now_rfc3339() -> String {
        let ms = now_ms();
        let days = ms.div_euclid(86_400_000);
        let rem = ms.rem_euclid(86_400_000);
        let (y, m, d) = civil_from_days(days);
        let hour = rem / 3_600_000;
        let min = (rem % 3_600_000) / 60_000;
        let sec = (rem % 60_000) / 1000;
        let millis = rem % 1000;
        format!("{y:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}.{millis:03}Z")
    }
}
