//! Render — build the single-screen dashboard as styled ratatui Lines.
//! Faithful port of the mjs render()/pageCompose/pageNetwork/pageSessions/pageSystem,
//! regrouped into 4 mega-sections (COMPOSE/SESSIONS/AI STACK/MESH) via mega_head(),
//! each still built from the original sub-section page_* helpers.
use crate::collect::{parse_df, parse_repo, Slot, REPOS};
use crate::offline::{ago, Cfg, ClaudeFlag, Hook, Mcp, Plugin, Sessions};
use crate::state::{build_rows, focusable, sel_args, St, PONY};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use std::collections::BTreeMap;
use std::fs;

const SPIN: [&str; 4] = ["|", "/", "-", "\\"];
const W: usize = 76;

use Color::{Blue, Cyan, DarkGray as Dim, Green, Magenta, Red, Yellow};

fn sp<S: Into<String>>(t: S, c: Color) -> Span<'static> {
    Span::styled(t.into(), Style::default().fg(c))
}
fn dim<S: Into<String>>(t: S) -> Span<'static> {
    sp(t, Dim)
}
fn raw<S: Into<String>>(t: S) -> Span<'static> {
    Span::raw(t.into())
}
fn boldc<S: Into<String>>(t: S, c: Color) -> Span<'static> {
    Span::styled(t.into(), Style::default().fg(c).add_modifier(Modifier::BOLD))
}
fn commas(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    let b = s.as_bytes();
    for (i, ch) in b.iter().enumerate() {
        if i > 0 && (b.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(*ch as char);
    }
    out
}
fn pad_e(s: &str, n: usize) -> String {
    if s.chars().count() >= n {
        s.to_string()
    } else {
        format!("{}{}", s, " ".repeat(n - s.chars().count()))
    }
}
fn num_body(v: &serde_json::Value, k: &str) -> String {
    commas(v.get(k).and_then(|x| x.as_u64()).unwrap_or(0))
}

pub struct Ctx<'a> {
    pub st: &'a St,
    pub mcps: &'a [Mcp],
    pub flags: &'a [ClaudeFlag],
    pub plugins: &'a [Plugin],
    pub hooks: &'a [Hook],
    pub sessions: &'a Sessions,
    pub cfg: &'a Cfg,
    pub data: &'a BTreeMap<String, Slot>,
    pub mesh: &'a BTreeMap<String, String>,
    pub public: &'a BTreeMap<String, String>,
    pub spin: usize,
    pub refreshing: bool,
    pub last_launch: &'a str,
    pub focus: usize,
    pub num_buf: &'a str,
    pub is_termux: bool,
}

impl<'a> Ctx<'a> {
    fn get(&self, id: &str) -> &Slot {
        self.data.get(id).unwrap_or(&Slot::NotProbed)
    }
    fn spinch(&self) -> &'static str {
        SPIN[self.spin % 4]
    }
}

/// Status-cell for a probe slot (mirror of dm()).
fn dm(slot: &Slot, spinch: &str) -> Vec<Span<'static>> {
    match slot {
        Slot::NotProbed => vec![dim("--    ")],
        Slot::Pending => vec![dim(format!("{spinch}     "))],
        Slot::Timeout => vec![sp("t/o   ", Yellow)],
        Slot::Stdio => vec![sp("stdio ", Blue)],
        Slot::Up { ms, .. } => {
            let col = if *ms < 60 { Green } else if *ms < 200 { Yellow } else { Red };
            vec![sp("up ", Green), sp(format!("{ms:>4}ms"), col)]
        }
        Slot::Down { .. } => vec![sp("dn    ", Red)],
        Slot::Cmd(_) => vec![dim("ok    ")],
        Slot::Image(_) => vec![dim("img   ")],
    }
}

fn sec_head(title: &str, right: &str) -> Line<'static> {
    let label = format!("[ {title} ]");
    let rt = if right.is_empty() { String::new() } else { format!("[ {right} ]") };
    let fill = W.saturating_sub(label.len() + rt.len() + 6).max(2);
    let mut spans = vec![boldc("  +==", Cyan), boldc(label, Magenta)];
    spans.push(boldc("=".repeat(fill), Cyan));
    if !rt.is_empty() {
        spans.push(sp(rt, Yellow));
    }
    spans.push(boldc("==+", Cyan));
    Line::from(spans)
}

/// Mega-section banner: bolder/wider than sec_head, marks top-level groups
/// (COMPOSE / SESSIONS / AI STACK / MESH) so hierarchy reads as
/// mega-section > sub-section (sec_head) > row.
fn mega_head(title: &str) -> Vec<Line<'static>> {
    let bar = "#".repeat(W + 2);
    let label = format!(" {title} ");
    let fill = (W + 2).saturating_sub(label.len());
    let lead = fill / 2;
    let trail = fill - lead;
    let mid = format!("{}{}{}", "#".repeat(lead), label, "#".repeat(trail));
    vec![
        Line::from(""),
        Line::from(boldc(format!("  {bar}"), Yellow)),
        Line::from(boldc(format!("  {mid}"), Yellow)),
        Line::from(boldc(format!("  {bar}"), Yellow)),
    ]
}

/// Rendered lines plus the line index the focused row landed on.
///
/// The caller needs the LINE index, not the focusable-row index: only a subset
/// of lines are focusable rows (headers, blanks and read-only blocks sit
/// between them), so the two counts differ and scrolling by the row index
/// moves the viewport at the wrong rate.
pub struct Rendered {
    pub lines: Vec<Line<'static>>,
    pub focus_line: Option<usize>,
}

pub fn build_lines(cx: &Ctx) -> Rendered {
    let mut focus_line: Option<usize> = None;
    let mut l: Vec<Line> = Vec::new();
    let bar = format!("  +{}+", "-".repeat(W));
    l.push(Line::from(boldc(bar.clone(), Cyan)));
    l.push(Line::from(vec![
        boldc("  | ", Cyan),
        boldc("M Y - A I", Magenta),
        dim("   launch + infra dashboard"),
    ]));
    l.push(Line::from(boldc(bar, Cyan)));

    // composed-command line
    let self_cmd = std::env::var("CAS_SELF").unwrap_or_else(|_| "my-ai".into());
    let mut cmd_spans = vec![sp("   > ", Green), sp(format!("{self_cmd} {}", sel_args(cx.st, cx.mcps, cx.flags).join(" ")), Cyan)];
    if cx.refreshing {
        let pr = progress(cx);
        cmd_spans.push(sp(format!("   {} probing {}/{}", cx.spinch(), pr.0, pr.1), Yellow));
    } else {
        cmd_spans.push(dim("   r=Refresh"));
    }
    l.push(Line::from(cmd_spans));
    if !cx.last_launch.is_empty() {
        l.push(Line::from(sp(format!("   [launched in new window: {}]  TUI stays open", cx.last_launch), Green)));
    }

    l.extend(mega_head("COMPOSE"));
    focus_line = page_compose(cx, &mut l);

    l.extend(mega_head("SESSIONS"));
    page_sessions(cx, &mut l);

    l.extend(mega_head("AI STACK"));
    page_stack(cx, &mut l);

    l.extend(mega_head("MESH"));
    page_mesh(cx, &mut l);

    l.push(Line::from(""));
    l.push(sec_head("KEYS + LEGEND", ""));
    l.push(Line::from(vec![
        boldc("   (l)", Green),
        raw("aunch  "),
        boldc("(r)", Blue),
        raw("efresh  "),
        boldc("(q)", Dim),
        raw("uit   "),
        dim("Up/Down move . Space select . Left/Right change . 0-9 type N . Enter activate"),
    ]));
    l.push(Line::from(vec![
        sp("   up", Green),
        dim("=reachable(+latency)  "),
        sp("dn", Red),
        dim("=down  "),
        sp("t/o", Yellow),
        dim("=timeout(<2s)  ..=probing  --=not probed (r)  "),
        sp("stdio", Blue),
        dim("=local-process MCP"),
    ]));
    Rendered { lines: l, focus_line }
}

fn progress(cx: &Ctx) -> (usize, usize) {
    let mut done = 0;
    let mut total = 0;
    for (_id, s) in cx.data.iter() {
        total += 1;
        if !matches!(s, Slot::Pending | Slot::NotProbed) {
            done += 1;
        }
    }
    (done, total)
}

/// Returns the line index the focused row was rendered at, if any.
fn page_compose(cx: &Ctx, l: &mut Vec<Line<'static>>) -> Option<usize> {
    let mut focus_line = None;
    let rows = build_rows(cx.st, cx.mesh, cx.is_termux, cx.mcps, cx.flags);
    let fl = focusable(&rows);
    let foc_idx = fl.get(cx.focus.min(fl.len().saturating_sub(1))).copied().unwrap_or(usize::MAX);
    l.push(Line::from(""));
    l.push(sec_head("COMPOSE", &format!("{} · {}", cx.st.agent, cx.st.face)));
    for (i, row) in rows.iter().enumerate() {
        let foc = i == foc_idx;
        let cur = if foc { boldc("> ", Cyan) } else { raw("  ") };
        if row.kind == "sec" {
            l.push(Line::from(dim(format!("   {}", row.label))));
            continue;
        }
        let hl = |s: String| -> Span<'static> {
            if foc {
                Span::styled(s, Style::default().add_modifier(Modifier::REVERSED))
            } else {
                raw(s)
            }
        };
        let mut spans = vec![raw("  "), cur];
        match row.kind {
            "radio" => {
                let on = state_val(cx.st, row.grp) == row.val;
                spans.push(if on { sp("(*) ", Green) } else { dim("( ) ") });
                spans.push(hl(pad_e(&row.label, 8)));
                spans.push(dim(format!(" {}", row.note)));
            }
            "check" => {
                let on = state_bool(cx.st, row.key);
                spans.push(if on { sp("[x] ", Green) } else { dim("[ ] ") });
                spans.push(hl(pad_e(&row.label, 8)));
                spans.push(dim(format!(" {}", row.note)));
                // MCP rows carry their own live status dot (was a separate
                // read-only "MCP servers" block below COMPOSE; folded in here
                // so enabling/disabling and health share one row).
                if let Some(name) = row.key.strip_prefix("mcp:") {
                    spans.push(raw("  "));
                    let is_http = cx.mcps.iter().find(|m| m.name == name).map(|m| m.kind == "http").unwrap_or(false);
                    if is_http {
                        spans.extend(dm(cx.get(row.key), cx.spinch()));
                    } else {
                        spans.extend(dm(&Slot::Stdio, cx.spinch()));
                    }
                }
            }
            "checklevel" => {
                let on = cx.st.ponytail;
                spans.push(if on { sp("[x] ", Green) } else { dim("[ ] ") });
                spans.push(hl(pad_e(&row.label, 8)));
                if on {
                    spans.push(sp(format!(" < {} > ", PONY[cx.st.pony]), Magenta));
                } else {
                    spans.push(dim(" (off) "));
                }
                spans.push(dim(row.note.to_string()));
            }
            "number" => {
                let shown = if foc && !cx.num_buf.is_empty() { cx.num_buf.to_string() } else { cx.st.restore_n.to_string() };
                spans.push(raw("    "));
                spans.push(hl(row.label.clone()));
                if foc {
                    spans.push(Span::styled(format!(" {shown}_ "), Style::default().add_modifier(Modifier::REVERSED)));
                } else {
                    spans.push(sp(format!(" < {shown} > "), Magenta));
                }
                spans.push(dim(format!("  {}", row.note)));
            }
            "action" => {
                let (txt, col) = match row.key {
                    "refresh" => (" (r) Refresh ", Blue),
                    "launch" => (" (l) LAUNCH ", Green),
                    _ => (" (q) Quit ", Dim),
                };
                if foc {
                    spans.push(Span::styled(txt.to_string(), Style::default().fg(col).add_modifier(Modifier::REVERSED)));
                } else {
                    spans.push(sp(format!("[{}]", txt.trim()), col));
                }
            }
            _ => {}
        }
        if foc {
            focus_line = Some(l.len());
        }
        l.push(Line::from(spans));
    }
    focus_line
}

fn state_val<'b>(st: &'b St, grp: &str) -> &'b str {
    match grp {
        "agent" => &st.agent,
        "face" => &st.face,
        "restore" => &st.restore,
        _ => "",
    }
}
fn state_bool(st: &St, key: &str) -> bool {
    match key {
        "headroom" => st.headroom,
        "rtk" => st.rtk,
        "caveman" => st.caveman,
        "ponytail" => st.ponytail,
        "statusline" => st.statusline,
        _ if key.starts_with("mcp:") => st.mcp_is_on(&key[4..]),
        // Data-driven claude-flags.json keys land here; flag_on() defaults to
        // false for anything not in claude_flags, same as the old fallback.
        _ => st.flag_on(key),
    }
}

fn kv(k: &str, mut spans: Vec<Span<'static>>) -> Line<'static> {
    let mut out = vec![dim(format!("    {}", pad_e(k, 11)))];
    out.append(&mut spans);
    Line::from(out)
}

/// AI STACK mega-section: FACES/services health, container, tokens,
/// image-arches, plus HOST/GIT REPOS/CLAUDE (local-machine-stack details).
fn page_stack(cx: &Ctx, l: &mut Vec<Line<'static>>) {
    l.push(Line::from(""));
    l.push(sec_head("FACES", ""));
    let labels = ["proxy", "api", "ollama", "compr", "direct"];
    let ids = ["proxy", "api", "ollama", "compress", "direct"];
    let mut svc = Vec::new();
    for (lab, id) in labels.iter().zip(ids.iter()) {
        svc.push(dim(format!("{lab} ")));
        svc.extend(dm(cx.get(id), cx.spinch()));
        svc.push(raw(" "));
    }
    l.push(kv("services", svc));

    // container health
    let mut cont = vec![dim("--".to_string())];
    match cx.get("health") {
        Slot::Pending => cont = vec![dim(cx.spinch().to_string())],
        Slot::Timeout => cont = vec![sp("t/o", Yellow)],
        Slot::Up { body: Some(b), .. } => {
            let stats = b.get("stats").cloned().unwrap_or(serde_json::json!({}));
            cont = vec![
                dim("conc "),
                raw(format!("{}/{}  ", b.get("active").and_then(|v| v.as_u64()).unwrap_or(0), b.get("max").and_then(|v| v.as_u64()).unwrap_or(0))),
                dim("calls "),
                raw(format!("{}  ", num_body(&stats, "calls"))),
                dim("err "),
                raw(format!("{}  ", num_body(&stats, "errors"))),
                dim("in "),
                raw(format!("{}  ", num_body(&stats, "prompt_tokens"))),
                dim("out "),
                raw(num_body(&stats, "completion_tokens")),
            ];
        }
        _ => {}
    }
    l.push(kv("container", cont));

    // tokens saved
    let mut tok = vec![dim("--".to_string())];
    match cx.get("tokens") {
        Slot::Pending => tok = vec![dim(cx.spinch().to_string())],
        Slot::Timeout => tok = vec![sp("t/o", Yellow)],
        Slot::Up { body: Some(j), .. } => {
            let ratio = j.get("lifetime_ratio").and_then(|v| v.as_f64()).unwrap_or(0.0) * 100.0;
            tok = vec![
                sp(num_body(j, "tokens_saved"), Yellow),
                dim(format!(" saved ({ratio:.0}%)  before ")),
                raw(num_body(j, "tokens_before")),
                dim("  after "),
                raw(num_body(j, "tokens_after")),
                dim("  compress "),
                raw(num_body(j, "compressions")),
            ];
        }
        _ => {}
    }
    l.push(kv("tokens", tok));

    // image arches
    let mut img = vec![dim("--".to_string())];
    match cx.get("image") {
        Slot::Pending => img = vec![dim(cx.spinch().to_string())],
        Slot::Timeout => img = vec![sp("t/o", Yellow)],
        Slot::Image(arches) => {
            let multi = arches.len() > 1;
            img = vec![
                sp(arches.join(","), if multi { Green } else { Red }),
                dim(if multi { " (multi-arch)" } else { " (single-arch!)" }.to_string()),
            ];
        }
        _ => {}
    }
    l.push(kv("image", img));

    // HOST (disk/mem/load) + GIT REPOS + CLAUDE (model/plugins/skills/hooks)
    page_system(cx, l);
}

/// MESH mega-section: wireguard peers + public edge — everything about the
/// peer/network mesh.
fn page_mesh(cx: &Ctx, l: &mut Vec<Line<'static>>) {
    // mesh
    l.push(Line::from(""));
    l.push(sec_head("MESH (wg)", ""));
    let mut mesh = vec![raw("    ")];
    for n in cx.mesh.keys() {
        mesh.push(dim(pad_e(n, 13)));
        mesh.extend(dm(cx.get(&format!("mesh:{n}")), cx.spinch()));
        mesh.push(raw("  "));
    }
    l.push(Line::from(mesh));

    // public
    l.push(Line::from(""));
    l.push(sec_head("PUBLIC edge", ""));
    let mut pubs = vec![raw("    ")];
    for n in cx.public.keys() {
        pubs.push(dim(pad_e(n, 13)));
        pubs.extend(dm(cx.get(&format!("pub:{n}")), cx.spinch()));
        pubs.push(raw("  "));
    }
    l.push(Line::from(pubs));
}

fn page_sessions(cx: &Ctx, l: &mut Vec<Line<'static>>) {
    l.push(Line::from(""));
    l.push(sec_head(
        &format!("LOCAL sessions ({} total, {}MB)", cx.sessions.total, cx.sessions.bytes / 1_048_576),
        "",
    ));
    l.push(Line::from(dim(format!(
        "    {}{}{}{}cwd",
        pad_e("age", 5),
        pad_e("msgs", 6),
        pad_e("size", 7),
        pad_e("title", 32)
    ))));
    for s in &cx.sessions.list {
        l.push(Line::from(vec![
            raw(format!("    {}", pad_e(&s.age, 5))),
            dim(format!("{}{}", pad_e(&s.msgs.to_string(), 6), pad_e(&format!("{}K", s.kb), 7))),
            raw(pad_e(&s.title, 32)),
            dim(s.cwd.clone()),
        ]));
    }

    l.push(Line::from(""));
    l.push(sec_head("SERVER sessions (hub)", if cx.refreshing { "probing" } else { "" }));
    match cx.get("server") {
        Slot::NotProbed => l.push(Line::from(dim("    -- press Refresh / r"))),
        Slot::Pending => l.push(Line::from(dim(format!("    {} loading", cx.spinch())))),
        Slot::Timeout => l.push(Line::from(sp("    t/o (hub unreachable)", Yellow))),
        Slot::Up { body: Some(serde_json::Value::Array(arr)), .. } => {
            let mut by_dev: BTreeMap<String, Vec<&serde_json::Value>> = BTreeMap::new();
            for s in arr {
                let dev = s.get("device").and_then(|v| v.as_str()).unwrap_or("?").to_string();
                by_dev.entry(dev).or_default().push(s);
            }
            l.push(Line::from(dim(format!("    {} sessions across {} device(s)", arr.len(), by_dev.len()))));
            for (dev, list) in &by_dev {
                l.push(Line::from(vec![sp(format!("    {dev}"), Cyan), dim(format!(" ({})", list.len()))]));
                for s in list.iter().take(10) {
                    let mt = s.get("mtime").and_then(|v| v.as_u64()).unwrap_or(0);
                    let id = s.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    let sz = s.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
                    l.push(Line::from(dim(format!(
                        "      {:>5}  {}{}",
                        if mt > 0 { ago(mt) } else { String::new() },
                        pad_e(&id.chars().take(8).collect::<String>(), 10),
                        pad_e(&format!("{}K", sz / 1024), 6)
                    ))));
                }
            }
        }
        _ => {}
    }
}

fn page_system(cx: &Ctx, l: &mut Vec<Line<'static>>) {
    l.push(Line::from(""));
    l.push(sec_head("HOST", ""));
    match cx.get("hostdisk") {
        Slot::NotProbed => l.push(Line::from(dim("    disk    -- press Refresh"))),
        Slot::Pending => l.push(Line::from(dim(format!("    disk    {}", cx.spinch())))),
        Slot::Timeout => l.push(Line::from(sp("    disk    t/o", Yellow))),
        Slot::Cmd(out) => {
            for d in parse_df(out) {
                let pct: i64 = d.pct.trim_end_matches('%').parse().unwrap_or(0);
                let col = if pct > 90 { Red } else if pct > 75 { Yellow } else { Green };
                l.push(Line::from(vec![
                    dim(format!("    disk  {} ", pad_e(&d.mount, 18))),
                    sp(format!("{:>4}", d.pct), col),
                    dim(format!(" {}/{} used, {} free", d.used, d.size, d.avail)),
                ]));
            }
        }
        _ => {}
    }
    if let Ok(mi) = fs::read_to_string("/proc/meminfo") {
        let g = |k: &str| -> f64 {
            mi.lines()
                .find(|l| l.starts_with(k))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|n| n.parse::<f64>().ok())
                .unwrap_or(0.0)
        };
        let tot = g("MemTotal:");
        let av = g("MemAvailable:");
        if tot > 0.0 {
            l.push(Line::from(dim(format!(
                "    mem   {} {:.0}% {:.1}G free / {:.1}G",
                pad_e("", 18),
                (1.0 - av / tot) * 100.0,
                av / 1_048_576.0,
                tot / 1_048_576.0
            ))));
        }
    }
    if let Ok(la) = fs::read_to_string("/proc/loadavg") {
        let la: String = la.split_whitespace().take(3).collect::<Vec<_>>().join(" ");
        l.push(Line::from(dim(format!("    load  {} {la}", pad_e("", 18)))));
    }

    l.push(Line::from(""));
    l.push(sec_head("GIT REPOS", ""));
    for rp in REPOS {
        let slot = cx.get(&format!("repo:{rp}"));
        let mut spans = vec![sp(format!("    {}", pad_e(rp, 8)), Magenta), raw(" ")];
        match slot {
            Slot::NotProbed => spans.push(dim("-- Refresh")),
            Slot::Pending => spans.push(dim(cx.spinch().to_string())),
            Slot::Timeout => spans.push(sp("t/o", Yellow)),
            Slot::Cmd(out) => {
                let v = parse_repo(out);
                spans.push(sp(pad_e(&v.br, 8), Cyan));
                spans.push(raw(" "));
                if v.ahead > 0 {
                    spans.push(sp(format!("+{} ", v.ahead), Green));
                }
                if v.behind > 0 {
                    spans.push(sp(format!("-{} ", v.behind), Red));
                }
                if v.dirty > 0 {
                    spans.push(sp(format!("{} dirty", v.dirty), Yellow));
                } else {
                    spans.push(sp("clean", Green));
                }
            }
            _ => {}
        }
        l.push(Line::from(spans));
    }

    l.push(Line::from(""));
    l.push(sec_head("CLAUDE", ""));
    l.push(Line::from(vec![
        dim("    model     "),
        raw(format!("{}   ", cx.cfg.model)),
        dim("mcp "),
        raw(cx.cfg.mcp_count.to_string()),
    ]));
    // Statusline is listed AS a plugin (it is one).
    let mut plugin_spans = vec![dim("    plugins   ")];
    for p in cx.plugins {
        let txt = if p.detail.is_empty() { p.label.clone() } else { format!("{}:{}", p.label, p.detail) };
        plugin_spans.push(sp(format!("{txt}  "), if p.on { Green } else { Dim }));
    }
    plugin_spans.push(sp(
        if cx.cfg.statusline { "Statusline:on" } else { "Statusline:off" },
        if cx.cfg.statusline { Green } else { Dim },
    ));
    l.push(Line::from(plugin_spans));
    let skills = if cx.cfg.skills.is_empty() {
        "none".to_string()
    } else {
        cx.cfg.skills.iter().take(12).cloned().collect::<Vec<_>>().join(" ")
    };
    l.push(Line::from(vec![dim("    skills    "), dim(skills)]));
    let hooks: Vec<Hook> = cx.hooks.iter().map(|h| Hook { name: h.name.clone(), kb: h.kb }).collect();
    let hookstr = hooks.iter().map(|h| format!("{}({}K)", h.name, h.kb)).collect::<Vec<_>>().join("  ");
    l.push(Line::from(vec![dim("    hooks     "), dim(hookstr)]));
}
