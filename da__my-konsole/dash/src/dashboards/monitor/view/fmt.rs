// Every number that reaches the screen goes through here.
//
// One module because the rules are shared and easy to get subtly inconsistent
// otherwise: which unit a size uses, when a zero is a dash and when it is a
// measurement, how wide a column's value may be.
use crate::dashboards::monitor::data::HIST;

pub(crate) fn push(v: &mut Vec<f64>, x: f64) {
    v.push(x);
    if v.len() > HIST {
        v.remove(0);
    }
}

/// Zero is noise. A table where most cells read 0.0 hides the few that do
/// not, so a measured zero is drawn as a dash and only real values carry
/// digits.
///
/// Distinct from the em dash used for UNKNOWN (an unreadable smaps_rollup, a
/// unit row with nothing to measure): "-" means we looked and it was zero,
/// "—" means we could not look. Collapsing the two would be the easy thing
/// and would quietly turn "no permission" into "no activity".
/// A percentage cell. Anything under one percent is rounded to nothing: a
/// column of 0.1s and 0.4s is the same visual weight as a column of real
/// numbers and none of the information.
pub(crate) fn zp(v: f64, w: usize) -> String {
    if v < 1.0 { format!("{:>w$}", "-") } else { format!("{:>w$.1}", v) }
}

pub(crate) fn z(v: f64, w: usize, shown: String) -> String {
    if v == 0.0 { format!("{:>w$}", "-") } else { shown }
}

/// Memory is mebibytes. Always, everywhere, two decimals: "748.00 MiB".
///
/// One unit for every memory cell on every page. A column that slides to K
/// under a megabyte and to G over a gigabyte makes the eye rescale each row
/// before it can be compared with the one above, which is the entire job of a
/// memory column — and it is how "356KiB" ends up looking bigger than
/// "5.379MiB". Below a mebibyte there is nothing worth reading and this says
/// so with digits, not by changing units.
pub(crate) fn fmt_mib(bytes: f64) -> String {
    format!("{:.2} MiB", bytes.max(0.0) / 1_048_576.0)
}

/// The same cell from a gibibyte figure. /proc reports several of these in GiB
/// already, and converting at each call site is exactly how units drift apart.
pub(crate) fn fmt_mib_g(gib: f64) -> String {
    fmt_mib(gib * 1_073_741_824.0)
}

/// A memory cell in a table column, right aligned so the decimal points line
/// up. 12 wide holds a 64GiB total ("65536.00 MiB"); past that it grows and
/// the column grows with it rather than the number being cut.
pub(crate) fn fmt_mem_cell(bytes: f64) -> String {
    format!("{:>12}", fmt_mib(bytes))
}

/// Storage stays in gigabytes — a disk column and a memory column answer
/// different questions and are never read against each other.
pub(crate) fn fmt_gib(g: f64) -> String {
    if g >= 1.0 {
        format!("{g:.2}G")
    } else {
        format!("{:.0}M", g * 1024.0)
    }
}

pub(crate) fn fmt_rate_mb(mb: f64) -> String {
    if mb >= 1.0 {
        format!("{mb:.1}M/s")
    } else if mb >= 0.001 {
        format!("{:.0}K/s", mb * 1024.0)
    } else {
        "0".into()
    }
}

pub(crate) fn fmt_bps(b: f64) -> String {
    if b >= 1_048_576.0 {
        format!("{:.1}M", b / 1_048_576.0)
    } else if b >= 1024.0 {
        format!("{:.0}K", b / 1024.0)
    } else if b > 0.0 {
        format!("{b:.0}")
    } else {
        // Same dash as every other measured zero — a middot for one kind of
        // zero and a dash for another is a distinction with no meaning.
        "-".into()
    }
}

/// Storage, always in gigabytes to one decimal. A column that mixes "741.6M"
/// with "22.7G" makes the reader rescale every row before they can compare
/// two of them; "0.7G" beside "22.7G" compares at a glance. Disks are sized
/// in gigabytes and this is a disk column.
pub(crate) fn fmt_g(b: f64) -> String {
    format!("{:.1}G", b / 1_073_741_824.0)
}

/// A pages-per-second figure, short.
///
/// These run from single digits to hundreds of thousands during a reclaim
/// storm, and a column of raw integers that wide cannot be read at a glance.
/// PAGES, not bytes — that is what /proc/vmstat counts, and converting would
/// mean assuming a page size the dashboard has no way to ask for. The row
/// labels carry the unit.
pub(crate) fn fmt_rate(v: f64) -> String {
    if v < 1.0 {
        "-".into()
    } else if v < 1000.0 {
        format!("{v:.0}")
    } else if v < 1_000_000.0 {
        format!("{:.1}k", v / 1000.0)
    } else {
        format!("{:.1}M", v / 1_000_000.0)
    }
}

pub(crate) fn fmt_bytes_short(b: f64) -> String {
    const U: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut v = b;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{v:.0}{}", U[i]) } else { format!("{v:.1}{}", U[i]) }
}

pub(crate) fn fmt_uptime(secs: f64) -> String {
    let s = secs as u64;
    let (d, h, m) = (s / 86400, (s % 86400) / 3600, (s % 3600) / 60);
    if d > 0 { format!("{d}d {h:02}:{m:02}") } else { format!("{h:02}:{m:02}") }
}

// ─────────────────────────────── process table ────────────────────────────────

/// The directory holding a pid's binary. /proc/<pid>/exe is the resolved
/// link, so this survives an argv[0] that was never a path (an ld-linux
/// invocation, a renamed thread, a busybox applet).
/// Cut to `n` CHARACTERS, not bytes — a byte slice through a multibyte name
/// panics, and hostnames are not guaranteed ascii.
pub(crate) fn trunc(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { s.chars().take(n).collect() }
}

