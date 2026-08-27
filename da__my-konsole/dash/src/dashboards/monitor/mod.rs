// Monitor — btop's UI, drawn from the my-konsole watchdog snapshot.
//
// WHY THIS READS A FILE INSTEAD OF SAMPLING
// The previous version ran sysinfo::System::refresh_all() plus shellouts to df
// and /proc/net/dev on every tick — a second full sampler competing with the
// tray daemon that already samples this machine every 2s and publishes
// $XDG_RUNTIME_DIR/my-konsole-watchdog.json. That duplication is exactly what
// makes glances cost 20-24% CPU here for numbers something else already has.
// This box collects nothing: one read per tick, then draw.
//
// It also gets data a TUI sampler would not have: the daemon keeps 10s/1m/5m/15m
// rolling averages and run-queue wait PER PROCESS (the `w` key cycles them, and
// the C10s/C60s/M10s/M60s columns show two of them beside the live value and
// are sortable in their own right),
// and freeze-guard publishes its own PSI voter state to /run/freeze-guard.json,
// so the PSI box can show not just pressure but which voters are armed.
//
// The kill path is the daemon's, not ours: a request is a "<pid> <SIG>" line
// appended to my-konsole-watchdog.kill, and the daemon enforces the protected
// slices. What this UI does with `protected` is a courtesy (dim the row, say
// why) — it is not the safety boundary and must never be treated as one.
//
// NOTE ON SELECTING TEXT: no mouse capture is enabled anywhere in this crate,
// which is deliberate — it is why you can drag-select and copy out of this
// dashboard the way you can in glances but cannot in btop.
use std::fs;
use std::io::Write as _;

use crossterm::event::KeyCode;
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Cell, Clear, Paragraph, Row, Table};
use ratatui::Frame;
use serde_json::Value;

use crate::frame::Dashboard;

// ── the parts of this dashboard that are their own concern ─────────────
// Split out because a four-thousand-line file is not a module, it is a
// directory that has not happened yet. Each is testable on its own and none
// of them knows about the others.
mod data;
mod export;
mod input;
mod model;
mod view;

// Re-imported so a view still says `num(&s, "cpu")`: the split is for
// organising the source, not for making every call site longer.
use data::parse::{age_secs, ctr_mem, ctr_num};
use data::sort::{avg_or, num_opt, sort_procs, tree_order, Sort, Win, SORT_ORDER};
use data::storage;
use data::tree::{file_tree, TreeCache};
use data::{arr, kill_path, now_secs, num, read_json, snapshot_path, text, HIST};
use export::{exe_dir, export_snapshot, open_dir, proc_comm};
use input::cmd;
use model::columns::{
    UnitRow, CTR_ACTIONS, CTR_SORT, FLEET_SORT, IMG_ACTIONS, IMG_SORT, UNIT_ACTIONS,
};
use model::keys::{
    ACTIONS, BOX_NAMES, B_MESH, B_NET, B_PSI, B_SLICES, B_STORAGE, CMD_HELP, FRAME_RESERVED, FREE,
    MENU, OTHER_KEYS, SORT_KEYS,
};
use model::tabs::{Sub, Tab, TABS};
use view::draw::{bbox, braille_graph, grad, meter, tabbox, DIM, GRAPH_FLOOR, LABEL};
use view::fmt::{
    fmt_bps, fmt_bytes_short, fmt_fixed, fmt_g, fmt_gib, fmt_mem_cell, fmt_rate, fmt_rate_mb,
    fmt_uptime, push, trunc, z, zp,
};







/// Which modal owns the keyboard. btop's Esc opens a menu rather than quitting,
/// and every modal here closes back to None — so Esc is never a way out of the
/// program, which is the whole point of ^c/^d being the only exit.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Overlay {
    None,
    Menu,
    Help,
    Kill,
    Detail,
    /// The `x` menu of memory-freeing tools.
    Free,
    /// start/stop/restart a declared unit the cursor is parked on.
    Unit,
    /// One machine's totals, opened from the fleet view.
    Machine,
    /// One container, with the verbs that act on it.
    Ctr,
    /// One image, with the verbs that act on it.
    Img,
    /// Pick which machine the whole dashboard is measuring.
    Target,
    /// The `:` command line.
    Cmd,
    /// Which boxes are shown — the "options" the menu always advertised.
    Boxes,
}


// ───────────────────────────────── dashboard ──────────────────────────────────

pub struct Monitor {
    snap: Value,
    guard: Value,
    stale: bool,
    age: f64,
    last_ts: f64,
    host: String,
    kernel: String,

    cpu_hist: Vec<f64>,
    /// One history per core, so each core row can carry its own btop
    /// sparkline instead of a bar that only knows this instant.
    core_hist: Vec<Vec<f64>>,
    mem_hist: Vec<f64>,
    rx_hist: Vec<f64>,
    tx_hist: Vec<f64>,
    psi_hist: Vec<f64>,

    sort: Sort,
    desc: bool,
    win: Win,
    /// WHICH TAB, AND WHICH MODE OF IT. This pair is the source of truth for
    /// the view; the booleans below are its projection, written only by
    /// `apply_tab`.
    ///
    /// The mode is remembered PER TAB, so leaving the fleet on wg-public-ipv6
    /// and coming back returns to wg-public-ipv6 rather than resetting.
    tab: usize,
    sub: [usize; TABS.len()],
    /// The `:` command line's buffer, while it is open.
    cmd: String,
    /// Which picker row is highlighted.
    cmd_sel: usize,
    box_sel: usize,
    /// `t`: order by the parent/child tree instead of by the sort column.
    tree: bool,
    /// `v`: append the declared service units that are stopped or idle.
    units: bool,
    /// `f`: the proc area becomes one row per mesh peer.
    fleet: bool,
    /// `z`: only the processes nothing is looking after.
    zombies: bool,
    /// `y`: what this machine did over the last day.
    history: bool,
    /// `o`: containers and what they are using.
    docker: bool,
    /// `I`: the images on the box, running or not.
    images: bool,
    /// `F`: the home directory as a tree.
    files: bool,
    /// `.` inside the files tab: whether dotfiles are in it.
    files_hidden: bool,
    /// The rendered tree, cached. `tree -L 4` over a home directory walks tens
    /// of thousands of inodes — running it on a 1s render loop would make this
    /// panel the most expensive thing on the machine. It is built when the tab
    /// is opened and when the dotfile toggle flips, and not otherwise.
    /// Keyed by machine + dotfile toggle; see TreeCache.
    files_cache: TreeCache,
    /// The storage declaration, cached. It parses a 383KB JSON out of
    /// cloud-infra and reads /proc/mounts; neither belongs on a 1s render
    /// loop, and neither changes while you are looking at it.
    storage_cache: Vec<storage::Unit>,
    /// Drive quotas and repository lists, filled by a background thread.
    /// Separate from the cache above because that one is read synchronously
    /// and this one arrives when the network decides to answer.
    repos: storage::Extras,
    files_scroll: u16,
    /// Which column containers-c ranks by, and which way.
    ctr_sort: usize,
    ctr_desc: bool,
    /// Which column the fleet ranks by, and which way.
    fleet_sort: usize,
    fleet_desc: bool,
    /// Same for containers-i.
    img_sort: usize,
    img_desc: bool,
    /// The container the detail modal is pinned to, by NAME. Same reason the
    /// process modal pins a pid: the list re-ranks every tick and the modal is
    /// about the container you chose, not about row 7.
    ctr_pin: Option<String>,
    img_pin: Option<String>,
    /// `w`: what is declared open against what is actually bound.
    firewall: bool,

    /// `a`: the static facts — what this machine IS, not what it is doing.
    about: bool,
    sel: usize,
    /// The cursor's real identity. `sel` is only where that pid happened to
    /// land in the current ordering, and the ordering changes every tick.
    sel_pid: Option<i64>,
    offset: usize,
    killing: Option<(i32, String)>,
    msg: Option<(String, bool)>,

    overlay: Overlay,
    menu_sel: usize,
    act_sel: usize,
    show: [bool; BOX_NAMES.len()],
    /// The mesh peer table and the remote-snapshot fetcher, both on their
    /// own threads so a dead peer's connect timeout cannot stall a render.
    mesh: crate::dashboards::mesh::Mesh,
    target_sel: usize,
    free_sel: usize,
    unit_sel: usize,
    /// Alias of the peer the Machine modal is describing.
    machine: Option<String>,
    /// The pid the detail modal was opened on, pinned. The modal is about
    /// that process; the list underneath re-sorts every tick.
    detail_pid: Option<i32>,
    /// (name, scope) of the unit the Unit modal is acting on.
    acting_unit: Option<(String, String)>,
    /// `x` → "list lost processes": filter the table down to orphans.
    orphans: bool,
    quit: bool,
    /// Scroll position inside the process detail modal — a full disclosure is
    /// longer than any terminal, so it has to scroll or it is not full.
    detail_scroll: u16,
}

impl Monitor {
    pub fn new() -> Self {
        Monitor {
            snap: Value::Null,
            guard: Value::Null,
            stale: true,
            age: 0.0,
            last_ts: -1.0,
            host: fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default().trim().to_string(),
            kernel: fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default().trim().to_string(),
            cpu_hist: vec![],
            core_hist: vec![],
            mem_hist: vec![],
            rx_hist: vec![],
            tx_hist: vec![],
            psi_hist: vec![],
            sort: Sort::Cpu,
            desc: true,
            win: Win::Now,
            tab: 0,
            sub: [0; TABS.len()],
            cmd: String::new(),
            cmd_sel: 0,
            box_sel: 0,
            tree: false,
            units: false,
            fleet: false,
            zombies: false,
            history: false,
            docker: false,
            images: false,
            files: false,
            files_hidden: false,
            files_cache: TreeCache::default(),
            storage_cache: vec![],
            repos: storage::Extras::default(),
            files_scroll: 0,
            ctr_sort: 0,
            ctr_desc: true,
            fleet_sort: 0,
            fleet_desc: true,
            img_sort: 0,
            img_desc: true,
            ctr_pin: None,
            img_pin: None,
            about: false,
            firewall: false,
            sel: 0,
            sel_pid: None,
            offset: 0,
            killing: None,
            msg: None,
            overlay: Overlay::None,
            menu_sel: 0,
            act_sel: 0,
            show: [true; BOX_NAMES.len()],
            mesh: crate::dashboards::mesh::Mesh::start(),
            target_sel: 0,
            free_sel: 0,
            unit_sel: 0,
            machine: None,
            detail_pid: None,
            acting_unit: None,
            orphans: false,
            quit: false,
            detail_scroll: 0,
        }
    }

    /// Ask the daemon to signal a pid. We do NOT signal it ourselves: the
    /// daemon owns the protected-slice check, and routing every request
    /// through it keeps one enforcement point rather than two that can drift.
    fn request_kill(&mut self, pid: i32, sig: &str) {
        let path = kill_path();
        let res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "{pid} {sig}"));
        self.msg = Some(match res {
            Ok(()) => (
                match sig {
                    // Addressed to the machine, not a pid — saying "pid 0"
                    // here would be technically true and completely useless.
                    "REAP" => "reap → queued: SIGCHLD to every zombie's parent".to_string(),
                    "RECLAIM" => "reclaim → queued: pushing this session's cold pages out".to_string(),
                    "RESTART" => format!("restart → pid {pid} queued for the daemon"),
                    _ => format!("SIG{sig} → pid {pid} queued for the daemon"),
                },
                false,
            ),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
    }

    /// The storage box.
    ///
    /// df is not enough here and that is the whole reason this exists: on a
    /// single btrfs pool every subvolume mount reports the SAME total/used, so
    /// fifteen mounts render fifteen identical bars. What actually answers
    /// "what is eating the disk" is per-subvolume quota accounting, which the
    /// daemon reads out of btrfs' own sysfs.
    ///
    ///   referenced — everything the subvolume can see (its apparent size)
    ///   exclusive  — what deleting it would ACTUALLY return; the gap is data
    ///                shared with snapshots and reflinks
    ///
    /// Falls back to the plain statvfs rows when there is no btrfs pool or
    /// quotas are off, which is a normal state, not an error.
    fn storage_lines(&self, s: &Value, width: u16, height: u16) -> Vec<Line<'static>> {
        let mut l: Vec<Line> = vec![];
        let pools = arr(s, "storage");
        let bw = (width as usize).saturating_sub(34).clamp(6, 30);

        for pool in pools {
            let alloc = num(pool, "alloc");
            let size = num(pool, "dev_size").max(1.0);
            let used = num(pool, "alloc_used");
            let label = text(pool, "label");
            let mut sp = vec![Span::styled(
                format!("{:<9}", if label.is_empty() { "btrfs".into() } else { label }),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            )];
            sp.extend(meter(bw, used / size, "").spans);
            sp.push(Span::styled(
                format!(" {} / {}", fmt_g(used), fmt_g(size)),
                Style::default().fg(Color::Gray),
            ));
            l.push(Line::from(sp));
            // Allocated-but-unused chunks are the classic btrfs surprise: the
            // pool can report free space that no allocation can reach until a
            // balance runs, so the two figures are shown apart.
            l.push(Line::from(vec![
                Span::styled("  data ", Style::default().fg(LABEL)),
                Span::styled(
                    format!("{}/{}", fmt_g(num(pool, "data_used")), fmt_g(num(pool, "data_total"))),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled("  meta ", Style::default().fg(LABEL)),
                Span::styled(
                    format!("{}/{}", fmt_g(num(pool, "meta_used")), fmt_g(num(pool, "meta_total"))),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled("  unalloc ", Style::default().fg(LABEL)),
                Span::styled(fmt_g((size - alloc).max(0.0)), Style::default().fg(Color::Rgb(120, 200, 255))),
            ]));

            let vols = arr(pool, "volumes");
            l.push(Line::from(vec![
                Span::styled(format!("{:<22}", "  subvolume"), Style::default().fg(DIM)),
                Span::styled(format!("{:>9}", "refer"), Style::default().fg(DIM)),
                Span::styled(format!("{:>9}", "excl"), Style::default().fg(DIM)),
                Span::styled("  quota", Style::default().fg(DIM)),
            ]));
            // One line per remaining row; the list is already sorted biggest
            // first by the daemon, so a truncated box still shows what matters.
            let room = (height as usize).saturating_sub(l.len()).max(1);
            for v in vols.iter().take(room) {
                let refer = num(v, "referenced");
                let excl = num(v, "exclusive");
                let limit = num(v, "limit");
                let mount = text(v, "mount");
                // Tail, not head: /home/diego/.local/share/claude and
                // /home/diego/.local/share/octocode differ only at the end.
                // char-wise so a non-ASCII mount cannot panic on a byte split.
                let short = if mount.chars().count() > 20 {
                    let tail: String = mount.chars().skip(mount.chars().count() - 19).collect();
                    format!("…{tail}")
                } else {
                    mount
                };
                let quota = if limit > 0.0 {
                    Span::styled(
                        format!("  {:>3.0}% of {}", refer / limit * 100.0, fmt_g(limit)),
                        Style::default().fg(grad(refer / limit)),
                    )
                } else {
                    Span::styled("     —", Style::default().fg(DIM))
                };
                l.push(Line::from(vec![
                    Span::styled(format!("  {short:<20}"), Style::default().fg(Color::Gray)),
                    Span::styled(format!("{:>9}", fmt_g(refer)), Style::default().fg(grad(refer / size))),
                    Span::styled(format!("{:>9}", fmt_g(excl)), Style::default().fg(Color::Rgb(140, 150, 170))),
                    quota,
                ]));
            }
        }

        if pools.is_empty() {
            for dk in arr(s, "disks") {
                let pct = num(dk, "pct");
                let mut sp = vec![Span::styled(format!("{:<9}", text(dk, "mount")), Style::default().fg(LABEL))];
                sp.extend(meter(bw, pct / 100.0, "").spans);
                sp.push(Span::styled(
                    format!(" {}/{}", fmt_gib(num(dk, "used_gib")), fmt_gib(num(dk, "total_gib"))),
                    Style::default().fg(Color::Gray),
                ));
                l.push(Line::from(sp));
            }
        }
        l.push(Line::from(vec![
            Span::styled("  io  read ", Style::default().fg(LABEL)),
            Span::styled(fmt_rate_mb(num(s, "disk_r")), Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled("  write ", Style::default().fg(LABEL)),
            Span::styled(fmt_rate_mb(num(s, "disk_w")), Style::default().fg(Color::Rgb(220, 140, 240))),
        ]));
        l
    }

    /// The watchdog's slice manager.
    ///
    /// cgroup slices are the units the watchdog actually reasons about: the
    /// protected ones refuse kill requests, and memory.high/memory.max are the
    /// throttle and kill points that decide what dies when this box runs out.
    /// A slice can also be stalling on its own while machine-wide PSI looks
    /// calm, which is why each row carries its own pressure.
    fn slice_lines(&self, s: &Value, width: u16, height: u16) -> Vec<Line<'static>> {
        let slices = arr(s, "slices");
        let mut l: Vec<Line> = vec![Line::from(vec![
            Span::styled(format!("{:<20}", "slice"), Style::default().fg(DIM)),
            Span::styled(format!("{:>8}", "mem"), Style::default().fg(DIM)),
            Span::styled(format!("{:>8}", "swap"), Style::default().fg(DIM)),
            Span::styled(format!("{:>9}", "high"), Style::default().fg(DIM)),
            Span::styled(format!("{:>9}", "max"), Style::default().fg(DIM)),
            Span::styled(format!("{:>6}", "pids"), Style::default().fg(DIM)),
            Span::styled(format!("{:>7}", "mem·io"), Style::default().fg(DIM)),
        ])];
        if slices.is_empty() {
            l.push(Line::from(Span::styled(
                "  no cgroup data — daemon too old to publish slices",
                Style::default().fg(Color::Rgb(240, 160, 90)),
            )));
            return l;
        }
        let _ = width;
        for sl in slices.iter().take((height as usize).saturating_sub(2)) {
            let name = text(sl, "name");
            let cur = num(sl, "current");
            let max = num(sl, "max");
            let high = num(sl, "high");
            let prot = sl.get("protected").and_then(|v| v.as_bool()).unwrap_or(false);
            // A limit of -1 is the daemon's way of saying the file read "max":
            // no limit at all, which is not the same as a limit of zero.
            let lim = |v: f64| -> Span<'static> {
                if v < 0.0 {
                    Span::styled(format!("{:>9}", "—"), Style::default().fg(DIM))
                } else {
                    Span::styled(format!("{:>9}", fmt_bytes_short(v)), Style::default().fg(Color::Gray))
                }
            };
            // Colour against whichever ceiling exists — max if set, else high.
            let ceil = if max > 0.0 { max } else { high };
            let frac = if ceil > 0.0 { cur / ceil } else { 0.0 };
            let mpsi = num(sl, "mem_psi");
            let iopsi = num(sl, "io_psi");
            l.push(Line::from(vec![
                Span::styled(
                    format!("{}{:<width$}", if prot { "🔒" } else { "  " }, name, width = 18),
                    Style::default().fg(if prot { Color::Rgb(240, 160, 90) } else { Color::Gray }),
                ),
                Span::styled(format!("{:>8}", fmt_bytes_short(cur)), Style::default().fg(grad(frac))),
                Span::styled(format!("{:>8}", fmt_bytes_short(num(sl, "swap"))), Style::default().fg(Color::Rgb(140, 150, 170))),
                lim(high),
                lim(max),
                Span::styled(format!("{:>6.0}", num(sl, "pids")), Style::default().fg(LABEL)),
                Span::styled(format!("{mpsi:>3.0}·{iopsi:<3.0}"), Style::default().fg(grad(mpsi.max(iopsi) / 20.0))),
            ]));
        }
        l
    }

    /// A centred modal frame: clear the cells under it (otherwise the boxes
    /// below bleed through the gaps) and draw a titled border.
    fn modal(f: &mut Frame, area: Rect, w: u16, h: u16, title: &str, accent: Color) -> Rect {
        let w = w.min(area.width.saturating_sub(2));
        let h = h.min(area.height.saturating_sub(2));
        let r = Rect {
            x: area.x + (area.width.saturating_sub(w)) / 2,
            y: area.y + (area.height.saturating_sub(h)) / 2,
            width: w,
            height: h,
        };
        f.render_widget(Clear, r);
        let b = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(accent))
            .style(Style::default().bg(Color::Rgb(16, 18, 24)))
            .title(Line::from(vec![
                Span::styled("┤", Style::default().fg(accent)),
                Span::styled(title.to_string(), Style::default().fg(accent).add_modifier(Modifier::BOLD)),
                Span::styled("├", Style::default().fg(accent)),
            ]));
        let inner = b.inner(r);
        f.render_widget(b, r);
        inner
    }

    fn render_kill(&self, f: &mut Frame, area: Rect) {
        let Some((pid, name)) = self.killing.clone() else { return };
        let red = Color::Rgb(240, 72, 72);
        let inner = Self::modal(f, area, 74, ACTIONS.len() as u16 + 5, "act on process", red);
        let mut lines = vec![
            Line::from(vec![
                Span::styled(name, Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
                Span::styled(format!("  pid {pid}"), Style::default().fg(LABEL)),
            ]),
            Line::from(Span::styled("", Style::default())),
        ];
        for (i, (sig, why)) in ACTIONS.iter().enumerate() {
            let on = i == self.act_sel;
            let mark = if on { "▶" } else { " " };
            let key = Style::default().fg(Color::Black).bg(if *sig == "RESTART" {
                Color::Rgb(120, 220, 140)
            } else {
                Color::Rgb(120, 200, 255)
            });
            lines.push(Line::from(vec![
                Span::styled(format!("{mark} "), Style::default().fg(red)),
                Span::styled(format!(" {} ", i + 1), key),
                Span::styled(
                    format!(" {sig:<8}"),
                    Style::default()
                        .fg(if on { Color::White } else { Color::Gray })
                        .add_modifier(if on { Modifier::BOLD } else { Modifier::empty() }),
                ),
                Span::styled(*why, Style::default().fg(LABEL)),
            ]));
        }
        lines.push(Line::from(Span::styled(
            "↑↓ pick · enter or a digit to send · any other key cancels",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(lines), inner);
    }

    fn render_menu(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(f, area, 68, MENU.len() as u16 + 4, "menu", accent);
        let mut lines = vec![Line::from(Span::styled("", Style::default()))];
        for (i, (item, why)) in MENU.iter().enumerate() {
            let on = i == self.menu_sel;
            lines.push(Line::from(vec![
                Span::styled(if on { " ▶ " } else { "   " }, Style::default().fg(accent)),
                Span::styled(
                    format!("{item:<9}"),
                    Style::default()
                        .fg(if on { Color::White } else { Color::Gray })
                        .add_modifier(if on { Modifier::BOLD } else { Modifier::empty() }),
                ),
                Span::styled(*why, Style::default().fg(LABEL)),
            ]));
        }
        lines.push(Line::from(Span::styled(
            "  ↑↓ enter · esc closes · ^c quits from anywhere",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(lines), inner);
    }

    /// The peers you can actually switch TO. "this machine" is already the
    /// first row of the picker as the local option, so listing it again among
    /// the ssh targets would offer to ssh to yourself — and, worse, would put
    /// the drawn list and the picked index one apart.
    fn selectable_peers(mesh: &crate::dashboards::mesh::Mesh) -> Vec<crate::dashboards::mesh::Peer> {
        mesh.list().into_iter().filter(|p| !p.local).collect()
    }

    /// Pick the machine this dashboard measures: this one, or a mesh peer
    /// read over ssh. Peers that did not answer their last probe are still
    /// listed and still selectable — "unreachable" is a probe result, not a
    /// permission, and the ssh attempt gives a better error than we can.
    fn render_target(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let peers = Self::selectable_peers(&self.mesh);
        let cur = self.mesh.target();
        let inner = Self::modal(f, area, 84, peers.len() as u16 + 6, "measure which machine", accent);
        let mut l: Vec<Line> = vec![];
        let mut row = |i: usize, mark: bool, name: String, note: String, style: Style| {
            let sel = i == self.target_sel;
            l.push(Line::from(vec![
                Span::styled(
                    if sel { "▶ " } else { "  " },
                    Style::default().fg(accent),
                ),
                Span::styled(if mark { "● " } else { "  " }, Style::default().fg(Color::Rgb(120, 220, 140))),
                // 30: "oci-analytics-pub  10.1.0.1" is 27 wide and used to
                // run straight into its own latency.
                Span::styled(format!("{name:<30}"), if sel { style.add_modifier(Modifier::BOLD) } else { style }),
                Span::styled(note, Style::default().fg(DIM)),
            ]));
        };
        row(
            0,
            cur.is_none(),
            format!("{}  (this machine)", self.host),
            "read straight from the runtime dir".into(),
            Style::default().fg(Color::Gray),
        );
        for (i, p) in peers.iter().enumerate() {
            let note = if !p.probed {
                "probing…".to_string()
            } else if p.up {
                format!("{:.0} ms", p.rtt_ms)
            } else {
                "unreachable".to_string()
            };
            row(
                i + 1,
                cur.as_deref() == Some(p.alias.as_str()),
                format!("{}  {}", p.alias, p.ip),
                note,
                Style::default().fg(if p.probed && !p.up { Color::Rgb(150, 110, 110) } else { Color::Gray }),
            );
        }
        if peers.is_empty() {
            l.push(Line::from(Span::styled(
                "  no mesh peers in ~/.ssh/config",
                Style::default().fg(Color::Rgb(240, 160, 90)),
            )));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter measures it · esc cancels · the peer needs my-konsole-tray",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// The `x` menu. Each entry says what it actually does, because "clean
    /// memory" means four different things and three of them are myths.
    fn render_free(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 220, 140);
        let inner = Self::modal(f, area, 86, FREE.len() as u16 * 2 + 4, "free memory", accent);
        let mut l: Vec<Line> = vec![];
        for (i, (_, title, why)) in FREE.iter().enumerate() {
            let sel = i == self.free_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶  " } else { "   " }, Style::default().fg(accent)),
                Span::styled(format!("{}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    title.to_string(),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
            ]));
            l.push(Line::from(Span::styled(format!("        {why}"), Style::default().fg(DIM))));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit runs it · any other key cancels",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// The `:` line and its picker, drawn where vim and fzf both draw them:
    /// the input on the bottom edge, the candidates stacked UPWARDS above it.
    ///
    /// Upwards because the input must not move. A list that grows downwards
    /// pushes the line you are typing on down the screen as it fills, and a
    /// prompt that walks away from the cursor is unusable.
    fn render_cmd(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let hits = cmd::matches(&self.cmd, self.tab);
        let shown = hits.len().min(8);
        let bottom = area.y + area.height.saturating_sub(1);

        // The list, one row per hit, climbing from just above the input.
        for (i, p) in hits.iter().take(shown).enumerate() {
            let y = bottom.saturating_sub((shown - i) as u16);
            if y <= area.y {
                break;
            }
            let r = Rect { x: area.x, y, width: area.width, height: 1 };
            f.render_widget(Clear, r);
            let sel = i == self.cmd_sel.min(shown.saturating_sub(1));
            let bg = if sel { Color::Rgb(38, 48, 66) } else { Color::Rgb(16, 18, 24) };
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(if sel { " ▶ " } else { "   " }, Style::default().fg(accent)),
                    Span::styled(
                        format!("{:<18}", trunc(&p.name, 18)),
                        if sel {
                            Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                        } else {
                            Style::default().fg(Color::Gray)
                        },
                    ),
                    Span::styled(trunc(&p.desc, 70), Style::default().fg(DIM)),
                ]))
                .style(Style::default().bg(bg)),
                r,
            );
        }

        let r = Rect { x: area.x, y: bottom, width: area.width, height: 1 };
        f.render_widget(Clear, r);
        let tail = if hits.is_empty() && !self.cmd.is_empty() {
            "  no match".to_string()
        } else {
            format!("  {} match{}  ·  ↑↓ pick · tab completes · enter runs", hits.len(),
                    if hits.len() == 1 { "" } else { "es" })
        };
        f.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(format!(":{}", self.cmd), Style::default().fg(accent)),
                // The block cursor, drawn rather than moved: this panel never
                // shows a real one, and an invisible caret reads as a frozen
                // screen.
                Span::styled("▌", Style::default().fg(accent)),
                Span::styled(
                    tail,
                    Style::default().fg(if hits.is_empty() && !self.cmd.is_empty() {
                        Color::Rgb(240, 160, 90)
                    } else {
                        DIM
                    }),
                ),
            ]))
            .style(Style::default().bg(Color::Rgb(16, 18, 24))),
            r,
        );
    }

    fn cmd_key(&mut self, k: KeyCode) {
        let n = cmd::matches(&self.cmd, self.tab).len().min(8);
        match k {
            KeyCode::Esc => {
                self.cmd.clear();
                self.cmd_sel = 0;
                self.overlay = Overlay::None;
            }
            KeyCode::Down => self.cmd_sel = if n == 0 { 0 } else { (self.cmd_sel + 1) % n },
            KeyCode::Up => self.cmd_sel = if n == 0 { 0 } else { (self.cmd_sel + n - 1) % n },
            // Tab completes to the highlighted row without running it, so you
            // can see what you are about to do and keep editing.
            KeyCode::Tab => {
                if let Some(p) = cmd::matches(&self.cmd, self.tab).into_iter().nth(self.cmd_sel) {
                    self.cmd = p.name;
                    self.cmd_sel = 0;
                }
            }
            KeyCode::Enter => {
                // The HIGHLIGHTED candidate, not the raw text — that is what
                // makes the picker a picker. With nothing matching, the typed
                // text still runs, so an exact command never needs the list.
                let pick = cmd::matches(&self.cmd, self.tab).into_iter().nth(self.cmd_sel);
                let line = match pick {
                    Some(p) => p.name,
                    None => self.cmd.clone(),
                };
                self.cmd.clear();
                self.cmd_sel = 0;
                self.run_cmd(&line);
            }
            KeyCode::Backspace => {
                // Backspacing past the colon leaves, the way it does in vim.
                if self.cmd.pop().is_none() {
                    self.overlay = Overlay::None;
                }
                self.cmd_sel = 0;
            }
            KeyCode::Char(c) => {
                self.cmd.push(c);
                // Every keystroke re-ranks the list, so a highlight held over
                // from the previous query would point at an unrelated row.
                self.cmd_sel = 0;
            }
            _ => {}
        }
    }

    /// Run one command line: resolve it, then do the one thing it named.
    fn run_cmd(&mut self, line: &str) {
        self.overlay = Overlay::None;
        let c = cmd::resolve(line, self.tab);
        self.apply_cmd(c);
    }

    /// Do what a resolved command says.
    ///
    /// Shared by the command line and the main menu, so a menu entry and the
    /// `:` name for it cannot drift into doing different things.
    fn apply_cmd(&mut self, c: cmd::Cmd) {
        match c {
            cmd::Cmd::Go(t, sub) => {
                let sub = sub.unwrap_or(self.sub[t]);
                self.goto(t, sub);
            }
            cmd::Cmd::Open(o) => {
                // Every list-shaped modal opens at its first row rather than
                // wherever it was left, which is where the eye goes.
                self.menu_sel = 0;
                self.target_sel = 0;
                self.box_sel = 0;
                self.free_sel = 0;
                self.overlay = o;
            }
            cmd::Cmd::Quit => self.quit = true,
            cmd::Cmd::Export(all) => self.export_now(all),
            cmd::Cmd::Units => {
                self.units = !self.units;
                self.msg = Some((
                    format!(
                        "declared units {}",
                        if self.units { "shown — stopped and idle services" } else { "hidden" }
                    ),
                    false,
                ));
            }
            cmd::Cmd::Err(e) => self.msg = Some((e, true)),
            cmd::Cmd::Nothing => {}
        }
    }

    /// Which boxes are shown.
    ///
    /// The menu has always described "options" as "sorting, averaging window,
    /// which boxes are shown" and then opened the help page, which can show
    /// you the keys but cannot change anything. This is the screen it was
    /// describing. It also buys back 1-9, which were spent on a preference you
    /// set once and are worth far more as sub-tab keys.
    fn render_boxes(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(f, area, 60, BOX_NAMES.len() as u16 + 4, "boxes", accent);
        let mut l: Vec<Line> = vec![];
        for (i, b) in BOX_NAMES.iter().enumerate() {
            let sel = i == self.box_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶  " } else { "   " }, Style::default().fg(accent)),
                Span::styled(format!("{}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    if self.show[i] { "[x]  " } else { "[ ]  " },
                    Style::default().fg(if self.show[i] { accent } else { DIM }),
                ),
                Span::styled(
                    b.to_string(),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
            ]));
        }
        l.push(Line::from(Span::styled(
            "   1-5 or ↑↓ and enter · esc closes",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// Stays open while you toggle. Folding boxes away is something you do to
    /// two or three of them at once, and a screen that closed after each one
    /// would make you reopen it every time.
    fn boxes_key(&mut self, k: KeyCode) {
        let n = BOX_NAMES.len();
        match k {
            KeyCode::Down => self.box_sel = (self.box_sel + 1) % n,
            KeyCode::Up => self.box_sel = (self.box_sel + n - 1) % n,
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = (c as usize).wrapping_sub('1' as usize);
                if i < n {
                    self.box_sel = i;
                    self.toggle_box(i);
                }
            }
            KeyCode::Enter | KeyCode::Char(' ') => {
                let i = self.box_sel;
                self.toggle_box(i);
            }
            _ => self.overlay = Overlay::None,
        }
    }

    fn toggle_box(&mut self, i: usize) {
        self.show[i] = !self.show[i];
        self.msg = Some((
            format!("{} {}", BOX_NAMES[i], if self.show[i] { "shown" } else { "hidden" }),
            false,
        ));
    }

    fn render_overlays(&self, f: &mut Frame, area: Rect) {
        match self.overlay {
            Overlay::Kill => self.render_kill(f, area),
            Overlay::Menu => self.render_menu(f, area),
            Overlay::Cmd => self.render_cmd(f, area),
            Overlay::Boxes => self.render_boxes(f, area),
            Overlay::Help => self.render_help(f, area),
            Overlay::Detail => self.render_detail(f, area),
            Overlay::Target => self.render_target(f, area),
            Overlay::Free => self.render_free(f, area),
            Overlay::Unit => self.render_unit(f, area),
            Overlay::Machine => self.render_machine(f, area),
            Overlay::Ctr => self.render_ctr(f, area),
            Overlay::Img => self.render_img(f, area),
            Overlay::None => {}
        }
    }

    /// One machine, whole: what it is, what it is doing, and how much it has
    /// moved since it booted.
    ///
    /// The totals are the daemon's arithmetic, not this panel's — the local
    /// daemon computes them from /proc and the remote collector computes them
    /// the same way, so a peer and this machine answer the question
    /// identically instead of one of them being reconstructed here.
    fn render_machine(&self, f: &mut Frame, area: Rect) {
        let Some(alias) = self.machine.clone() else { return };
        let peers = self.mesh.list();
        let peer = peers.iter().find(|p| p.alias == alias);
        let local = peer.map(|p| p.local).unwrap_or(false);
        let v = if local {
            self.snap.clone()
        } else {
            self.mesh.fleet().get(&alias).and_then(|r| r.clone().ok()).unwrap_or(Value::Null)
        };
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(f, area, 82, 26, &alias, accent);
        if v.is_null() {
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!("  no snapshot from {alias} yet — the sweep runs every 20s"),
                    Style::default().fg(Color::Rgb(240, 160, 90)),
                ))),
                inner,
            );
            return;
        }
        let head = |t: &str| -> Line<'static> {
            Line::from(Span::styled(t.to_string(), Style::default().fg(accent).add_modifier(Modifier::BOLD)))
        };
        let kv = |k: &str, val: String| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<20}"), Style::default().fg(LABEL)),
                Span::styled(val, Style::default().fg(Color::Gray)),
            ])
        };
        let g = |k: &str| num(&v, k);
        let hi = |k: &str| text(&v, &format!("host_info.{k}"));
        let mut l = vec![head("identity")];
        l.push(kv("host", if hi("host").is_empty() { alias.clone() } else { hi("host") }));
        l.push(kv("address", peer.map(|p| p.ip.clone()).unwrap_or_default()));
        if !hi("os").is_empty() {
            l.push(kv("os", hi("os")));
        }
        l.push(kv("kernel", hi("kernel")));
        l.push(kv("uptime", fmt_uptime(num(&v, "totals.since_s"))));
        l.push(kv(
            "reached",
            match peer {
                Some(p) if p.local => "locally — this is the hub".into(),
                Some(p) if p.up => format!("ssh · {:.0} ms", p.rtt_ms),
                _ => "unreachable".into(),
            },
        ));

        l.push(head("now"));
        let ncpu = arr(&v, "cores").len().max(1);
        l.push(kv("cpu", format!("{:.1}%  over {} cores", g("cpu"), ncpu)));
        l.push(kv(
            "load",
            format!("{:.2}  {:.2}  {:.2}", g("load1"), g("load5"), g("load15")),
        ));
        l.push(kv(
            "memory",
            format!("{:.1}%  {} of {}", g("mem"), fmt_gib(num(&v, "mem_detail.used")), fmt_gib(num(&v, "mem_detail.total"))),
        ));
        l.push(kv(
            "swap",
            format!("{:.1}%  {} of {}", g("swap"), fmt_gib(num(&v, "swap_detail.used")), fmt_gib(num(&v, "swap_detail.total"))),
        ));
        l.push(kv(
            "psi cpu / io / mem",
            format!("{:.2}  {:.2}  {:.2}", g("psi.cpu.some10"), g("psi.io.full10"), g("psi.memory.full10")),
        ));
        l.push(kv("processes", format!("{} in the table", arr(&v, "proc_table").len())));

        // ── since boot ─────────────────────────────────────────────────
        l.push(head("moved since boot"));
        let secs = num(&v, "totals.since_s").max(1.0);
        let t = |k: &str| num(&v, &format!("totals.{k}"));
        let per_day = |b: f64| fmt_bytes_short(b / secs * 86400.0);
        l.push(kv(
            "downloaded",
            format!("{}   ({}/day)", fmt_bytes_short(t("net_rx_bytes")), per_day(t("net_rx_bytes"))),
        ));
        l.push(kv(
            "uploaded",
            format!("{}   ({}/day)", fmt_bytes_short(t("net_tx_bytes")), per_day(t("net_tx_bytes"))),
        ));
        l.push(kv(
            "read from disk",
            format!("{}   ({}/day)", fmt_bytes_short(t("disk_read_bytes")), per_day(t("disk_read_bytes"))),
        ));
        l.push(kv(
            "written to disk",
            format!("{}   ({}/day)", fmt_bytes_short(t("disk_write_bytes")), per_day(t("disk_write_bytes"))),
        ));
        l.push(Line::from(Span::styled(
            "  counters are the kernel's own, cumulative since boot — nothing here accumulates them",
            Style::default().fg(DIM),
        )));

        let ifaces = arr(&v, "host_info.ifaces");
        if !ifaces.is_empty() {
            // The mesh interfaces first and in full — v4 AND v6, both of which
            // a peer has — because the mesh address is how this machine is
            // reached and the one people come here for.
            let mesh: Vec<&Value> = ifaces
                .iter()
                .filter(|i| i.get("mesh").and_then(|m| m.as_bool()).unwrap_or(false))
                .collect();
            if !mesh.is_empty() {
                l.push(head("mesh"));
                for i in mesh {
                    let mtu = text(i, "mtu");
                    let st = text(i, "state");
                    l.push(kv(
                        &text(i, "name"),
                        format!(
                            "{}{}{}",
                            text(i, "addr"),
                            if mtu.is_empty() { String::new() } else { format!("   mtu {mtu}") },
                            if st.is_empty() { String::new() } else { format!("   {st}") },
                        ),
                    ));
                }
                l.push(Line::from(Span::styled(
                    "  keys, last handshake and per-peer transfer need root — wg(8) and",
                    Style::default().fg(DIM),
                )));
                l.push(Line::from(Span::styled(
                    "  /etc/wireguard are unreadable to an unprivileged sampler, here and on every peer.",
                    Style::default().fg(DIM),
                )));
            }
            l.push(head("network"));
            // Every remaining interface, not the first six: a box with a dozen
            // docker bridges was silently cutting the one address that mattered.
            for i in ifaces.iter().filter(|i| !i.get("mesh").and_then(|m| m.as_bool()).unwrap_or(false)) {
                l.push(kv(&text(i, "name"), text(i, "addr")));
            }
            let dns: Vec<String> = arr(&v, "host_info.dns")
                .iter()
                .filter_map(|d| d.as_str().map(|x| x.to_string()))
                .collect();
            let pubip = text(&v, "host_info.public");
            l.push(kv("public", if pubip.is_empty() { "behind NAT".into() } else { pubip }));
            l.push(kv("gateway", text(&v, "host_info.gateway")));
            l.push(kv("dns", if dns.is_empty() { "—".into() } else { dns.join("  ") }));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ scroll · any other key returns",
            Style::default().fg(DIM),
        )));
        let max = (l.len() as u16).saturating_sub(inner.height);
        f.render_widget(Paragraph::new(l).scroll((self.detail_scroll.min(max), 0)), inner);
    }

    /// The container rows in the order the view shows them — ranked and, for
    /// the name column, alphabetical. One function so the renderer and the
    /// cursor agree on which row is which.
    fn ctr_rows<'a>(&self, s: &'a Value) -> Vec<&'a Value> {
        let mut v: Vec<&Value> = arr(s, "containers").iter().collect();
        let (label, field) = CTR_SORT[self.ctr_sort.min(CTR_SORT.len() - 1)];
        v.sort_by(|a, b| {
            let key = |x: &Value| -> f64 {
                // MEM USED is the left of the slash, not the whole cell:
                // ranking on "469.7MiB / 7.595GiB" as one string would rank by
                // whichever container has the biggest LIMIT.
                if field == "mem" { ctr_num(&ctr_mem(&text(x, field)).0) } else { ctr_num(&text(x, field)) }
            };
            // "Up 18 minutes" parsed as a duration. A container that is not
            // up has no uptime to compare, so it sorts as zero and lands
            // together with the rest of the stopped ones rather than being
            // scattered through the running list by whatever its text says.
            let up = |x: &Value| -> f64 {
                let t = text(x, field);
                match t.strip_prefix("Up ") {
                    // docker writes "Up About an hour" and "Up About a
                    // minute", where the count is a word rather than a digit
                    // and age_secs reads it as zero. Both mean one of the
                    // unit that follows.
                    Some(rest) => {
                        let rest = rest.replace("About an ", "1 ").replace("About a ", "1 ");
                        // A container that IS up but whose duration will not
                        // parse still outranks one that is not up at all.
                        age_secs(&rest).max(0.000_1)
                    }
                    None => 0.0,
                }
            };
            let ord = if label == "CONTAINER" {
                text(a, field).to_lowercase().cmp(&text(b, field).to_lowercase())
            } else if label == "STATUS" {
                up(a).partial_cmp(&up(b)).unwrap_or(std::cmp::Ordering::Equal)
            } else {
                key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal)
            };
            if self.ctr_desc { ord.reverse() } else { ord }
        });
        v
    }

    /// The image rows in the order the view shows them.
    /// Is this image backing no running container?
    ///
    /// BY IMAGE ID, not by "repo:tag". `docker ps` reports the reference a
    /// container was CREATED with, and renders it as a bare ID once that
    /// reference stops resolving — which is the normal state here: CI pushes a
    /// new :latest, the box pulls it, the tag moves, and the running container
    /// is left holding an image that now shows as <none>. Comparing tags
    /// therefore called every long-running container's image idle: on oci-apps
    /// it flagged fourteen images that were each backing a live container, and
    /// two <none> rows that were running two containers apiece.
    ///
    /// The tag comparison stays as a fallback for a peer whose watchdog is
    /// older than the image_id field, so an out-of-date box degrades to the
    /// previous behaviour instead of calling everything idle.
    fn image_idle(s: &Value, img: &Value) -> bool {
        let id = text(img, "id");
        let full = format!("{}:{}", text(img, "repo"), text(img, "tag"));
        !arr(s, "containers").iter().any(|c| {
            let cid = text(c, "image_id");
            if !cid.is_empty() && !id.is_empty() {
                // Either may be the short form; compare on the shorter.
                let n = cid.len().min(id.len());
                return cid[..n] == id[..n];
            }
            text(c, "image") == full
        })
    }

    fn img_rows<'a>(&self, s: &'a Value) -> Vec<&'a Value> {
        let mut v: Vec<&Value> = arr(s, "images").iter().collect();
        let (label, field) = IMG_SORT[self.img_sort.min(IMG_SORT.len() - 1)];
        // The same set the IN USE column is drawn from, so the ranking and the
        // text in the cell can never disagree about which images are idle.
        let idle = |x: &Value| Self::image_idle(s, x);
        v.sort_by(|a, b| {
            let ord = match label {
                // Descending puts the idle ones on top, which is the direction
                // anybody asking this question wants first.
                "IN USE" => idle(a).cmp(&idle(b)),
                "IMAGE" => text(a, field).to_lowercase().cmp(&text(b, field).to_lowercase()),
                "CREATED" => age_secs(&text(a, field))
                    .partial_cmp(&age_secs(&text(b, field)))
                    .unwrap_or(std::cmp::Ordering::Equal),
                _ => ctr_num(&text(a, field))
                    .partial_cmp(&ctr_num(&text(b, field)))
                    .unwrap_or(std::cmp::Ordering::Equal),
            };
            if self.img_desc { ord.reverse() } else { ord }
        });
        v
    }

    /// One container, whole, with the verbs that act on it.
    fn render_ctr(&self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();
        let rows = self.ctr_rows(&s);
        let pin = self.ctr_pin.clone().unwrap_or_default();
        let Some(c) = rows.iter().find(|c| text(c, "name") == pin) else { return };
        let accent = Color::Rgb(120, 200, 255);
        let name = text(c, "name");
        let inner = Self::modal(f, area, 92, 24, &name, accent);
        let kv = |k: &str, v: String| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<16}"), Style::default().fg(LABEL)),
                Span::styled(v, Style::default().fg(Color::Gray)),
            ])
        };
        let or = |k: &str| -> String {
            let v = text(c, k);
            // Empty means docker could not read the cgroup, which is not zero.
            if v.is_empty() { "—".into() } else { v }
        };
        let mut l = vec![Line::from(Span::styled(
            "what it is",
            Style::default().fg(accent).add_modifier(Modifier::BOLD),
        ))];
        l.push(kv("image", text(c, "image")));
        l.push(kv("on disk", or("image_size")));
        l.push(kv("state", format!("{}  {}", text(c, "state"), text(c, "status"))));
        l.push(kv("up", or("uptime")));
        l.push(kv("command", or("command")));
        l.push(kv("ports", or("ports")));
        l.push(Line::from(Span::styled(
            "using",
            Style::default().fg(accent).add_modifier(Modifier::BOLD),
        )));
        l.push(kv("cpu", or("cpu")));
        l.push(kv("memory", format!("{}   {}", or("mem"), or("mem_pct"))));
        l.push(kv("net i/o", or("net")));
        l.push(kv("block i/o", or("block")));
        l.push(kv("pids", or("pids")));
        l.push(Line::from(Span::styled(
            "act",
            Style::default().fg(Color::Rgb(240, 169, 66)).add_modifier(Modifier::BOLD),
        )));
        for (i, (verb, why)) in CTR_ACTIONS.iter().enumerate() {
            let sel = i == self.act_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶ " } else { "  " }, Style::default().fg(accent)),
                Span::styled(format!(" {}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    format!("{verb:<10}"),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
                Span::styled(why.to_string(), Style::default().fg(LABEL)),
            ]));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit sends it · any other key returns · no remove, on purpose",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// One image, whole, with the verbs that act on it.
    fn render_img(&self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();
        let imgs = self.img_rows(&s);
        let pin = self.img_pin.clone().unwrap_or_default();
        let Some(i) = imgs
            .iter()
            .find(|i| format!("{}:{}", text(i, "repo"), text(i, "tag")) == pin)
        else {
            return;
        };
        let accent = Color::Rgb(120, 200, 255);
        let full = format!("{}:{}", text(i, "repo"), text(i, "tag"));
        let inner = Self::modal(f, area, 92, 16, &full, accent);
        let kv = |k: &str, v: String| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<16}"), Style::default().fg(LABEL)),
                Span::styled(v, Style::default().fg(Color::Gray)),
            ])
        };
        // Which containers this image is behind. It is the answer to "can I
        // delete this", and docker's own refusal is the other half.
        let users: Vec<String> = arr(&s, "containers")
            .iter()
            .filter(|c| text(c, "image") == full)
            .map(|c| text(c, "name"))
            .collect();
        let mut l = vec![Line::from(Span::styled(
            "image",
            Style::default().fg(accent).add_modifier(Modifier::BOLD),
        ))];
        l.push(kv("repository", text(i, "repo")));
        l.push(kv("tag", text(i, "tag")));
        l.push(kv("id", text(i, "id")));
        l.push(kv("size", text(i, "size")));
        l.push(kv("created", text(i, "created")));
        l.push(kv(
            "used by",
            if users.is_empty() { "nothing — this is dead weight".into() } else { users.join(", ") },
        ));
        l.push(Line::from(Span::styled(
            "act",
            Style::default().fg(Color::Rgb(240, 169, 66)).add_modifier(Modifier::BOLD),
        )));
        for (n, (verb, why)) in IMG_ACTIONS.iter().enumerate() {
            let sel = n == self.act_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶ " } else { "  " }, Style::default().fg(accent)),
                Span::styled(format!(" {}  ", n + 1), Style::default().fg(DIM)),
                Span::styled(
                    format!("{verb:<10}"),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
                Span::styled(why.to_string(), Style::default().fg(LABEL)),
            ]));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit sends it · any other key returns",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// Both action modals share their key handling: pick a row, fire a verb on
    /// the mailbox, close. `ctr` picks which table and which verb prefix.
    fn ctr_img_key(&mut self, k: KeyCode, ctr: bool) {
        let n = if ctr { CTR_ACTIONS.len() } else { IMG_ACTIONS.len() };
        let fire = |me: &mut Self, i: usize| {
            let s = me.snap.clone();
            // The pinned one, so an action never lands on a row that moved.
            let target = if ctr { me.ctr_pin.clone() } else { me.img_pin.clone() };
            let _ = &s;
            if let Some(t) = target {
                let verb = if ctr { CTR_ACTIONS[i].0 } else { IMG_ACTIONS[i].0 };
                me.request_docker(if ctr { "CTR" } else { "IMG" }, verb, &t);
            }
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Down => self.act_sel = (self.act_sel + 1) % n,
            KeyCode::Up => self.act_sel = (self.act_sel + n - 1) % n,
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= n {
                    fire(self, i - 1);
                }
            }
            KeyCode::Enter => {
                let i = self.act_sel;
                fire(self, i);
            }
            _ => self.overlay = Overlay::None,
        }
    }

    /// "0 CTR <verb> <name>" / "0 IMG <verb> <ref>" on the same mailbox the
    /// signals use — the daemon allow-lists the verb, the panel decides
    /// nothing.
    fn request_docker(&mut self, kind: &str, verb: &str, target: &str) {
        let path = kill_path();
        let res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "0 {kind} {verb} {target}"));
        self.msg = Some(match res {
            Ok(()) => (format!("{verb} {target} → queued for the daemon"), false),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
    }

    /// What can be done to a declared unit. Same mailbox as the signals, so
    /// the daemon applies one policy to everything the panel asks for.
    fn render_unit(&self, f: &mut Frame, area: Rect) {
        let Some((name, scope)) = self.acting_unit.clone() else { return };
        let accent = Color::Rgb(240, 169, 66);
        let inner = Self::modal(f, area, 78, UNIT_ACTIONS.len() as u16 + 5, "act on unit", accent);
        let mut l: Vec<Line> = vec![
            Line::from(vec![
                Span::styled(trunc(&name, 46), Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
                Span::styled(format!("  ({scope} manager)"), Style::default().fg(DIM)),
            ]),
            Line::from(""),
        ];
        for (i, (verb, why)) in UNIT_ACTIONS.iter().enumerate() {
            let sel = i == self.unit_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶ " } else { "  " }, Style::default().fg(accent)),
                Span::styled(format!(" {}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    format!("{verb:<14}"),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
                Span::styled(why.to_string(), Style::default().fg(LABEL)),
            ]));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit sends it · any other key cancels",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    fn unit_key(&mut self, k: KeyCode) {
        let Some((name, scope)) = self.acting_unit.clone() else {
            self.overlay = Overlay::None;
            return;
        };
        let fire = |me: &mut Self, i: usize| {
            me.request_unit(&name, &scope, UNIT_ACTIONS[i].0);
            me.acting_unit = None;
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Down => self.unit_sel = (self.unit_sel + 1) % UNIT_ACTIONS.len(),
            KeyCode::Up => self.unit_sel = (self.unit_sel + UNIT_ACTIONS.len() - 1) % UNIT_ACTIONS.len(),
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= UNIT_ACTIONS.len() {
                    fire(self, i - 1);
                }
            }
            KeyCode::Enter => {
                let i = self.unit_sel;
                fire(self, i);
            }
            _ => {
                self.acting_unit = None;
                self.overlay = Overlay::None;
            }
        }
    }

    /// "0 UNIT <scope> <verb> <name>" on the same mailbox the signals use.
    /// pid 0 because this is addressed to the machine, not to a process.
    fn request_unit(&mut self, name: &str, scope: &str, verb: &str) {
        let path = kill_path();
        let res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "0 UNIT {scope} {verb} {name}"));
        self.msg = Some(match res {
            Ok(()) => (format!("{verb} {name} → queued for the daemon"), false),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
    }

    /// The storage tab's rows: what is declared here, then the repositories
    /// once they arrive. Rebuilt per render rather than cached, because the
    /// second half turns up on its own schedule.
    fn storage_rows(&self) -> Vec<storage::Unit> {
        let mut v = self.storage_cache.clone();
        v.extend(self.repos.get());
        v
    }

    /// The peers on the network the fleet sub-tab is showing.
    ///
    /// The mesh reaches several of these boxes on both tunnels, so one merged
    /// list made oci-analytics and oci-analytics-pub read as two machines
    /// rather than two roads to one. Split by network they read correctly,
    /// and "is it up" gets the per-tunnel answer it always had.
    fn visible_peers(&self) -> Vec<crate::dashboards::mesh::Peer> {
        let net = TABS[self.tab].subs.get(self.sub[self.tab]).and_then(|sb| sb.net);
        let Some(pfx) = net else { return vec![] };
        self.mesh
            .list()
            .into_iter()
            // This machine sits on every network it has an address on, so it
            // belongs in each of those tabs rather than only its wg0 one.
            .filter(|p| p.local || p.ip.starts_with(pfx))
            .collect()
    }

    /// The fleet exactly as the table draws it: this sub-tab's network, ranked
    /// by the chosen column.
    ///
    /// ONE list for the renderer and the key handler. They used to disagree —
    /// the keys walked the whole mesh while the table drew a filtered subset,
    /// so enter on the second row opened whichever machine happened to be
    /// second in the UNFILTERED list. Ranking would have made that worse.
    fn fleet_view(&self, s: &Value) -> Vec<crate::dashboards::mesh::Peer> {
        let got = self.mesh.fleet();
        let mut v = self.visible_peers();
        let (label, field) = FLEET_SORT[self.fleet_sort.min(FLEET_SORT.len() - 1)];
        // A peer that has not answered has no number to rank on. Sorting it to
        // the bottom is the useful answer: you rank by CPU to find the busy
        // machine, not to be shown six silent ones first.
        let key = |p: &crate::dashboards::mesh::Peer| -> f64 {
            let snap = if p.local {
                Some(s.clone())
            } else {
                got.get(&p.alias).and_then(|r| r.clone().ok())
            };
            let Some(v) = snap else { return f64::MIN };
            match field {
                "proc_table" | "cores" => arr(&v, field).len() as f64,
                _ => num(&v, field),
            }
        };
        v.sort_by(|a, b| {
            let ord = match label {
                "PEER" => a.alias.to_lowercase().cmp(&b.alias.to_lowercase()),
                // Down is not a time. It sorts as "worst", which is where a
                // machine you cannot reach belongs in an RTT ranking.
                "RTT" => {
                    let r = |p: &crate::dashboards::mesh::Peer| {
                        if p.local {
                            0.0
                        } else if p.up {
                            p.rtt_ms
                        } else {
                            f64::MAX
                        }
                    };
                    r(a).partial_cmp(&r(b)).unwrap_or(std::cmp::Ordering::Equal)
                }
                _ => key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal),
            };
            if self.fleet_desc {
                ord.reverse()
            } else {
                ord
            }
        });
        v
    }

    /// The tab strip for whatever is on screen, both rows of it.
    ///
    /// Every view used to name its own tab — `tab("files")`, `tab("fleet")` —
    /// which is a second statement of something `self.tab` already knows, and
    /// one that can disagree with it. The strip now reads the state directly,
    /// so a view cannot render under the wrong heading.
    fn tabs_box(&self, hint: &str) -> Block<'static> {
        let tabs: Vec<(&str, char)> = TABS.iter().map(|t| (t.name, t.key)).collect();
        let subs: Vec<&str> = TABS[self.tab].subs.iter().map(|sb| sb.name).collect();
        tabbox(&tabs, self.tab, &subs, self.sub[self.tab], hint)
    }

    /// (tab, sub) is the truth; these flags are its projection.
    ///
    /// The render path reads `self.tree`, `self.fleet` and the rest in a few
    /// hundred places, and rewriting every one of them to consult the table
    /// would be a large diff for no change in behaviour. So this is the ONLY
    /// function that writes them: there is still exactly one place where the
    /// current view is decided, and the flags are a cache of it rather than a
    /// second opinion about it.
    fn apply_tab(&mut self) {
        let name = TABS[self.tab].name;
        let sub = self.sub[self.tab];
        self.tree = name == "proc" && sub == 1;
        self.zombies = name == "proc" && sub == 2;
        self.docker = name == "containers" && sub == 0;
        self.images = name == "containers" && sub == 1;
        self.fleet = name == "fleet";
        self.history = name == "history";
        self.files = name == "files";
        self.about = name == "about";
        self.firewall = name == "firewall";
    }

    /// Move to a tab and a mode of it, doing the per-view setup each needs.
    ///
    /// One door in, so nothing can switch view and forget to tell the mesh
    /// thread to start sweeping, or leave the cursor pointing past the end of
    /// a shorter list.
    fn goto(&mut self, t: usize, sub: usize) {
        let was_fleet = self.fleet;
        self.tab = t.min(TABS.len() - 1);
        let n = TABS[self.tab].subs.len().max(1);
        self.sub[self.tab] = sub.min(n - 1);
        self.apply_tab();
        // Each of these lists is a different length and a different thing, so
        // a cursor carried across from the last one points at nothing.
        if self.docker || self.images || self.fleet {
            self.sel = 0;
        }
        if self.files {
            self.files_scroll = 0;
            self.files_cache.fetch(self.files_key(), self.mesh.target(), self.files_hidden);
        }
        // Same rule as the file tree: read it on the way in, not every tick.
        if self.fleet && self.sub_name() == "storage" {
            self.storage_cache = storage::units();
            // Off-thread, and a no-op once it has answered once.
            self.repos.fetch();
        }
        // The fleet sweep is an ssh round trip per peer; it runs only while
        // the tab that needs it is open.
        if was_fleet != self.fleet {
            self.mesh.set_fleet(self.fleet);
        }
        self.msg = Some((self.tab_label(), false));
    }

    /// The current mode's name, or "" for a tab that has none.
    fn sub_name(&self) -> &'static str {
        TABS[self.tab].subs.get(self.sub[self.tab]).map(|sb| sb.name).unwrap_or("")
    }

    /// What the files cache is keyed by: the machine being measured, and
    /// whether dotfiles are shown. Both change what the tree IS.
    fn files_key(&self) -> String {
        format!("{}|{}", self.mesh.target().unwrap_or_default(), self.files_hidden)
    }

    /// "fleet · wg-public-ipv6", or just "history" for a tab with one mode.
    fn tab_label(&self) -> String {
        let t = &TABS[self.tab];
        match t.subs.get(self.sub[self.tab]) {
            Some(s) if t.subs.len() > 1 => format!("{} · {}", t.name, s.name),
            _ => t.name.to_string(),
        }
    }

    /// Write every tab out. Kept in one place so the global key path is the
    /// only thing that has to know how.
    ///
    /// `all` folds every peer into the same file. Off by default: the fleet
    /// was three quarters of the old export, and most exports are about the
    /// machine in front of you.
    fn export_now(&mut self, all: bool) {
        let snap = self.snap.clone();
        let t = self.mesh.target();
        // Peers are collected only when asked for — fleet() is an ssh round
        // trip per peer, so the default export does not pay for it at all.
        let fleet: Vec<(String, Value)> = if all {
            self.mesh
                .fleet()
                .into_iter()
                .filter_map(|(k, v)| v.ok().map(|v| (k, v)))
                .collect()
        } else {
            Vec::new()
        };
        // Exporting without having opened the files tab should still carry the
        // tree rather than an empty list.
        // Whatever is loaded for the machine currently being measured, and
        // nothing otherwise — a peer's export must never carry this machine's
        // directory names.
        let levels = self.files_cache.view(&self.files_key()).0.unwrap_or_default();
        // L3 only. The four panes overlap by construction — every L4 path has
        // its L3 parent above it and its L1 grandparent above that — so
        // concatenating them wrote the same prefixes four times over. L3 is
        // the level that carries the shape of the tree without the leaf spray
        // of L4, and one pane is the whole of it.
        let files: Vec<String> = levels[2].clone();
        self.msg = Some(match export_snapshot(&snap, t, &files, &fleet) {
            Ok(stem) => {
                let what = if all { format!(" + {} peers", fleet.len()) } else { String::new() };
                (format!("exported {stem}.json .yaml .md{what}"), false)
            }
            Err(e) => (format!("export failed: {e}"), true),
        });
    }

    /// The tab keys, honoured from whichever view you are in.
    ///
    /// They were handled per-view, so pressing `z` while looking at containers
    /// did nothing at all — a tab strip that only works from one tab is not a
    /// tab strip. Returns true when the key was a tab switch.
    fn view_key(&mut self, k: KeyCode) -> bool {
        let KeyCode::Char(c) = k else { return false };
        // Export is a GLOBAL action and must be handled before the per-view
        // branches, not inside the process view's match. It was reachable only
        // from the process list and silently did nothing everywhere else —
        // the same failure as a key the frame had already taken.
        if c == 'E' || c == 'A' {
            self.export_now(c == 'A');
            return true;
        }
        // A SUB-TAB key first, then a tab key.
        //
        // The two overlap on purpose: 'p' is the proc tab AND its "normal"
        // mode, 'o' is the containers tab AND its "containers" mode. Checking
        // modes first is what makes 'p' mean "the flat list" the way it always
        // did, rather than "whichever proc mode you left behind" — while 'f'
        // and 'y', which name no mode, return you to the one you were on.
        for (i, t) in TABS.iter().enumerate() {
            if let Some(j) = t.subs.iter().position(|sb| sb.key == Some(c)) {
                self.goto(i, j);
                return true;
            }
        }
        if let Some(i) = TABS.iter().position(|t| t.key == c) {
            self.goto(i, self.sub[i]);
            return true;
        }
        false
    }

    /// Step through the modes of the current tab, wrapping. A tab with one
    /// mode has nothing to step through and says so rather than blinking.
    fn cycle_sub(&mut self, back: bool) {
        let n = TABS[self.tab].subs.len();
        if n < 2 {
            self.msg = Some((format!("{} has no sub-tabs", TABS[self.tab].name), false));
            return;
        }
        let cur = self.sub[self.tab];
        let next = if back { (cur + n - 1) % n } else { (cur + 1) % n };
        self.goto(self.tab, next);
    }

    fn free_key(&mut self, k: KeyCode) {
        let run = |me: &mut Self, i: usize| {
            match FREE[i].0 {
                // pid 0: these are addressed to the machine, not a process.
                // The daemon answers them before its per-pid guards.
                "REAP" => me.request_kill(0, "REAP"),
                "RECLAIM" => me.request_kill(0, "RECLAIM"),
                _ => {
                    me.orphans = !me.orphans;
                    me.msg = Some((
                        if me.orphans {
                            "showing orphans only — reparented to init, under no unit. k to act.".into()
                        } else {
                            "showing every process again".to_string()
                        },
                        false,
                    ));
                }
            }
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Down => self.free_sel = (self.free_sel + 1) % FREE.len(),
            KeyCode::Up => self.free_sel = (self.free_sel + FREE.len() - 1) % FREE.len(),
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= FREE.len() {
                    run(self, i - 1);
                }
            }
            KeyCode::Enter => {
                let i = self.free_sel;
                run(self, i);
            }
            _ => self.overlay = Overlay::None,
        }
    }

    /// Every binding, in one place. Generated from the same ACTIONS/BOX_NAMES
    /// the handlers use, so a key that changes cannot leave the help behind.
    fn render_help(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        // DERIVED, not a magic number. This column has been widened by hand
        // twice — 12 → 14 for "ctrl-c ctrl-d", then again for "esc backspace"
        // — and each time the new number EQUALLED the longest label rather
        // than exceeding it, which is precisely what leaves no gap at all.
        // Measured from the tables, it cannot be wrong again.
        let kw = OTHER_KEYS
            .iter()
            .map(|(_, k, _)| k.chars().count())
            .chain(CMD_HELP.iter().map(|(k, _)| k.chars().count()))
            .chain(std::iter::once("m → options".chars().count()))
            .max()
            .unwrap_or(12)
            + 2;
        let key = |k: &str, d: &str| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<kw$}"), Style::default().fg(Color::Rgb(120, 220, 140))),
                Span::styled(d.to_string(), Style::default().fg(Color::Gray)),
            ])
        };
        let head = |t: &str| -> Line<'static> {
            Line::from(Span::styled(
                t.to_string(),
                Style::default().fg(accent).add_modifier(Modifier::BOLD),
            ))
        };
        let mut l: Vec<Line> = vec![];

        // Rendered FROM the tables the handler dispatches from, never written
        // out a second time beside them. Two lists of keybindings is how a key
        // ends up documented and unhandled — or, as "about a" was, listed in
        // two places and eaten by the frame before either could act on it.
        let section = |l: &mut Vec<Line>, name: &str| {
            l.push(head(name));
            for (sec, k, d) in OTHER_KEYS.iter().filter(|(s, _, _)| *s == name) {
                let _ = sec;
                l.push(key(k, d));
            }
        };

        section(&mut l, "moving");

        l.push(head("tabs"));
        for t in TABS {
            l.push(key(&t.key.to_string(), &format!("{} — {}", t.name, t.desc)));
            // Modes on one line under their tab. Nine sub-tabs each claiming a
            // row would push the rest of this page off the bottom, and the
            // numbers are what `:f2` needs anyway.
            if t.subs.len() > 1 {
                let names: Vec<String> = t
                    .subs
                    .iter()
                    .enumerate()
                    .map(|(i, sb)| match sb.key {
                        Some(c) => format!("{} {} ({c})", i + 1, sb.name),
                        None => format!("{} {}", i + 1, sb.name),
                    })
                    .collect();
                l.push(key("", &format!("   {}", names.join(" · "))));
            }
        }

        l.push(head("sorting"));
        // One line per group of four so nine sort keys do not take nine rows.
        for chunk in SORT_KEYS.chunks(4) {
            let ks: Vec<String> = chunk.iter().map(|(k, _, _)| k.to_string()).collect();
            let ds: Vec<&str> = chunk.iter().map(|(_, _, d)| *d).collect();
            l.push(key(&ks.join(" "), &format!("sort by {}", ds.join(" · "))));
        }
        for (sec, k, d) in OTHER_KEYS.iter().filter(|(s, _, _)| *s == "sorting") {
            let _ = sec;
            l.push(key(k, d));
        }

        section(&mut l, "acting");
        section(&mut l, "modal");

        l.push(head("layout"));
        l.push(key(
            "m → options",
            &format!(
                "show/hide boxes — {}",
                BOX_NAMES
                    .iter()
                    .enumerate()
                    .map(|(i, b)| format!("{b}{}", if self.show[i] { "" } else { " (hidden)" }))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        ));

        // The command line gets its own block: it is the one thing here you
        // TYPE rather than press, so a list of keys cannot describe it.
        l.push(head("command line  :"));
        for (k, d) in CMD_HELP {
            l.push(key(k, d));
        }

        section(&mut l, "leaving");
        l.push(head("the frame owns these"));
        for (sec, k, d) in OTHER_KEYS.iter().filter(|(s, _, _)| *s == "frame") {
            let _ = sec;
            l.push(key(k, d));
        }
        l.push(Line::from(Span::styled("  any key returns", Style::default().fg(DIM))));
        let h = l.len() as u16 + 2;
        // 96, not 78: the fleet has four sub-tabs whose names are long enough
        // that the line describing them was being cut off mid-word — a help
        // page that truncates the thing it is explaining.
        let inner = Self::modal(f, area, 96, h, "keys", accent);
        f.render_widget(Paragraph::new(l), inner);
    }

    /// Full disclosure for one process.
    ///
    /// This reads /proc directly rather than the snapshot, which is the one
    /// place in this dashboard that samples anything. That is deliberate and
    /// bounded: it is a single pid, only while its window is open, and the
    /// fields here (cwd, exe, fd count, per-thread state, VmSwap) are ones the
    /// daemon has no reason to publish for all ~500 processes every 2s.
    ///
    /// /proc/PID/environ is NOT read. It routinely holds tokens and passwords,
    /// and "full disclosure" of a process does not extend to putting its
    /// secrets on a screen someone may be sharing.
    fn render_detail(&self, f: &mut Frame, area: Rect) {
        // The pinned pid, looked up in the current table so the live figures
        // stay live. If it has left the table, /proc may still have it, so the
        // modal keeps describing it rather than jumping to whoever took its
        // place in the ranking.
        let Some(pid) = self.detail_pid else { return };
        let rows = self.rows();
        let row = rows.iter().find(|p| num(p, "pid") as i32 == pid);
        let name = row
            .map(|p| text(p, "name"))
            .unwrap_or_else(|| proc_comm(pid).unwrap_or_else(|| "(gone)".into()));
        let prot = row
            .map(|p| p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false))
            .unwrap_or(false);
        let why = row.map(|p| text(p, "protected_reason")).unwrap_or_default();
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(
            f,
            area,
            area.width.saturating_sub(8).min(112),
            area.height.saturating_sub(4),
            &format!("{name} · pid {pid}"),
            accent,
        );

        let rd = |f: &str| fs::read_to_string(format!("/proc/{pid}/{f}")).unwrap_or_default();
        let link = |f: &str| {
            fs::read_link(format!("/proc/{pid}/{f}"))
                .map(|p| p.display().to_string())
                .unwrap_or_else(|e| format!("({e})"))
        };
        let status = rd("status");
        let st = |k: &str| -> String {
            status
                .lines()
                .find(|l| l.starts_with(&format!("{k}:")))
                .map(|l| l[k.len() + 1..].trim().to_string())
                .unwrap_or_default()
        };
        let head = |t: &str| -> Line<'static> {
            Line::from(Span::styled(t.to_string(), Style::default().fg(accent).add_modifier(Modifier::BOLD)))
        };
        let kv = |k: &str, v: String| -> Line<'static> {
            Line::from(vec![
                // 21, not 16: "mem% 10s / 1m / 15m" is 19 wide and its value
                // started in the very next cell with no gap at all.
                Span::styled(format!("  {k:<21}"), Style::default().fg(LABEL)),
                Span::styled(v, Style::default().fg(Color::Gray)),
            ])
        };
        // A deep cgroup path runs ~100 chars and used to vanish at the box
        // edge. This modal is the full-disclosure view, so a value that does
        // not fit wraps onto continuation lines rather than being cut.
        let kvw = |k: &str, v: String| -> Vec<Line<'static>> {
            let room = (inner.width as usize).saturating_sub(24).max(16);
            let ch: Vec<char> = v.chars().collect();
            if ch.is_empty() {
                return vec![kv(k, v)];
            }
            ch.chunks(room)
                .enumerate()
                .map(|(i, c)| kv(if i == 0 { k } else { "" }, c.iter().collect()))
                .collect()
        };

        // The row the table is showing, so the modal and the list agree.
        let p = row.map(|p| (*p).clone()).unwrap_or(Value::Null);

        let cmdline = fs::read(format!("/proc/{pid}/cmdline"))
            .map(|r| {
                r.split(|b| *b == 0)
                    .filter(|a| !a.is_empty())
                    .map(|a| String::from_utf8_lossy(a).into_owned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        let mut l = vec![head("identity")];
        l.push(kv("name", name.clone()));
        l.push(kv("pid / ppid", format!("{pid} / {}", st("PPid"))));
        l.push(kv("state", st("State")));
        // Uid/Gid are four tab-separated ids (real/effective/saved/fs). Tabs
        // wreck a TUI row, and the real uid is the one people mean.
        let id1 = |k: &str| st(k).split_whitespace().next().unwrap_or("").to_string();
        l.push(kv("user", format!("{}  uid {}  gid {}", text(&p, "user"), id1("Uid"), id1("Gid"))));
        l.push(kv("threads", st("Threads")));
        l.extend(kvw("exe", link("exe")));
        l.extend(kvw("cwd", link("cwd")));
        l.push(kv("fds", fs::read_dir(format!("/proc/{pid}/fd")).map(|d| d.count().to_string()).unwrap_or_else(|e| format!("({e})"))));
        // The command as you would type it. The argv breakdown below answers
        // "how was it split"; this answers "what is it", which is the question
        // people actually arrive with, so it comes first.
        l.extend(kvw("command", if cmdline.is_empty() {
            format!("[{name}]  (kernel thread — no cmdline)")
        } else {
            cmdline.join(" ")
        }));
        l.extend(kvw("comm", st("Name")));
        l.push(kv("argv", format!("{} args", cmdline.len())));
        for (i, a) in cmdline.iter().enumerate().take(12) {
            l.push(Line::from(vec![
                Span::styled(format!("    [{i}] "), Style::default().fg(DIM)),
                Span::styled(a.clone(), Style::default().fg(Color::Rgb(200, 205, 215))),
            ]));
        }
        if cmdline.len() > 12 {
            l.push(Line::from(Span::styled(
                format!("    … {} more", cmdline.len() - 12),
                Style::default().fg(DIM),
            )));
        }

        // ── tree ───────────────────────────────────────────────────────
        // Read straight from /proc, not from proc_table: the table is the
        // top-N by CPU, so a process's real parent is usually not in it and a
        // tree built from the table alone would quietly lie about ancestry.
        let pname = |q: i64| -> String {
            fs::read_to_string(format!("/proc/{q}/status"))
                .ok()
                .and_then(|s| s.lines().find(|l| l.starts_with("Name:")).map(|l| l[5..].trim().to_string()))
                .unwrap_or_else(|| "?".into())
        };
        let pparent = |q: i64| -> Option<i64> {
            fs::read_to_string(format!("/proc/{q}/status"))
                .ok()
                .and_then(|s| s.lines().find(|l| l.starts_with("PPid:")).and_then(|l| l[5..].trim().parse().ok()))
                .filter(|&x: &i64| x > 0)
        };
        l.push(head("tree"));
        // Walk up to init, then print top-down so the chain reads the way a
        // path does. Bounded at 12 because a pid cycle would otherwise hang
        // the panel, and no real ancestry is that deep.
        let mut chain: Vec<i64> = vec![];
        let mut cur = pparent(pid as i64);
        while let Some(q) = cur {
            if chain.contains(&q) || chain.len() >= 12 {
                break;
            }
            chain.push(q);
            cur = pparent(q);
        }
        chain.reverse();
        for (d, q) in chain.iter().enumerate() {
            l.push(Line::from(vec![
                Span::styled(format!("  {}{}", "  ".repeat(d), if d == 0 { "" } else { "└ " }), Style::default().fg(DIM)),
                Span::styled(format!("{} ", pname(*q)), Style::default().fg(Color::Gray)),
                Span::styled(format!("({q})"), Style::default().fg(DIM)),
            ]));
        }
        l.push(Line::from(vec![
            Span::styled(format!("  {}{}", "  ".repeat(chain.len()), if chain.is_empty() { "" } else { "└ " }), Style::default().fg(DIM)),
            Span::styled(format!("{name} "), Style::default().fg(accent).add_modifier(Modifier::BOLD)),
            Span::styled(format!("({pid})  ← this process"), Style::default().fg(DIM)),
        ]));
        // task/<pid>/children is the kernel's own answer, so this costs two
        // reads rather than a scan of every entry in /proc.
        let kids: Vec<i64> = fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
            .unwrap_or_default()
            .split_whitespace()
            .filter_map(|x| x.parse().ok())
            .collect();
        if kids.is_empty() {
            l.push(Line::from(Span::styled("      (no children)", Style::default().fg(DIM))));
        }
        for q in kids.iter().take(24) {
            let zst = fs::read_to_string(format!("/proc/{q}/status"))
                .ok()
                .and_then(|s| s.lines().find(|l| l.starts_with("State:")).map(|l| l[6..].trim().to_string()))
                .unwrap_or_default();
            let zombie = zst.starts_with('Z');
            l.push(Line::from(vec![
                Span::styled(format!("  {}└ ", "  ".repeat(chain.len() + 1)), Style::default().fg(DIM)),
                Span::styled(
                    format!("{} ", pname(*q)),
                    Style::default().fg(if zombie { Color::Rgb(240, 72, 72) } else { Color::Gray }),
                ),
                Span::styled(
                    format!("({q}){}", if zombie { "  ZOMBIE" } else { "" }),
                    Style::default().fg(if zombie { Color::Rgb(240, 72, 72) } else { DIM }),
                ),
            ]));
        }
        if kids.len() > 24 {
            l.push(Line::from(Span::styled(
                format!("      … {} more children", kids.len() - 24),
                Style::default().fg(DIM),
            )));
        }
        l.push(kv("children / threads", format!("{} / {}", kids.len(), st("Threads"))));

        l.push(head("cpu"));
        l.push(kv(
            "now / 10s / 1m",
            format!(
                "{:.1}%  {:.1}%  {:.1}%",
                num(&p, "cpu_pct"),
                avg_or(&p, "10s", "cpu_pct"),
                avg_or(&p, "1m", "cpu_pct")
            ),
        ));
        l.push(kv(
            "5m / 15m",
            format!("{:.1}%  {:.1}%", avg_or(&p, "5m", "cpu_pct"), avg_or(&p, "15m", "cpu_pct")),
        ));
        // nice/priority/times live in /proc/PID/stat, not status. comm sits in
        // parentheses there and can itself contain ')', so split after the LAST
        // one — the field-index bug every naive stat parser has.
        let stat = rd("stat");
        let sf: Vec<&str> = stat.rsplit_once(')').map(|(_, r)| r.split_whitespace().collect()).unwrap_or_default();
        // Offsets are proc(5) field numbers minus 3, since sf[0] is field 3.
        let sfi = |i: usize| -> f64 { sf.get(i).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0) };
        let hz = 100.0; // USER_HZ is 100 on every Linux target this ships to
        l.push(kv("nice / priority", format!("{} / {}", sfi(16), sfi(15))));
        l.push(kv(
            "cpu time u/s",
            format!("{:.1}s / {:.1}s", sfi(11) / hz, sfi(12) / hz),
        ));
        l.push(kv("faults min/maj", format!("{:.0} / {:.0}", sfi(7), sfi(9))));
        l.push(kv(
            "elapsed",
            fmt_uptime(
                (fs::read_to_string("/proc/uptime")
                    .ok()
                    .and_then(|u| u.split_whitespace().next().and_then(|x| x.parse::<f64>().ok()))
                    .unwrap_or(0.0)
                    - sfi(19) / hz)
                    .max(0.0),
            ),
        ));
        // Time spent runnable but not running: the number that says "this box
        // is oversubscribed" as opposed to "this process is busy".
        l.push(kv("run-queue wait", format!("{:.2}%", num(&p, "runq_wait_pct"))));
        // The memory-stall number, beside the cpu-stall one. A page fetched
        // back from disk is what memory pressure is actually made of, so this
        // is the line that says whether THIS process is the one thrashing.
        l.push(kv(
            "major faults",
            format!("{:.1}/s  (pages read back from disk)", num(&p, "majflt_per_s")),
        ));

        l.push(head("memory"));
        l.push(kv(
            "rss now / 10s / 1m",
            format!(
                "{}  {}  {}",
                fmt_bytes_short(num(&p, "mem_rss_bytes")),
                fmt_bytes_short(avg_or(&p, "10s", "mem_rss_bytes")),
                fmt_bytes_short(avg_or(&p, "1m", "mem_rss_bytes"))
            ),
        ));
        // smaps_rollup, read here rather than taken from the snapshot: this is
        // one process, the modal is already reading /proc for this pid, and it
        // carries USS which the table has no column for. The three figures
        // answer three different questions and only together are they honest:
        //   RSS  every resident page, shared ones counted in full — the number
        //        that sums to far more than the RAM installed
        //   PSS  private pages plus this process's SHARE of each shared one —
        //        the number that sums to the truth across the whole box
        //   USS  private pages only — what you would actually get back by
        //        killing it, which is usually the question being asked
        let roll = rd("smaps_rollup");
        let rk = |k: &str| -> Option<f64> {
            roll.lines()
                .find(|l| l.starts_with(&format!("{k}:")))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<f64>().ok())
                .map(|kb| kb * 1024.0)
        };
        let uss = match (rk("Private_Clean"), rk("Private_Dirty")) {
            (Some(c), Some(d)) => Some(c + d),
            (a, b) => a.or(b),
        };
        let one = |v: Option<f64>| v.map(fmt_bytes_short).unwrap_or_else(|| "—".into());
        l.push(kv(
            "rss / pss / uss",
            format!("{}  {}  {}", one(rk("Rss")), one(rk("Pss")), one(uss)),
        ));
        l.push(kv(
            "  what each means",
            "rss all resident · pss share-adjusted · uss private only".into(),
        ));
        if roll.is_empty() {
            l.push(kv("  smaps_rollup", "not readable for this uid".into()));
        }
        l.push(kv(
            "mem% 10s / 1m / 15m",
            format!(
                "{:.2}%  {:.2}%  {:.2}%",
                avg_or(&p, "10s", "mem_pct"),
                avg_or(&p, "1m", "mem_pct"),
                avg_or(&p, "15m", "mem_pct")
            ),
        ));
        // status reports these as "7268852 kB"; every other size in this modal
        // is human-formatted, so parse the number off and match.
        let stb = |k: &str| -> String {
            match st(k).split_whitespace().next().and_then(|n| n.parse::<f64>().ok()) {
                Some(kb) => fmt_bytes_short(kb * 1024.0),
                None => st(k),
            }
        };
        l.push(kv("vm size / peak", format!("{} / {}", stb("VmSize"), stb("VmPeak"))));
        l.push(kv("rss anon / file", format!("{} / {}", stb("RssAnon"), stb("RssFile"))));
        l.push(kv("rss shmem", stb("RssShmem")));
        l.push(kv("swapped out", stb("VmSwap")));

        l.push(head("io"));
        l.push(kv(
            "read / write",
            format!("{}  {}", fmt_bps(num(&p, "read_bytes_per_s")), fmt_bps(num(&p, "write_bytes_per_s"))),
        ));
        l.push(kv(
            "down / up",
            format!(
                "{}  {}",
                fmt_bps(num(&p, "net_rx_bytes_per_s")),
                fmt_bps(num(&p, "net_tx_bytes_per_s"))
            ),
        ));
        // Everything this process has moved, not the rate it is moving at.
        // Disk comes straight from /proc/PID/io, which is cumulative for the
        // life of the process. Network is integrated by the daemon: the
        // kernel keeps no per-process network counter, so a total can only be
        // built by summing what it sees, which means traffic on a socket
        // opened and closed between two samples is missed. It undercounts and
        // never overcounts — the right way round for a number read as a total.
        l.push(kv(
            "downloaded (total)",
            fmt_bytes_short(num(&p, "net_rx_bytes_total")),
        ));
        l.push(kv("uploaded (total)", fmt_bytes_short(num(&p, "net_tx_bytes_total"))));
        l.push(kv("read (total)", fmt_bytes_short(num(&p, "read_bytes_total"))));
        l.push(kv("written (total)", fmt_bytes_short(num(&p, "write_bytes_total"))));
        l.push(Line::from(Span::styled(
            "  disk totals are the process's own since it started; network is the daemon's running sum",
            Style::default().fg(DIM),
        )));
        for k in ["read_bytes", "write_bytes", "syscr", "syscw"] {
            let v = rd("io")
                .lines()
                .find(|l| l.starts_with(&format!("{k}:")))
                .and_then(|l| l.split_whitespace().nth(1).map(|x| x.to_string()))
                .unwrap_or_else(|| "—".into());
            let pretty = v.parse::<f64>().map(fmt_bytes_short).unwrap_or(v);
            l.push(kv(k, pretty));
        }

        l.push(head("containment"));
        let cg = rd("cgroup");
        l.extend(kvw(
            "cgroup",
            cg.lines().next().and_then(|x| x.rsplit(':').next().map(|s| s.to_string())).unwrap_or_default(),
        ));
        l.push(Line::from(vec![
            Span::styled(format!("  {:<21}", "protected"), Style::default().fg(LABEL)),
            Span::styled(
                if prot { format!("yes — {}", if why.is_empty() { "protected slice".into() } else { why }) } else { "no".into() },
                Style::default().fg(if prot { Color::Rgb(240, 160, 90) } else { Color::Gray }),
            ),
        ]));
        l.push(head("actions"));
        l.push(Line::from(vec![
            Span::styled("  k    ", Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled(
                if prot { "blocked — this process is in a protected slice".to_string() }
                else { format!("act on {name}: RESTART, or any signal") },
                Style::default().fg(if prot { Color::Rgb(240, 160, 90) } else { Color::Gray }),
            ),
        ]));
        l.push(Line::from(vec![
            Span::styled("  o    ", Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled(
                format!("open the folder holding the binary — {}", exe_dir(pid).unwrap_or_else(|| "unknown".into())),
                Style::default().fg(Color::Gray),
            ),
        ]));
        l.push(Line::from(Span::styled(
            "  ↑↓ pgup pgdn scroll · any other key returns · environ is deliberately not shown",
            Style::default().fg(DIM),
        )));

        let max = (l.len() as u16).saturating_sub(inner.height);
        f.render_widget(
            Paragraph::new(l).scroll((self.detail_scroll.min(max), 0)),
            inner,
        );
    }

    /// The `k` action menu. Arrows or a digit pick; anything else backs out.
    fn kill_key(&mut self, k: KeyCode) {
        let Some((pid, name)) = self.killing.clone() else {
            self.overlay = Overlay::None;
            return;
        };
        let fire = |me: &mut Self, i: usize| {
            me.request_kill(pid, ACTIONS[i].0);
            me.killing = None;
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= ACTIONS.len() {
                    fire(self, i - 1);
                }
            }
            KeyCode::Down => self.act_sel = (self.act_sel + 1) % ACTIONS.len(),
            KeyCode::Up => self.act_sel = (self.act_sel + ACTIONS.len() - 1) % ACTIONS.len(),
            KeyCode::Enter => {
                // Read the index out first: `fire(self, self.act_sel)` would
                // borrow self mutably and then read through it in the same
                // call, which the borrow checker refuses.
                let i = self.act_sel;
                fire(self, i);
            }
            _ => {
                self.msg = Some((format!("cancelled — {name} ({pid}) untouched"), false));
                self.killing = None;
                self.overlay = Overlay::None;
            }
        }
    }

    /// btop's menu: measure / options / help / quit. "options" is the box
    /// visibility screen it has always claimed to be; "help" is the one list
    /// of what the keys do, and nothing paraphrases it.
    fn menu_key(&mut self, k: KeyCode) {
        match k {
            KeyCode::Down => self.menu_sel = (self.menu_sel + 1) % MENU.len(),
            KeyCode::Up => self.menu_sel = (self.menu_sel + MENU.len() - 1) % MENU.len(),
            KeyCode::Enter | KeyCode::Char(' ') => {
                // ONE mapping from menu entry to action, shared with the `:`
                // line — see cmd::menu_cmd. The two used to be separate
                // matches over the same four indices.
                //
                // Quit stops claiming first: the frame owns quitting and only
                // quits on keys it actually sees.
                let c = cmd::menu_cmd(self.menu_sel);
                self.overlay = Overlay::None;
                self.apply_cmd(c);
            }
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= MENU.len() {
                    self.menu_sel = i - 1;
                    self.menu_key(KeyCode::Enter);
                }
            }
            _ => self.overlay = Overlay::None,
        }
    }

    /// The row the cursor is on, copied out of the snapshot.
    ///
    /// Copied, not borrowed: sort_procs() borrows self.snap for as long as its
    /// Vec lives, so anything that then wants to touch self.msg / self.overlay
    /// has to take owned values first. Every caller here needs to do exactly
    /// that, so the copy lives in one place instead of four.
    /// The single source of truth for row order. picked(), the key handler
    /// and the renderer all go through it, so the cursor cannot mean one row
    /// in one of them and a different row in another.
    /// Reparented to init and under no systemd unit: a process whose parent
    /// died and which nothing is supervising. That is a much narrower claim
    /// than "lost" — a daemon legitimately parented to pid 1 sits inside its
    /// own .service cgroup and is excluded — and it is the set actually worth
    /// looking at when memory has gone somewhere nobody owns.
    fn is_orphan(p: &Value) -> bool {
        num(p, "ppid") as i64 == 1
    }

    /// Nothing is looking after this one: it is either already dead and
    /// uncollected, or its parent died and init inherited it.
    fn is_lost(p: &Value) -> bool {
        text(p, "state").starts_with('Z') || Self::is_orphan(p)
    }

    fn rows(&self) -> Vec<&Value> {
        let procs = sort_procs(&self.snap, self.sort, self.desc, self.win);
        let procs: Vec<&Value> = if self.orphans || self.zombies {
            procs.into_iter().filter(|p| Self::is_lost(p)).collect()
        } else {
            procs
        };
        if self.tree {
            tree_order(&procs, arr(&self.snap, "proc_spine")).into_iter().map(|(p, _)| p).collect()
        } else {
            procs
        }
    }

    /// The declared service units worth listing under the live processes.
    ///
    /// Two kinds, and they answer different halves of "what is supposed to be
    /// running": units that are NOT active+running have no process at all, so
    /// a process table can never show them; units that are active+running but
    /// whose name does not appear in the table are up and doing nothing, which
    /// in a CPU-ranked table is indistinguishable from absent.
    ///
    /// The second test is a NAME heuristic — unit "foo.service" against
    /// process "foo" — because the snapshot carries no unit-to-pid mapping.
    /// It can mislabel a busy process as idle when the unit and the binary are
    /// named differently; it never invents a unit that does not exist.
    fn unit_rows(&self, s: &Value) -> Vec<UnitRow> {
        if !self.units {
            return vec![];
        }
        let live: std::collections::HashSet<String> =
            arr(s, "proc_table").iter().map(|p| text(p, "name")).collect();
        let mut rows: Vec<(String, String, String)> = arr(s, "services")
            .iter()
            .filter_map(|u| {
                let name = text(u, "name");
                let active = text(u, "active");
                let sub = text(u, "sub");
                let running = active == "active" && sub == "running";
                let stem = name.trim_end_matches(".service").to_string();
                if running && live.contains(&stem) {
                    return None;
                }
                let state = if running { "idle".to_string() } else { format!("{active}/{sub}") };
                Some((name, text(u, "scope"), state))
            })
            .collect::<Vec<_>>();

        // Worst first. In systemctl's own order these come out grouped by
        // manager and then alphabetically, which buries the one row anybody
        // opened this list for ("plasmashell is dead, where is it?") a
        // hundred lines down among units that are dead because they are
        // oneshots that already ran.
        let rank = |state: &str| -> u8 {
            if state.starts_with("failed") {
                0
            } else if state.starts_with("inactive") {
                1
            } else if state.starts_with("not-loaded") {
                2
            } else if state.starts_with("active/exited") {
                3
            } else {
                4
            }
        };
        rows.sort_by(|a, b| rank(&a.2).cmp(&rank(&b.2)).then_with(|| a.0.cmp(&b.0)));

        // A heading before each group. Sorted-but-unbroken, the eye cannot
        // tell where "failed" stops and "merely exited" starts, and those two
        // mean completely different things.
        let head_for = |state: &str| -> &'static str {
            match rank(state) {
                0 => "FAILED — died and did not come back",
                1 => "INACTIVE — declared, not running",
                2 => "NOT LOADED — declared, never started this boot",
                3 => "EXITED — oneshots that already ran",
                _ => "IDLE — running, doing nothing",
            }
        };
        let mut out: Vec<UnitRow> = Vec::new();
        let mut last = usize::MAX;
        for (name, scope, state) in rows {
            let r = rank(&state) as usize;
            if r != last {
                last = r;
                out.push(UnitRow { heading: Some(head_for(&state)), name: String::new(), scope: String::new(), state: String::new() });
            }
            out.push(UnitRow { heading: None, name, scope, state });
        }
        out
    }

    /// None when the cursor is parked on an appended unit row: those have no
    /// pid, so every action keyed off a pid correctly does nothing.
    /// The declared unit under the cursor, if the cursor is past the live
    /// processes and not on a group heading.
    fn picked_unit(&self) -> Option<(String, String)> {
        let snap = self.snap.clone();
        let n = self.rows().len();
        let units = self.unit_rows(&snap);
        let u = units.get(self.sel.checked_sub(n)?)?;
        if u.heading.is_some() {
            return None;
        }
        Some((u.name.clone(), u.scope.clone()))
    }

    /// The process the detail modal is pinned to, in the same shape picked()
    /// returns — so acting from inside the modal acts on what is on screen,
    /// not on whatever the cursor has drifted onto behind it.
    fn pinned(&self) -> Option<(i32, String, bool, String)> {
        let pid = self.detail_pid?;
        let rows = self.rows();
        let p = rows.iter().find(|p| num(p, "pid") as i32 == pid)?;
        Some((
            pid,
            text(p, "name"),
            p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false),
            text(p, "protected_reason"),
        ))
    }

    fn picked(&self) -> Option<(i32, String, bool, String)> {
        let procs = self.rows();
        procs.get(self.sel).map(|p| {
            (
                num(p, "pid") as i32,
                text(p, "name"),
                p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false),
                text(p, "protected_reason"),
            )
        })
    }
}

impl Dashboard for Monitor {
    fn title(&self) -> String {
        "📊 monitor".into()
    }
    fn tick_ms(&self) -> u64 {
        1000
    }

    fn update(&mut self) {
        // A remote target swaps the SOURCE of the snapshot and nothing else:
        // every box below reads the same shape either way, which is the whole
        // benefit of the daemon publishing a file rather than the panel
        // sampling. The ssh fetch itself happens on the mesh thread.
        let (s, err) = match self.mesh.target() {
            None => (read_json(&snapshot_path()), String::new()),
            Some(_) => self.mesh.remote_snapshot(),
        };
        if !err.is_empty() {
            self.msg = Some((err, true));
        }
        if s.is_null() {
            self.stale = true;
            return;
        }
        let ts = num(&s, "ts");
        self.age = (now_secs() - ts).max(0.0);
        // The daemon publishes every 2s. Older than a few periods means it
        // died, and showing its last numbers forever is how a dead publisher
        // hides — the graphs must visibly stop, not quietly freeze.
        self.stale = self.age > 15.0;
        // Only extend history when the publisher actually moved, otherwise a
        // 1s poll against a 2s publisher draws every sample twice and the
        // graph's time axis silently runs at half speed.
        if ts > self.last_ts {
            self.last_ts = ts;
            push(&mut self.cpu_hist, num(&s, "cpu"));
            let cores = arr(&s, "cores");
            self.core_hist.resize(cores.len(), vec![]);
            for (i, c) in cores.iter().enumerate() {
                push(&mut self.core_hist[i], c.as_f64().unwrap_or(0.0));
            }
            push(&mut self.mem_hist, num(&s, "mem"));
            push(&mut self.rx_hist, num(&s, "net_rx"));
            push(&mut self.tx_hist, num(&s, "net_tx"));
            let worst = num(&s, "psi.cpu.some10")
                .max(num(&s, "psi.io.full10"))
                .max(num(&s, "psi.memory.full10"));
            push(&mut self.psi_hist, worst);
        }
        self.snap = s;
        // Published by the SYSTEM watchdog, a different publisher on a
        // different cadence. Absent until that unit is running, so every read
        // below has to tolerate Null.
        self.guard = read_json("/run/freeze-guard.json");
    }

    /// Everything except ^c/^d, which frame.rs takes unconditionally. Esc is
    /// bound here precisely so it does NOT reach the frame's quit.
    fn wants_quit(&self) -> bool {
        self.quit
    }

    fn claims(&self, k: KeyCode) -> bool {
        // A modal owns the whole keyboard: while one is up, q must close it
        // rather than close the program, and a stray 'c' must not re-sort the
        // list under the pid you are aiming at.
        self.overlay != Overlay::None || k == KeyCode::Esc
    }

    fn on_key(&mut self, k: KeyCode) {
        let snap = self.snap.clone();
        // rows(), not proc_table: in tree mode the list also carries the
        // spine, so counting the published rows capped the cursor above the
        // real end of the list and scrolling simply stopped.
        // The cursor is bounded by the list you can SEE. The fleet is a
        // handful of peers where the process table is hundreds of rows, so
        // one shared count let the cursor run off the end of the short one.
        let n = if self.fleet {
            if self.sub_name() == "storage" {
                self.storage_rows().len()
            } else {
                self.visible_peers().len()
            }
        } else {
            self.rows().len() + self.unit_rows(&snap).len()
        };
        match self.overlay {
            Overlay::Kill => return self.kill_key(k),
            Overlay::Free => return self.free_key(k),
            Overlay::Ctr => return self.ctr_img_key(k, true),
            Overlay::Img => return self.ctr_img_key(k, false),
            Overlay::Unit => return self.unit_key(k),
            Overlay::Machine => {
                match k {
                    KeyCode::Down | KeyCode::Char('j') => self.detail_scroll = self.detail_scroll.saturating_add(1),
                    KeyCode::Up => self.detail_scroll = self.detail_scroll.saturating_sub(1),
                    KeyCode::Home => self.detail_scroll = 0,
                    _ => {
                        self.machine = None;
                        self.overlay = Overlay::None;
                    }
                }
                return;
            }
            Overlay::Menu => return self.menu_key(k),
            Overlay::Cmd => return self.cmd_key(k),
            Overlay::Boxes => return self.boxes_key(k),
            Overlay::Help => {
                // Any key dismisses a page of text; making people find the one
                // right key to leave a help screen is its own small insult.
                self.overlay = Overlay::None;
                return;
            }
            Overlay::Target => {
                let n = Self::selectable_peers(&self.mesh).len() + 1;
                match k {
                    KeyCode::Down => self.target_sel = (self.target_sel + 1) % n,
                    KeyCode::Up => self.target_sel = (self.target_sel + n - 1) % n,
                    KeyCode::Enter | KeyCode::Char(' ') => {
                        let peers = Self::selectable_peers(&self.mesh);
                        let pick = if self.target_sel == 0 {
                            None
                        } else {
                            peers.get(self.target_sel - 1).map(|p| p.alias.clone())
                        };
                        self.mesh.set_target(pick.clone());
                        // History is per-machine. Carrying the old graphs into
                        // a new target would draw one box's past as another's.
                        self.cpu_hist.clear();
                        self.core_hist.clear();
                        self.mem_hist.clear();
                        self.rx_hist.clear();
                        self.tx_hist.clear();
                        self.psi_hist.clear();
                        self.last_ts = -1.0;
                        self.msg = Some((
                            match &pick {
                                Some(a) => format!("measuring {a} over ssh"),
                                None => "measuring this machine".into(),
                            },
                            false,
                        ));
                        self.overlay = Overlay::None;
                    }
                    _ => self.overlay = Overlay::None,
                }
                return;
            }
            Overlay::Detail => {
                // `k` acts here rather than scrolling. Arriving at the full
                // disclosure and then having to back out to signal the thing
                // you are looking at is the wrong shape, so the actions live
                // where the evidence is. Scrolling keeps the arrows and j.
                match k {
                    KeyCode::Down | KeyCode::Char('j') => self.detail_scroll = self.detail_scroll.saturating_add(1),
                    KeyCode::Up => self.detail_scroll = self.detail_scroll.saturating_sub(1),
                    KeyCode::PageDown => self.detail_scroll = self.detail_scroll.saturating_add(10),
                    KeyCode::PageUp => self.detail_scroll = self.detail_scroll.saturating_sub(10),
                    KeyCode::Home => self.detail_scroll = 0,
                    KeyCode::Char('k') => {
                        if let Some((pid, name, prot, why)) = self.pinned() {
                            if prot {
                                let why = if why.is_empty() { "protected slice".to_string() } else { why };
                                self.msg = Some((format!("{name} ({pid}) is protected — {why}"), true));
                                self.overlay = Overlay::None;
                            } else {
                                self.msg = None;
                                self.killing = Some((pid, name));
                                self.act_sel = 0;
                                self.overlay = Overlay::Kill;
                            }
                        }
                    }
                    KeyCode::Char('o') => {
                        if let Some(pid) = self.detail_pid {
                            self.msg = Some(match exe_dir(pid) {
                                Some(d) => match open_dir(&d) {
                                    Ok(()) => (format!("opened {d}"), false),
                                    Err(e) => (format!("xdg-open {d}: {e}"), true),
                                },
                                None => (format!("pid {pid} has no readable exe link"), true),
                            });
                            self.overlay = Overlay::None;
                        }
                    }
                    _ => self.overlay = Overlay::None,
                }
                return;
            }
            Overlay::None => {}
        }
        // GLOBAL KEYS, ahead of every per-view branch.
        //
        // These were handled inside each view's own match, five copies of the
        // same three lines, and a view that forgot one simply had no escape
        // key. One place, every view.
        match k {
            // esc opens HELP now, not the menu. The menu moved to `m`: the
            // first thing anyone presses on an unfamiliar TUI is escape, and
            // what they want then is "what are the keys", not a chooser whose
            // first entry is "measure".
            KeyCode::Esc => {
                self.overlay = Overlay::Help;
                return;
            }
            KeyCode::Char('m') => {
                self.overlay = Overlay::Menu;
                self.menu_sel = 0;
                return;
            }
            // vim's colon. Reachable from anywhere, not only from the help
            // page — a command line you have to open a help screen to find is
            // a command line nobody uses.
            KeyCode::Char(':') => {
                self.cmd.clear();
                self.overlay = Overlay::Cmd;
                return;
            }
            // 1-9 jump straight to a sub-tab — the number the strip already
            // draws under the tab. This is the navigation people will use
            // every minute, which is why it gets the digits; box visibility is
            // set once and moved to the options screen.
            KeyCode::Char(c) if c.is_ascii_digit() && c != '0' => {
                let i = c as usize - '1' as usize;
                let n = TABS[self.tab].subs.len();
                if i < n {
                    self.goto(self.tab, i);
                } else {
                    self.msg = Some((
                        format!("{} has {n} sub-tab(s)", TABS[self.tab].name),
                        true,
                    ));
                }
                return;
            }
            KeyCode::Tab => {
                self.cycle_sub(false);
                return;
            }
            KeyCode::BackTab => {
                self.cycle_sub(true);
                return;
            }
            _ => {}
        }
        if self.view_key(k) {
            return;
        }
        if self.files {
            match k {
                KeyCode::Down | KeyCode::Char('j') => {
                    self.files_scroll = self.files_scroll.saturating_add(1)
                }
                KeyCode::Up => self.files_scroll = self.files_scroll.saturating_sub(1),
                KeyCode::PageDown => self.files_scroll = self.files_scroll.saturating_add(20),
                KeyCode::PageUp => self.files_scroll = self.files_scroll.saturating_sub(20),
                KeyCode::Home => self.files_scroll = 0,
                KeyCode::Char('.') => {
                    self.files_hidden = !self.files_hidden;
                    self.files_cache.fetch(self.files_key(), self.mesh.target(), self.files_hidden);
                    self.files_scroll = 0;
                    self.msg = Some((
                        format!("dotfiles {}", if self.files_hidden { "shown" } else { "hidden" }),
                        false,
                    ));
                }
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                _ => {}
            }
            return;
        }
        // firewall joins these: no row cursor, one scrolling page.
        if self.history || self.about || self.firewall {
            // None of these has a row cursor; about scrolls, the rest are one
            // screen.
            match k {
                KeyCode::Down | KeyCode::Char('j') => {
                    self.detail_scroll = self.detail_scroll.saturating_add(1)
                }
                KeyCode::Up => self.detail_scroll = self.detail_scroll.saturating_sub(1),
                KeyCode::PageDown => self.detail_scroll = self.detail_scroll.saturating_add(10),
                KeyCode::PageUp => self.detail_scroll = self.detail_scroll.saturating_sub(10),
                KeyCode::Home => self.detail_scroll = 0,
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                _ => {}
            }
            return;
        }
        if self.docker || self.images {
            // Two lists, one cursor. Without arrow keys a tab showing 52
            // containers can only ever display the first screenful, which is
            // what oci-apps looks like.
            let n = if self.docker {
                arr(&self.snap, "containers").len()
            } else {
                arr(&self.snap, "images").len()
            };
            match k {
                KeyCode::Down | KeyCode::Char('j') => self.sel = (self.sel + 1).min(n.saturating_sub(1)),
                KeyCode::Up => self.sel = self.sel.saturating_sub(1),
                KeyCode::PageDown => self.sel = (self.sel + 10).min(n.saturating_sub(1)),
                KeyCode::PageUp => self.sel = self.sel.saturating_sub(10),
                KeyCode::Home => self.sel = 0,
                KeyCode::End => self.sel = n.saturating_sub(1),
                // Same gesture as the process header: ←/→ walks the column
                // this list is ranked by.
                KeyCode::Left => {
                    if self.docker {
                        self.ctr_sort = (self.ctr_sort + CTR_SORT.len() - 1) % CTR_SORT.len();
                    } else {
                        self.img_sort = (self.img_sort + IMG_SORT.len() - 1) % IMG_SORT.len();
                    }
                }
                KeyCode::Right => {
                    if self.docker {
                        self.ctr_sort = (self.ctr_sort + 1) % CTR_SORT.len();
                    } else {
                        self.img_sort = (self.img_sort + 1) % IMG_SORT.len();
                    }
                }
                KeyCode::Char('i') => {
                    if self.docker {
                        self.ctr_desc = !self.ctr_desc;
                    } else {
                        self.img_desc = !self.img_desc;
                    }
                }
                KeyCode::Enter => {
                    if n > 0 {
                        // Pin by identity, not by row. Re-ranking on the next
                        // tick would otherwise slide a different container
                        // under the modal a second after it opened.
                        let snap = self.snap.clone();
                        if self.docker {
                            self.ctr_pin =
                                self.ctr_rows(&snap).get(self.sel).map(|c| text(c, "name"));
                            self.overlay = Overlay::Ctr;
                        } else {
                            self.img_pin = self.img_rows(&snap).get(self.sel).map(|i| {
                                format!("{}:{}", text(i, "repo"), text(i, "tag"))
                            });
                            self.overlay = Overlay::Img;
                        }
                        self.act_sel = 0;
                        self.detail_scroll = 0;
                    }
                }
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                _ => {}
            }
            return;
        }
        if self.fleet {
            // The fleet table is its own list; the process keys would move a
            // cursor through rows that are not on screen.
            // The list the TABLE is showing — filtered to this network and
            // ranked. Walking mesh.list() here opened the wrong machine the
            // moment either of those did anything.
            // The storage mode is a different list, so it is a different
            // count. One shared number would run the cursor off the end of
            // whichever of the two is shorter.
            let storage = self.sub_name() == "storage";
            let peers = if storage { vec![] } else { self.fleet_view(&snap) };
            let np = if storage { self.storage_rows().len() } else { peers.len() };
            match k {
                KeyCode::Down => self.sel = (self.sel + 1).min(np.saturating_sub(1)),
                KeyCode::Up => self.sel = self.sel.saturating_sub(1),
                KeyCode::Home => self.sel = 0,
                KeyCode::End => self.sel = np.saturating_sub(1),
                // Same gesture as the process header and the container list:
                // ←/→ walks the column this table is ranked by.
                KeyCode::Left => {
                    self.fleet_sort = (self.fleet_sort + FLEET_SORT.len() - 1) % FLEET_SORT.len();
                    self.msg = Some((format!("rank by {}", FLEET_SORT[self.fleet_sort].0), false));
                }
                KeyCode::Right => {
                    self.fleet_sort = (self.fleet_sort + 1) % FLEET_SORT.len();
                    self.msg = Some((format!("rank by {}", FLEET_SORT[self.fleet_sort].0), false));
                }
                KeyCode::Char('i') => self.fleet_desc = !self.fleet_desc,
                KeyCode::Enter => {
                    if let Some(p) = peers.get(self.sel) {
                        self.machine = Some(p.alias.clone());
                        self.detail_scroll = 0;
                        self.overlay = Overlay::Machine;
                    }
                }
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                _ => {}
            }
            return;
        }
        match k {
            KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
            KeyCode::Down => self.sel = (self.sel + 1).min(n.saturating_sub(1)),
            KeyCode::Up => self.sel = self.sel.saturating_sub(1),
            KeyCode::PageDown => self.sel = (self.sel + 10).min(n.saturating_sub(1)),
            KeyCode::PageUp => self.sel = self.sel.saturating_sub(10),
            KeyCode::Home => self.sel = 0,
            KeyCode::End => self.sel = n.saturating_sub(1),
            // glances' arrows: walk the sort column along the header. Landing
            // on the same column twice does not flip the direction — `i` does
            // that — so ←→← puts you back exactly where you started.
            KeyCode::Left => self.sort = self.sort.step(-1),
            KeyCode::Right => self.sort = self.sort.step(1),
            // From SORT_KEYS, not from nine hand-written arms: the help
            // renders from the same table, so the two cannot disagree.
            KeyCode::Char(c) if SORT_KEYS.iter().any(|(k, _, _)| *k == c) => {
                self.sort = SORT_KEYS.iter().find(|(k, _, _)| *k == c).map(|(_, s, _)| *s).unwrap();
            }
            KeyCode::Char('s') => self.sort = Sort::Slice,
            KeyCode::Char('i') => self.desc = !self.desc,
            KeyCode::Char('w') => self.win = self.win.next(),
            KeyCode::Char('x') => {
                self.free_sel = 0;
                self.overlay = Overlay::Free;
            }
            KeyCode::Char('v') => {
                self.units = !self.units;
                self.msg = Some((
                    format!(
                        "declared units {}",
                        if self.units { "shown — stopped and idle services" } else { "hidden" }
                    ),
                    false,
                ));
            }
            KeyCode::Enter => {
                if let Some((pid, _, _, _)) = self.picked() {
                    // Pin it. Without this the modal followed the cursor's ROW
                    // through every re-sort, so the process being described
                    // changed underneath the reader a second after they opened
                    // it.
                    self.detail_pid = Some(pid);
                    self.detail_scroll = 0;
                    self.overlay = Overlay::Detail;
                } else if let Some(u) = self.picked_unit() {
                    // The cursor is on a declared unit, which has no pid and
                    // so no process detail to show. What it does have is a
                    // systemd verb.
                    self.acting_unit = Some(u);
                    self.unit_sel = 0;
                    self.overlay = Overlay::Unit;
                }
            }
            KeyCode::Char('k') => {
                if let Some((pid, name, prot, why)) = self.picked() {
                    // The daemon refuses these anyway; saying so here means the
                    // answer arrives before the keystroke, not after a silent
                    // no-op the user has to go read a log to explain.
                    if prot {
                        let why = if why.is_empty() { "protected slice".to_string() } else { why };
                        self.msg = Some((format!("{name} ({pid}) is protected — {why}"), true));
                    } else {
                        self.msg = None;
                        self.killing = Some((pid, name));
                        self.act_sel = 0;
                        self.overlay = Overlay::Kill;
                    }
                }
            }
            _ => {}
        }
        // Re-anchor on whatever pid the cursor now sits on. Without this the
        // selection is a bare index, and the next tick's re-sort slides a
        // different process underneath it.
        let now_on = self.rows().get(self.sel).map(|p| num(p, "pid") as i64);
        self.sel_pid = now_on;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();

        // The lower band only costs rows when something is in it; folding both
        // its boxes away (2/4) gives every one of those rows to the process
        // table rather than leaving a labelled gap.
        // 16, counted rather than guessed: 1 header + 6 psi + 3 reclaim + 3
        // health + 1 guard = 14 lines, plus two rows of border. Every previous
        // value here was exactly full, so each new row silently clipped the
        // guard line off the bottom instead of appearing.
        //
        // It costs the process table six rows against the original ten. That
        // is the right trade: this box answers "why is this machine slow",
        // which is the question the panel exists for, and the process table
        // still gets everything left over.
        let low_h: u16 =
            if self.show[B_PSI] || self.show[B_SLICES] || self.show[B_MESH] { 16 } else { 0 };
        let rows = Layout::vertical([
            Constraint::Length(1),     // header
            Constraint::Length(11),    // cpu
            Constraint::Length(13),    // mem | storage | net
            Constraint::Length(low_h), // psi | slices
            Constraint::Min(6),        // procs
            Constraint::Length(1),     // status
        ])
        .split(area);

        // ── header ────────────────────────────────────────────────────────────
        let uptime = fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next().and_then(|x| x.parse::<f64>().ok()))
            .unwrap_or(0.0);
        // Identity comes from the SNAPSHOT, not from this machine's /proc: the
        // panel can be pointed at a peer, and a header naming the desktop above
        // another box's numbers is worse than no header at all.
        let hi = |k: &str| text(&s, &format!("host_info.{k}"));
        let host = if hi("host").is_empty() { self.host.clone() } else { hi("host") };
        let kernel = if hi("kernel").is_empty() { self.kernel.clone() } else { hi("kernel") };
        let ifaces = arr(&s, "host_info.ifaces");
        let addr_of = |pred: &dyn Fn(&str) -> bool| -> String {
            ifaces
                .iter()
                .find(|i| pred(&text(i, "name")))
                .map(|i| text(i, "addr").split('/').next().unwrap_or("").to_string())
                .unwrap_or_default()
        };
        let lan = addr_of(&|n: &str| {
            !n.starts_with("wg") && !n.starts_with("docker") && !n.starts_with("br-")
        });
        let wg = addr_of(&|n: &str| n.starts_with("wg"));
        // user@host(ip) — how a machine gets written down. The mesh address is
        // the identifying one: it is what the fleet is addressed by and every
        // peer has exactly one.
        let who = hi("user");
        let ip = if wg.is_empty() { lan.clone() } else { wg };
        let ident = format!(
            "{}{host}{}",
            if who.is_empty() { String::new() } else { format!("{who}@") },
            if ip.is_empty() { String::new() } else { format!(" ({ip})") },
        );
        let mut head = vec![Span::styled(
            format!(" {ident} "),
            Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
        )];
        if let Some(alias) = self.mesh.target() {
            // Never let a remote reading be mistaken for the local one.
            head.push(Span::styled(
                format!("via ssh {alias} "),
                Style::default().fg(Color::Rgb(240, 169, 66)).add_modifier(Modifier::BOLD),
            ));
        }
        if !hi("os").is_empty() {
            head.push(Span::styled(format!("· {} ", hi("os")), Style::default().fg(Color::Gray)));
        }
        head.push(Span::styled(
            format!("· {kernel} · up {} ", fmt_uptime(uptime)),
            Style::default().fg(LABEL),
        ));
        if num(&s, "battery.present") != 0.0 || !text(&s, "battery.status").is_empty() {
            let b = num(&s, "battery.pct");
            let chg = s.get("battery").and_then(|x| x.get("charging")).and_then(|v| v.as_bool()).unwrap_or(false);
            head.push(Span::styled(
                format!("· bat {}{:.0}% ", if chg { "↑" } else { "" }, b),
                Style::default().fg(grad(1.0 - b / 100.0)),
            ));
        }
        head.push(Span::styled(
            if self.stale {
                format!("· ⚠ SNAPSHOT {:.0}s OLD — daemon not publishing ", self.age)
            } else {
                format!("· snapshot {:.0}s ago ", self.age)
            },
            Style::default().fg(if self.stale { Color::Rgb(240, 72, 72) } else { DIM }),
        ));
        f.render_widget(Paragraph::new(Line::from(head)), rows[0]);

        // ── cpu box ───────────────────────────────────────────────────────────
        // btop's cpu box is not just a graph: it names the chip, and shows
        // what it is clocked at and how hot it is right now. Those three are
        // what makes it read as a CPU box rather than a generic meter.
        let model = text(&s, "cpu_info.model");
        let mhz = num_opt(&s, "cpu_info.mhz");
        let temp = num_opt(&s, "cpu_info.temp_c");
        // btop names the chip on the TOP border, right beside the box name,
        // not tucked into the bottom-right where the key hints go. Trimmed of
        // the marketing: "11th Gen Intel(R) Core(TM) i5-1145G7 @ 2.60GHz" is
        // the same chip as "i5-1145G7" and the rest is border it has to fit in.
        let mut title = "cpu".to_string();
        let short = model
            .replace("(R)", "")
            .replace("(TM)", "")
            .split_whitespace()
            .filter(|w| !w.ends_with("Gen") && *w != "11th" && *w != "Intel" && *w != "Core")
            .collect::<Vec<_>>()
            .join(" ");
        if !short.is_empty() {
            title.push_str(&format!("  {}", trunc(short.trim(), 40)));
        }
        if let Some(m) = mhz {
            // AGAINST THE CEILING. A clock alone reads as fine — 0.60GHz means
            // nothing until you know the part will do 4.40, and then it means
            // the machine is running at a seventh of its speed. This one line
            // is the difference between "cpu looks quiet" and "something is
            // holding the clock down".
            let max = num(&s, "health.max_mhz");
            if max > 0.0 {
                title.push_str(&format!(
                    "  {:.2}/{:.2}GHz {:.0}%",
                    m / 1000.0,
                    max / 1000.0,
                    num(&s, "health.scal_pct")
                ));
            } else {
                title.push_str(&format!("  {:.2}GHz", m / 1000.0));
            }
        }
        if let Some(t) = temp {
            title.push_str(&format!("  {t:.0}°C"));
        }
        let core_temps = arr(&s, "cpu_info.core_temps");
        let cpu_b = bbox(&title, "");
        let cpu_in = cpu_b.inner(rows[1]);
        f.render_widget(cpu_b, rows[1]);
        let cores = arr(&s, "cores");
        // Two columns of core meters when there are enough cores to warrant it,
        // so the graph keeps the width that makes braille worth using.
        let core_cols = if cores.len() > 8 { 2 } else { 1 };
        let core_w = 24u16 * core_cols as u16;
        let cpu_split = Layout::horizontal([Constraint::Min(20), Constraint::Length(core_w)]).split(cpu_in);
        let cpu_left = Layout::vertical([Constraint::Min(3), Constraint::Length(1), Constraint::Length(2)]).split(cpu_split[0]);

        let gw = cpu_left[0].width as usize;
        let gh = cpu_left[0].height as usize;
        f.render_widget(Paragraph::new(braille_graph(&self.cpu_hist, 100.0, gw, gh)), cpu_left[0]);

        let cpu_pct = num(&s, "cpu");
        let mw = (cpu_left[1].width as usize).saturating_sub(14);
        let mut total = vec![Span::styled("CPU ", Style::default().fg(Color::Rgb(120, 200, 255)))];
        total.extend(meter(mw, cpu_pct / 100.0, &format!("{cpu_pct:5.1}%")).spans);
        f.render_widget(Paragraph::new(Line::from(total)), cpu_left[1]);

        let d = |k: &str| num(&s, &format!("cpu_detail.{k}"));
        let detail = Line::from(vec![
            Span::styled("usr ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>5.1}", d("user")), Style::default().fg(grad(d("user") / 100.0))),
            Span::styled("  sys ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>5.1}", d("system")), Style::default().fg(grad(d("system") / 100.0))),
            Span::styled("  io ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>5.1}", d("iowait")), Style::default().fg(grad(d("iowait") / 20.0))),
            Span::styled("  irq ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>4.1}", d("irq")), Style::default().fg(Color::Gray)),
            Span::styled("  nice ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>4.1}", d("nice")), Style::default().fg(Color::Gray)),
            Span::styled("  steal ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>4.1}", d("steal")), Style::default().fg(Color::Gray)),
        ]);
        let ncpu = cores.len().max(1) as f64;
        let load = Line::from(vec![
            Span::styled("load ", Style::default().fg(LABEL)),
            Span::styled(format!("{:.2}", num(&s, "load1")), Style::default().fg(grad(num(&s, "load1") / ncpu))),
            Span::styled(format!(" {:.2} {:.2}", num(&s, "load5"), num(&s, "load15")), Style::default().fg(Color::Gray)),
            Span::styled(format!("   {} cores", cores.len()), Style::default().fg(LABEL)),
        ]);
        f.render_widget(Paragraph::new(vec![detail, load]), cpu_left[2]);

        // per-core meters
        let per = (cores.len() + core_cols - 1) / core_cols.max(1);
        let core_areas = Layout::horizontal(vec![Constraint::Ratio(1, core_cols as u32); core_cols]).split(cpu_split[1]);
        for (ci, ca) in core_areas.iter().enumerate() {
            let lines: Vec<Line> = cores
                .iter()
                .enumerate()
                .skip(ci * per)
                .take(per.min(ca.height as usize))
                .map(|(i, c)| {
                    let v = c.as_f64().unwrap_or(0.0);
                    // btop gives every core its own graph, not just a bar. A
                    // single braille row is 4 levels tall and 2 samples wide
                    // per cell — coarse, but it distinguishes "pinned" from
                    // "just spiked", which a bar cannot.
                    let gw = ((ca.width as usize) / 3).clamp(4, 10);
                    // btop's core labels are C0, C1, … and each carries its own
                    // temperature. A bare number reads as a row index.
                    let ct = core_temps.get(i).and_then(|v| v.as_f64());
                    let tw = if ct.is_some() { 5 } else { 0 };
                    let bw = (ca.width as usize).saturating_sub(gw + 10 + tw);
                    let mut sp = vec![Span::styled(format!("C{i:<2}"), Style::default().fg(LABEL))];
                    if let Some(h) = self.core_hist.get(i) {
                        sp.extend(braille_graph(h, 100.0, gw, 1).pop().map(|l| l.spans).unwrap_or_default());
                    } else {
                        sp.push(Span::raw(" ".repeat(gw)));
                    }
                    sp.push(Span::raw(" "));
                    sp.extend(meter(bw, v / 100.0, "").spans);
                    sp.push(Span::styled(format!(" {v:>3.0}%"), Style::default().fg(grad(v / 100.0))));
                    if let Some(t) = ct {
                        // Scaled to 100°C: thermal throttling starts around
                        // there, so the colour means "close to throttling"
                        // rather than "warmer than the other cores".
                        sp.push(Span::styled(format!(" {t:>3.0}°"), Style::default().fg(grad(t / 100.0))));
                    }
                    Line::from(sp)
                })
                .collect();
            f.render_widget(Paragraph::new(lines), *ca);
        }

        // ── mem | storage | net ───────────────────────────────────────────────
        let mid = Layout::horizontal(if self.show[B_STORAGE] {
            vec![Constraint::Percentage(36), Constraint::Percentage(37), Constraint::Percentage(27)]
        } else {
            vec![Constraint::Percentage(48), Constraint::Percentage(52)]
        })
        .split(rows[2]);

        // memory — RAM and swap kept apart on purpose. They are two different
        // stores, and a page can be in BOTH at once (SwapCached), so a single
        // merged "memory used" figure is arithmetic on overlapping sets.
        let mem_b = bbox("mem", "");
        let mem_in = mem_b.inner(mid[0]);
        f.render_widget(mem_b, mid[0]);
        let bw = (mem_in.width as usize).saturating_sub(24);
        let mut ml: Vec<Line> = vec![];
        let bar = |label: &str, pct: f64, txt: String| -> Line<'static> {
            let mut sp = vec![Span::styled(format!("{label:<7}"), Style::default().fg(LABEL))];
            sp.extend(meter(bw, pct / 100.0, "").spans);
            sp.push(Span::styled(format!(" {txt}"), Style::default().fg(Color::Gray)));
            Line::from(sp)
        };
        let md = |k: &str| num(&s, &format!("mem_detail.{k}"));
        let sd = |k: &str| num(&s, &format!("swap_detail.{k}"));
        let total = md("total").max(0.001);

        ml.push(Line::from(Span::styled(
            "RAM",
            Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
        )));
        ml.push(bar("used", num(&s, "mem"), format!("{} / {}", fmt_gib(md("used")), fmt_gib(total))));
        // The composition line: these four are disjoint and sum to total, which
        // is what makes it a breakdown rather than four unrelated numbers.
        // anon = process memory, cached/buffers = reclaimable page cache,
        // kernel = slab+stacks+page tables, free = untouched.
        let part = |name: &str, v: f64, c: Color| -> Vec<Span<'static>> {
            vec![
                Span::styled(format!(" {name} "), Style::default().fg(LABEL)),
                Span::styled(fmt_gib(v), Style::default().fg(c)),
                Span::styled(format!(" {:>4.1}%", v / total * 100.0), Style::default().fg(DIM)),
            ]
        };
        let mut comp = vec![Span::styled("  ", Style::default())];
        comp.extend(part("anon", md("anon"), Color::Rgb(240, 160, 90)));
        comp.extend(part("cache", md("cached"), Color::Rgb(120, 220, 140)));
        ml.push(Line::from(comp));
        let mut comp2 = vec![Span::styled("  ", Style::default())];
        comp2.extend(part("kern", md("kernel"), Color::Rgb(190, 150, 240)));
        comp2.extend(part("free", md("free"), Color::Rgb(120, 200, 255)));
        ml.push(Line::from(comp2));
        ml.push(Line::from(vec![
            Span::styled("  buffers ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("buffers")), Style::default().fg(Color::Gray)),
            Span::styled(" shmem ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("shmem")), Style::default().fg(Color::Gray)),
            // The only figure that answers "can I start something big": it
            // already accounts for what the kernel would reclaim.
            Span::styled(" avail ", Style::default().fg(LABEL)),
            Span::styled(
                fmt_gib(md("available")),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            ),
        ]));
        ml.push(Line::from(vec![
            Span::styled("  dirty ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("dirty")), Style::default().fg(grad(md("dirty") / 2.0))),
            Span::styled(" wb ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("writeback")), Style::default().fg(Color::Gray)),
            Span::styled(" commit ", Style::default().fg(LABEL)),
            Span::styled(
                format!("{}/{}", fmt_gib(md("committed")), fmt_gib(md("commit_limit"))),
                Style::default().fg(Color::Gray),
            ),
        ]));

        // GPU memory, and the two kinds are not interchangeable. Dedicated
        // belongs to the card and filling it makes the GPU evict; shared comes
        // out of the same RAM as everything else, so filling it is a memory
        // problem rather than a GPU one. A single merged "VRAM" answers
        // neither question, which is why they are separate rows.
        let vd = |k: &str| -> Option<(f64, f64)> {
            let u = num_opt(&s, &format!("vram_detail.{k}.used"))?;
            let t = num_opt(&s, &format!("vram_detail.{k}.total"))?;
            if t > 0.0 { Some((u, t)) } else { None }
        };
        let ded = vd("dedicated");
        let shr = vd("shared");
        if ded.is_some() || shr.is_some() {
            ml.push(Line::from(Span::styled(
                "VRAM",
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            )));
            if let Some((u, t)) = ded {
                ml.push(bar(
                    "dedicated",
                    u / t * 100.0,
                    format!("{} / {}", fmt_bytes_short(u), fmt_bytes_short(t)),
                ));
            }
            if let Some((u, t)) = shr {
                ml.push(bar(
                    "shared",
                    u / t * 100.0,
                    format!("{} / {}", fmt_bytes_short(u), fmt_bytes_short(t)),
                ));
            }
        }

        ml.push(Line::from(Span::styled(
            "SWAP",
            Style::default().fg(Color::Rgb(190, 150, 240)).add_modifier(Modifier::BOLD),
        )));
        ml.push(bar("used", num(&s, "swap"), format!("{} / {}", fmt_gib(sd("used")), fmt_gib(sd("total")))));
        ml.push(Line::from(vec![
            Span::styled("  free ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(sd("free")), Style::default().fg(Color::Gray)),
            // Pages that are on disk AND still resident. Faulting one back is
            // free, which is why swap "used" alone overstates the damage.
            Span::styled(" cached ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(sd("cached")), Style::default().fg(Color::Gray)),
            Span::styled(" zswap ", Style::default().fg(LABEL)),
            Span::styled(
                format!("{}→{}", fmt_gib(sd("zswapped")), fmt_gib(sd("zswap"))),
                Style::default().fg(Color::Gray),
            ),
        ]));
        // The user slice's own cap is what actually decides who gets OOM-killed
        // on this machine — RAM% can look calm while the slice is at its limit.
        ml.push(bar(
            "slice",
            num(&s, "slice_pct"),
            format!("{} / {}", fmt_gib(num(&s, "slice_gib")), fmt_gib(num(&s, "slice_max_gib"))),
        ));
        f.render_widget(Paragraph::new(ml), mem_in);

        // ── storage ───────────────────────────────────────────────────────────
        if self.show[B_STORAGE] {
            let st_b = bbox("storage", "");
            let st_in = st_b.inner(mid[1]);
            f.render_widget(st_b, mid[1]);
            f.render_widget(Paragraph::new(self.storage_lines(&s, st_in.width, st_in.height)), st_in);
        }
        let net_area = mid[if self.show[B_STORAGE] { 2 } else { 1 }];

        // network
        if self.show[B_NET] {
            let net_b = bbox("net", "");
            let net_in = net_b.inner(net_area);
            f.render_widget(net_b, net_area);
            // The throughput graphs answer "how much"; the config block below
            // answers "where" — which address to reach this box on, through
            // which gateway, resolved by whom. On a remote target it is that
            // machine's configuration, not this one's.
            let cfg = arr(&s, "host_info.ifaces");
            let dns = arr(&s, "host_info.dns");
            // Every interface, plus a gateway line and a DNS line. Capped only
            // by the box: "all the network config" is the point, and hiding
            // the third wg address to save a row defeats it.
            let cfg_h = (cfg.len() + 3).min(net_in.height.saturating_sub(6) as usize).max(3) as u16;
            let nrows = Layout::vertical([
                Constraint::Length(1),
                Constraint::Min(2),
                Constraint::Length(1),
                Constraint::Min(2),
                Constraint::Length(cfg_h),
            ])
            .split(net_in);
            let rx_max = self.rx_hist.iter().cloned().fold(0.001, f64::max);
            let tx_max = self.tx_hist.iter().cloned().fold(0.001, f64::max);
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("▼ ", Style::default().fg(Color::Rgb(120, 220, 140))),
                    Span::styled(fmt_rate_mb(num(&s, "net_rx")), Style::default().fg(Color::Gray)),
                    Span::styled(format!("  peak {}", fmt_rate_mb(rx_max)), Style::default().fg(DIM)),
                ])),
                nrows[0],
            );
            f.render_widget(
                Paragraph::new(braille_graph(&self.rx_hist, rx_max, nrows[1].width as usize, nrows[1].height as usize)),
                nrows[1],
            );
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("▲ ", Style::default().fg(Color::Rgb(220, 140, 240))),
                    Span::styled(fmt_rate_mb(num(&s, "net_tx")), Style::default().fg(Color::Gray)),
                    Span::styled(format!("  peak {}", fmt_rate_mb(tx_max)), Style::default().fg(DIM)),
                ])),
                nrows[2],
            );
            f.render_widget(
                Paragraph::new(braille_graph(&self.tx_hist, tx_max, nrows[3].width as usize, nrows[3].height as usize)),
                nrows[3],
            );

            let mut cl: Vec<Line> = vec![];
            for i in cfg.iter().take(cfg_h.saturating_sub(3) as usize) {
                let n = text(i, "name");
                cl.push(Line::from(vec![
                    Span::styled(
                        format!("{:<10}", trunc(&n, 10)),
                        // The mesh interfaces are the ones that matter here.
                        Style::default().fg(if n.starts_with("wg") {
                            Color::Rgb(120, 200, 255)
                        } else {
                            LABEL
                        }),
                    ),
                    Span::styled(text(i, "addr"), Style::default().fg(Color::Gray)),
                ]));
            }
            let gw = text(&s, "host_info.gateway");
            let ns: Vec<String> = dns.iter().map(|d| d.as_str().unwrap_or("").to_string()).collect();
            let pubip = text(&s, "host_info.public");
            cl.push(Line::from(vec![
                Span::styled(format!("{:<10}", "public"), Style::default().fg(LABEL)),
                Span::styled(
                    if pubip.is_empty() {
                        // Not a failure: from behind NAT it cannot be known
                        // without asking somebody outside.
                        "behind NAT — no routable address on any interface".to_string()
                    } else {
                        pubip.clone()
                    },
                    Style::default().fg(if pubip.is_empty() { DIM } else { Color::Rgb(240, 169, 66) }),
                ),
            ]));
            cl.push(Line::from(vec![
                Span::styled(format!("{:<10}", "gateway"), Style::default().fg(LABEL)),
                Span::styled(
                    format!("{} via {}", if gw.is_empty() { "—" } else { &gw }, text(&s, "host_info.wan_if")),
                    Style::default().fg(Color::Gray),
                ),
            ]));
            let search = arr(&s, "host_info.search");
            cl.push(Line::from(vec![
                Span::styled(format!("{:<10}", "dns"), Style::default().fg(LABEL)),
                Span::styled(
                    if ns.is_empty() { "—".to_string() } else { ns.join("  ") },
                    Style::default().fg(Color::Gray),
                ),
                Span::styled(
                    if search.is_empty() {
                        String::new()
                    } else {
                        format!(
                            "  search {}",
                            search.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" ")
                        )
                    },
                    Style::default().fg(DIM),
                ),
            ]));
            f.render_widget(Paragraph::new(cl), nrows[4]);
        }

        // PSI — the box that matters most on this machine. systemd-oomd watches
        // MEMORY pressure only; the 2026-08-22 freeze was IO-bound, invisible to
        // it, and only freeze-guard's voters covered it. So show both: the raw
        // some/full averages, and which of the guard's voters are armed.
        // Three boxes share this band and any of them can be folded away, so
        // the split is built from whichever are actually shown. Fill weights
        // rather than percentages: they stay correct for every subset instead
        // of leaving a gap whenever the numbers no longer add to 100.
        let low_boxes: Vec<usize> =
            [B_PSI, B_SLICES, B_MESH].into_iter().filter(|i| self.show[*i]).collect();
        let low = Layout::horizontal(if low_boxes.is_empty() {
            vec![Constraint::Fill(1)]
        } else {
            low_boxes
                .iter()
                .map(|i| match *i {
                    B_PSI => Constraint::Fill(34),
                    B_SLICES => Constraint::Fill(42),
                    _ => Constraint::Fill(24),
                })
                .collect::<Vec<_>>()
        })
        .split(rows[3]);
        let slot = |b: usize| low_boxes.iter().position(|x| *x == b).unwrap_or(0);
        if self.show[B_PSI] {
            let psi_area = low[slot(B_PSI)];
            let psi_b = bbox("psi", "");
            let psi_in = psi_b.inner(psi_area);
            f.render_widget(psi_b, psi_area);
            let mut pl: Vec<Line> = vec![Line::from(vec![
                Span::styled("         10s    60s   300s  now", Style::default().fg(LABEL)),
            ])];
            for (kind, short) in [("cpu", "cpu"), ("io", "io"), ("memory", "mem")] {
                for band in ["some", "full"] {
                    // `full` means every task was stalled — on io it is the number
                    // that tracked the freeze, so it is never scaled the same as
                    // `some`, which is routinely nonzero on a busy but healthy box.
                    let scale = if band == "full" { 20.0 } else { 60.0 };
                    let v10 = num(&s, &format!("psi.{kind}.{band}10"));
                    let v60 = num(&s, &format!("psi.{kind}.{band}60"));
                    let v300 = num(&s, &format!("psi.{kind}.{band}300"));
                    let mut sp = vec![
                        Span::styled(
                            format!("{:<4}", if band == "some" { short } else { "" }),
                            Style::default().fg(Color::Rgb(120, 200, 255)),
                        ),
                        // 5, not 4: a value of 10 or more fills all five of
                        // its own columns and "some16.75" has no gap at all.
                        Span::styled(format!("{:<5}", band), Style::default().fg(LABEL)),
                        Span::styled(format!("{v10:>5.2}"), Style::default().fg(grad(v10 / scale))),
                        Span::styled(format!("{v60:>7.2}"), Style::default().fg(grad(v60 / scale))),
                        Span::styled(format!("{v300:>7.2}"), Style::default().fg(grad(v300 / scale))),
                        Span::raw("  "),
                    ];
                    // A thermometer per row. The numbers alone make you do the
                    // "is 4.2 bad for `full`?" arithmetic every time; the bar
                    // is already scaled by the band, so a long bar means bad
                    // whichever row it is on. Driven by the 10s figure — the
                    // one that moves while you are watching.
                    let tw = (psi_in.width as usize).saturating_sub(28).min(18);
                    if tw >= 4 {
                        sp.extend(meter(tw, v10 / scale, "").spans);
                    }
                    pl.push(Line::from(sp));
                }
        }
            // WHAT IS PRODUCING THAT MEMORY PRESSURE.
            //
            // The grid above says pressure exists; these three lines say what
            // kind. The pair that matters is direct vs kswapd: reclaim by
            // kswapd is background work on its own thread and surfaces as
            // `some`, while DIRECT reclaim is a process being made to free
            // memory before its own allocation can proceed — a synchronous
            // stall, and what drives `full`. Same numbers, completely
            // different responses.
            let rc = |k: &str| num(&s, &format!("reclaim.{k}"));
            let pair = |label: &str, a: (&str, f64), b: (&str, f64), scale: f64| -> Line<'static> {
                Line::from(vec![
                    Span::styled(format!("{label:<9}"), Style::default().fg(Color::Rgb(120, 200, 255))),
                    Span::styled(format!("{:<7}", a.0), Style::default().fg(LABEL)),
                    Span::styled(
                        format!("{:>7}", fmt_rate(a.1)),
                        Style::default().fg(grad(a.1 / scale)),
                    ),
                    Span::styled(format!("   {:<6}", b.0), Style::default().fg(LABEL)),
                    Span::styled(
                        format!("{:>7}", fmt_rate(b.1)),
                        Style::default().fg(grad(b.1 / scale)),
                    ),
                ])
            };
            pl.push(pair(
                "reclaim/s",
                // Direct reclaim is the one that stalls, so it is scaled ten
                // times tighter — any of it at all is worth seeing.
                ("direct", rc("scan_direct")),
                ("kswapd", rc("scan_kswapd")),
                2000.0,
            ));
            pl.push(pair(
                "refault/s",
                ("file", rc("refault_file")),
                ("anon", rc("refault_anon")),
                2000.0,
            ));
            pl.push(pair("swap/s", ("in", rc("swap_in")), ("out", rc("swap_out")), 500.0));

            // ── the rest of what atop shows and this did not ──────────────
            // Six figures the panel collected or could reach and never drew.
            // They belong here rather than scattered: every one answers "is
            // something being held back", which is what this box is for.
            let hh = |k: &str| num(&s, &format!("health.{k}"));
            let cd = |k: &str| num(&s, &format!("cpu_detail.{k}"));
            let md = |k: &str| num(&s, &format!("mem_detail.{k}"));
            let cell = |label: &str, v: String, c: Color| -> Vec<Span<'static>> {
                vec![
                    Span::styled(format!("{label:<7}"), Style::default().fg(LABEL)),
                    Span::styled(format!("{v:<9}"), Style::default().fg(c)),
                ]
            };
            // steal is the one that matters on the fleet: a cloud peer starved
            // by its hypervisor looks idle from inside, and nothing here said
            // so. iowait and irq were collected all along and never shown.
            let mut r1 = vec![Span::styled(
                format!("{:<9}", "cpu"),
                Style::default().fg(Color::Rgb(120, 200, 255)),
            )];
            r1.extend(cell("steal", format!("{:.1}%", cd("steal")), grad(cd("steal") / 10.0)));
            r1.extend(cell("wait", format!("{:.1}%", cd("iowait")), grad(cd("iowait") / 20.0)));
            r1.extend(cell("irq", format!("{:.1}%", cd("irq")), grad(cd("irq") / 20.0)));
            r1.extend(cell("runq", format!("{:.0}", hh("procs_running")), grad(hh("procs_running") / 32.0)));
            // procs_blocked is uninterruptible sleep — the D-state count, and
            // the outward signature of an I/O hang.
            r1.extend(cell("blkd", format!("{:.0}", hh("procs_blocked")), grad(hh("procs_blocked") / 8.0)));
            pl.push(Line::from(r1));

            let mut r2 = vec![Span::styled(
                format!("{:<9}", "mem"),
                Style::default().fg(Color::Rgb(120, 200, 255)),
            )];
            // Committed against the limit. Over 100% means the kernel has
            // promised more than it can deliver — not fatal, but it is the
            // number that decides whether the next big allocation is refused.
            let lim = md("commit_limit");
            let com = md("committed");
            r2.extend(cell(
                "commit",
                if lim > 0.0 { format!("{:.0}%", com / lim * 100.0) } else { "-".into() },
                grad(if lim > 0.0 { com / lim } else { 0.0 }),
            ));
            r2.extend(cell("dirty", fmt_g(md("dirty")), grad(md("dirty") / 2.0)));
            r2.extend(cell(
                "slab",
                fmt_g(md("slab_reclaimable") + md("slab_unreclaimable")),
                Color::Gray,
            ));
            // The one number nobody wants to be non-zero.
            let oom = hh("oom_kill");
            r2.extend(cell(
                "oomkill",
                format!("{oom:.0}"),
                if oom > 0.0 { Color::Rgb(240, 100, 100) } else { Color::Gray },
            ));
            pl.push(Line::from(r2));

            let mut r3 = vec![Span::styled(
                format!("{:<9}", "io/net"),
                Style::default().fg(Color::Rgb(120, 200, 255)),
            )];
            r3.extend(cell("busy", format!("{:.0}%", hh("disk_busy_pct")), grad(hh("disk_busy_pct") / 100.0)));
            // Service time per io. A disk shows this climbing long before its
            // throughput drops, which is why throughput alone never warns you.
            r3.extend(cell("avio", format!("{:.2}ms", hh("disk_avio_ms")), grad(hh("disk_avio_ms") / 20.0)));
            r3.extend(cell("iops", format!("{:.0}", hh("disk_iops")), Color::Gray));
            // Retransmits are loss. On a mesh spanning three providers this is
            // the best single number for whether the network is healthy.
            let rt = hh("tcp_retrans_pct");
            r3.extend(cell("retrans", format!("{rt:.2}%"), grad(rt / 2.0)));
            r3.extend(cell("ctxsw/s", fmt_rate(hh("ctxt_per_s")), Color::Gray));
            pl.push(Line::from(r3));

        let voters = arr(&self.guard, "voters");
        if voters.is_empty() {
            pl.push(Line::from(Span::styled(
                "guard: no /run/freeze-guard.json",
                Style::default().fg(Color::Rgb(240, 72, 72)),
            )));
        } else {
            let armed: Vec<String> = voters
                .iter()
                .filter(|v| v.get("armed").and_then(|x| x.as_bool()).unwrap_or(false))
                .map(|v| text(v, "id"))
                .collect();
            // Worst voter as a fraction of its own threshold — one number for
            // "how close is the guard to firing", which no raw PSI cell gives.
            let worst = voters
                .iter()
                .map(|v| {
                    let t = num(v, "threshold");
                    if t > 0.0 { num(v, "value") / t } else { 0.0 }
                })
                .fold(0.0, f64::max);
            pl.push(Line::from(vec![
                Span::styled("guard ", Style::default().fg(LABEL)),
                Span::styled(format!("{}/{} voters", armed.len(), voters.len()), Style::default().fg(Color::Gray)),
                Span::styled(format!("  worst {:.0}%", worst * 100.0), Style::default().fg(grad(worst))),
            ]));
            if !armed.is_empty() {
                pl.push(Line::from(Span::styled(
                    format!("ARMED: {}", armed.join(", ")),
                    Style::default().fg(Color::Rgb(240, 72, 72)).add_modifier(Modifier::BOLD),
                )));
            }
        }
        f.render_widget(Paragraph::new(pl), psi_in);
        }

        // ── watchdog slice manager ───────────────────────────────────────────
        if self.show[B_SLICES] {
            let sl_area = low[slot(B_SLICES)];
            let sl_b = bbox("watchdog · slices", "protected slices refuse kills");
            let sl_in = sl_b.inner(sl_area);
            f.render_widget(sl_b, sl_area);
            f.render_widget(Paragraph::new(self.slice_lines(&s, sl_in.width, sl_in.height)), sl_in);
        }

        // ── mesh ─────────────────────────────────────────────────────────────
        // wg(8) cannot be read unprivileged, so "up" here is a TCP connect the
        // kernel completed to the peer's sshd, not a handshake age. That is a
        // narrower claim and a truer one: it means you can reach the machine.
        if self.show[B_MESH] {
            let target = self.mesh.target();
            let mesh_area = low[slot(B_MESH)];
            let mesh_b = bbox("mesh", "esc → measure");
            let mesh_in = mesh_b.inner(mesh_area);
            f.render_widget(mesh_b, mesh_area);
            let peers = self.mesh.list();
            let mut l: Vec<Line> = vec![Line::from(vec![
                Span::styled(format!("{:<16}", "peer"), Style::default().fg(DIM)),
                Span::styled(format!("{:>10}", "addr"), Style::default().fg(DIM)),
                Span::styled(format!("{:>8}", "rtt"), Style::default().fg(DIM)),
            ])];
            for p in peers.iter().take((mesh_in.height as usize).saturating_sub(1)) {
                let here = p.local && target.is_none()
                    || target.as_deref() == Some(p.alias.as_str());
                let (dot, dc) = if !p.probed {
                    ("·", DIM)
                } else if p.up {
                    ("●", Color::Rgb(120, 220, 140))
                } else {
                    ("●", Color::Rgb(240, 72, 72))
                };
                l.push(Line::from(vec![
                    Span::styled(format!("{dot} "), Style::default().fg(dc)),
                    Span::styled(
                        format!("{:<14}", trunc(&p.alias, 14)),
                        Style::default().fg(if here { Color::Rgb(120, 200, 255) } else { Color::Gray }),
                    ),
                    Span::styled(format!("{:>10}", p.ip), Style::default().fg(DIM)),
                    Span::styled(
                        if p.local {
                            format!("{:>8}", "here")
                        } else if !p.probed {
                            format!("{:>8}", "…")
                        } else if p.up {
                            format!("{:>7.0}ms", p.rtt_ms)
                        } else {
                            format!("{:>8}", "down")
                        },
                        Style::default().fg(if p.local {
                            Color::Rgb(120, 200, 255)
                        } else if p.up {
                            grad(p.rtt_ms / 200.0)
                        } else {
                            DIM
                        }),
                    ),
                ]));
            }
            if peers.is_empty() {
                l.push(Line::from(Span::styled(
                    "no mesh peers in ~/.ssh/config",
                    Style::default().fg(Color::Rgb(240, 160, 90)),
                )));
            }
            f.render_widget(Paragraph::new(l), mesh_in);
        }

        // ── files ─────────────────────────────────────────────────────────────
        // The home directory, four levels deep. Cached, because tree(1) walks
        // tens of thousands of inodes and this panel redraws every second.
        if self.files {
            // Re-key here too, not only on tab entry: the target can change
            // while you are already standing on this tab, and that is exactly
            // the case that used to leave a peer's tab showing this machine.
            let key = self.files_key();
            self.files_cache.fetch(key.clone(), self.mesh.target(), self.files_hidden);
            let (tree, loading) = self.files_cache.view(&key);
            let tree = tree.unwrap_or_default();
            let whose = self.mesh.target().unwrap_or_else(|| "this machine".into());
            let fb = self.tabs_box(
                &format!(
                    "four levels side by side · dotfiles {} · . toggles · ↑↓ pgup pgdn",
                    if self.files_hidden { "shown" } else { "hidden" }
                ),
            );
            let fin = fb.inner(rows[4]);
            f.render_widget(fb, rows[4]);
            // One pane per depth, side by side. Four nested trees would be
            // four copies of each other — a level is only interesting next to
            // the other levels, which is what the columns are for.
            let panes = Layout::horizontal([Constraint::Ratio(1, 4); 4]).split(fin);
            for (n, area) in panes.iter().enumerate() {
                let entries = &tree[n];
                let w = area.width as usize;
                let mut l: Vec<Line> = vec![Line::from(Span::styled(
                    format!("L{}  {} dirs", n + 1, entries.len()),
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                ))];
                for e in entries.iter().skip(self.files_scroll as usize) {
                    // Elide from the LEFT: the tail is what identifies a path,
                    // and a column this narrow cannot hold "a/b/c/d" whole.
                    let shown = if e.chars().count() > w.saturating_sub(1) {
                        let keep = w.saturating_sub(2);
                        let tail: String = e.chars().rev().take(keep).collect::<Vec<_>>()
                            .into_iter().rev().collect();
                        format!("…{tail}")
                    } else {
                        e.clone()
                    };
                    l.push(Line::from(Span::styled(shown, Style::default().fg(Color::Gray))));
                }
                f.render_widget(Paragraph::new(l), *area);
            }
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None if loading => format!(" reading {whose}'s home over ssh…"),
                    None => format!(
                        " {} directories in {whose}'s home · L1 {} · L2 {} · L3 {} · L4 {}",
                        tree.iter().map(|v| v.len()).sum::<usize>(),
                        tree[0].len(),
                        tree[1].len(),
                        tree[2].len(),
                        tree[3].len(),
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── about ─────────────────────────────────────────────────────────────
        // What this machine IS, rather than what it is doing. Everything here
        // changes on the scale of a reboot or a reinstall, which is exactly
        // why it does not belong in a box that redraws every second.
        if self.about {
            let ab = self.tabs_box("b back to processes");
            let ain = ab.inner(rows[4]);
            f.render_widget(ab, rows[4]);
            let hi2 = |k: &str| text(&s, &format!("host_info.{k}"));
            let sect = |t: &str| -> Line<'static> {
                Line::from(Span::styled(
                    t.to_string(),
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                ))
            };
            let kv2 = |k: &str, v: String| -> Line<'static> {
                Line::from(vec![
                    Span::styled(format!("  {k:<18}"), Style::default().fg(LABEL)),
                    Span::styled(v, Style::default().fg(Color::Gray)),
                ])
            };
            let cores = arr(&s, "cores").len();
            // What this program IS, before what the machine is. It is the
            // first thing anyone opening "about" is actually looking for, and
            // it is the only place the repo and the version live at runtime.
            let mut al: Vec<Line> = vec![sect("this app")];
            al.push(kv2("name", format!("my-konsole-dash {}", env!("CARGO_PKG_VERSION"))));
            al.push(kv2("what", "a btop-shaped panel over one JSON snapshot".into()));
            let repo = "https://github.com/diegonmarcos/cloud-unix";
            // The product's own directory, not the repo root: cloud-unix holds
            // dozens of products and landing on the root leaves you to find
            // this one. The root is one click up from here anyway.
            al.push(kv2("repo", format!("{repo}/tree/main/da__my-konsole")));
            // Deep links: "da__my-konsole/dash" tells you where to look only if
            // you already have the tree checked out.
            al.push(kv2("source", format!("{repo}/tree/main/da__my-konsole/dash/src/dashboards")));
            al.push(kv2("watchdog source", format!("{repo}/tree/main/da_watchdog")));
            al.push(kv2("releases", format!("{repo}/releases")));
            al.push(kv2("this binary", format!("{repo}/releases/tag/my-konsole-latest")));
            al.push(kv2("watchdog binary", format!("{repo}/releases/tag/my-watchdog-latest")));
            al.push(kv2(
                "policy source",
                format!("{repo}/blob/main/da_watchdog/configs/watchdog-policy.json"),
            ));
            al.push(kv2(
                "publisher",
                // The split is the thing worth explaining here: this program
                // measures nothing, and every number on screen came from that
                // file.
                "my-watchdog — da_watchdog, its own product".into(),
            ));
            al.push(kv2("reads", snapshot_path()));
            al.push(kv2("built", format!("rustc target {}", std::env::consts::ARCH)));

            al.push(sect("system"));
            al.push(kv2("host", hi2("host")));
            al.push(kv2("user", hi2("user")));
            al.push(kv2("os", hi2("os")));
            al.push(kv2("kernel", hi2("kernel")));
            al.push(kv2("uptime", fmt_uptime(num(&s, "totals.since_s"))));
            al.push(kv2(
                "measured",
                match self.mesh.target() {
                    Some(a) => format!("{a}, over ssh — collected on demand"),
                    None => "locally — this is the hub".into(),
                },
            ));

            al.push(sect("hardware"));
            al.push(kv2("cpu", text(&s, "cpu_info.model")));
            let mhz = num_opt(&s, "cpu_info.mhz");
            al.push(kv2(
                "cores",
                match mhz {
                    Some(m) => format!("{cores} @ {:.2} GHz right now", m / 1000.0),
                    None => format!("{cores}"),
                },
            ));
            if let Some(t) = num_opt(&s, "cpu_info.temp_c") {
                let per = arr(&s, "cpu_info.core_temps");
                al.push(kv2(
                    "temperature",
                    if per.is_empty() {
                        format!("{t:.0}°C package")
                    } else {
                        format!(
                            "{t:.0}°C package · cores {}",
                            per.iter()
                                .filter_map(|v| v.as_f64())
                                .map(|v| format!("{v:.0}"))
                                .collect::<Vec<_>>()
                                .join(" ")
                        )
                    },
                ));
            }
            al.push(kv2("memory", fmt_gib(num(&s, "mem_detail.total"))));
            let vsrc = text(&s, "vram_detail.source");
            let vsize = |k: &str| -> Option<String> {
                num_opt(&s, &format!("vram_detail.{k}.total")).filter(|t| *t > 0.0).map(fmt_bytes_short)
            };
            match (vsize("dedicated"), vsize("shared")) {
                (None, None) => al.push(kv2(
                    "gpu memory",
                    // i915 keeps its usage in debugfs, which is root-only. Not
                    // knowing is a different answer from having none.
                    if vsrc == "none" { "not readable here (integrated, usage is root-only)".into() } else { "—".into() },
                )),
                (d, sh) => {
                    if let Some(d) = d {
                        al.push(kv2("gpu dedicated", d));
                    }
                    if let Some(sh) = sh {
                        al.push(kv2("gpu shared", sh));
                    }
                }
            }
            al.push(kv2("swap", fmt_gib(num(&s, "swap_detail.total"))));
            for pool in arr(&s, "storage") {
                let label = text(pool, "label");
                al.push(kv2(
                    if label.is_empty() { "storage" } else { "storage" },
                    format!(
                        "{} of {}{}",
                        fmt_g(num(pool, "alloc_used")),
                        fmt_g(num(pool, "dev_size")),
                        // "df" is the collector's label for a peer, where no
                        // qgroup data is gathered. Saying so beats letting a
                        // df number pass for a btrfs one.
                        if label == "df" { "  (df, not btrfs qgroups)" } else { "" }
                    ),
                ));
            }

            al.push(sect("network"));
            for i in arr(&s, "host_info.ifaces").iter().take(10) {
                al.push(kv2(&text(i, "name"), text(i, "addr")));
            }
            let pubip = hi2("public");
            al.push(kv2(
                "public",
                if pubip.is_empty() { "behind NAT — no routable address here".into() } else { pubip },
            ));
            al.push(kv2("gateway", format!("{} via {}", hi2("gateway"), hi2("wan_if"))));
            let dns: Vec<String> = arr(&s, "host_info.dns")
                .iter()
                .filter_map(|d| d.as_str().map(|x| x.to_string()))
                .collect();
            al.push(kv2("dns", if dns.is_empty() { "—".into() } else { dns.join("  ") }));
            let search: Vec<String> = arr(&s, "host_info.search")
                .iter()
                .filter_map(|d| d.as_str().map(|x| x.to_string()))
                .collect();
            if !search.is_empty() {
                al.push(kv2("search", search.join(" ")));
            }

            al.push(sect("running"));
            al.push(kv2("containers", format!("{}", arr(&s, "containers").len())));
            let svc = arr(&s, "services");
            let active = svc.iter().filter(|u| text(u, "active") == "active").count();
            al.push(kv2("units", format!("{active} active of {} declared", svc.len())));
            al.push(kv2("slices", format!("{}", arr(&s, "slices").len())));

            let max = (al.len() as u16).saturating_sub(ain.height);
            f.render_widget(
                Paragraph::new(al).scroll((self.detail_scroll.min(max), 0)),
                ain,
            );
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => " about · ↑↓ scroll · h keys · esc menu · ^c quits".to_string(),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── containers-c ──────────────────────────────────────────────────────
        // Containers are processes too, but a container is not a row in the
        // process table: the thing you want named is the container, and what
        // it uses is the sum of everything inside it. docker already computes
        // that, so this shows docker's own numbers rather than re-deriving
        // them from cgroups and getting a subtly different answer.
        if self.docker {
            let (label, _) = CTR_SORT[self.ctr_sort.min(CTR_SORT.len() - 1)];
            let cb = self.tabs_box(
                &format!(
                    "{label}{} · ←→ rank · i inv · enter acts",
                    if self.ctr_desc { "▼" } else { "▲" }
                ),
            );
            let cin = cb.inner(rows[4]);
            f.render_widget(cb, rows[4]);
            let cs = self.ctr_rows(&s);
            let _ = &label;
            if cs.is_empty() {
                f.render_widget(
                    Paragraph::new(vec![
                        Line::from(Span::styled(
                            "  no containers",
                            Style::default().fg(Color::Rgb(240, 160, 90)),
                        )),
                        Line::from(Span::styled(
                            "  nothing running, no docker or podman, or this user is not in the",
                            Style::default().fg(DIM),
                        )),
                        Line::from(Span::styled(
                            "  docker group — all three look the same from here, and all three",
                            Style::default().fg(DIM),
                        )),
                        Line::from(Span::styled("  mean the same thing.", Style::default().fg(DIM))),
                    ]),
                    cin,
                );
            } else {
                // Scroll, because oci-apps has 52 of these and a view that can
                // only ever show the first screenful is not a list.
                let vis = (cin.height as usize).saturating_sub(1).max(1);
                self.sel = self.sel.min(cs.len().saturating_sub(1));
                if self.sel < self.offset {
                    self.offset = self.sel;
                } else if self.sel >= self.offset + vis {
                    self.offset = self.sel + 1 - vis;
                }
                if self.offset + vis > cs.len() {
                    self.offset = cs.len().saturating_sub(vis);
                }
                let pct = |t: &str| -> f64 { t.trim_end_matches('%').parse().unwrap_or(0.0) };
                let crows: Vec<Row> = cs
                    .iter()
                    .enumerate()
                    .skip(self.offset)
                    .take(vis)
                    .map(|(n, c)| {
                        let sel = n == self.sel;
                        let base = if sel {
                            Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                        } else {
                            Style::default()
                        };
                        let cpu = pct(&text(c, "cpu"));
                        let mem = pct(&text(c, "mem_pct"));
                        // Empty is docker failing to read the cgroup, not zero.
                        let st = |k: &str, w: usize| -> String {
                            let v = text(c, k);
                            if v.is_empty() { format!("{:>w$}", "-") } else { format!("{v:>w$}") }
                        };
                        Row::new(vec![
                            Cell::from(format!(
                                "{}{}",
                                if sel { "▶" } else { " " },
                                trunc(&text(c, "name"), 22)
                            ))
                            .style(base.fg(Color::White)),
                            Cell::from(trunc(&text(c, "status"), 18)).style(base.fg(
                                if text(c, "state") == "running" {
                                    Color::Rgb(120, 220, 140)
                                } else {
                                    Color::Rgb(240, 160, 90)
                                },
                            )),
                            Cell::from(st("cpu", 7)).style(base.fg(grad(cpu / 100.0))),
                            Cell::from(st("mem_pct", 7)).style(base.fg(grad(mem / 100.0))),
                            {
                                let (used, _) = ctr_mem(&text(c, "mem"));
                                Cell::from(if used.is_empty() {
                                    format!("{:>10}", "-")
                                } else {
                                    format!("{used:>10}")
                                })
                                .style(base.fg(Color::Gray))
                            },
                            {
                                let (_, lim) = ctr_mem(&text(c, "mem"));
                                Cell::from(if lim.is_empty() {
                                    // No slash means no ceiling, which since
                                    // the caps came off is the normal case.
                                    format!("{:>10}", "none")
                                } else {
                                    format!("{lim:>10}")
                                })
                                .style(base.fg(DIM))
                            },
                            Cell::from(st("net", 19)).style(base.fg(Color::Rgb(120, 200, 255))),
                            Cell::from(st("block", 19)).style(base.fg(Color::Rgb(220, 140, 240))),
                            Cell::from(st("pids", 5)).style(base.fg(DIM)),
                            Cell::from(trunc(&text(c, "ports"), 30))
                                .style(base.fg(Color::Rgb(150, 170, 200))),
                            Cell::from(format!("{:>8}", text(c, "image_size"))).style(base.fg(Color::Gray)),
                            Cell::from(trunc(&text(c, "image"), 40)).style(base.fg(DIM)),
                        ])
                    })
                    .collect();
                let table = Table::new(
                    crows,
                    [
                        Constraint::Length(23),
                        Constraint::Length(19),
                        Constraint::Length(8),
                        Constraint::Length(8),
                        Constraint::Length(11),
                        Constraint::Length(11),
                        Constraint::Length(20),
                        Constraint::Length(20),
                        Constraint::Length(6),
                        Constraint::Length(31),
                        Constraint::Length(9),
                        Constraint::Min(12),
                    ],
                )
                // The ranked column is marked, exactly like the process
                // header: ←/→ moving a sort you cannot see is a gesture with
                // no feedback.
                .header(Row::new(
                    [
                        "CONTAINER", "STATUS", "CPU%", "MEM%", "MEM USED", "MEM MAX", "NET I/O",
                        "BLOCK I/O", "PIDS", "PORTS", "ON DISK", "IMAGE",
                    ]
                    .map(|h| {
                        if h == label {
                            Cell::from(format!("{h}{}", if self.ctr_desc { "▼" } else { "▲" }))
                                .style(
                                    Style::default()
                                        .fg(Color::Rgb(120, 200, 255))
                                        .add_modifier(Modifier::BOLD),
                                )
                        } else {
                            Cell::from(h).style(Style::default().fg(LABEL))
                        }
                    }),
                ));
                f.render_widget(table, cin);
            }
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} containers · {} of them · ↑↓ to move · enter for detail and actions",
                        cs.len(),
                        self.sel + 1
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── containers-i ──────────────────────────────────────────────────────
        // A container list answers "what is running". It cannot answer "what is
        // this costing me on disk", because the images nothing runs are exactly
        // the ones nobody notices — so those get their own tab and are called
        // out by name.
        if self.images {
            let (ilabel, _) = IMG_SORT[self.img_sort.min(IMG_SORT.len() - 1)];
            let ib = self.tabs_box(
                &format!(
                    "{ilabel}{} · ←→ rank · i inv · enter acts",
                    if self.img_desc { "▼" } else { "▲" }
                ),
            );
            let iin = ib.inner(rows[4]);
            f.render_widget(ib, rows[4]);
            let imgs = arr(&s, "images");
            if imgs.is_empty() {
                f.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        "  no images — nothing pulled here, or no docker this user can reach",
                        Style::default().fg(Color::Rgb(240, 160, 90)),
                    ))),
                    iin,
                );
            } else {

                let vis = (iin.height as usize).saturating_sub(1).max(1);
                self.sel = self.sel.min(imgs.len().saturating_sub(1));
                if self.sel < self.offset {
                    self.offset = self.sel;
                } else if self.sel >= self.offset + vis {
                    self.offset = self.sel + 1 - vis;
                }
                if self.offset + vis > imgs.len() {
                    self.offset = imgs.len().saturating_sub(vis);
                }
                let irows: Vec<Row> = self
                    .img_rows(&s)
                    .into_iter()
                    .enumerate()
                    .skip(self.offset)
                    .take(vis)
                    .map(|(n, i)| {
                        let sel = n == self.sel;
                        let base = if sel {
                            Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                        } else {
                            Style::default()
                        };
                        let full = format!("{}:{}", text(i, "repo"), text(i, "tag"));
                        let idle = Self::image_idle(&s, i);
                        Row::new(vec![
                            Cell::from(format!(
                                "{}{}",
                                if sel { "▶" } else { " " },
                                trunc(&full, 51)
                            ))
                            .style(base.fg(if idle { Color::Rgb(150, 140, 110) } else { Color::Gray })),
                            Cell::from(format!("{:>9}", text(i, "size"))).style(base.fg(Color::White)),
                            Cell::from(format!("{:>16}", text(i, "created"))).style(base.fg(DIM)),
                            Cell::from(text(i, "id")).style(base.fg(DIM)),
                            Cell::from(if idle { "nothing runs this" } else { "" })
                                .style(base.fg(Color::Rgb(240, 160, 90))),
                        ])
                    })
                    .collect();
                let itable = Table::new(
                    irows,
                    [
                        Constraint::Length(53),
                        Constraint::Length(10),
                        Constraint::Length(17),
                        Constraint::Length(14),
                        Constraint::Min(10),
                    ],
                )
                // The last column was headed with an empty string, so it could
                // never carry the ▼ marker and never said what it was. It is
                // the IN USE column; naming it does both.
                .header(Row::new(["IMAGE", "SIZE", "CREATED", "ID", "IN USE"].map(|h| {
                    if h == ilabel {
                        Cell::from(format!("{h}{}", if self.img_desc { "▼" } else { "▲" })).style(
                            Style::default()
                                .fg(Color::Rgb(120, 200, 255))
                                .add_modifier(Modifier::BOLD),
                        )
                    } else {
                        Cell::from(h).style(Style::default().fg(LABEL))
                    }
                })));
                f.render_widget(itable, iin);
            }
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} images · ↑↓ to move · enter for detail and actions",
                        arr(&s, "images").len()
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── firewall ──────────────────────────────────────────────────────────
        // The firewall cannot be read without root and this panel is
        // deliberately unprivileged, so it shows the two things it CAN see and
        // lets the gap between them be the finding: what cloud-infra declares
        // open, and what is actually bound here.
        if self.firewall {
            let fb = self.tabs_box("W back · ↑↓ scrolls");
            let fin = fb.inner(rows[4]);
            f.render_widget(fb, rows[4]);
            let mut l: Vec<Line> = vec![];
            let dec = storage::firewall_declared();
            let host = text(&s, "host_info.host");

            // WHAT IS BOUND, worst first. The address is the exposure: a port
            // on 0.0.0.0 reaches the internet, one on 127.x reaches nobody.
            let mut socks: Vec<&Value> = arr(&s, "listening").iter().collect();
            let rank = |x: &Value| match text(x, "scope").as_str() {
                "world" => 0,
                "mesh" => 1,
                _ => 2,
            };
            socks.sort_by(|a, b| rank(a).cmp(&rank(b)).then(num(a, "port").total_cmp(&num(b, "port"))));

            // The declared ingress for THIS machine, if it is in the fleet.
            // Keyed by the ssh alias the declaration uses, which is what
            // host_info.host reports on a peer.
            let rules: Vec<Value> = dec
                .as_ref()
                .and_then(|d| d.get("hosts"))
                .and_then(|h| h.get(&host).or_else(|| h.as_object()?.values().next()))
                .and_then(|r| r.as_array().cloned())
                .unwrap_or_default();
            let declared_ports: std::collections::HashSet<u64> =
                rules.iter().map(|r| num(r, "port") as u64).collect();

            l.push(Line::from(Span::styled(
                format!("listening on {host} — {} sockets", socks.len()),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            )));
            l.push(Line::from(Span::styled(
                "  PORT   ADDRESS            REACHES     DECLARED",
                Style::default().fg(LABEL),
            )));
            for sk in &socks {
                let scope = text(sk, "scope");
                let port = num(sk, "port") as u64;
                let known = declared_ports.contains(&port);
                // Only a WORLD-facing port needs declaring. Loopback and mesh
                // sockets are not ingress, and marking them undeclared would
                // bury the one line that matters under forty that do not.
                let (flag, fc) = match (scope.as_str(), known) {
                    ("world", false) => ("UNDECLARED", Color::Rgb(240, 100, 100)),
                    ("world", true) => ("declared", Color::Rgb(120, 220, 140)),
                    _ => ("—", DIM),
                };
                l.push(Line::from(vec![
                    Span::styled(format!("  {port:<6}"), Style::default().fg(Color::White)),
                    Span::styled(format!("{:<19}", trunc(&text(sk, "addr"), 18)), Style::default().fg(Color::Gray)),
                    Span::styled(
                        format!("{:<12}", scope),
                        Style::default().fg(match scope.as_str() {
                            "world" => Color::Rgb(240, 169, 66),
                            "mesh" => Color::Rgb(120, 200, 255),
                            _ => DIM,
                        }),
                    ),
                    Span::styled(flag, Style::default().fg(fc)),
                ]));
            }

            l.push(Line::from(""));
            l.push(Line::from(Span::styled(
                format!("declared ingress — {} rule(s)", rules.len()),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            )));
            if rules.is_empty() {
                l.push(Line::from(Span::styled(
                    "  no declaration for this machine — it is not in the fleet's firewall table",
                    Style::default().fg(DIM),
                )));
            }
            for r in &rules {
                let port = num(r, "port") as u64;
                // A declared port nothing is listening on is the other half of
                // the drift: a hole opened for a service that is not there.
                let bound = socks.iter().any(|sk| num(sk, "port") as u64 == port);
                l.push(Line::from(vec![
                    Span::styled(format!("  {port:<6}"), Style::default().fg(Color::White)),
                    Span::styled(format!("{:<5}", text(r, "proto")), Style::default().fg(DIM)),
                    Span::styled(format!("{:<19}", trunc(&text(r, "source"), 18)), Style::default().fg(Color::Gray)),
                    Span::styled(
                        format!("{:<11}", if bound { "bound" } else { "NOTHING BOUND" }),
                        Style::default().fg(if bound { Color::Rgb(120, 220, 140) } else { Color::Rgb(240, 160, 90) }),
                    ),
                    Span::styled(trunc(&text(r, "desc"), 52), Style::default().fg(DIM)),
                ]));
            }

            // The forward/NAT policy, which is fleet-wide rather than per-host.
            if let Some(g) = dec.as_ref().and_then(|d| d.get("global")) {
                l.push(Line::from(""));
                l.push(Line::from(Span::styled(
                    "global policy",
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                )));
                for k in ["forward_policy", "docker_iptables", "docker_subnet", "wg_subnet"] {
                    l.push(Line::from(vec![
                        Span::styled(format!("  {k:<18}"), Style::default().fg(LABEL)),
                        Span::styled(
                            g.get(k).map(|v| v.to_string()).unwrap_or_else(|| "—".into()),
                            Style::default().fg(Color::Gray),
                        ),
                    ]));
                }
            }

            let hmax = (l.len() as u16).saturating_sub(fin.height);
            self.detail_scroll = self.detail_scroll.min(hmax);
            f.render_widget(Paragraph::new(l).scroll((self.detail_scroll, 0)), fin);
            let world = socks.iter().filter(|x| text(x, "scope") == "world").count();
            let undecl = socks
                .iter()
                .filter(|x| text(x, "scope") == "world" && !declared_ports.contains(&(num(x, "port") as u64)))
                .count();
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} listening · {world} world-facing · {undecl} undeclared · nft needs root, this does not",
                        socks.len()
                    ),
                },
                Style::default().fg(if undecl > 0 { Color::Rgb(240, 160, 90) } else { LABEL }),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── history ───────────────────────────────────────────────────────────
        // What this machine actually did, rather than what it is doing. The
        // daemon keeps the series and computes the window; the panel only
        // renders it, so a peer would answer the same way if it kept one.
        if self.history {
            let hb = self.tabs_box("y back to processes");
            let hin = hb.inner(rows[4]);
            f.render_widget(hb, rows[4]);
            let win = num(&s, "history.window_s");
            let n = num(&s, "history.samples");
            let mut hl: Vec<Line> = vec![];
            if n < 2.0 {
                hl.push(Line::from(Span::styled(
                    "  no history yet — the daemon records one sample a minute, and needs two to measure anything",
                    Style::default().fg(Color::Rgb(240, 160, 90)),
                )));
                if !self.mesh.target().is_none() {
                    hl.push(Line::from(Span::styled(
                        "  (a peer collected over ssh keeps no history: it is sampled on demand, not continuously)",
                        Style::default().fg(DIM),
                    )));
                }
            } else {
                let row = |k: &str, v: String, per: String, c: Color| -> Line<'static> {
                    Line::from(vec![
                        Span::styled(format!("  {k:<22}"), Style::default().fg(LABEL)),
                        Span::styled(format!("{v:>12}"), Style::default().fg(c)),
                        Span::styled(format!("   {per}"), Style::default().fg(DIM)),
                    ])
                };
                let h = |k: &str| num(&s, &format!("history.{k}"));
                let hours = win / 3600.0;
                let rate = |b: f64| format!("{}/h", fmt_bytes_short(b / hours.max(0.01)));
                hl.push(Line::from(Span::styled(
                    format!(
                        "  covering {} · {} samples · one a minute",
                        fmt_uptime(win),
                        n as i64
                    ),
                    Style::default().fg(Color::Gray),
                )));
                hl.push(Line::from(""));
                hl.push(Line::from(Span::styled(
                    "moved",
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                )));
                hl.push(row("downloaded", fmt_bytes_short(h("net_rx_bytes")), rate(h("net_rx_bytes")), Color::Rgb(120, 200, 255)));
                hl.push(row("uploaded", fmt_bytes_short(h("net_tx_bytes")), rate(h("net_tx_bytes")), Color::Rgb(240, 169, 66)));
                hl.push(row("read from disk", fmt_bytes_short(h("disk_read_bytes")), rate(h("disk_read_bytes")), Color::Rgb(120, 220, 140)));
                hl.push(row("written to disk", fmt_bytes_short(h("disk_write_bytes")), rate(h("disk_write_bytes")), Color::Rgb(220, 140, 240)));
                hl.push(Line::from(""));
                hl.push(Line::from(Span::styled(
                    "held",
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                )));
                // Time-weighted, which is what a percentage averaged over a
                // day has to mean when it is sampled once a minute.
                let cpu_avg = h("cpu_pct_avg");
                hl.push(row(
                    "cpu, time-weighted",
                    format!("{cpu_avg:.2}%"),
                    format!("≈ {} of one core busy", fmt_uptime(cpu_avg / 100.0 * win)),
                    grad(cpu_avg / 100.0),
                ));
                let mem_avg = h("mem_pct_avg");
                hl.push(row("memory, time-weighted", format!("{mem_avg:.2}%"), String::new(), grad(mem_avg / 100.0)));
                let swap_avg = h("swap_pct_avg");
                hl.push(row("swap, time-weighted", format!("{swap_avg:.2}%"), String::new(), grad(swap_avg / 100.0)));
                hl.push(Line::from(""));
                hl.push(row(
                    "up",
                    fmt_uptime(num(&s, "totals.since_s")),
                    "since boot".into(),
                    Color::Gray,
                ));
                hl.push(Line::from(Span::styled(
                    "  counters that went backwards are treated as a reboot and not counted across",
                    Style::default().fg(DIM),
                )));

                // ── per day ───────────────────────────────────────────────
                // The block above is one rolling day. This is every day the
                // file still holds, which is what makes a number mean
                // anything: 40G downloaded is neither good nor bad until you
                // can see that yesterday was 4G.
                let days = arr(&s, "history.days");
                if !days.is_empty() {
                    hl.push(Line::from(""));
                    hl.push(Line::from(Span::styled(
                        format!("per day  ({} recorded, newest first)", days.len()),
                        Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                    )));
                    hl.push(Line::from(Span::styled(
                        "  DATE          COVERED     DOWN       UP     READ    WRITE     CPU%     MEM%    SWAP%",
                        Style::default().fg(LABEL),
                    )));
                    for d in days.iter().take(31) {
                        let g = |k: &str| num(d, k);
                        hl.push(Line::from(vec![
                            Span::styled(
                                format!("  {:<12}", text(d, "date")),
                                Style::default().fg(Color::White),
                            ),
                            Span::styled(
                                // A partial day is the normal case for today
                                // and for the oldest row, so say how much of
                                // one each total actually covers.
                                format!("{:>8}", fmt_uptime(g("seconds"))),
                                Style::default().fg(DIM),
                            ),
                            Span::styled(
                                format!("{:>9}", fmt_bytes_short(g("net_rx_bytes"))),
                                Style::default().fg(Color::Rgb(120, 200, 255)),
                            ),
                            Span::styled(
                                format!("{:>9}", fmt_bytes_short(g("net_tx_bytes"))),
                                Style::default().fg(Color::Rgb(240, 169, 66)),
                            ),
                            Span::styled(
                                format!("{:>9}", fmt_bytes_short(g("disk_read_bytes"))),
                                Style::default().fg(Color::Rgb(120, 220, 140)),
                            ),
                            Span::styled(
                                format!("{:>9}", fmt_bytes_short(g("disk_write_bytes"))),
                                Style::default().fg(Color::Rgb(220, 140, 240)),
                            ),
                            Span::styled(
                                format!("{:>9.1}", g("cpu_pct_avg")),
                                Style::default().fg(grad(g("cpu_pct_avg") / 100.0)),
                            ),
                            Span::styled(
                                format!("{:>9.1}", g("mem_pct_avg")),
                                Style::default().fg(grad(g("mem_pct_avg") / 100.0)),
                            ),
                            Span::styled(
                                format!("{:>9.1}", g("swap_pct_avg")),
                                Style::default().fg(grad(g("swap_pct_avg") / 100.0)),
                            ),
                        ]));
                    }
                    if days.len() > 31 {
                        hl.push(Line::from(Span::styled(
                            format!("  … {} older days, all of them in the export", days.len() - 31),
                            Style::default().fg(DIM),
                        )));
                    }
                }
            }
            // SCROLLS. The rolling-day block alone nearly fills this area, and
            // a month of per-day rows underneath it certainly does. The keys
            // were already wired to detail_scroll for this branch; the view
            // simply never applied it, so the extra rows would have been drawn
            // into a box that quietly cut them off.
            let hmax = (hl.len() as u16).saturating_sub(hin.height).max(0);
            self.detail_scroll = self.detail_scroll.min(hmax);
            f.render_widget(Paragraph::new(hl).scroll((self.detail_scroll, 0)), hin);
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => " last 24 hours, then per day · ↑↓ scrolls · h keys · ^c quits".to_string(),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── fleet ─────────────────────────────────────────────────────────────
        // The whole mesh in one table, instead of one machine in detail. Rows
        // come from the same collector the measure-a-peer path uses, so a peer
        // is described by its own /proc rather than by anything guessed here.
        // The storage mode of the fleet tab is not a peer table at all, so it
        // branches before the one below rather than growing a third shape into
        // it.
        if self.fleet && self.sub_name() == "storage" {
            let sb = self.tabs_box("what this fleet keeps · ↑↓ to move");
            let sin = sb.inner(rows[4]);
            f.render_widget(sb, rows[4]);
            let units = self.storage_rows();
            let units = &units;
            let colour = |kind: &str| match kind {
                "local" => Color::Rgb(120, 200, 255),
                "mount" => Color::Rgb(120, 220, 140),
                "s3" => Color::Rgb(120, 200, 255),
                "git" | "repo" => Color::Rgb(230, 190, 120),
                "gdrive" => Color::Rgb(200, 160, 240),
                _ => Color::Gray,
            };
            // SCROLLING, because this list is now long. Declared mounts plus
            // buckets plus two git hosts plus forty-five repositories does not
            // fit in eleven rows, and a cursor that walks past the bottom edge
            // into rows nobody can see is worse than no cursor.
            let vis = (sin.height as usize).saturating_sub(1).max(1);
            self.sel = self.sel.min(units.len().saturating_sub(1));
            if self.sel < self.offset {
                self.offset = self.sel;
            } else if self.sel >= self.offset + vis {
                self.offset = self.sel + 1 - vis;
            }
            if self.offset + vis > units.len() {
                self.offset = units.len().saturating_sub(vis);
            }
            let srows: Vec<Row> = units
                .iter()
                .enumerate()
                .skip(self.offset)
                .take(vis)
                .map(|(i, u)| {
                    let sel = i == self.sel;
                    let base = if sel {
                        Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default()
                    };
                    Row::new(vec![
                        Cell::from(format!("{}{}", if sel { "▶" } else { " " }, u.kind))
                            .style(base.fg(colour(u.kind))),
                        Cell::from(trunc(&u.name, 34)).style(base.fg(Color::White)),
                        Cell::from(trunc(&u.provider, 14)).style(base.fg(Color::Gray)),
                        Cell::from(trunc(&u.tier, 14)).style(base.fg(DIM)),
                        // The whole point of the tab: mounted, or not.
                        Cell::from(if u.at.is_empty() {
                            "—".to_string()
                        } else {
                            trunc(&u.at, 38)
                        })
                        .style(base.fg(if u.at.is_empty() {
                            DIM
                        } else {
                            Color::Rgb(120, 220, 140)
                        })),
                        Cell::from(trunc(&u.addr, 60)).style(base.fg(DIM)),
                    ])
                    .style(base)
                })
                .collect();
            let empty = units.is_empty();
            f.render_widget(
                Table::new(
                    srows,
                    [
                        Constraint::Length(8),
                        Constraint::Length(35),
                        Constraint::Length(15),
                        Constraint::Length(15),
                        Constraint::Length(39),
                        Constraint::Min(20),
                    ],
                )
                .header(Row::new(vec![
                    Cell::from("  KIND").style(Style::default().fg(LABEL)),
                    Cell::from("NAME").style(Style::default().fg(LABEL)),
                    Cell::from("PROVIDER").style(Style::default().fg(LABEL)),
                    Cell::from("TIER / TYPE").style(Style::default().fg(LABEL)),
                    Cell::from("MOUNTED AT").style(Style::default().fg(LABEL)),
                    Cell::from("ENDPOINT").style(Style::default().fg(LABEL)),
                ])),
                sin,
            );
            let mounted = units.iter().filter(|u| u.tier == "mounted").count();
            let repos = units.iter().filter(|u| u.kind == "repo").count();
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    match &self.msg {
                        Some((m, _)) => format!(" {m}"),
                        None if empty => " nothing declared here — cloud-infra is not on this machine".into(),
                        None => format!(
                            " {} units · {mounted} mounted · {}",
                            units.len() - repos,
                            if repos == 0 { "repos loading…".into() } else { format!("{repos} repos") }
                        ),
                    },
                    Style::default().fg(LABEL),
                ))),
                rows[5],
            );
            self.render_overlays(f, area);
            return;
        }
        if self.fleet {
            let (flabel, _) = FLEET_SORT[self.fleet_sort.min(FLEET_SORT.len() - 1)];
            let fb = self.tabs_box(&format!(
                "{flabel}{} · ←→ rank · i inv · enter opens a machine",
                if self.fleet_desc { "▼" } else { "▲" }
            ));
            let fin = fb.inner(rows[4]);
            f.render_widget(fb, rows[4]);
            let got = self.mesh.fleet();
            let peers = self.fleet_view(&s);
            let mut frows: Vec<Row> = vec![];
            if peers.is_empty() {
                // An empty table reads as "broken". Saying which network has
                // nothing on it — and that wg0 has no v6 at all — is the
                // whole reason these four tabs exist.
                let sb = TABS[self.tab].subs.get(self.sub[self.tab]);
                frows.push(Row::new(vec![Cell::from(Line::from(Span::styled(
                    match sb.and_then(|x| x.net) {
                        Some(pfx) => format!("  no peers answering on {pfx}*"),
                        None => format!("  {}", sb.map(|x| x.desc).unwrap_or("no addresses here")),
                    },
                    Style::default().fg(LABEL),
                )))]));
            }
            for (fi, p) in peers.iter().enumerate() {
                // Without this the cursor moves and nothing on screen says so,
                // which reads as arrow keys that do not work.
                let fsel = fi == self.sel;
                let base = if fsel {
                    Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };
                // This machine is described by the snapshot already on screen;
                // there is no reason to ssh to ourselves to learn it.
                let res = if p.local { Some(Ok(s.clone())) } else { got.get(&p.alias).cloned() };
                let snap = match &res {
                    Some(Ok(v)) => Some(v.clone()),
                    _ => None,
                };
                let name = Span::styled(
                    // 18 plus the cursor mark, for a 17-character name.
                    // "oci-analytics-pub" is exactly 17: widening the field to
                    // 17 stopped truncating it and left it welded to the
                    // address, because a value that fills its field leaves no
                    // separator behind it. The width has to exceed the longest
                    // name, not equal it.
                    format!("{}{:<18}", if fsel { "▶" } else { " " }, trunc(&p.alias, 17)),
                    base.fg(if p.local { Color::Rgb(120, 200, 255) } else { Color::White }),
                );
                let addr = Span::styled(format!("{:<16}", p.ip), base.fg(DIM));
                let Some(v) = snap else {
                    // Reachable but not yet collected, or not reachable at all
                    // — two different states and they must not read the same.
                    // Spans, not a second cell: the status is a sentence and
                    // the RTT column is eight characters wide, which turned
                    // "unreachable" into "unreacha".
                    frows.push(Row::new(vec![Cell::from(Line::from(vec![
                        name,
                        addr,
                        match &res {
                            // Reached and refused is not the same as not yet
                            // reached, and the reason is the useful part.
                            Some(Err(e)) => Span::styled(
                                trunc(e, 74),
                                Style::default().fg(Color::Rgb(240, 160, 90)),
                            ),
                            _ if p.local => Span::styled("—".to_string(), Style::default().fg(LABEL)),
                            _ if !p.probed => {
                                Span::styled("probing…".to_string(), Style::default().fg(LABEL))
                            }
                            _ if p.up => Span::styled(
                                "reachable · collecting…".to_string(),
                                Style::default().fg(LABEL),
                            ),
                            _ => Span::styled(
                                "unreachable".to_string(),
                                Style::default().fg(Color::Rgb(240, 72, 72)),
                            ),
                        },
                    ]))])
                    // The row carries the highlight, not the cells. This one
                    // is a single cell against twelve columns, so without it
                    // the bar stopped 56 characters in.
                    .style(base));
                    continue;
                };
                let g = |k: &str| num(&v, k);
                let pct = |x: f64| Cell::from(z(x, 5, format!("{x:>5.1}"))).style(base.fg(grad(x / 100.0)));
                let ncpu = arr(&v, "cores").len().max(1) as f64;
                let l1 = g("load1");
                frows.push(Row::new(vec![
                    Cell::from(Line::from(vec![name, addr])),
                    Cell::from(if p.local {
                        format!("{:>7}", "here")
                    } else if p.up {
                        format!("{:>6.0}ms", p.rtt_ms)
                    } else {
                        format!("{:>7}", "down")
                    })
                    .style(base.fg(DIM)),
                    pct(g("cpu")),
                    pct(g("mem")),
                    pct(g("swap")),
                    // Absent is not zero: most of this fleet has no readable
                    // GPU memory at all, and a 0% bar would claim a measurement.
                    {
                        let vg = |k: &str| -> Option<f64> {
                            let u = num_opt(&v, &format!("vram_detail.{k}.used"))?;
                            let t = num_opt(&v, &format!("vram_detail.{k}.total"))?;
                            if t > 0.0 { Some(u / t * 100.0) } else { None }
                        };
                        Cell::from(Line::from(vec![
                            Span::styled(
                                match vg("dedicated") {
                                    Some(x) => format!("{x:>5.1}"),
                                    None => format!("{:>5}", "-"),
                                },
                                Style::default().fg(grad(vg("dedicated").unwrap_or(0.0) / 100.0)),
                            ),
                            Span::styled(
                                match vg("shared") {
                                    Some(x) => format!(" {x:>5.1}"),
                                    None => format!(" {:>5}", "-"),
                                },
                                Style::default().fg(grad(vg("shared").unwrap_or(0.0) / 100.0)),
                            ),
                        ]))
                    },
                    Cell::from(format!("{:>6.1}G", num(&v, "mem_detail.total"))).style(base.fg(Color::Gray)),
                    // btrfs allocates in chunks and df cannot see that, so on a
                    // machine that publishes storage the pool figure is the
                    // true one; peers fall back to their own df.
                    pct(match arr(&v, "storage").first() {
                        Some(st) if num(st, "dev_size") > 0.0 => {
                            num(st, "alloc_used") / num(st, "dev_size") * 100.0
                        }
                        _ => g("disk"),
                    }),
                    // The same measurement as DISK%, in the unit you act on:
                    // "86%" tells you to look, "6.2G left of 45G" tells you
                    // whether it can wait. Same source as the percentage
                    // beside it — btrfs pool where there is one, df otherwise
                    // — so the two columns can never disagree.
                    Cell::from(match arr(&v, "storage").first() {
                        Some(st) if num(st, "dev_size") > 0.0 => {
                            format!("{:>7}", fmt_g(num(st, "alloc_used")))
                        }
                        _ => match arr(&v, "disks").first() {
                            Some(dk) => format!("{:>6.1}G", num(dk, "used_gib")),
                            None => format!("{:>7}", "-"),
                        },
                    })
                    .style(base.fg(Color::Gray)),
                    // All three loads, like uptime(1) — one number cannot tell
                    // a spike from a machine that has been buried for an hour.
                    Cell::from(Line::from(vec![
                        Span::styled(format!("{l1:>5.2}"), Style::default().fg(grad(l1 / ncpu))),
                        Span::styled(
                            format!(" {:>5.2} {:>5.2}", g("load5"), g("load15")),
                            Style::default().fg(Color::Gray),
                        ),
                    ])),
                    Cell::from(format!("{:>4.0}", ncpu)).style(base.fg(DIM)),
                    // some-cpu, full-io, full-mem at 10s: the three that
                    // actually tell you what a machine is stuck on. `full`
                    // for io and memory because that is every task stalled,
                    // which is the figure that tracked the freeze.
                    Cell::from(Line::from(vec![
                        Span::styled(
                            format!("{:>6.2}", g("psi.cpu.some10")),
                            Style::default().fg(grad(g("psi.cpu.some10") / 60.0)),
                        ),
                        Span::styled(
                            format!(" {:>6.2}", g("psi.io.full10")),
                            Style::default().fg(grad(g("psi.io.full10") / 20.0)),
                        ),
                        Span::styled(
                            format!(" {:>6.2}", g("psi.memory.full10")),
                            Style::default().fg(grad(g("psi.memory.full10") / 20.0)),
                        ),
                    ])),
                    Cell::from(format!("{:>6}", arr(&v, "proc_table").len())).style(base.fg(DIM)),
                ])
                // THE SELECTION BAR LIVES HERE, not on the cells.
                //
                // Cells were carrying it individually, so it broke at every
                // cell built from spans — VRAM, LOAD, PSI all style their
                // spans `Style::default().fg(..)` — and at the single space
                // of column_spacing between each pair. The result was a
                // highlight in stripes. A row style is painted across the
                // whole row first and a span that sets only `fg` patches over
                // it without clearing the background, so one line here fixes
                // every gap at once.
                .style(base));
            }
            // WHICH COLUMN IS RANKED HAS TO BE VISIBLE, or ←→ moves something
            // invisible. These columns are five characters wide holding
            // five-character numbers, with no room for a ▼ that does not push
            // a digit off the end — so the header LIGHTS UP instead, and the
            // hint along the bottom edge names the column and the direction.
            let fh = |txt: &str, name: &str| -> Cell<'static> {
                Cell::from(txt.to_string()).style(if flabel == name {
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(LABEL)
                })
            };
            let ftable = Table::new(
                frows,
                [
                    Constraint::Length(56), // peer + address + status
                    Constraint::Length(8),  // rtt
                    Constraint::Length(5),  // cpu
                    Constraint::Length(5),  // mem
                    Constraint::Length(5),  // swap
                    Constraint::Length(12), // vram d/s
                    Constraint::Length(7),  // ram total
                    Constraint::Length(5),  // disk %
                    Constraint::Length(7),  // disk used
                    Constraint::Length(17), // load 1/5/15
                    Constraint::Length(4),  // cores
                    Constraint::Length(20), // psi cpu/io/mem
                    Constraint::Length(6),  // procs
                ],
            )
            // WHICH COLUMN IS RANKED HAS TO BE VISIBLE, or ←→ moves something
            // invisible. These columns are five characters wide holding
            // five-character numbers, with no room for a ▼ that does not push
            // a digit off the end — so the header LIGHTS UP instead, and the
            // hint along the bottom edge names the column and the direction.
            .header(Row::new(vec![
                fh("PEER              ADDRESS", "PEER"),
                fh("     RTT", "RTT"),
                fh(" CPU%", "CPU%"),
                fh(" MEM%", "MEM%"),
                fh("SWAP%", "SWAP%"),
                fh("VRAM-d VRAM-s", ""),
                fh("    RAM", "RAM"),
                fh("DISK%", "DISK%"),
                fh("   DISK", "DISK%"),
                fh(" LOAD  1     5   15", "LOAD"),
                fh("CPUS", "CPUS"),
                fh("PSI cpu     io   mem", "PSI"),
                fh(" PROCS", "PROCS"),
            ]));
            f.render_widget(ftable, fin);
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} peers · ↑↓ to move · enter for the whole machine · swept every 20s",
                        peers.len()
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── processes ─────────────────────────────────────────────────────────
        // Sorted against the local clone `s`, so self stays free to mutate for
        // the scroll bookkeeping just below.
        let sorted = sort_procs(&s, self.sort, self.desc, self.win);
        let sorted: Vec<&Value> = if self.orphans || self.zombies {
            sorted.into_iter().filter(|p| Self::is_lost(p)).collect()
        } else {
            sorted
        };
        // Depth rides along even when the tree is off, so the row builder does
        // not need two shapes; it is simply 0 for every row.
        let procs: Vec<(&Value, usize)> = if self.tree {
            tree_order(&sorted, arr(&s, "proc_spine"))
        } else {
            sorted.iter().map(|p| (*p, 0usize)).collect()
        };
        // Follow the pid, not the row number. Re-sorting happens every tick and
        // the cursor must stay on the process the user chose, not on whatever
        // slid into that slot.
        if let Some(pid) = self.sel_pid {
            if let Some(i) = procs.iter().position(|(p, _)| num(p, "pid") as i64 == pid) {
                self.sel = i;
            }
        }
        let hint = format!(
            "{}{} · {} · {}{}←→ column · i inv · w win · t tree · x free · enter details · k act · h help",
            self.sort.label(),
            if self.desc { "▼" } else { "▲" },
            self.win.label(),
            if self.tree { "tree · " } else { "" },
            if self.orphans { "ORPHANS ONLY · " } else { "" },
        );
        let proc_b = self.tabs_box(&hint);
        let proc_in = proc_b.inner(rows[4]);
        f.render_widget(proc_b, rows[4]);

        // Keep the selection inside the viewport, scrolling only when it would
        // otherwise leave — a table that recentres on every tick is unreadable.
        let vis = (proc_in.height as usize).saturating_sub(1).max(1);
        // Declared units ride at the bottom of the same list, so the cursor
        // and the scroll window have to count them too — otherwise `v` shows
        // rows nothing can ever reach.
        let units = self.unit_rows(&s);
        let total = procs.len() + units.len();
        self.sel = self.sel.min(total.saturating_sub(1));
        if self.sel < self.offset {
            self.offset = self.sel;
        } else if self.sel >= self.offset + vis {
            self.offset = self.sel + 1 - vis;
        }
        if self.offset + vis > total {
            self.offset = total.saturating_sub(vis);
        }

        let w = self.win;
        let trows: Vec<Row> = procs
            .iter()
            .enumerate()
            .skip(self.offset)
            .take(vis)
            .map(|(i, (p, depth))| {
                let cpu = w.get(p, "cpu_pct");
                let memp = w.get(p, "mem_pct");
                let rss = w.get(p, "mem_rss_bytes");
                let rd = w.get(p, "read_bytes_per_s");
                let wr = w.get(p, "write_bytes_per_s");
                let rq = w.get(p, "runq_wait_pct");
                // The memory-stall counterpart to RUNQ. A major fault is a
                // page fetched back from disk, so this names the process that
                // is actually thrashing — the one thing this table could never
                // say before, however loud the psi box was.
                let mf = w.get(p, "majflt_per_s");
                // The average columns are fixed windows, NOT the `w` window:
                // the point of showing them beside the live value is comparing
                // the three, which a column that moved with `w` could not do.
                let a = |win: &str, field: &str| avg_or(p, win, field);
                let prot = p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false);
                let zombie = text(p, "state").starts_with('Z');
                // A spine row is an ancestor the daemon added to complete the
                // tree, not a measured process. It has a pid, a ppid and a
                // name and nothing else, so every metric cell stays blank.
                let spine = p.get("cpu_pct").is_none();
                // In tree mode the indent IS the parent/child relation, so it
                // goes in the name column where the eye already is.
                let name = format!(
                    "{}{}{}{}",
                    if self.tree && *depth > 0 { "  ".repeat(depth - 1) } else { String::new() },
                    if self.tree && *depth > 0 { "└ " } else { "" },
                    if prot { "🔒" } else { "" },
                    text(p, "name"),
                );
                let sel = i == self.sel;
                let base = if sel {
                    Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                } else if zombie {
                    // A zombie holds nothing but a pid and an exit code. It is
                    // never the thing eating the box, so it reads as debris.
                    Style::default().fg(Color::Rgb(240, 72, 72))
                } else if spine || prot {
                    Style::default().fg(DIM)
                } else {
                    Style::default()
                };
                if spine {
                    let mut c = vec![
                        Cell::from(format!("{}", num(p, "pid") as i64)).style(base),
                        Cell::from("").style(base),
                        Cell::from("").style(base),
                        Cell::from(name).style(base),
                    ];
                    c.extend((0..12).map(|_| Cell::from("").style(base)));
                    return Row::new(c);
                }
                Row::new(vec![
                    Cell::from(format!("{}", num(p, "pid") as i64)).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(text(p, "slice")).style(base.fg(if sel { Color::White } else { DIM })),
                    Cell::from(text(p, "user")).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(name).style(base),
                    Cell::from(zp(cpu, 5)).style(base.fg(grad(cpu / 100.0))),
                    Cell::from(zp(a("10s", "cpu_pct"), 5)).style(base.fg(grad(a("10s", "cpu_pct") / 100.0))),
                    Cell::from(zp(a("1m", "cpu_pct"), 5)).style(base.fg(grad(a("1m", "cpu_pct") / 100.0))),
                    Cell::from(zp(memp, 5)).style(base.fg(grad(memp / 100.0))),
                    Cell::from(zp(a("10s", "mem_pct"), 5)).style(base.fg(grad(a("10s", "mem_pct") / 100.0))),
                    Cell::from(zp(a("1m", "mem_pct"), 5)).style(base.fg(grad(a("1m", "mem_pct") / 100.0))),
                    Cell::from(fmt_mem_cell(rss)).style(base.fg(Color::Gray)),
                    // null when the daemon could not read another user's
                    // smaps_rollup. A dash, not a zero — we do not know.
                    Cell::from(match num_opt(p, "mem_pss_bytes") {
                        Some(v) => fmt_mem_cell(v),
                        None => "    —".into(),
                    })
                    .style(base.fg(Color::Rgb(150, 170, 200))),
                    Cell::from(fmt_bps(num(p, "net_rx_bytes_per_s"))).style(base.fg(Color::Rgb(120, 200, 255))),
                    Cell::from(fmt_bps(num(p, "net_tx_bytes_per_s"))).style(base.fg(Color::Rgb(240, 169, 66))),
                    Cell::from(fmt_bps(rd)).style(base.fg(Color::Rgb(120, 220, 140))),
                    Cell::from(fmt_bps(wr)).style(base.fg(Color::Rgb(220, 140, 240))),
                    // runq is a pressure share, not a load percentage: a
                    // tenth of a percent of stall time is still a real signal
                    // and keeps its digits.
                    Cell::from(z(rq, 5, format!("{rq:>5.2}"))).style(base.fg(grad(rq / 20.0))),
                    // 50/s is a machine in trouble, so that is where the
                    // gradient tops out — the same reasoning as runq at 20%.
                    Cell::from(z(mf, 6, format!("{mf:>6.0}"))).style(base.fg(grad(mf / 50.0))),
                ])
            })
            .collect();

        // Everything a unit row can honestly say: it has no pid, no rss and no
        // rates. Blanks rather than zeroes — a zero here would read as a
        // measurement, and there is nothing being measured.
        let mut trows = trows;
        let ustart = self.offset.saturating_sub(procs.len());
        for (j, u) in units.iter().enumerate().skip(ustart).take(vis.saturating_sub(trows.len())) {
            if let Some(h) = u.heading {
                let mut c = vec![
                    Cell::from("").style(Style::default()),
                    Cell::from("").style(Style::default()),
                    Cell::from("").style(Style::default()),
                    Cell::from(format!("── {h} ──"))
                        .style(Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD)),
                ];
                c.extend((0..13).map(|_| Cell::from("")));
                trows.push(Row::new(c));
                continue;
            }
            let (name, scope, state) = (&u.name, &u.scope, &u.state);
            let sel = procs.len() + j == self.sel;
            let failed = state.starts_with("failed");
            let base = if sel {
                Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(DIM)
            };
            // Dead-but-declared reads as a warning, not as debris: something
            // that is supposed to be running is not. Oneshots that already
            // exited, and units that are merely idle, stay quiet.
            let sc = if failed {
                Color::Rgb(240, 72, 72)
            } else if state.starts_with("inactive") || state.starts_with("not-loaded") {
                Color::Rgb(240, 160, 90)
            } else {
                Color::Rgb(120, 128, 145)
            };
            let mut cells = vec![
                Cell::from("  —").style(base),
                Cell::from(scope.clone()).style(base),
                Cell::from("—").style(base),
                Cell::from(format!("{}  {}", trunc(name, 34), state)).style(base.fg(sc)),
            ];
            cells.extend((0..13).map(|_| Cell::from("").style(base)));
            trows.push(Row::new(cells));
        }

        let hdr = |name: &'static str, k: Sort| -> Cell<'static> {
            if self.sort == k {
                Cell::from(format!("{name}{}", if self.desc { "▼" } else { "▲" }))
                    .style(Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD))
            } else {
                Cell::from(name).style(Style::default().fg(LABEL))
            }
        };
        let table = Table::new(
            trows,
            [
                Constraint::Length(7),  // PID
                Constraint::Length(9),  // SLICE
                Constraint::Length(8),  // USER
                Constraint::Min(12),    // PROGRAM
                Constraint::Length(5),  // CPU%
                Constraint::Length(5),  // C10s
                Constraint::Length(5),  // C60s
                Constraint::Length(5),  // MEM%
                Constraint::Length(5),  // M10s
                Constraint::Length(5),  // M60s
                Constraint::Length(5),  // RSS
                Constraint::Length(5),  // PSS
                Constraint::Length(6),  // D/s
                Constraint::Length(6),  // U/s
                Constraint::Length(6),  // R/s
                Constraint::Length(6),  // W/s
                Constraint::Length(5),  // RUNQ
                Constraint::Length(6),  // MAJF/s
            ],
        )
        .header(Row::new(vec![
            hdr("PID", Sort::Pid),
            hdr("SLICE", Sort::Slice),
            hdr("USER", Sort::User),
            hdr("PROGRAM", Sort::Name),
            hdr("CPU%", Sort::Cpu),
            hdr("C10s", Sort::C10s),
            hdr("C60s", Sort::C60s),
            hdr("MEM%", Sort::Mem),
            hdr("M10s", Sort::M10s),
            hdr("M60s", Sort::M60s),
            hdr("RSS", Sort::Rss),
            hdr("PSS", Sort::Pss),
            hdr("D/s", Sort::Net),
            hdr("U/s", Sort::Net),
            hdr("R/s", Sort::Disk),
            hdr("W/s", Sort::Disk),
            hdr("RUNQ", Sort::Runq),
            hdr("MAJF/s", Sort::Majflt),
        ]));
        f.render_widget(table, proc_in);

        // ── status line ───────────────────────────────────────────────────────
        let status = match &self.msg {
            Some((m, err)) => Line::from(Span::styled(
                format!(" {m}"),
                Style::default().fg(if *err { Color::Rgb(240, 72, 72) } else { Color::Rgb(120, 220, 140) }),
            )),
            None => Line::from(vec![
                Span::styled(
                    format!(" {} procs · showing {} values", procs.len(), self.win.label()),
                    Style::default().fg(LABEL),
                ),
                Span::styled(
                    "  · h keys · esc menu · ^c quits · drag to select text (no mouse capture)",
                    Style::default().fg(DIM),
                ),
            ]),
        };
        f.render_widget(Paragraph::new(status), rows[5]);

        // ── overlays ──────────────────────────────────────────────────────────
        self.render_overlays(f, area);
    }

}

// ─────────────────────────────────── checks ───────────────────────────────────
// The two pieces here that are not just layout: the braille rasteriser (an
// off-by-one in the height mapping silently draws every graph one sub-row low)
// and the sort/window pair (a missing `avg` block must fall back to the instant
// value, not sort the process to the bottom as a zero).
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // The whole point of the keybinding tables: a key cannot be advertised in
    // one place and handled in another, and it cannot collide with a key the
    // frame already took. "about" was bound to 'a' — listed in the tab strip
    // AND in the help, and swallowed by frame.rs for auto-refresh before the
    // dashboard ever saw it, so the view was simply unreachable. This fails if
    // that is ever true again.
    #[test]
    fn no_keybinding_collides_with_the_frame_or_itself() {
        let mut seen: Vec<(char, &str)> = Vec::new();
        for t in TABS {
            seen.push((t.key, t.name));
            for sb in t.subs {
                // A mode may share its tab's key on purpose: 'p' is both "the
                // proc tab" and "its normal mode", and they land in the same
                // place. Any OTHER duplicate is a real collision.
                if let Some(c) = sb.key {
                    if c != t.key {
                        seen.push((c, sb.name));
                    }
                }
            }
        }
        for (k, _, d) in SORT_KEYS {
            seen.push((*k, d));
        }
        // The single-character entries in OTHER_KEYS are real bindings too;
        // the multi-key ones ("← →", "pgup pgdn") describe non-char keys.
        for (sec, k, d) in OTHER_KEYS {
            // "modal" entries are scoped to an overlay; "frame" entries belong
            // to frame.rs and are listed here only so the help is complete.
            // Neither is a binding this dashboard dispatches.
            if *sec == "modal" || *sec == "frame" {
                continue;
            }
            let mut ch = k.chars();
            if let (Some(c), None) = (ch.next(), ch.next()) {
                seen.push((c, d));
            }
        }
        for (c, what) in &seen {
            assert!(
                !FRAME_RESERVED.contains(c),
                "{c:?} ({what}) is reserved by frame.rs — it would never reach this dashboard"
            );
        }
        for (i, (c, a)) in seen.iter().enumerate() {
            for (d, b) in seen.iter().skip(i + 1) {
                assert_ne!(c, d, "{c:?} is bound twice: {a} and {b}");
            }
        }
    }

    // ←/→ walks the header left to right and wraps. If step() ever clamped
    // instead, the two ends of the header would be dead keys.
    #[test]
    fn arrows_walk_the_sort_columns_and_wrap() {
        // Relative order, not fixed neighbours: every new column inserted in
        // the header used to break this test for no reason. What must hold is
        // that SORT_ORDER reads left to right the way the header does.
        let at = |k: Sort| SORT_ORDER.iter().position(|x| *x == k).expect("column is sortable");
        let header_order = [
            Sort::Pid, Sort::Slice, Sort::User, Sort::Name, Sort::Cpu,
            Sort::C10s, Sort::C60s, Sort::Mem, Sort::M10s, Sort::M60s,
            Sort::Pss, Sort::Net, Sort::Disk, Sort::Runq, Sort::Majflt,
        ];
        for w in header_order.windows(2) {
            assert!(at(w[0]) < at(w[1]), "{:?} must sort before {:?}", w[0], w[1]);
        }
        // and one step really is one column
        assert_eq!(SORT_ORDER[at(Sort::Cpu) + 1], Sort::Cpu.step(1));
        assert_eq!(Sort::Cpu.step(1).step(-1), Sort::Cpu);
        // wrap both ways off the ends
        assert_eq!(SORT_ORDER[0].step(-1), SORT_ORDER[SORT_ORDER.len() - 1]);
        assert_eq!(SORT_ORDER[SORT_ORDER.len() - 1].step(1), SORT_ORDER[0]);
        // ←→ is a round trip, i.e. it does not also flip the direction
        for k in SORT_ORDER {
            assert_eq!(k.step(1).step(-1), k);
        }
    }

    // Esc must never quit — the whole point of ^c/^d being the only exit —
    // and it must be CLAIMED, or frame.rs breaks on it before this dashboard
    // is asked. It opens help now rather than the menu: the first thing anyone
    // presses on an unfamiliar TUI is escape, and what they want then is the
    // list of keys, not a chooser. `m` is the menu.
    #[test]
    fn esc_is_claimed_and_opens_help_instead_of_quitting() {
        let mut m = Monitor::new();
        assert!(m.claims(KeyCode::Esc), "esc must not reach the frame's quit");
        assert!(!m.claims(KeyCode::Char('c')), "plain keys stay unclaimed while no modal is up");
        m.on_key(KeyCode::Esc);
        assert!(m.overlay == Overlay::Help, "esc opens help");
        m.on_key(KeyCode::Char('x'));
        m.on_key(KeyCode::Char('m'));
        assert!(m.overlay == Overlay::Menu, "m opens the main menu");
        assert!(!m.wants_quit());
        // While a modal is up it owns everything, so q closes it rather than
        // closing the program.
        assert!(m.claims(KeyCode::Char('q')));
        m.on_key(KeyCode::Char('q'));
        assert!(m.overlay == Overlay::None);
        assert!(!m.wants_quit());
    }

    // The menu's "quit" is the one path that may exit, and it can only do it
    // by asking the frame — a claimed key never reaches the frame's own quit.
    #[test]
    fn menu_quit_item_asks_the_frame_to_exit() {
        let mut m = Monitor::new();
        m.on_key(KeyCode::Char('m'));
        for _ in 0..MENU.len() - 1 {
            m.on_key(KeyCode::Down);
        }
        // Walked to the last entry, whatever the menu has grown to — the point
        // of the test is that quit exits, not where it happens to sit today.
        assert_eq!(MENU[m.menu_sel].0, "quit");
        m.on_key(KeyCode::Enter);
        assert!(m.wants_quit());
    }

    // RESTART rides the same mailbox as the signals but must not be sent as
    // one: the daemon branches on the literal word.
    #[test]
    fn restart_is_the_first_action_and_is_not_a_signal() {
        assert_eq!(ACTIONS[0].0, "RESTART");
        assert!(ACTIONS.iter().filter(|(n, _)| *n == "RESTART").count() == 1);
        // every other entry is a real signal name the daemon can map
        for (n, _) in ACTIONS.iter().skip(1) {
            assert!(n.chars().all(|c| c.is_ascii_uppercase()), "{n} is not a signal name");
        }
    }

    // The 10s/60s columns read fixed windows. If avg_or fell back to the live
    // value when a window exists, a spiking process would look sustained.
    #[test]
    fn average_columns_read_their_own_window() {
        let p: Value = serde_json::from_str(
            r#"{"cpu_pct": 90.0, "avg": {"10s": {"cpu_pct": 40.0}, "1m": {"cpu_pct": 5.0}}}"#,
        )
        .unwrap();
        assert_eq!(avg_or(&p, "10s", "cpu_pct"), 40.0);
        assert_eq!(avg_or(&p, "1m", "cpu_pct"), 5.0);
        // A window the daemon has not accumulated yet falls back to live
        // rather than showing a confident zero.
        assert_eq!(avg_or(&p, "15m", "cpu_pct"), 90.0);
    }

    const BLANK: char = '\u{2800}';

    #[test]
    fn braille_zero_is_a_baseline_and_full_is_solid() {
        // Zero is a flat baseline, not an empty box. Counting glyphs in btop's
        // own output says 85% of what it emits is exactly this character, and
        // it is what makes an idle graph read as a graph.
        const FLOOR: char = '\u{28C0}'; // dots 7,8 — the bottom sub-row
        let z = braille_graph(&vec![0.0; 8], 100.0, 4, 2);
        assert_eq!(z.len(), 2);
        for sp in &z[0].spans {
            assert_eq!(sp.content.chars().next().unwrap(), BLANK, "top row stays empty");
        }
        for sp in &z[1].spans {
            assert_eq!(sp.content.chars().next().unwrap(), FLOOR, "bottom row is the floor");
            // And it is GREY. Colouring the floor by its height is what made
            // the graph one continuous green band; btop spends the gradient
            // only where a value reaches.
            assert_eq!(sp.style.fg, Some(GRAPH_FLOOR), "the floor is not a value");
        }
        // Every dot set is U+28FF. A full-scale column must light the TOP row
        // too — that is the check that catches a height mapping that is short
        // by one sub-row, which looks plausible on screen but clips every peak.
        let f = braille_graph(&vec![100.0; 8], 100.0, 4, 2);
        for sp in &f[0].spans {
            assert_eq!(sp.content.chars().next().unwrap(), '\u{28FF}');
        }
    }

    #[test]
    fn braille_half_scale_fills_bottom_half_only() {
        let g = braille_graph(&vec![50.0; 4], 100.0, 2, 2);
        // rows=2 -> 8 sub-rows; 50% -> 4 lit from the bottom, so the top cell
        // row is empty and the bottom one is solid.
        for sp in &g[0].spans {
            assert_eq!(sp.content.chars().next().unwrap(), BLANK);
        }
        let _ = &g;
        for sp in &g[1].spans {
            assert_eq!(sp.content.chars().next().unwrap(), '\u{28FF}');
        }
    }

    #[test]
    fn graph_right_aligns_short_history() {
        // Two samples in a 4-column (8-slot) graph must sit at the RIGHT edge,
        // so a freshly started dashboard grows in instead of stretching.
        let g = braille_graph(&[100.0, 100.0], 100.0, 4, 1);
        let chars: Vec<char> = g[0].spans.iter().map(|s| s.content.chars().next().unwrap()).collect();
        // The empty part of the history is the floor, not nothing — but it is
        // still visibly not the data, which is the point of the check.
        assert_eq!(chars[0], '\u{28C0}');
        assert_eq!(chars[2], '\u{28C0}');
        assert_eq!(chars[3], '\u{28FF}');
        // grey where it is padding, coloured only where the samples are
        assert_eq!(g[0].spans[0].style.fg, Some(GRAPH_FLOOR));
        assert_ne!(g[0].spans[3].style.fg, Some(GRAPH_FLOOR));
    }

    fn snap() -> Value {
        json!({"proc_table": [
            {"pid": 1, "name": "beta",  "user": "root",  "cpu_pct": 5.0, "mem_pct": 1.0,
             "avg": {"10s": {"cpu_pct": 80.0, "mem_pct": 3.0},
                     "1m":  {"cpu_pct":  2.0, "mem_pct": 40.0},
                     "15m": {"cpu_pct": 90.0}}},
            {"pid": 2, "name": "alpha", "user": "diego", "cpu_pct": 50.0, "mem_pct": 20.0}
        ]})
    }

    #[test]
    fn sorts_by_cpu_desc_and_inverts() {
        let s = snap();
        let d = sort_procs(&s, Sort::Cpu, true, Win::Now);
        assert_eq!(num(d[0], "pid") as i32, 2);
        let a = sort_procs(&s, Sort::Cpu, false, Win::Now);
        assert_eq!(num(a[0], "pid") as i32, 1);
    }

    #[test]
    fn window_uses_average_and_falls_back_when_absent() {
        let s = snap();
        // pid 1 is quiet now but a 90% hog over 15m; pid 2 has no avg block at
        // all and must fall back to its instant 50, not be treated as zero.
        let v = sort_procs(&s, Sort::Cpu, true, Win::M15);
        assert_eq!(num(v[0], "pid") as i32, 1);
        assert_eq!(Win::M15.get(v[1], "cpu_pct"), 50.0);
    }

    #[test]
    fn sorts_by_name_as_text() {
        let s = snap();
        let v = sort_procs(&s, Sort::Name, false, Win::Now);
        assert_eq!(text(v[0], "name"), "alpha");
    }

    // The four average columns rank on their own fixed window: asking for C60s
    // must order by the 1m average even while the display is showing "now".
    #[test]
    fn average_columns_rank_on_their_own_window_not_the_display_one() {
        let s = snap();
        // pid 1: 10s cpu 80 / 1m cpu 2. pid 2 has no avg block, so it falls
        // back to its instant 50 for both.
        assert_eq!(num(sort_procs(&s, Sort::C10s, true, Win::Now)[0], "pid") as i32, 1);
        assert_eq!(num(sort_procs(&s, Sort::C60s, true, Win::Now)[0], "pid") as i32, 2);
        // and `w` does not move them
        assert_eq!(num(sort_procs(&s, Sort::C60s, true, Win::M15)[0], "pid") as i32, 2);
        // mem averages read mem_pct, not the rss bytes the MEM% column sorts on
        assert_eq!(num(sort_procs(&s, Sort::M10s, true, Win::Now)[0], "pid") as i32, 2);
        assert_eq!(num(sort_procs(&s, Sort::M60s, true, Win::Now)[0], "pid") as i32, 1);
    }

    // The YAML is hand-written, so the thing that can go wrong is quoting: a
    // string that looks like a number, a bool or a comment has to come back as
    // a string, and one that does not must stay bare or the whole point (token
    // count) is lost. Structure is checked at the same time, since a map value
    // that is itself a map has to start on the next line and a scalar must not.
    // A label that exactly FILLS its column welds itself to the description:
    //   esc  backspaceleave — backspacing past the colon also leaves
    // This has happened three times now — the help column twice and the fleet
    // peer name once — always by setting the width EQUAL to the longest value
    // instead of wider than it. The width is derived from these tables now, so
    // this asserts the derivation still leaves a gap.
    #[test]
    fn no_help_label_fills_its_column() {
        let kw = OTHER_KEYS
            .iter()
            .map(|(_, k, _)| k.chars().count())
            .chain(CMD_HELP.iter().map(|(k, _)| k.chars().count()))
            .chain(std::iter::once("m → options".chars().count()))
            .max()
            .unwrap()
            + 2;
        for (_, k, _) in OTHER_KEYS {
            assert!(k.chars().count() < kw, "{k:?} fills the {kw}-wide key column");
        }
        for (k, _) in CMD_HELP {
            assert!(k.chars().count() < kw, "{k:?} fills the {kw}-wide key column");
        }
    }

    // The help is the ONLY place anybody looks, so a key that works but is not
    // listed may as well not exist. Everything the panel dispatches outside an
    // overlay has to appear in one of the three tables the help is built from.
    #[test]
    fn every_dispatched_key_is_documented() {
        let listed = |c: char| -> bool {
            TABS.iter().any(|t| t.key == c || t.subs.iter().any(|sb| sb.key == Some(c)))
                || SORT_KEYS.iter().any(|(k, _, _)| *k == c)
                || OTHER_KEYS.iter().any(|(_, k, _)| k.contains(c))
        };
        // Every Char arm on_key handles with no overlay up.
        for c in ['.', ':', '?', 'h', 'i', 'j', 'k', 'm', 'o', 'v', 'w', 'x', 'E', 'A'] {
            assert!(listed(c), "{c:?} is dispatched but appears in no help table");
        }
        // The frame takes these before the panel is asked, and people still
        // need to know they exist.
        for c in FRAME_RESERVED {
            assert!(listed(*c), "{c:?} is reserved by the frame but undocumented");
        }
        // The ranges and named keys, which have no single char to look up.
        for k in ["1-9", "tab", "shift-tab", "space", "← →", "↑ ↓", "pgup pgdn", "home end"] {
            assert!(
                OTHER_KEYS.iter().any(|(_, x, _)| *x == k),
                "{k} is dispatched but has no line in the help"
            );
        }
    }

    // 1-9 changed meaning: they folded boxes away, now they pick sub-tabs.
    // Both halves matter — the new binding has to work, and the old one has to
    // be gone, or a key that used to hide the net box quietly moves the view.
    #[test]
    fn digits_pick_sub_tabs_and_no_longer_fold_boxes() {
        let mut m = Monitor::new();
        let before = m.show;

        m.on_key(KeyCode::Char('p'));
        m.on_key(KeyCode::Char('2'));
        assert!(m.tree, "2 is the proc tab's second sub-tab");
        assert_eq!(m.show, before, "digits must not touch box visibility any more");

        m.on_key(KeyCode::Char('3'));
        assert!(m.zombies && !m.tree, "3 is the third");

        // Out of range reports it rather than landing somewhere arbitrary.
        m.on_key(KeyCode::Char('9'));
        assert!(m.zombies, "9 is not a proc sub-tab, so nothing moves");

        // The boxes are still reachable — from the options screen the menu has
        // always said they were on.
        m.on_key(KeyCode::Char('m'));
        m.on_key(KeyCode::Down);
        m.on_key(KeyCode::Enter);
        assert!(m.overlay == Overlay::Boxes, "menu → options opens the box list");
        m.on_key(KeyCode::Char('1'));
        assert_ne!(m.show[0], before[0], "1 toggles the first box in there");
        assert!(m.overlay == Overlay::Boxes, "it stays open so you can fold several");
    }

    // The command language is the only place a typo can silently do the wrong
    // thing, so both halves are pinned: what must resolve, and what must NOT.
    #[test]
    fn the_command_line_resolves_names_numbers_and_prefixes() {
        let proc = tab_of("proc");
        let fleet = tab_of("fleet");

        // :f2 is the second sub-tab OF THE TAB YOU ARE ON, so the same text
        // means different things in different tabs — that is the point of it.
        assert_eq!(cmd::resolve("f2", proc), cmd::Cmd::Go(proc, Some(1)));
        assert_eq!(cmd::resolve("2", proc), cmd::Cmd::Go(proc, Some(1)));
        assert_eq!(cmd::resolve("f4", fleet), cmd::Cmd::Go(fleet, Some(3)));
        // Out of range says so rather than clamping to something plausible.
        assert!(matches!(cmd::resolve("f4", proc), cmd::Cmd::Err(_)));

        // A tab by name keeps the mode it was left on: None, not Some(0).
        assert_eq!(cmd::resolve("fleet", proc), cmd::Cmd::Go(fleet, None));
        // A sub-tab by name goes straight there from anywhere.
        assert_eq!(cmd::resolve("wg-public-ipv6", proc), cmd::Cmd::Go(fleet, Some(3)));
        assert_eq!(cmd::resolve("zombies", fleet), cmd::Cmd::Go(proc, Some(2)));

        // "files" starts with f and a digit-parse of "iles" must fail, or the
        // whole name space collapses into the :fN shortcut.
        assert_eq!(cmd::resolve("files", proc), cmd::Cmd::Go(tab_of("files"), None));

        // An unambiguous prefix is enough; an ambiguous one names the choices
        // instead of picking one.
        assert_eq!(cmd::resolve("wg-public-ipv4", proc), cmd::Cmd::Go(fleet, Some(2)));
        match cmd::resolve("wg-public", proc) {
            cmd::Cmd::Err(e) => assert!(e.contains("ambiguous"), "{e}"),
            other => panic!("wg-public matches two sub-tabs, got {other:?}"),
        }
        assert!(matches!(cmd::resolve("nonsense", proc), cmd::Cmd::Err(_)));

        assert_eq!(cmd::resolve("q", proc), cmd::Cmd::Quit);
        assert_eq!(cmd::resolve("export all", proc), cmd::Cmd::Export(true));
        assert_eq!(cmd::resolve("   ", proc), cmd::Cmd::Nothing);
    }

    // Sub-tabs are addressed by number in the strip and by index in the code;
    // an off-by-one between those is invisible until you press the key.
    #[test]
    fn every_sub_tab_is_addressable_by_its_displayed_number() {
        for (i, t) in TABS.iter().enumerate() {
            for (j, sb) in t.subs.iter().enumerate() {
                assert_eq!(
                    cmd::resolve(&format!("f{}", j + 1), i),
                    cmd::Cmd::Go(i, Some(j)),
                    "{}: {} is shown as {} but f{} does not reach it",
                    t.name,
                    sb.name,
                    j + 1,
                    j + 1
                );
            }
            // A tab with modes must have at least two, or the strip draws a
            // row to say there is one choice.
            assert_ne!(t.subs.len(), 1, "{} has a single sub-tab", t.name);
        }
    }

    fn tab_of(name: &str) -> usize {
        TABS.iter().position(|t| t.name == name).expect(name)
    }

    #[test]
    fn yaml_quotes_only_what_would_change_meaning() {
        let v = json!({
            "host": "surface-nixos",
            "version": "1.20",
            "flag": "true",
            "cmd": "sh -c x",
            "arg": "--no-tray",
            "note": "a: b",
            "empty": "",
            "cpu": 12.5,
            "on": true,
            "gone": null,
            "list": ["a", "b"],
            "nested": {"k": "v"},
            "blank": {},
        });
        let mut y = String::new();
        export::to_yaml(&v, 0, &mut y);

        // Bare: nothing here reparses as another type.
        assert!(y.contains("host: surface-nixos"), "{y}");
        // Quoted: these would come back as f64 / bool / a mapping / nothing.
        assert!(y.contains("version: \"1.20\""), "{y}");
        assert!(y.contains("flag: \"true\""), "{y}");
        assert!(y.contains("note: \"a: b\""), "{y}");
        assert!(y.contains("empty: \"\""), "{y}");
        // A leading '-' opens a sequence entry, so that one has to be quoted.
        assert!(y.contains("arg: \"--no-tray\""), "{y}");
        // ...but an interior dash is harmless, and quoting it would be exactly
        // the over-quoting this format exists to avoid.
        assert!(y.contains("cmd: sh -c x"), "{y}");
        // Non-strings are never quoted — they are already the right type.
        assert!(y.contains("cpu: 12.5") && y.contains("gone: null"), "{y}");
        // Blocks open on the next line, one space deeper; empties stay inline.
        assert!(y.contains("nested:\n k: v"), "{y}");
        assert!(y.contains("list:\n - a\n - b"), "{y}");
        assert!(y.contains("blank: {}"), "{y}");
    }
}
