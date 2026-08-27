// Shared UI helpers for the dashboards.
use ratatui::style::{Color, Style};
use ratatui::widgets::{Block, Borders};

pub const ACCENT: Color = Color::Cyan;

pub fn block(title: &str) -> Block<'static> {
    Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray))
        .title(format!(" {title} "))
        .title_style(Style::default().fg(ACCENT))
}

pub fn dot(ok: bool) -> ratatui::text::Span<'static> {
    if ok {
        ratatui::text::Span::styled("●", Style::default().fg(Color::Green))
    } else {
        ratatui::text::Span::styled("●", Style::default().fg(Color::Red))
    }
}
