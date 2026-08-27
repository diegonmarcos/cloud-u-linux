// Every key table. The help, the pickers and the dispatch all read these,
// so none of them can disagree about what is bound.
//
// Moved out of monitor/mod.rs, which had grown to 6007 lines. Same code,
// same order; only the file it lives in changed.
use crate::dashboards::monitor::data::sort::Sort;


/// What the `k` menu can send. RESTART is first because it is the thing people
/// actually want most of the time — a wedged process put back rather than a
/// hole where it used to be — and because listing it beside the signals is the
/// only way anyone discovers the daemon grew the verb.
///
/// It is not a signal: the daemon restarts a user systemd unit through
/// systemctl when the pid belongs to one, and otherwise re-execs its argv. The
/// blurb says which, because "restart" quietly meaning two different things is
/// worse than saying so.
pub(crate) const ACTIONS: [(&str, &str); 8] = [
    ("RESTART", "stop it and bring it back (unit, else re-exec argv)"),
    ("TERM", "polite stop, the default"),
    ("INT", "as if you pressed ctrl-c"),
    ("HUP", "reload, or stop if unhandled"),
    ("QUIT", "stop and dump core"),
    ("STOP", "freeze, unignorable"),
    ("CONT", "resume one you froze"),
    ("KILL", "unignorable, no cleanup"),
];

/// The `x` menu: things that give memory back, in increasing order of how
/// much they disturb.
///
/// Every one of them is a request on the same mailbox the signals use, so the
/// daemon applies the same protected-slice policy to all of them. The panel
/// decides nothing.
pub(crate) const FREE: [(&str, &str, &str); 3] = [
    (
        "REAP",
        "reap zombies",
        "SIGCHLD to each zombie's parent — one cannot be killed, only collected",
    ),
    (
        "RECLAIM",
        "reclaim session memory",
        "push this session's cold pages out — scoped, not system-wide drop_caches",
    ),
    (
        "ORPHANS",
        "list lost processes",
        "filter to processes reparented to init — look first, then k them",
    ),
];

/// The three things the big box can be. Naming them in the frame is the only
/// way anyone finds out the other two exist.
/// Keys the FRAME handles before a dashboard ever sees them.
///
/// frame.rs takes r and a for refresh and auto-refresh unless the dashboard
/// claims them, and it advertises both in its own header line. Binding one of
/// these in a view produces a key that is listed everywhere and works nowhere —
/// which is exactly what "about a" did. The test at the bottom of this file
/// fails if anything here is ever bound again.
///
/// `q` is on the list for a worse reason: frame.rs does not merely handle it,
/// it BREAKS on it. A view that bound q would not be dead, it would quit the
/// program — and quietly, since nothing else would look wrong. `:q` is the
/// deliberate route, and it goes through the command line rather than a key.
pub(crate) const FRAME_RESERVED: &[char] = &['r', 'a', 'q'];

/// The sort columns reachable by a single key.
///
/// PID is deliberately NOT here: 'p' is the proc tab, and a key that sorts in
/// one mode and switches view in another is exactly the ambiguity this table
/// exists to prevent. ←/→ still walks onto PID like every other column.
///
/// ONE table: the handler dispatches from it and the help renders from it, so
/// a key cannot be documented and unhandled, or handled and undocumented.
pub(crate) const SORT_KEYS: &[(char, Sort, &str)] = &[
    ('c', Sort::Cpu, "cpu"),
    ('M', Sort::Mem, "memory %"),
    ('d', Sort::Disk, "disk"),
    ('g', Sort::Runq, "run-queue wait"),
    ('n', Sort::Name, "name"),
    ('u', Sort::User, "user"),
    ('e', Sort::Net, "network"),
    ('s', Sort::Slice, "slice"),
];

/// Everything else this dashboard binds: key, section, what it does.
///
/// The views live in TABS and the sorts in SORT_KEYS because those two
/// tables are also the dispatch; this is the remainder, and the help is built
/// from all three rather than written a second time beside them.
pub(crate) const OTHER_KEYS: &[(&str, &str, &str)] = &[
    ("sorting", "← →", "move the sort to the next column, glances style"),
    ("sorting", "", "← → also reach C10s C60s M10s M60s and PSS"),
    ("sorting", "i", "invert the direction"),
    ("sorting", "w", "cycle the CPU%/MEM% window: now → 1m → 5m → 15m"),
    ("acting", "enter", "full disclosure — command, tree, cpu, mem, io, cgroup"),
    ("acting", "k", "act on it — restart, or any of the signals"),
    ("acting", "space", "in any menu: the same as enter"),
    // Was pushed straight into the help renderer instead of living here, so
    // the completeness test could not see it and neither could the collision
    // test. One table, like everything else.
    ("acting", "v", "append the declared units that are stopped or idle"),
    // "modal" entries are scoped to an overlay, so they may reuse a
    // top-level key: `o` opens a folder inside the detail view and switches
    // tab outside it, and the two can never both be live. The collision test
    // skips this section for that reason.
    ("modal", "o", "in the detail view: open the binary's folder"),
    ("modal", ".", "in the files tab: show or hide dotfiles"),
    ("acting", "x", "free memory — reap zombies, reclaim, find orphans"),
    ("acting", "E", "export THIS machine — {host}-{user}-{time}.json, .yaml, .md"),
    ("acting", "A", "export all — the same, with every fleet peer folded in"),
    ("moving", "1-9", "jump to a sub-tab by the number the strip shows"),
    ("moving", "j", "same as ↓, for the vim hand"),
    ("moving", "tab", "next sub-tab of this tab"),
    ("moving", "shift-tab", "previous sub-tab"),
    ("moving", "↑ ↓", "move the cursor through the list"),
    ("moving", "pgup pgdn", "ten rows at a time"),
    ("moving", "home end", "first / last row"),
    ("frame", "r", "refresh now (frame.rs, works in every dashboard)"),
    ("frame", "a", "auto-refresh on/off"),
    ("frame", "q", "quit — the frame takes this one before the panel sees it"),
    ("leaving", "esc", "the help page — it does NOT quit"),
    ("leaving", "m", "the main menu — measure, options, help, quit"),
    ("leaving", ":", "the command line — :f2 :fleet :wg-public-ipv6 :q"),
    ("leaving", "h ? F1", "this page"),
    ("leaving", "ctrl-c ctrl-d", "quit. the only keys that do"),
];

/// The `:` vocabulary. A table, so the width rule below can measure it and
/// the help cannot describe a command that does not exist.
pub(crate) const CMD_HELP: &[(&str, &str)] = &[
    ("", "type to filter — fuzzy, like fzf: :wg6 finds wg0-ipv6"),
    ("↑ ↓", "pick from the list above the prompt"),
    ("tab", "complete to the highlighted one without running it"),
    ("enter", "run the highlighted one, or the raw text if nothing matches"),
    (":f1 … :f9", "a sub-tab of this tab, by its number"),
    (":<tab>", "any tab by name — :fleet :files :about"),
    (":<sub-tab>", "any sub-tab by name — :tree :images :wg0-ipv4"),
    ("", "an unambiguous prefix is enough; :wg-public is not one"),
    (":e  :ea", "export this machine · export all, with every peer"),
    (":h  :q", "help · quit"),
    ("esc backspace", "leave — backspacing past the colon also leaves"),
];

/// The btop-style Esc menu.
pub(crate) const MENU: [(&str, &str); 4] = [
    ("measure", "this machine, or any mesh peer over ssh"),
    ("options", "sorting, averaging window, which boxes are shown"),
    ("help", "every key this dashboard binds"),
    ("quit", "leave the dashboard"),
];

/// Boxes that can be folded away. The two new sections plus net are the ones
/// worth trading for process rows on a short terminal; cpu/mem/proc are the
/// dashboard and stay.
pub(crate) const BOX_NAMES: [&str; 5] = ["storage", "net", "psi", "slices", "mesh"];
pub(crate) const B_STORAGE: usize = 0;
pub(crate) const B_NET: usize = 1;
pub(crate) const B_PSI: usize = 2;
pub(crate) const B_SLICES: usize = 3;
pub(crate) const B_MESH: usize = 4;
