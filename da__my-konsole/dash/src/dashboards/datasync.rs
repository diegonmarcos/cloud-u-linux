// DataSync — local data topology (cloud-terminal DATASYNC port).
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::block;
use super::sh;

pub struct DataSync {
    mounts: Vec<String>,
    volumes: Vec<String>,
    remotes: Vec<String>,
    repos: Vec<String>,
}

impl DataSync {
    pub fn new() -> Self { DataSync { mounts: vec![], volumes: vec![], remotes: vec![], repos: vec![] } }
}

impl Dashboard for DataSync {
    fn title(&self) -> String { "🔄 data-sync".into() }
    fn tick_ms(&self) -> u64 { 10000 }

    fn update(&mut self) {
        self.mounts = sh("findmnt -rn -t ext4,btrfs,vfat,ntfs,xfs -o TARGET,SIZE,USE% 2>/dev/null")
            .lines().map(|l| l.to_string()).collect();
        self.volumes = sh("docker volume ls --format '{{.Name}}' 2>/dev/null")
            .lines().map(|l| l.to_string()).collect();
        self.remotes = sh("rclone listremotes 2>/dev/null").lines().map(|l| l.to_string()).collect();
        self.repos = ["cloud", "unix", "front", "vault", "tools"].iter().filter_map(|r| {
            let dir = format!("$HOME/git/{r}");
            if sh(&format!("test -d {dir}/.git && echo y")).trim() != "y" { return None; }
            let br = sh(&format!("git -C {dir} rev-parse --abbrev-ref HEAD 2>/dev/null")).trim().to_string();
            let dirty = sh(&format!("git -C {dir} status --porcelain 2>/dev/null | wc -l")).trim().to_string();
            Some(format!("{r:<8} {br}  ({dirty} dirty)"))
        }).collect();
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let grid = Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)]).split(area);
        let top = Layout::horizontal([Constraint::Percentage(60), Constraint::Percentage(40)]).split(grid[0]);
        let bot = Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).split(grid[1]);

        let lines = |v: &[String]| -> Vec<Line> { v.iter().map(|s| Line::from(s.clone())).collect() };
        f.render_widget(Paragraph::new(lines(&self.mounts)).block(block("LOCAL · MOUNTS")), top[0]);
        f.render_widget(Paragraph::new(lines(&self.volumes)).block(block("DOCKER VOLUMES")), top[1]);
        f.render_widget(Paragraph::new(self.repos.iter().map(|s|
            Line::from(vec![Span::styled(s.clone(), Style::default().fg(Color::Gray))])).collect::<Vec<_>>())
            .block(block("GIT REPOS")), bot[0]);
        f.render_widget(Paragraph::new(self.remotes.iter().map(|s|
            Line::from(vec![Span::styled("☁ ", Style::default().fg(Color::Cyan)), Span::raw(s.clone())])).collect::<Vec<_>>())
            .block(block("RCLONE · REMOTES")), bot[1]);
    }
}
