// Cloud — VM fleet status (cloud-terminal CLOUD port). Reads the fleet from
// ~/.local/share/my-konsole/cloud-targets.json and SSH-probes each VM.
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::{block, dot};
use super::sh_timeout;

struct Vm { alias: String, wg: String, label: String, up: bool, uptime: String, disk: String, running: String, probed: bool }

pub struct Cloud { vms: Vec<Vm> }

impl Cloud {
    pub fn new() -> Self {
        let path = format!("{}/.local/share/my-konsole/cloud-targets.json", std::env::var("HOME").unwrap_or_default());
        let mut vms = Vec::new();
        if let Ok(txt) = std::fs::read_to_string(&path) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                if let Some(arr) = v.get("vms").and_then(|x| x.as_array()) {
                    for m in arr {
                        vms.push(Vm {
                            alias: m.get("alias").and_then(|s| s.as_str()).unwrap_or("?").into(),
                            wg: m.get("wg").and_then(|s| s.as_str()).unwrap_or("").into(),
                            label: m.get("label").and_then(|s| s.as_str()).unwrap_or("").into(),
                            up: false, uptime: "—".into(), disk: "—".into(), running: "—".into(), probed: false,
                        });
                    }
                }
            }
        }
        Cloud { vms }
    }
}

impl Dashboard for Cloud {
    fn title(&self) -> String { "☁ cloud".into() }
    fn tick_ms(&self) -> u64 { 10000 }

    fn update(&mut self) {
        for vm in self.vms.iter_mut() {
            // one SSH round-trip, hard-timeout so a dead host never wedges the pane
            let out = sh_timeout(8, &format!(
                "ssh -o BatchMode=yes -o ConnectTimeout=5 {} 'uptime -p; df -h / | awk \"NR==2{{print \\$5}}\"; docker ps -q 2>/dev/null | wc -l'",
                vm.alias));
            let lines: Vec<&str> = out.lines().collect();
            vm.probed = true;
            vm.up = !lines.is_empty() && !out.trim().is_empty();
            vm.uptime = lines.first().unwrap_or(&"—").trim().to_string();
            vm.disk = lines.get(1).unwrap_or(&"—").trim().to_string();
            vm.running = lines.get(2).unwrap_or(&"—").trim().to_string();
        }
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let n = self.vms.len().max(1);
        let constraints: Vec<Constraint> = (0..n).map(|_| Constraint::Ratio(1, n as u32)).collect();
        let cols = Layout::horizontal(constraints).split(area);
        for (i, vm) in self.vms.iter().enumerate() {
            let status = if !vm.probed { Span::styled("○ unprobed", Style::default().fg(Color::DarkGray)) }
                else if vm.up { Span::styled("● up", Style::default().fg(Color::Green)) }
                else { Span::styled("● down", Style::default().fg(Color::Red)) };
            let body = vec![
                Line::from(vec![dot(vm.up), Span::styled(format!(" {}", vm.alias), Style::default().fg(Color::Cyan))]),
                Line::from(Span::styled(vm.wg.clone(), Style::default().fg(Color::DarkGray))),
                Line::from(Span::raw(vm.label.chars().take(22).collect::<String>())),
                Line::from(""),
                Line::from(vec![Span::styled("⏱ ", Style::default().fg(Color::DarkGray)), Span::raw(vm.uptime.chars().take(20).collect::<String>())]),
                Line::from(vec![Span::styled("💾 ", Style::default().fg(Color::DarkGray)), Span::raw(vm.disk.clone())]),
                Line::from(vec![Span::styled("📦 ", Style::default().fg(Color::DarkGray)), Span::raw(format!("{} running", vm.running))]),
                Line::from(""),
                Line::from(status),
            ];
            f.render_widget(Paragraph::new(body).block(block(&vm.alias)), cols[i]);
        }
    }
}
