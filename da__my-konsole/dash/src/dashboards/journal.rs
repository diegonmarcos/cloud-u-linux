// Journal — merged systemd journal feed (cloud-terminal JOURNAL port).
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::block;
use super::sh;

struct Entry { prio: u8, unit: String, msg: String }

pub struct Journal { entries: Vec<Entry> }

impl Journal {
    pub fn new() -> Self { Journal { entries: vec![] } }
}

fn parse(out: &str, into: &mut Vec<Entry>) {
    for line in out.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let prio = v.get("PRIORITY").and_then(|p| p.as_str()).and_then(|s| s.parse().ok()).unwrap_or(6u8);
        let unit = v.get("_SYSTEMD_UNIT").or_else(|| v.get("SYSLOG_IDENTIFIER"))
            .and_then(|u| u.as_str()).unwrap_or("?").trim_end_matches(".service").to_string();
        let msg = match v.get("MESSAGE") {
            Some(serde_json::Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        into.push(Entry { prio, unit, msg });
    }
}

impl Dashboard for Journal {
    fn title(&self) -> String { "📜 journal".into() }
    fn tick_ms(&self) -> u64 { 5000 }

    fn update(&mut self) {
        let mut e = Vec::new();
        parse(&sh("journalctl -o json -n 300 --no-pager 2>/dev/null"), &mut e);
        parse(&sh("journalctl --user -o json -n 200 --no-pager 2>/dev/null"), &mut e);
        e.reverse(); // newest first (approx — both streams appended)
        self.entries = e;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([Constraint::Length(3), Constraint::Min(0)]).split(area);
        let total = self.entries.len();
        let err = self.entries.iter().filter(|e| e.prio <= 3).count();
        let warn = self.entries.iter().filter(|e| e.prio == 4).count();
        let info = total - err - warn;
        let tiles = Line::from(vec![
            Span::styled(format!("  {total} total  "), Style::default().fg(Color::Gray)),
            Span::styled(format!("  {err} errors  "), Style::default().fg(Color::Red)),
            Span::styled(format!("  {warn} warnings  "), Style::default().fg(Color::Yellow)),
            Span::styled(format!("  {info} info+  "), Style::default().fg(Color::Green)),
        ]);
        f.render_widget(Paragraph::new(tiles).block(block("SUMMARY")), rows[0]);

        let feed: Vec<Line> = self.entries.iter().take(rows[1].height as usize).map(|e| {
            let (lbl, col) = match e.prio {
                0..=3 => ("ERR ", Color::Red),
                4 => ("WARN", Color::Yellow),
                5 => ("NOTE", Color::Cyan),
                _ => ("INFO", Color::DarkGray),
            };
            Line::from(vec![
                Span::styled(format!("{lbl} "), Style::default().fg(col)),
                Span::styled(format!("{:<18} ", e.unit.chars().take(18).collect::<String>()), Style::default().fg(Color::Blue)),
                Span::raw(e.msg.chars().take(90).collect::<String>()),
            ])
        }).collect();
        f.render_widget(Paragraph::new(feed).block(block("FEED")), rows[1]);
    }
}
