// The report IS the dashboard, not a drawing of one.
//
// WHY THIS FILE EXISTS
// The HTML report used to re-implement the panel's layout by hand: boxes
// rebuilt in TypeScript, columns re-derived, colours re-picked. Every one of
// those was a guess about what draw() does, and a guess diverges — the frames
// were wrong, the alignment was wrong, the palette drifted, the cpu box put
// the model in a row instead of the title, and psi lost two of its three
// windows. Fixing them one at a time never converges, because the reference
// keeps moving and nothing forces the two to agree.
//
// So nothing is re-implemented. The real Monitor renders into an off-screen
// ratatui buffer through TestBackend — the same widgets, the same Layout, the
// same bbox() frames, the same grad() colours — and this file turns that grid
// of styled cells into spans. The page cannot disagree with the panel about a
// frame or a column, because it is not drawing them: it is transcribing what
// the panel drew.
//
// It also means a change to the TUI shows up in the report with no work here
// at all, which is the property the hand-written version could never have.
use super::Monitor;
use crate::frame::Dashboard;
use ratatui::backend::TestBackend;
use ratatui::style::{Color, Modifier};
use ratatui::Terminal;

/// The grid the report is drawn at.
///
/// Fixed, not measured: the page has no terminal to ask. 200x64 is wide enough
/// for the three-across mem|storage|net row to get its real proportions and
/// tall enough for the process table to carry rows rather than a stub, and the
/// page scrolls sideways on anything narrower rather than reflowing — a
/// reflowed terminal grid is exactly the misalignment this file exists to end.
pub(crate) const COLS: u16 = 200;
pub(crate) const ROWS: u16 = 64;

/// The phone grid.
///
/// A phone does not get the desktop transcript shrunk to fit: 200 columns
/// across 390 points is about three pixels a character, which is not small
/// text, it is a texture. So the panel is drawn AGAIN at a width a phone can
/// actually hold, and ratatui lays it out for that width the way it would on a
/// narrow terminal — which is the whole reason the panel is being asked to
/// draw rather than being imitated.
///
/// 104 columns still gives the mem box its numbers: the bar derives its width
/// from the widest figure it must print and gives up cells rather than
/// clipping them. Taller because everything is narrower and wraps into rows.
pub(crate) const M_COLS: u16 = 104;
pub(crate) const M_ROWS: u16 = 90;

/// ratatui's palette, as CSS.
///
/// The Rgb arm is the one that matters: every colour draw.rs picks — DIM,
/// LABEL, GRAPH_FLOOR, the accent, everything grad() returns — is an Rgb, so
/// it arrives here exact and needs no table. The named and indexed arms are
/// for the few spans that use ratatui's own defaults.
fn css(c: Color) -> Option<String> {
    let hex = |r: u8, g: u8, b: u8| Some(format!("#{r:02x}{g:02x}{b:02x}"));
    match c {
        Color::Rgb(r, g, b) => hex(r, g, b),
        Color::Reset => None,
        Color::Black => hex(0x0b, 0x0e, 0x14),
        Color::Red => hex(0xf0, 0x48, 0x48),
        Color::Green => hex(0x40, 0xdc, 0x78),
        Color::Yellow => hex(0xf0, 0xde, 0x40),
        Color::Blue => hex(0x78, 0xc8, 0xff),
        Color::Magenta => hex(0xc0, 0x88, 0xff),
        Color::Cyan => hex(0x60, 0xd8, 0xd0),
        Color::Gray => hex(0xc8, 0xcc, 0xd4),
        Color::DarkGray => hex(0x58, 0x5e, 0x6e),
        Color::LightRed => hex(0xff, 0x78, 0x78),
        Color::LightGreen => hex(0x78, 0xf0, 0xa0),
        Color::LightYellow => hex(0xff, 0xe8, 0x78),
        Color::LightBlue => hex(0xa0, 0xd8, 0xff),
        Color::LightMagenta => hex(0xd8, 0xa8, 0xff),
        Color::LightCyan => hex(0x90, 0xf0, 0xe8),
        Color::White => hex(0xff, 0xff, 0xff),
        // 256-colour: the cube and the grey ramp, by the standard formula.
        Color::Indexed(i) => match i {
            16..=231 => {
                let n = i - 16;
                let s = [0u8, 95, 135, 175, 215, 255];
                hex(s[(n / 36) as usize], s[(n / 6 % 6) as usize], s[(n % 6) as usize])
            }
            232..=255 => {
                let v = 8 + 10 * (i - 232);
                hex(v, v, v)
            }
            _ => None,
        },
    }
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Draw the dashboard headless and transcribe the buffer.
///
/// Cells are coalesced into runs of identical style rather than emitted one
/// span per character: a 200x64 grid is 12,800 cells, and one span each would
/// be a megabyte of markup to say what a few hundred spans say.
pub(crate) fn render(dash: &mut Monitor, cols: u16, rows: u16) -> Result<String, String> {
    let mut term =
        Terminal::new(TestBackend::new(cols, rows)).map_err(|e| format!("backend: {e}"))?;
    term.draw(|f| {
        let area = f.area();
        dash.render(f, area);
    })
    .map_err(|e| format!("draw: {e}"))?;

    let buf = term.backend().buffer().clone();
    let mut out = String::from("<pre class=\"tui\">");
    for y in 0..rows {
        // One run at a time, flushed when the style changes or the row ends.
        let mut open: Option<String> = None;
        let mut run = String::new();
        let flush = |open: &mut Option<String>, run: &mut String, out: &mut String| {
            if run.is_empty() {
                return;
            }
            match open.take() {
                Some(style) => out.push_str(&format!("<span style=\"{style}\">{}</span>", esc(run))),
                None => out.push_str(&esc(run)),
            }
            run.clear();
        };
        for x in 0..cols {
            let cell = &buf[(x, y)];
            let mut style = String::new();
            if let Some(c) = css(cell.fg) {
                style.push_str(&format!("color:{c};"));
            }
            if let Some(c) = css(cell.bg) {
                style.push_str(&format!("background:{c};"));
            }
            if cell.modifier.contains(Modifier::BOLD) {
                style.push_str("font-weight:700;");
            }
            if cell.modifier.contains(Modifier::DIM) {
                style.push_str("opacity:.6;");
            }
            if cell.modifier.contains(Modifier::ITALIC) {
                style.push_str("font-style:italic;");
            }
            let style = if style.is_empty() { None } else { Some(style) };
            if style != open && !run.is_empty() {
                flush(&mut open, &mut run, &mut out);
            }
            open = style;
            run.push_str(cell.symbol());
        }
        flush(&mut open, &mut run, &mut out);
        out.push('\n');
    }
    out.push_str("</pre>");
    Ok(out)
}
