// What order the process table is in, and which sample it is reading.
//
// Sort is the column; Win is which of the daemon's rolling averages fills the
// live cells. Two axes on purpose — "rank by the 60s average" and "show me 60s
// values" are different questions.
use serde_json::Value;

use crate::dashboards::monitor::data::{arr, num, text};

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Sort {
    Cpu,
    /// The four average columns rank on their own fixed window, independent of
    /// `w`. `w` retargets the live CPU%/MEM% columns; these four always mean
    /// what their header says, so "rank by C60s" is answerable without first
    /// putting the display into a particular mode.
    C10s,
    C60s,
    Mem,
    M10s,
    M60s,
    Rss,
    Pss,
    Net,
    Disk,
    Pid,
    Name,
    User,
    Slice,
    Runq,
    /// Major faults per second — who is thrashing.
    Majflt,
}

/// Left-to-right order of the sortable columns, so ←/→ walks the header the
/// way glances does rather than jumping around an enum's declaration order.
pub(crate) const SORT_ORDER: [Sort; 16] = [
    Sort::Pid,
    Sort::Slice,
    Sort::User,
    Sort::Name,
    Sort::Cpu,
    Sort::C10s,
    Sort::C60s,
    Sort::Mem,
    Sort::M10s,
    Sort::M60s,
    Sort::Rss,
    Sort::Pss,
    Sort::Net,
    Sort::Disk,
    Sort::Runq,
    Sort::Majflt,
];

impl Sort {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Sort::Cpu => "cpu",
            // Lowercased header names, so the box title names the same column
            // the ▼ marker is sitting on.
            Sort::C10s => "c10s",
            Sort::C60s => "c60s",
            Sort::Mem => "mem",
            Sort::M10s => "m10s",
            Sort::M60s => "m60s",
            Sort::Rss => "rss",
            Sort::Pss => "pss",
            Sort::Net => "net",
            Sort::Disk => "disk",
            Sort::Pid => "pid",
            Sort::Name => "name",
            Sort::User => "user",
            Sort::Slice => "slice",
            Sort::Runq => "runq",
            Sort::Majflt => "majflt",
        }
    }

    /// Step `d` columns along SORT_ORDER, wrapping. Wrapping rather than
    /// clamping because a sort cycle with dead ends at both edges is a worse
    /// answer than one you can spin.
    pub(crate) fn step(self, d: i32) -> Sort {
        let n = SORT_ORDER.len() as i32;
        let i = SORT_ORDER.iter().position(|x| *x == self).unwrap_or(0) as i32;
        SORT_ORDER[(((i + d) % n + n) % n) as usize]
    }
}

/// Which sample of a process to sort and display: the instant value the daemon
/// just measured, or one of the rolling averages it keeps. A 15m average is how
/// you tell a genuine hog from something that merely spiked while you looked.
#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Win {
    Now,
    M1,
    M5,
    M15,
}

impl Win {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Win::Now => "now",
            Win::M1 => "1m",
            Win::M5 => "5m",
            Win::M15 => "15m",
        }
    }
    pub(crate) fn next(self) -> Win {
        match self {
            Win::Now => Win::M1,
            Win::M1 => Win::M5,
            Win::M5 => Win::M15,
            Win::M15 => Win::Now,
        }
    }
    /// Read `field` from the chosen window, falling back to the instant value
    /// when the daemon has not accumulated that window for this pid yet.
    pub(crate) fn get(self, p: &Value, field: &str) -> f64 {
        match self {
            Win::Now => num(p, field),
            Win::M1 => avg_or(p, "1m", field),
            Win::M5 => avg_or(p, "5m", field),
            Win::M15 => avg_or(p, "15m", field),
        }
    }
}

/// Like num(), but keeps the difference between "zero" and "absent" —
/// mem_pss_bytes is null when the daemon could not read smaps_rollup, and
/// rendering that as 0 would claim a measurement nobody made.
pub(crate) fn num_opt(p: &Value, k: &str) -> Option<f64> {
    // Dotted, like num(): callers ask for "cpu_info.temp_c", not for a key
    // that literally contains a dot.
    let mut cur = p;
    for part in k.split('.') {
        cur = cur.get(part)?;
    }
    cur.as_f64()
}

pub(crate) fn avg_or(p: &Value, win: &str, field: &str) -> f64 {
    p.get("avg")
        .and_then(|a| a.get(win))
        .and_then(|w| w.get(field))
        .and_then(|v| v.as_f64())
        .unwrap_or_else(|| num(p, field))
}

/// Free function, not a method, on purpose: the returned refs borrow the
/// snapshot passed in, so render() can sort against its own local clone and
/// still mutate self.sel/self.offset for scrolling. As a `&self` method the
/// borrow would cover all of Monitor and neither caller would compile.
pub(crate) fn sort_procs<'a>(snap: &'a Value, sort: Sort, desc: bool, win: Win) -> Vec<&'a Value> {
    let mut v: Vec<&Value> = arr(snap, "proc_table").iter().collect();
    v.sort_by(|a, b| {
        let key = |p: &Value| -> f64 {
            match sort {
                Sort::Cpu => win.get(p, "cpu_pct"),
                // MEM% ranks by percentage and RSS by bytes. They agree on
                // one machine and stop agreeing the moment you measure a peer
                // with a different amount of RAM.
                Sort::Mem => win.get(p, "mem_pct"),
                Sort::Rss => win.get(p, "mem_rss_bytes"),
                Sort::Disk => win.get(p, "read_bytes_per_s") + win.get(p, "write_bytes_per_s"),
                Sort::Net => num(p, "net_rx_bytes_per_s") + num(p, "net_tx_bytes_per_s"),
                Sort::Pss => num(p, "mem_pss_bytes"),
                Sort::Runq => win.get(p, "runq_wait_pct"),
                Sort::Majflt => win.get(p, "majflt_per_s"),
                // Fixed windows, so these ignore `win` entirely. "1m" is the
                // daemon's label for the 60s bucket.
                Sort::C10s => avg_or(p, "10s", "cpu_pct"),
                Sort::C60s => avg_or(p, "1m", "cpu_pct"),
                Sort::M10s => avg_or(p, "10s", "mem_pct"),
                Sort::M60s => avg_or(p, "1m", "mem_pct"),
                Sort::Pid => num(p, "pid"),
                Sort::Name | Sort::User | Sort::Slice => 0.0,
            }
        };
        let ord = match sort {
            // Text columns sort as text; everything else numerically.
            Sort::Name => text(a, "name").to_lowercase().cmp(&text(b, "name").to_lowercase()),
            Sort::User => text(a, "user").to_lowercase().cmp(&text(b, "user").to_lowercase()),
            Sort::Slice => text(a, "slice").cmp(&text(b, "slice")),
            _ => key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal),
        };
        if desc { ord.reverse() } else { ord }
    });
    v
}

/// Re-orders an already-sorted list into parent-before-child order, returning
/// each row with its depth.
///
/// The published table is the top-N by CPU, so most parents are simply absent.
/// Anything whose ppid is not in the set is therefore a root — that keeps the
/// forest complete instead of silently dropping the majority of processes,
/// which is what anchoring on pid 1 would do here. Siblings keep the order the
/// sort column already put them in, so `t` re-groups the table without also
/// re-ranking it. Depth is capped so a deep chain cannot eat the name column.
pub(crate) fn tree_order<'a>(procs: &[&'a Value], spine: &'a [Value]) -> Vec<(&'a Value, usize)> {
    // The measured rows plus the daemon's spine — every ancestor of a measured
    // row, up to pid 1. Without the spine the forest bottoms out at whatever
    // happened to rank in the top-N and can never reach systemd; with it, each
    // process hangs off its real chain.
    let mut all: Vec<&Value> = procs.to_vec();
    let measured = procs.len();
    all.extend(spine.iter());

    let present: std::collections::HashSet<i64> =
        all.iter().map(|p| num(p, "pid") as i64).collect();
    let mut kids: std::collections::HashMap<i64, Vec<usize>> = std::collections::HashMap::new();
    let mut roots: Vec<usize> = vec![];
    for (i, p) in all.iter().enumerate() {
        let ppid = num(p, "ppid") as i64;
        if ppid != 0 && present.contains(&ppid) && ppid != num(p, "pid") as i64 {
            kids.entry(ppid).or_default().push(i);
        } else {
            roots.push(i);
        }
    }
    let _ = measured;
    let procs = &all;
    let mut out = Vec::with_capacity(procs.len());
    // Explicit stack, not recursion: a pid cycle would blow the real stack,
    // and `seen` makes one terminate instead of hanging the panel.
    let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut stack: Vec<(usize, usize)> = roots.into_iter().rev().map(|i| (i, 0)).collect();
    while let Some((i, depth)) = stack.pop() {
        if !seen.insert(i) {
            continue;
        }
        out.push((procs[i], depth.min(6)));
        if let Some(cs) = kids.get(&(num(procs[i], "pid") as i64)) {
            for &c in cs.iter().rev() {
                stack.push((c, depth + 1));
            }
        }
    }
    out
}

