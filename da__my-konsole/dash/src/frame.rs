// The shared frame contract (mirrors cloud-terminal/frame.js): a common toolbar
// (title · "as of" stamp · auto-refresh toggle · refresh/quit) wrapping each
// dashboard. The frame owns WHEN to refresh; the dashboard owns WHAT to render.
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

pub trait Dashboard {
    fn title(&self) -> String;
    fn tick_ms(&self) -> u64; // auto-refresh cadence
    fn update(&mut self); // exactly one refresh pass (gather data)
    fn render(&mut self, f: &mut Frame, area: Rect);
    fn on_key(&mut self, _k: KeyCode) {}
    /// Keys this dashboard takes BEFORE the frame's own bindings. The frame
    /// quits on q/Esc, but btop's Esc opens a menu and its modals close on q —
    /// a dashboard that says so gets the key instead of being closed under it.
    /// Ctrl-C and Ctrl-D are never offered here: they always quit.
    fn claims(&self, _k: KeyCode) -> bool { false }
    /// True once a dashboard's own UI has asked to exit — the Esc menu's
    /// "quit" item. Without it that item could only fake a keystroke, and the
    /// menu is the one place a claimed key can never reach the frame's quit.
    fn wants_quit(&self) -> bool { false }
    // True for dashboards whose values are a DELTA between two refreshes
    // (CPU%, net rate) — a single startup refresh reads as ~0/empty. Others
    // (SSH probes, file reads) gain nothing from a second pass, only latency.
    fn needs_warmup(&self) -> bool { false }
}

pub fn now_hms() -> String {
    std::process::Command::new("date")
        .arg("+%H:%M:%S")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "--:--:--".into())
}

pub fn run(dash: &mut dyn Dashboard) -> std::io::Result<()> {
    let mut term = ratatui::init();
    let mut auto = true; // dashboards are labeled "(live)" — refresh without being asked
    let mut last = Instant::now();
    dash.update();
    if dash.needs_warmup() {
        std::thread::sleep(Duration::from_millis(250));
        dash.update();
    }
    let mut as_of = now_hms();

    let res = (|| -> std::io::Result<()> {
        loop {
            term.draw(|f| {
                let rows = Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).split(f.area());
                let auto_span = if auto {
                    Span::styled(" [auto:ON] ", Style::default().fg(Color::Black).bg(Color::Green))
                } else {
                    Span::styled(" [auto:off] ", Style::default().fg(Color::DarkGray))
                };
                let bar = Line::from(vec![
                    Span::styled(format!(" {} ", dash.title()),
                        Style::default().fg(Color::Black).bg(Color::Cyan).add_modifier(Modifier::BOLD)),
                    Span::styled(format!("  as of {}  ", as_of), Style::default().fg(Color::Gray)),
                    auto_span,
                    Span::styled("   r:refresh  a:auto  ^c:quit", Style::default().fg(Color::DarkGray)),
                ]);
                f.render_widget(Paragraph::new(bar), rows[0]);
                dash.render(f, rows[1]);
            })?;

            if event::poll(Duration::from_millis(100))? {
                if let Event::Key(k) = event::read()? {
                    if k.kind == KeyEventKind::Press {
                        // Raw mode means the terminal no longer turns these
                        // into SIGINT/EOF for us — without this the dashboard
                        // has no unconditional way out, and ^c would fall
                        // through to whatever 'c' happens to be bound to.
                        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
                        if ctrl && matches!(k.code, KeyCode::Char('c') | KeyCode::Char('d')) {
                            break;
                        }
                        match k.code {
                            k2 if dash.claims(k2) => dash.on_key(k2),
                            KeyCode::Char('q') | KeyCode::Esc => break,
                            KeyCode::Char('r') => { dash.update(); as_of = now_hms(); }
                            KeyCode::Char('a') => { auto = !auto; last = Instant::now(); }
                            other => dash.on_key(other),
                        }
                        if dash.wants_quit() {
                            break;
                        }
                    }
                }
            }
            if auto && last.elapsed() >= Duration::from_millis(dash.tick_ms()) {
                dash.update();
                as_of = now_hms();
                last = Instant::now();
            }
        }
        Ok(())
    })();

    ratatui::restore();
    res
}
