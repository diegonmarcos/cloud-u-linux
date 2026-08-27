// btop's visual language: the gradient, the rounded boxes, the meters and the
// braille graphs. Nothing here knows what it is drawing — it takes numbers and
// returns spans, which is what lets every view share one look.
use ratatui::layout::Alignment;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders};

/// btop's value gradient: green below, yellow through the middle, red at the
/// top. Used for BOTH the fill colour of a meter position and the vertical
/// colour of a graph row, which is what makes the two read as one language.
pub(crate) fn grad(f: f64) -> Color {
    let f = f.clamp(0.0, 1.0);
    let lerp = |a: f64, b: f64, t: f64| (a + (b - a) * t) as u8;
    if f < 0.5 {
        let t = f / 0.5;
        Color::Rgb(lerp(64.0, 240.0, t), lerp(220.0, 222.0, t), lerp(120.0, 64.0, t))
    } else {
        let t = (f - 0.5) / 0.5;
        Color::Rgb(lerp(240.0, 240.0, t), lerp(222.0, 72.0, t), lerp(64.0, 72.0, t))
    }
}

pub(crate) const DIM: Color = Color::Rgb(58, 62, 74);
/// btop's graph floor, taken from its own output: flat (64,64,64), and 81% of
/// every glyph it paints.
pub(crate) const GRAPH_FLOOR: Color = Color::Rgb(64, 64, 64);
pub(crate) const LABEL: Color = Color::Rgb(120, 128, 145);

/// btop's box: rounded corners, the title bracketed into the top border, and
/// the keys that act on that box parked in the bottom-right of its frame.
/// The box name, replaced by a strip of tabs. Same rounded frame, same
/// bracketed title slot — but the slot names the three views and marks which
/// one you are in, because a box labelled "proc" while showing a fleet table
/// is a label that lies, and nothing on screen said the other views existed.
pub(crate) fn tabbox(
    tabs: &[(&str, char)],
    active: usize,
    subs: &[&str],
    sub_active: usize,
    hint: &str,
) -> Block<'static> {
    let mut spans = vec![Span::styled("┤", Style::default().fg(DIM))];
    for (i, (name, key)) in tabs.iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(" · ", Style::default().fg(DIM)));
        }
        let on = i == active;
        spans.push(Span::styled(
            name.to_string(),
            if on {
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(LABEL)
            },
        ));
        spans.push(Span::styled(
            format!(" {key}"),
            Style::default().fg(if on { Color::Rgb(120, 200, 255) } else { DIM }),
        ));
    }
    spans.push(Span::styled("├", Style::default().fg(DIM)));
    let mut b = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(DIM))
        .title(Line::from(spans));
    // SUB-TABS along the bottom of the same box, not a second row of screen.
    //
    // A tab strip that costs a line of the table it labels is a bad trade on
    // a panel always short of rows, and the box already has a bottom edge
    // doing nothing. Numbered, because the command line addresses them by
    // number: `:f2` is the second one, and you can see which that is.
    if subs.len() > 1 {
        let mut sp = vec![Span::styled("┤", Style::default().fg(DIM))];
        for (i, name) in subs.iter().enumerate() {
            if i > 0 {
                sp.push(Span::styled(" · ", Style::default().fg(DIM)));
            }
            let on = i == sub_active;
            sp.push(Span::styled(
                format!("{}", i + 1),
                Style::default().fg(if on { Color::Rgb(120, 200, 255) } else { DIM }),
            ));
            sp.push(Span::styled(
                format!(" {name}"),
                if on {
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(LABEL)
                },
            ));
        }
        sp.push(Span::styled("├", Style::default().fg(DIM)));
        b = b.title_bottom(Line::from(sp).alignment(Alignment::Left));
    }
    if !hint.is_empty() {
        b = b.title_bottom(
            Line::from(Span::styled(format!("┤{hint}├"), Style::default().fg(DIM)))
                .alignment(Alignment::Right),
        );
    }
    b
}

pub(crate) fn bbox(title: &str, hint: &str) -> Block<'static> {
    let mut b = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(DIM))
        .title(Line::from(vec![
            Span::styled("┤", Style::default().fg(DIM)),
            Span::styled(
                title.to_string(),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            ),
            Span::styled("├", Style::default().fg(DIM)),
        ]));
    if !hint.is_empty() {
        b = b.title_bottom(
            Line::from(Span::styled(format!("┤{hint}├"), Style::default().fg(DIM)))
                .alignment(Alignment::Right),
        );
    }
    b
}

/// btop's meter: a run of blocks whose colour comes from each POSITION along
/// the bar, not from the value — so a bar that is 80% full is green→yellow→red
/// across its own length, and the unfilled remainder stays dark.
pub(crate) fn meter(width: usize, frac: f64, label: &str) -> Line<'static> {
    let frac = frac.clamp(0.0, 1.0);
    let filled = (frac * width as f64).round() as usize;
    let mut spans: Vec<Span> = Vec::with_capacity(width + 2);
    for p in 0..width {
        if p < filled {
            spans.push(Span::styled("█", Style::default().fg(grad(p as f64 / width.max(1) as f64))));
        } else {
            spans.push(Span::styled("░", Style::default().fg(DIM)));
        }
    }
    if !label.is_empty() {
        spans.push(Span::raw(" "));
        spans.push(Span::styled(label.to_string(), Style::default().fg(Color::Gray)));
    }
    Line::from(spans)
}

// Braille cell dot bitmasks. A cell is 2 dots wide by 4 tall:
//     1 4
//     2 5
//     3 6
//     7 8
pub(crate) const LEFT: [u8; 4] = [0x01, 0x02, 0x04, 0x40];
pub(crate) const RIGHT: [u8; 4] = [0x08, 0x10, 0x20, 0x80];

/// btop's signature graph: braille gives 2x horizontal and 4x vertical
/// resolution over block characters, so an 8-row box holds 32 distinct levels
/// and a 60-column one holds 120 samples. Bottom-anchored area fill; each row
/// is coloured by its own height, so peaks go red without recolouring history.
pub(crate) fn braille_graph(data: &[f64], max: f64, cols: usize, rows: usize) -> Vec<Line<'static>> {
    if cols == 0 || rows == 0 {
        return vec![];
    }
    let want = cols * 2;
    let max = if max <= 0.0 { 1.0 } else { max };
    // Right-align history against the graph's right edge; pad the left with
    // zeroes so a freshly started dashboard grows in rather than stretching.
    let mut samples = vec![0.0f64; want];
    let have = data.len().min(want);
    for i in 0..have {
        samples[want - have + i] = data[data.len() - have + i];
    }
    // Two sets of heights, and the difference between them is the whole
    // reason this graph reads like btop's.
    //
    // `raw` is the measurement. `levels` is what gets DRAWN, floored at one
    // sub-dot so there is a continuous baseline across the full width —
    // including the part of the history buffer that is still zero. Dumping
    // btop's own output and counting glyphs says that floor is 85% of every
    // braille character it emits.
    //
    // The colour then comes from `raw`, never from `levels`. Counting the
    // COLOURS in that same dump: 81% of btop's painted glyphs are (64,64,64),
    // flat dark grey. It spends the green→yellow→red gradient only where a
    // value actually reaches, and draws everything else — the floor, the
    // empty history — in grey. Colouring the floor by its height instead
    // paints a green band across the entire width and a graph that is all
    // gradient all the time, which is exactly what ours looked like.
    let total = rows * 4;
    let raw: Vec<usize> = samples
        .iter()
        .map(|v| (((v / max).clamp(0.0, 1.0)) * total as f64).round() as usize)
        .collect();
    let levels: Vec<usize> = raw.iter().map(|l| (*l).max(1)).collect();

    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut spans: Vec<Span> = Vec::with_capacity(cols);
        // Height fraction of this row's top edge drives its colour.
        let row_frac = (total - r * 4) as f64 / total as f64;
        let lit = Style::default().fg(grad(row_frac));
        let floor = Style::default().fg(GRAPH_FLOOR);
        for c in 0..cols {
            let mut bits: u8 = 0;
            // True once any dot in this cell is backed by a real measurement
            // rather than by the drawn floor.
            let mut real = false;
            for (s, (&lm, &rm)) in LEFT.iter().zip(RIGHT.iter()).enumerate() {
                let height_from_bottom = total - (r * 4 + s);
                if levels[c * 2] >= height_from_bottom {
                    bits |= lm;
                    real |= raw[c * 2] >= height_from_bottom;
                }
                if levels[c * 2 + 1] >= height_from_bottom {
                    bits |= rm;
                    real |= raw[c * 2 + 1] >= height_from_bottom;
                }
            }
            let ch = char::from_u32(0x2800 + bits as u32).unwrap_or(' ');
            spans.push(Span::styled(ch.to_string(), if real { lit } else { floor }));
        }
        out.push(Line::from(spans));
    }
    out
}

