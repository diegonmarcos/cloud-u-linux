// DevCtl — data-call profiler (cloud-terminal DEVCTL port). cloud-terminal's
// DevCtl profiles every IPC invoke; the standalone analog times the dashboards'
// data-source commands so you can see which probes are slow/failing.
use std::time::Instant;

use ratatui::layout::{Constraint, Rect};
use ratatui::style::{Color, Style};
use ratatui::widgets::{Cell, Row, Table};
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::block;
use super::sh;

struct Probe { name: String, ms: u128, ok: bool }

pub struct DevCtl { probes: Vec<Probe> }

impl DevCtl {
    pub fn new() -> Self { DevCtl { probes: vec![] } }
}

const CMDS: &[(&str, &str)] = &[
    ("sys /proc", "cat /proc/stat /proc/meminfo >/dev/null"),
    ("df", "df -B1 >/dev/null"),
    ("findmnt", "findmnt -rn >/dev/null 2>&1"),
    ("docker ps", "docker ps -q >/dev/null 2>&1"),
    ("docker volumes", "docker volume ls -q >/dev/null 2>&1"),
    ("journal (sys)", "journalctl -o json -n 50 --no-pager >/dev/null 2>&1"),
    ("journal (user)", "journalctl --user -o json -n 50 --no-pager >/dev/null 2>&1"),
    ("rclone remotes", "rclone listremotes >/dev/null 2>&1"),
    ("gh auth", "gh auth status >/dev/null 2>&1"),
    ("claude scan", "find $HOME/.claude/projects -name '*.jsonl' -mtime -1 >/dev/null 2>&1"),
];

impl Dashboard for DevCtl {
    fn title(&self) -> String { "🛠 devctl".into() }
    fn tick_ms(&self) -> u64 { 5000 }

    fn update(&mut self) {
        self.probes = CMDS.iter().map(|(name, cmd)| {
            let t = Instant::now();
            let out = std::process::Command::new("sh").arg("-c").arg(format!("{cmd}")).status();
            let ok = out.map(|s| s.success()).unwrap_or(false);
            let _ = sh; // (shared helper kept available)
            Probe { name: name.to_string(), ms: t.elapsed().as_millis(), ok }
        }).collect();
        self.probes.sort_by(|a, b| b.ms.cmp(&a.ms));
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let rows: Vec<Row> = self.probes.iter().map(|p| {
            let col = if !p.ok { Color::Red } else if p.ms > 800 { Color::Yellow } else if p.ms > 200 { Color::Cyan } else { Color::Green };
            Row::new(vec![
                Cell::from(p.name.clone()),
                Cell::from(format!("{} ms", p.ms)).style(Style::default().fg(col)),
                Cell::from(if p.ok { "ok" } else { "FAIL" }).style(Style::default().fg(if p.ok { Color::Green } else { Color::Red })),
            ])
        }).collect();
        let table = Table::new(rows, [Constraint::Min(18), Constraint::Length(12), Constraint::Length(6)])
            .header(Row::new(vec!["DATA CALL", "LATENCY", "OK"]).style(Style::default().fg(Color::Cyan)))
            .block(block("DATA-CALL PROFILER (by latency)"));
        f.render_widget(table, area);
    }
}
