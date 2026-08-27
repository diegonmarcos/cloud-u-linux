// AGI — Claude Code usage + cost analytics (cloud-terminal AGI port). Scans
// ~/.claude/projects/**/*.jsonl transcripts for token usage and prices them
// against src/data/model-pricing.json (synced to $HOME/.local/share/my-konsole/).
// 3 pages ([1][2][3] or Left/Right to switch): Totals, Activity, Budget.
use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crossterm::event::KeyCode;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::Line;
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::block;
use super::sh;

const ACTIVE_SECS: u64 = 5 * 60; // mtime within 5min = still-running session

#[derive(Default, Clone)]
struct Usage { input: u64, output: u64, cache_r: u64, cache_w: u64, msgs: u64 }

#[derive(Clone)]
struct SessionInfo { name: String, age_secs: u64, msgs: u64, tokens: u64, cost: f64, duration_secs: i64 }

#[derive(Default, Clone)]
struct ToolStat { count: u64 }

struct ModelRate { input: f64, output: f64 }

struct Pricing {
    default: ModelRate,
    models: Vec<(String, ModelRate)>,
    cache_w_mult: f64,
    cache_r_mult: f64,
    budget_daily: f64,
    budget_monthly: f64,
}

impl Pricing {
    fn load() -> Self {
        let txt = sh("cat $HOME/.local/share/my-konsole/model-pricing.json 2>/dev/null");
        let v: serde_json::Value = serde_json::from_str(&txt).unwrap_or(serde_json::Value::Null);
        let rate = |o: &serde_json::Value| ModelRate {
            input: o.get("input").and_then(|x| x.as_f64()).unwrap_or(3.0),
            output: o.get("output").and_then(|x| x.as_f64()).unwrap_or(15.0),
        };
        let default = v.get("default").map(rate).unwrap_or(ModelRate { input: 3.0, output: 15.0 });
        let models = v.get("models").and_then(|m| m.as_array()).map(|arr| {
            arr.iter().filter_map(|m| {
                let name = m.get("match").and_then(|x| x.as_str())?.to_string();
                Some((name, rate(m)))
            }).collect()
        }).unwrap_or_default();
        Pricing {
            default,
            models,
            cache_w_mult: v.get("cache_write_multiplier").and_then(|x| x.as_f64()).unwrap_or(1.25),
            cache_r_mult: v.get("cache_read_multiplier").and_then(|x| x.as_f64()).unwrap_or(0.1),
            budget_daily: v.get("budget_usd_daily").and_then(|x| x.as_f64()).unwrap_or(20.0),
            budget_monthly: v.get("budget_usd_monthly").and_then(|x| x.as_f64()).unwrap_or(300.0),
        }
    }

    fn rate_for(&self, model: &str) -> &ModelRate {
        self.models.iter().find(|(m, _)| model.contains(m.as_str())).map(|(_, r)| r).unwrap_or(&self.default)
    }

    fn cost(&self, model: &str, u: &Usage) -> f64 {
        let r = self.rate_for(model);
        let cache_w_rate = r.input * self.cache_w_mult;
        let cache_r_rate = r.input * self.cache_r_mult;
        (u.input as f64 * r.input
            + u.output as f64 * r.output
            + u.cache_w as f64 * cache_w_rate
            + u.cache_r as f64 * cache_r_rate) / 1_000_000.0
    }
}

// Howard Hinnant's days-from-civil algorithm (proleptic Gregorian, no external date crate needed).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

// Zeller's congruence -> Mon=0..Sun=6
fn dow_index(y: i64, m: i64, d: i64) -> usize {
    let (yy, mm) = if m < 3 { (y - 1, m + 12) } else { (y, m) };
    let k = yy % 100;
    let j = yy / 100;
    let h = (d + (13 * (mm + 1)) / 5 + k + k / 4 + j / 4 + 5 * j).rem_euclid(7);
    ((h + 5) % 7) as usize
}

struct Ts { y: i64, mo: i64, d: i64, hh: i64, mi: i64, ss: i64 }

fn parse_ts(ts: &str) -> Option<Ts> {
    if ts.len() < 19 { return None; }
    Some(Ts {
        y: ts[0..4].parse().ok()?,
        mo: ts[5..7].parse().ok()?,
        d: ts[8..10].parse().ok()?,
        hh: ts[11..13].parse().ok()?,
        mi: ts[14..16].parse().ok()?,
        ss: ts[17..19].parse().ok()?,
    })
}

fn epoch_secs(t: &Ts) -> i64 {
    days_from_civil(t.y, t.mo, t.d) * 86400 + t.hh * 3600 + t.mi * 60 + t.ss
}

fn add(u: &mut Usage, usage: &serde_json::Value) {
    u.input += usage.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.output += usage.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.cache_r += usage.get("cache_read_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.cache_w += usage.get("cache_creation_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.msgs += 1;
}

fn age_label(secs: u64) -> String {
    if secs < 60 { format!("{secs}s ago") }
    else if secs < 3600 { format!("{}m ago", secs / 60) }
    else if secs < 86400 { format!("{}h ago", secs / 3600) }
    else { format!("{}d ago", secs / 86400) }
}

fn dur_label(secs: i64) -> String {
    let secs = secs.max(0);
    if secs < 3600 { format!("{}m", secs / 60) } else { format!("{}h{}m", secs / 3600, (secs % 3600) / 60) }
}

const BAR: &str = "▁▂▃▄▅▆▇█";
fn spark(counts: &[u64]) -> String {
    let max = *counts.iter().max().unwrap_or(&0).max(&1);
    counts.iter().map(|&c| {
        let idx = ((c as f64 / max as f64) * 7.0).round() as usize;
        BAR.chars().nth(idx.min(7)).unwrap_or('▁')
    }).collect()
}

pub struct Agi {
    page: usize,
    total: Usage,
    total_cost: f64,
    by_model: BTreeMap<String, Usage>,
    by_model_cost: BTreeMap<String, f64>,
    sessions: usize,
    recent: Vec<SessionInfo>,   // sorted newest-first
    active: usize,
    by_day: [u64; 7],           // tokens, index 0 = today (rolling 24h)
    cost_by_day: [f64; 7],
    by_project_cost: Vec<(String, f64)>, // sorted desc, top 8
    // activity page
    hour_hist: [u64; 24],
    dow_hist: [u64; 7],
    tool_stats: BTreeMap<String, ToolStat>,
    tool_result_total: u64,
    tool_result_errors: u64,
    compaction_events: u64,
    subagent_spawns: u64,
    sidechain_msgs: u64,
    // budget page
    budget_daily: f64,
    budget_monthly: f64,
    month_cost: f64,
    longest_sessions: Vec<(String, i64, f64)>, // name, duration_secs, cost — top 8
    model_share: Vec<(String, f64)>, // pct of total tokens, desc
}

impl Agi {
    pub fn new() -> Self {
        Agi {
            page: 0,
            total: Usage::default(), total_cost: 0.0,
            by_model: BTreeMap::new(), by_model_cost: BTreeMap::new(),
            sessions: 0, recent: Vec::new(), active: 0,
            by_day: [0; 7], cost_by_day: [0.0; 7], by_project_cost: Vec::new(),
            hour_hist: [0; 24], dow_hist: [0; 7],
            tool_stats: BTreeMap::new(), tool_result_total: 0, tool_result_errors: 0,
            compaction_events: 0, subagent_spawns: 0, sidechain_msgs: 0,
            budget_daily: 20.0, budget_monthly: 300.0, month_cost: 0.0,
            longest_sessions: Vec::new(), model_share: Vec::new(),
        }
    }
}

impl Dashboard for Agi {
    fn title(&self) -> String {
        let p = match self.page { 1 => "activity", 2 => "budget", _ => "totals" };
        format!("🤖 agi [{p} {}/3 — ←/→]", self.page + 1)
    }
    fn tick_ms(&self) -> u64 { 8000 }

    fn on_key(&mut self, key: KeyCode) {
        match key {
            KeyCode::Left | KeyCode::Char('h') => self.page = (self.page + 2) % 3,
            KeyCode::Right | KeyCode::Char('l') | KeyCode::Tab => self.page = (self.page + 1) % 3,
            KeyCode::Char('1') => self.page = 0,
            KeyCode::Char('2') => self.page = 1,
            KeyCode::Char('3') => self.page = 2,
            _ => {}
        }
    }

    fn update(&mut self) {
        let pricing = Pricing::load();
        self.budget_daily = pricing.budget_daily;
        self.budget_monthly = pricing.budget_monthly;
        self.total = Usage::default();
        self.total_cost = 0.0;
        self.by_model.clear();
        self.by_model_cost.clear();
        self.sessions = 0;
        self.active = 0;
        self.by_day = [0; 7];
        self.cost_by_day = [0.0; 7];
        self.hour_hist = [0; 24];
        self.dow_hist = [0; 7];
        self.tool_stats.clear();
        self.tool_result_total = 0;
        self.tool_result_errors = 0;
        self.compaction_events = 0;
        self.subagent_spawns = 0;
        self.sidechain_msgs = 0;
        self.month_cost = 0.0;
        let mut project_cost: BTreeMap<String, f64> = BTreeMap::new();
        let mut sessions: Vec<SessionInfo> = Vec::new();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        let now_epoch = now as i64;
        let files = sh("find $HOME/.claude/projects -name '*.jsonl' -mtime -30 2>/dev/null");
        for path in files.lines() {
            self.sessions += 1;
            let mtime = std::fs::metadata(path).ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(now);
            let age = now.saturating_sub(mtime);
            if age <= ACTIVE_SECS { self.active += 1; }
            let day = (age / 86400).min(6) as usize;

            let Ok(txt) = std::fs::read_to_string(path) else { continue };
            let mut s_msgs = 0u64;
            let mut s_tokens = 0u64;
            let mut s_cost = 0.0f64;
            let mut first_ts: Option<i64> = None;
            let mut last_ts: Option<i64> = None;
            for line in txt.lines() {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };

                if let Some(ts_str) = v.get("timestamp").and_then(|t| t.as_str()) {
                    if let Some(t) = parse_ts(ts_str) {
                        let e = epoch_secs(&t);
                        if now_epoch - e <= 30 * 86400 {
                            self.hour_hist[t.hh as usize] += 1;
                            self.dow_hist[dow_index(t.y, t.mo, t.d)] += 1;
                            if now_epoch - e <= 30 * 86400 && e / 86400 == now_epoch / 86400 { /* today, calendar */ }
                        }
                        first_ts = Some(first_ts.map_or(e, |f: i64| f.min(e)));
                        last_ts = Some(last_ts.map_or(e, |l: i64| l.max(e)));
                        // calendar month-to-date bucket handled below via cost accumulation
                    }
                }

                if v.get("isSidechain").and_then(|b| b.as_bool()) == Some(true) { self.sidechain_msgs += 1; }
                if v.pointer("/message/role").and_then(|r| r.as_str()) == Some("user") {
                    if let Some(s) = v.pointer("/message/content").and_then(|c| c.as_str()) {
                        if s.starts_with("This session is being continued from a previous conversation") {
                            self.compaction_events += 1;
                        }
                    }
                }
                if let Some(content) = v.pointer("/message/content").and_then(|c| c.as_array()) {
                    for item in content {
                        match item.get("type").and_then(|t| t.as_str()) {
                            Some("tool_use") => {
                                let name = item.get("name").and_then(|n| n.as_str()).unwrap_or("?").to_string();
                                if name == "Agent" || name == "Workflow" { self.subagent_spawns += 1; }
                                self.tool_stats.entry(name).or_default().count += 1;
                            }
                            Some("tool_result") => {
                                self.tool_result_total += 1;
                                if item.get("is_error").and_then(|b| b.as_bool()) == Some(true) {
                                    self.tool_result_errors += 1;
                                }
                            }
                            _ => {}
                        }
                    }
                }

                let Some(usage) = v.pointer("/message/usage") else { continue };
                let model = v.pointer("/message/model").and_then(|m| m.as_str()).unwrap_or("?").to_string();
                let mut one = Usage::default();
                add(&mut one, usage);
                add(&mut self.total, usage);
                add(self.by_model.entry(model.clone()).or_default(), usage);
                let c = pricing.cost(&model, &one);
                self.total_cost += c;
                *self.by_model_cost.entry(model).or_default() += c;
                self.cost_by_day[day] += c;
                s_cost += c;
                if age <= 30 * 86400 { self.month_cost += c; }

                let tin = usage.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                let tout = usage.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                s_msgs += 1;
                s_tokens += tin + tout;
                self.by_day[day] += tin + tout;
            }
            let name: String = std::path::Path::new(path)
                .parent().and_then(|p| p.file_name()).and_then(|s| s.to_str())
                .unwrap_or("?").chars().take(32).collect();
            *project_cost.entry(name.clone()).or_default() += s_cost;
            let duration_secs = match (first_ts, last_ts) { (Some(f), Some(l)) => l - f, _ => 0 };
            sessions.push(SessionInfo { name, age_secs: age, msgs: s_msgs, tokens: s_tokens, cost: s_cost, duration_secs });
        }

        let mut longest = sessions.clone();
        longest.sort_by(|a, b| b.duration_secs.cmp(&a.duration_secs));
        longest.truncate(8);
        self.longest_sessions = longest.into_iter().map(|s| (s.name, s.duration_secs, s.cost)).collect();

        sessions.sort_by_key(|s| s.age_secs);
        sessions.truncate(15);
        self.recent = sessions;

        let mut projects: Vec<(String, f64)> = project_cost.into_iter().collect();
        projects.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        projects.truncate(8);
        self.by_project_cost = projects;

        let total_tokens = (self.total.input + self.total.output).max(1) as f64;
        let mut share: Vec<(String, f64)> = self.by_model.iter()
            .map(|(m, u)| (m.clone(), (u.input + u.output) as f64 / total_tokens * 100.0))
            .collect();
        share.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        self.model_share = share;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        match self.page {
            0 => self.render_totals(f, area),
            1 => self.render_activity(f, area),
            _ => self.render_budget(f, area),
        }
    }
}

impl Agi {
    fn render_totals(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([
            Constraint::Length(4),
            Constraint::Length(9),
            Constraint::Min(6),
            Constraint::Length(9),
            Constraint::Length(10),
        ]).split(area);

        let cache_total = (self.total.cache_r + self.total.cache_w).max(1);
        let cache_hit_pct = self.total.cache_r as f64 / cache_total as f64 * 100.0;
        let head = Paragraph::new(vec![
            Line::from(format!(
                "sessions {}  active {}  msgs {}  cache-hit {:.0}%",
                self.sessions, self.active, self.total.msgs, cache_hit_pct
            )),
            Line::from(format!(
                "in {}  out {}  cache-r {}  cache-w {}",
                self.total.input, self.total.output, self.total.cache_r, self.total.cache_w
            )),
            Line::styled(
                format!(
                    "$ today {:.2}  7d {:.2}  30d {:.2}",
                    self.cost_by_day[0],
                    self.cost_by_day[..7.min(7)].iter().take(7).sum::<f64>(),
                    self.cost_by_day.iter().sum::<f64>()
                ),
                Style::default().fg(Color::Green),
            ),
        ]).block(block("TOTAL + COST (last 30d)"));
        f.render_widget(head, rows[0]);

        let day_lines: Vec<Line> = (0..7).map(|i| {
            let label = match i { 0 => "today".into(), n => format!("{n}d ago") };
            Line::from(format!("{:<8} tok {:<10} ${:.2}", label, self.by_day[i], self.cost_by_day[i]))
        }).collect();
        f.render_widget(Paragraph::new(day_lines).block(block("TOKENS + COST / DAY (last 7d)")), rows[1]);

        let sess_lines: Vec<Line> = self.recent.iter().map(|s| {
            Line::from(format!(
                "{:<32} {:<9} msgs {:<4} tok {:<8} ${:.2}",
                s.name, age_label(s.age_secs), s.msgs, s.tokens, s.cost
            ))
        }).collect();
        f.render_widget(Paragraph::new(sess_lines).block(block("LAST 15 SESSIONS")), rows[2]);

        let model_lines: Vec<Line> = self.by_model.iter().map(|(m, u)| {
            let c = self.by_model_cost.get(m).copied().unwrap_or(0.0);
            Line::from(format!(
                "{:<20} msgs {:<5} in {:<9} out {:<9} cache-r {:<9} ${:.2}",
                m, u.msgs, u.input, u.output, u.cache_r, c
            ))
        }).collect();
        f.render_widget(Paragraph::new(model_lines).block(block("BY MODEL + COST")), rows[3]);

        let max_p = self.by_project_cost.iter().map(|(_, c)| *c).fold(0.0_f64, f64::max).max(0.001);
        let proj_lines: Vec<Line> = self.by_project_cost.iter().map(|(name, c)| {
            let bar_len = ((c / max_p) * 30.0) as usize;
            Line::from(format!("{:<32} {} ${:.2}", name, "█".repeat(bar_len.max(1)), c))
        }).collect();
        f.render_widget(Paragraph::new(proj_lines).block(block("TOP PROJECTS BY COST (30d)")), rows[4]);
    }

    fn render_activity(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([
            Constraint::Length(5),
            Constraint::Length(4),
            Constraint::Min(6),
            Constraint::Length(4),
            Constraint::Length(5),
        ]).split(area);

        let dow_names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
        let dow_line = self.dow_hist.iter().zip(dow_names).map(|(c, n)| format!("{n}:{c}")).collect::<Vec<_>>().join("  ");
        let head = Paragraph::new(vec![
            Line::from(format!("hour(00-23) {}", spark(&self.hour_hist))),
            Line::from(dow_line),
        ]).block(block("ACTIVITY — HOUR-OF-DAY + DAY-OF-WEEK (30d, msg counts)"));
        f.render_widget(head, rows[0]);

        let velocity = self.by_day[0] as f64 / (24.0 * 60.0);
        let vel = Paragraph::new(vec![
            Line::styled(format!("~{:.0} tokens/min (rolling 24h avg, {} tok)", velocity, self.by_day[0]), Style::default().fg(Color::Cyan)),
        ]).block(block("TOKEN VELOCITY"));
        f.render_widget(vel, rows[1]);

        let err_pct = if self.tool_result_total > 0 { self.tool_result_errors as f64 / self.tool_result_total as f64 * 100.0 } else { 0.0 };
        let mut tools: Vec<(&String, u64)> = self.tool_stats.iter().map(|(n, s)| (n, s.count)).collect();
        tools.sort_by(|a, b| b.1.cmp(&a.1));
        let mut tool_lines: Vec<Line> = tools.iter().map(|(n, c)| Line::from(format!("{:<20} {}", n, c))).collect();
        tool_lines.push(Line::styled(
            format!("tool_result errors: {}/{} ({:.1}%)", self.tool_result_errors, self.tool_result_total, err_pct),
            Style::default().fg(if err_pct > 5.0 { Color::Red } else { Color::Yellow }),
        ));
        f.render_widget(Paragraph::new(tool_lines).block(block("TOOL-CALL FREQUENCY + ERROR RATE (30d)")), rows[2]);

        let comp = Paragraph::new(vec![
            Line::from(format!("{} auto-compaction events in last 30d", self.compaction_events)),
        ]).block(block("CONTEXT COMPACTION EVENTS"));
        f.render_widget(comp, rows[3]);

        let idle = self.sessions.saturating_sub(self.active);
        let sub = Paragraph::new(vec![
            Line::from(format!("Agent/Workflow spawns: {}   sidechain (subagent) msgs: {}", self.subagent_spawns, self.sidechain_msgs)),
            Line::from(format!("sessions active {} / idle {} (total {})", self.active, idle, self.sessions)),
        ]).block(block("SUBAGENT FAN-OUT + IDLE/ACTIVE"));
        f.render_widget(sub, rows[4]);
    }

    fn render_budget(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([
            Constraint::Length(6),
            Constraint::Min(6),
            Constraint::Length(6),
            Constraint::Length(4),
        ]).split(area);

        let bar = |used: f64, budget: f64| -> String {
            let pct = if budget > 0.0 { (used / budget * 100.0).min(200.0) } else { 0.0 };
            let filled = ((pct / 100.0) * 30.0).round().max(0.0) as usize;
            format!("{}{} {:.0}%", "█".repeat(filled.min(30)), "░".repeat(30usize.saturating_sub(filled.min(30))), pct)
        };
        let today = self.cost_by_day[0];
        let budget_lines = vec![
            Line::from(format!("today   ${:.2} / ${:.2}  {}", today, self.budget_daily, bar(today, self.budget_daily))),
            Line::from(format!("30d     ${:.2} / ${:.2}  {}", self.month_cost, self.budget_monthly, bar(self.month_cost, self.budget_monthly))),
            Line::from("(edit budget_usd_daily / budget_usd_monthly in model-pricing.json)"),
        ];
        f.render_widget(Paragraph::new(budget_lines).block(block("BUDGET vs ACTUAL")), rows[0]);

        let longest_lines: Vec<Line> = self.longest_sessions.iter().map(|(name, dur, cost)| {
            Line::from(format!("{:<32} {:<8} ${:.2}", name, dur_label(*dur), cost))
        }).collect();
        f.render_widget(Paragraph::new(longest_lines).block(block("LONGEST-RUNNING SESSIONS (by wall-clock, 30d)")), rows[1]);

        let mix_lines: Vec<Line> = self.model_share.iter().map(|(m, pct)| {
            let bar_len = (pct / 100.0 * 30.0) as usize;
            Line::from(format!("{:<20} {} {:.1}%", m, "█".repeat(bar_len.max(1)), pct))
        }).collect();
        f.render_widget(Paragraph::new(mix_lines).block(block("MODEL MIX TREND (% of tokens, 30d)")), rows[2]);

        let idle = self.sessions.saturating_sub(self.active);
        let ratio_pct = if self.sessions > 0 { self.active as f64 / self.sessions as f64 * 100.0 } else { 0.0 };
        let ratio = Paragraph::new(vec![
            Line::from(format!("active {} / idle {}  ({:.0}% active)", self.active, idle, ratio_pct)),
        ]).block(block("IDLE vs ACTIVE SESSION RATIO"));
        f.render_widget(ratio, rows[3]);
    }
}
