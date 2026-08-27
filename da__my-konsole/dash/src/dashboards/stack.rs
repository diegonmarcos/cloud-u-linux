// Stack — machine + config + tooling inventory (cloud-terminal STACK port).
// Self-contained live probes (no data-file dependency).
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::{block, dot};
use super::sh;

pub struct Stack {
    facts: Vec<(String, String)>,
    security: Vec<(String, bool)>,
    tools: Vec<(String, bool)>,
    repos: Vec<(String, String)>, // name, git status summary
}

impl Stack {
    pub fn new() -> Self { Stack { facts: vec![], security: vec![], tools: vec![], repos: vec![] } }
}

fn active(unit: &str) -> bool { sh(&format!("systemctl is-active {unit} 2>/dev/null")).trim() == "active" }
fn have(tool: &str) -> bool { !sh(&format!("command -v {tool} 2>/dev/null")).trim().is_empty() }

impl Dashboard for Stack {
    fn title(&self) -> String { "📦 stack".into() }
    fn tick_ms(&self) -> u64 { 60000 }

    fn update(&mut self) {
        self.facts = vec![
            ("host".into(), sh("hostname").trim().into()),
            ("kernel".into(), sh("uname -r").trim().into()),
            ("arch".into(), sh("uname -m").trim().into()),
            ("uptime".into(), sh("uptime -p 2>/dev/null").trim().into()),
            ("cpu".into(), sh("nproc").trim().to_string() + " cores"),
            ("mem".into(), sh("free -h | awk 'NR==2{print $3\"/\"$2}'").trim().into()),
            ("root disk".into(), sh("df -h / | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}'").trim().into()),
        ];
        self.security = vec![
            ("sshd".into(), active("sshd") || active("ssh")),
            ("firewall".into(), active("firewall") || active("nftables") || active("iptables")),
            ("docker".into(), active("docker")),
        ];
        self.tools = ["git", "gh", "docker", "nix", "rsync", "rclone", "jq", "fish", "btop", "ssh", "gcloud", "oci"]
            .iter().map(|t| (t.to_string(), have(t))).collect();
        self.repos = ["cloud", "unix", "front", "vault", "tools"].iter().map(|r| {
            let dir = format!("$HOME/git/{r}");
            let exists = sh(&format!("test -d {dir}/.git && echo y")).trim() == "y";
            let s = if exists {
                let br = sh(&format!("git -C {dir} rev-parse --abbrev-ref HEAD 2>/dev/null")).trim().to_string();
                let dirty = sh(&format!("git -C {dir} status --porcelain 2>/dev/null | wc -l")).trim().to_string();
                format!("{br}  ({dirty} dirty)")
            } else { "—".into() };
            (r.to_string(), s)
        }).collect();
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let cols = Layout::horizontal([Constraint::Percentage(40), Constraint::Percentage(60)]).split(area);
        let left = Layout::vertical([Constraint::Length(9), Constraint::Min(0)]).split(cols[0]);

        let facts: Vec<Line> = self.facts.iter().map(|(k, v)|
            Line::from(vec![Span::styled(format!("{k:>10}  "), Style::default().fg(Color::DarkGray)), Span::raw(v.clone())])
        ).collect();
        f.render_widget(Paragraph::new(facts).block(block("MACHINE")), left[0]);

        let sec: Vec<Line> = self.security.iter().map(|(k, ok)|
            Line::from(vec![dot(*ok), Span::raw(format!(" {k}"))])
        ).collect();
        f.render_widget(Paragraph::new(sec).block(block("SECURITY")), left[1]);

        let right = Layout::vertical([Constraint::Length(9), Constraint::Min(0)]).split(cols[1]);
        let tools: Vec<Line> = self.tools.chunks(3).map(|ch| {
            let mut spans = vec![];
            for (t, ok) in ch { spans.push(dot(*ok)); spans.push(Span::raw(format!(" {t:<10} "))); }
            Line::from(spans)
        }).collect();
        f.render_widget(Paragraph::new(tools).block(block("TOOLS")), right[0]);

        let repos: Vec<Line> = self.repos.iter().map(|(n, s)|
            Line::from(vec![Span::styled(format!("{n:<8} "), Style::default().fg(Color::Cyan)), Span::raw(s.clone())])
        ).collect();
        f.render_widget(Paragraph::new(repos).block(block("REPOS · GIT")), right[1]);
    }
}
