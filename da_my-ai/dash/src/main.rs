//! `my-ai-dash` — live single-screen infra + launch dashboard (ratatui/crossterm).
//! Faithful port of claude-superset-tui.mjs. Offline data is read instantly at
//! startup; NETWORK/CMD probes fire only on Refresh (r), each on its own thread.
mod collect;
mod offline;
mod render;
mod snapshot;
mod state;

use collect::{collectors, run, Slot};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::widgets::Paragraph;
use state::{build_rows, focusable, sel_args, St, PRESETS_COUNT, PRESETS_HOURS};
use std::collections::BTreeMap;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

type Shared = Arc<Mutex<BTreeMap<String, Slot>>>;

fn main() -> anyhow::Result<()> {
    let ep = my_ai_core::endpoints()?;

    // --snapshot: print a JSON dashboard snapshot and exit (used by my-ai-gui).
    if std::env::args().any(|a| a == "--snapshot") {
        println!("{}", snapshot::snapshot(&ep));
        return Ok(());
    }

    let mcps = offline::load_mcps();
    let flags = offline::load_claude_flags();
    let plugins = offline::load_plugins();
    let hooks = offline::load_hooks();
    let sessions = offline::load_sessions();
    let cfg = offline::claude_config(mcps.len());

    // Not a TTY → print the composed command and exit (mirrors the mjs guard).
    if !std::io::IsTerminal::is_terminal(&std::io::stdout()) {
        let mut st = St::default();
        seed_flag_defaults(&mut st, &flags);
        println!("my-ai-dash needs a terminal. Would launch: my-ai {}", sel_args(&st, &mcps, &flags).join(" "));
        return Ok(());
    }

    let data: Shared = Arc::new(Mutex::new(BTreeMap::new()));
    let mut st = St::default();
    seed_flag_defaults(&mut st, &flags);
    let mut focus = 0usize;
    let mut num_buf = String::new();
    let mut spin = 0usize;
    let mut last_launch = String::new();

    let mut term = ratatui::init();
    let res = run_loop(
        &mut term, &ep, &mcps, &flags, &plugins, &hooks, &sessions, &cfg, &data, &mut st, &mut focus,
        &mut num_buf, &mut spin, &mut last_launch,
    );
    ratatui::restore();
    res
}

/// Seed St.claude_flags from claude-flags.json's `default` field so freshly
/// loaded flags render checked/unchecked per the data file instead of always off.
fn seed_flag_defaults(st: &mut St, flags: &[offline::ClaudeFlag]) {
    for f in flags {
        st.claude_flags.insert(f.key.clone(), f.default);
    }
}

#[allow(clippy::too_many_arguments)]
fn run_loop(
    term: &mut ratatui::DefaultTerminal,
    ep: &my_ai_core::Endpoints,
    mcps: &[offline::Mcp],
    flags: &[offline::ClaudeFlag],
    plugins: &[offline::Plugin],
    hooks: &[offline::Hook],
    sessions: &offline::Sessions,
    cfg: &offline::Cfg,
    data: &Shared,
    st: &mut St,
    focus: &mut usize,
    num_buf: &mut String,
    spin: &mut usize,
    last_launch: &mut String,
) -> anyhow::Result<()> {
    loop {
        let snapshot = data.lock().unwrap().clone();
        let refreshing = snapshot.values().any(|s| matches!(s, Slot::Pending));
        let rows = build_rows(st, &ep.mesh, my_ai_core::is_termux(), mcps, flags);
        let fl = focusable(&rows);
        if *focus >= fl.len() {
            *focus = fl.len().saturating_sub(1);
        }
        let cx = render::Ctx {
            st: &*st,
            mcps,
            flags,
            plugins,
            hooks,
            sessions,
            cfg,
            data: &snapshot,
            mesh: &ep.mesh,
            public: &ep.public,
            spin: *spin,
            refreshing,
            last_launch: last_launch.as_str(),
            focus: *focus,
            num_buf: num_buf.as_str(),
            is_termux: my_ai_core::is_termux(),
        };
        let lines = render::build_lines(&cx);
        let total = lines.len();
        let ratio = if fl.is_empty() { 0.0 } else { *focus as f32 / fl.len().max(1) as f32 };
        term.draw(|f| {
            let area = f.area();
            let max_scroll = total.saturating_sub(area.height as usize) as f32;
            let scroll = (ratio * max_scroll).round() as u16;
            f.render_widget(Paragraph::new(lines).scroll((scroll, 0)), area)
        })?;

        if event::poll(Duration::from_millis(120))? {
            if let Event::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Release {
                    continue;
                }
                let foc_row_idx = fl.get(*focus).copied();
                let kind = foc_row_idx.map(|i| rows[i].kind).unwrap_or("");
                match k.code {
                    KeyCode::Char('q') => return Ok(()),
                    KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => return Ok(()),
                    KeyCode::Char('r') => refresh(ep, mcps, data),
                    KeyCode::Char('l') => {
                        if launch(term, st, mcps, flags, last_launch) {
                            return Ok(());
                        }
                    }
                    KeyCode::Up | KeyCode::Char('k') => {
                        num_buf.clear();
                        if !fl.is_empty() {
                            *focus = (*focus + fl.len() - 1) % fl.len();
                        }
                    }
                    KeyCode::Down | KeyCode::Char('j') | KeyCode::Tab => {
                        num_buf.clear();
                        if !fl.is_empty() {
                            *focus = (*focus + 1) % fl.len();
                        }
                    }
                    KeyCode::Left => adjust(st, &rows, foc_row_idx, -1, num_buf),
                    KeyCode::Right => adjust(st, &rows, foc_row_idx, 1, num_buf),
                    KeyCode::Char(c @ '0'..='9') if kind == "number" => {
                        num_buf.push(c);
                        let trimmed = num_buf.trim_start_matches('0').to_string();
                        *num_buf = if trimmed.is_empty() { "0".into() } else { trimmed.chars().take(4).collect() };
                        st.restore_n = num_buf.parse().unwrap_or(0);
                    }
                    KeyCode::Backspace if kind == "number" => {
                        num_buf.pop();
                        st.restore_n = num_buf.parse().unwrap_or(0);
                    }
                    KeyCode::Char(' ') | KeyCode::Enter => {
                        if let Some(i) = foc_row_idx {
                            let row = &rows[i];
                            if row.kind == "action" {
                                match row.key {
                                    "refresh" => refresh(ep, mcps, data),
                                    "launch" => {
                                        if launch(term, st, mcps, flags, last_launch) {
                                            return Ok(());
                                        }
                                    }
                                    _ => return Ok(()),
                                }
                            } else {
                                activate(st, row);
                            }
                        }
                    }
                    _ => {}
                }
            }
        } else {
            *spin = (*spin + 1) % 4;
        }
    }
}

fn refresh(ep: &my_ai_core::Endpoints, mcps: &[offline::Mcp], data: &Shared) {
    let cols = collectors(ep, mcps);
    {
        let mut d = data.lock().unwrap();
        d.clear();
        for (id, _) in &cols {
            d.insert(id.clone(), Slot::Pending);
        }
    }
    for (id, probe) in cols {
        let data = data.clone();
        thread::spawn(move || {
            let v = run(&probe);
            data.lock().unwrap().insert(id, v);
        });
    }
}

fn activate(st: &mut St, row: &state::Row) {
    match row.kind {
        "radio" => match row.grp {
            "agent" => st.agent = row.val.to_string(),
            "face" => st.face = row.val.to_string(),
            "restore" => st.restore = row.val.to_string(),
            _ => {}
        },
        "check" => match row.key {
            "headroom" => st.headroom = !st.headroom,
            "rtk" => st.rtk = !st.rtk,
            "caveman" => st.caveman = !st.caveman,
            "statusline" => st.statusline = !st.statusline,
            k if k.starts_with("mcp:") => {
                let name = &k[4..];
                let cur = st.mcp_is_on(name);
                st.mcp_on.insert(name.to_string(), !cur);
            }
            // Data-driven claude-flags.json keys — flip the on/off map entry.
            k => {
                let cur = st.flag_on(k);
                st.claude_flags.insert(k.to_string(), !cur);
            }
        },
        "checklevel" => st.ponytail = !st.ponytail,
        _ => {}
    }
}

fn adjust(st: &mut St, rows: &[state::Row], foc: Option<usize>, dir: i64, num_buf: &mut String) {
    let Some(i) = foc else { return };
    let row = &rows[i];
    match row.kind {
        "checklevel" if st.ponytail => {
            st.pony = ((st.pony as i64 + dir).rem_euclid(3)) as usize;
        }
        "number" => {
            num_buf.clear();
            let presets: &[u64] = if st.restore == "hours" { &PRESETS_HOURS } else { &PRESETS_COUNT };
            let cur = presets.iter().position(|&p| p == st.restore_n).unwrap_or(0) as i64;
            let idx = (cur + dir).clamp(0, presets.len() as i64 - 1) as usize;
            st.restore_n = presets[idx];
        }
        "radio" => {
            let opts: Vec<&str> = rows.iter().filter(|r| r.kind == "radio" && r.grp == row.grp).map(|r| r.val).collect();
            let cur: &str = match row.grp {
                "agent" => &st.agent,
                "face" => &st.face,
                "restore" => &st.restore,
                _ => return,
            };
            let ci = opts.iter().position(|&o| o == cur).unwrap_or(0);
            let ni = (ci as i64 + dir).rem_euclid(opts.len() as i64) as usize;
            let val = opts[ni].to_string();
            match row.grp {
                "agent" => st.agent = val,
                "face" => st.face = val,
                "restore" => st.restore = val,
                _ => {}
            }
        }
        _ => {}
    }
}

/// Launch the composed command. Returns true if the TUI should exit (TTY hand-over).
fn launch(_term: &mut ratatui::DefaultTerminal, st: &St, mcps: &[offline::Mcp], flags: &[offline::ClaudeFlag], last_launch: &mut String) -> bool {
    let args = sel_args(st, mcps, flags);
    let is_restore = args.iter().any(|a| a == "restore" || a == "restore-hours");
    let self_cmd = std::env::var("CAS_SELF").unwrap_or_else(|_| "my-ai".into());
    let konsole = std::env::var("CAS_KONSOLE").ok().filter(|s| !s.is_empty()).or_else(|| which("konsole"));

    if let (Some(konsole), true) = (konsole, std::env::var_os("DISPLAY").is_some()) {
        // Open in a NEW window and keep the TUI open. Restore opens its own tabs,
        // so run the wrapper directly; a fresh launch needs `konsole -e`.
        let mut cmd = if is_restore {
            let mut c = Command::new(&self_cmd);
            c.args(&args);
            c
        } else {
            let mut c = Command::new(&konsole);
            c.arg("-e").arg(&self_cmd).args(&args);
            c
        };
        let ok = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .is_ok();
        *last_launch = if ok { args.join(" ") } else { "FAILED".into() };
        return false;
    }

    // Bare TTY / termux: hand the terminal over — the TUI exits.
    ratatui::restore();
    let status = Command::new(&self_cmd).args(&args).status();
    std::process::exit(status.ok().and_then(|s| s.code()).unwrap_or(0));
}

fn which(bin: &str) -> Option<String> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|d| d.join(bin))
            .find(|p| p.exists())
            .map(|p| p.to_string_lossy().into_owned())
    })
}
