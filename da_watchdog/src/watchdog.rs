// Style lints are allowed for this module, deliberately and narrowly.
//
// It is a verbatim move out of my-konsole: the code has been sampling this
// machine for months and it is the enforcement point for every kill, restart
// and unit verb a panel can ask for. Reflowing 2900 lines of it to satisfy
// `unnecessary_sort_by` and friends risks a real bug in the one file where a
// real bug means signalling the wrong process, and buys nothing but tidiness.
//
// Correctness lints are NOT allowed away — only style. New code here should
// still be written the way clippy wants; this is a moving allowance, not a
// standing one.
#![allow(
    clippy::empty_line_after_doc_comments,
    clippy::manual_contains,
    clippy::manual_is_multiple_of,
    clippy::needless_borrow,
    clippy::too_many_arguments,
    clippy::unnecessary_sort_by
)]

// watchdog.rs — ONE process reads the machine, everything else reads a file.
//
// This exists because of what the KDE panel cost. Fourteen
// org.kde.plasma.systemmonitor applets each build a sensor-face controller, a
// KQuickCharts scene graph and their own ksystemstats subscriptions, and
// plasmashell settled at ~24% CPU and 410MB of which 135MB was QML JS heap —
// on a panel showing eight numbers. Reading /proc was never the expensive
// part: ksystemstats, which actually does it, costs 2.5%. Fourteen QML
// sub-applications maintaining chart geometry is.
//
// Same shape as the fix that worked twice already today: the Claude status
// line went from a 4.6s jq slurp per paint to reading one published JSON, and
// my-ai's usage daemon went from 134MB to 13MB once one process did the work.
// So the tray daemon — which already runs permanently under Restart=always —
// samples once and writes a snapshot, and the panel widgets become Text
// elements over a Timer. Cost stops scaling with how many numbers you show.
use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

const INTERVAL_MS: u64 = 2_000;

/// The publish cadence, for anything that has to say it out loud (the tray
/// tooltip, `--help`) rather than guess it.
pub fn interval_ms() -> u64 {
    INTERVAL_MS
}

/// One snapshot, rendered and returned instead of published.
///
/// Every rate here is a delta between two samples, and this takes exactly one,
/// so the rate fields come back as zero. That is the honest result: it exists
/// to show the SHAPE of the contract — which keys, nested how — not to be read
/// for numbers. Anything that wants numbers should read the published file,
/// which is written by a loop that has a previous sample to subtract.

/// How many rows the process-table (`proc_table`) publishes, top-N by CPU%.
/// Data-driven via env rather than a bare literal: at 2s cadence the snapshot
/// is read by a widget's XMLHttpRequest on every tick, so the row count is a
/// direct trade against JSON size — an operator who wants a deeper table (or
/// a smaller one, on a machine with hundreds of processes) sets
/// MY_KONSOLE_PROCTABLE_N rather than editing and rebuilding this file.
fn proc_table_n() -> usize {
    std::env::var("MY_KONSOLE_PROCTABLE_N")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(40)
}

/// Slices the process-table's kill action must never signal into, no matter
/// which signal was requested — read fresh on every drain so an edit to the
/// file takes effect without restarting the daemon. Mirrors the
/// `protected_slices` notion in aa_desk-usr's cloud-data-disk-protection.json
/// (os-essentials.slice = ssh/wg/session/watchdog, connectivity.slice = the
/// freeze-guard island) — kept as a separate, unprivileged-readable copy
/// because that file is consumed by root-owned nix-generated systemd units
/// and this one is read by the per-user tray daemon straight off disk. Falls
/// back to the same two names if the file is missing/unparseable so a broken
/// sync never *widens* what can be killed.
/// Where the fleet policy lives, in the order it is looked for.
///
/// One file, one shape, every machine — the desktop and the VMs resolve the
/// same document, so "what limits this box" is answerable by reading it rather
/// than by grepping a flake per host. The desktop's own
/// cloud-data-system-protection.json is where the numbers came from; this is
/// that design, made portable.
fn policy_paths() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(h) = std::env::var_os("HOME") {
        let h = PathBuf::from(h);
        v.push(h.join(".config/my-watchdog/watchdog-policy.json"));
        v.push(h.join(".local/share/my-konsole/watchdog-policy.json"));
    }
    v.push(PathBuf::from("/etc/my-watchdog/watchdog-policy.json"));
    v
}

fn read_policy() -> Option<String> {
    policy_paths().into_iter().find_map(|p| fs::read_to_string(p).ok())
}

/// Pull one array out of a JSON document by key.
///
/// Hand-parsed rather than pulling serde_json in for this: the crate is std +
/// libc precisely so the fleet build stays a static musl binary with no
/// dependency that could drag libc back in, and the policy is read once per
/// kill request from a file this user owns.
fn json_array(body: &str, key: &str) -> Vec<String> {
    let Some(start) = body.find(&format!("\"{key}\"")) else { return vec![] };
    let Some(open) = body[start..].find('[') else { return vec![] };
    let Some(close) = body[start + open..].find(']') else { return vec![] };
    body[start + open + 1..start + open + close]
        .split(',')
        .filter_map(|tok| {
            let t = tok.trim().trim_matches('"').trim();
            if t.is_empty() { None } else { Some(t.to_string()) }
        })
        .collect()
}

fn load_protected_slices() -> Vec<String> {
    let fallback = || vec!["os-essentials.slice".to_string(), "connectivity.slice".to_string()];
    // The fleet policy first: it is the single source of truth, and a machine
    // that has it should not also be reading a per-host copy that can drift.
    if let Some(body) = read_policy() {
        let names = json_array(&body, "slices");
        if !names.is_empty() {
            return names;
        }
    }
    let Some(home) = std::env::var_os("HOME") else { return fallback() };
    let path = PathBuf::from(home).join(".local/share/my-konsole/protected-slices.json");
    let Ok(body) = fs::read_to_string(&path) else { return fallback() };
    // Hand-parse rather than pull in serde_json for one array: find
    // "protected_slices": [ ... ] and split its quoted entries.
    let Some(start) = body.find("\"protected_slices\"") else { return fallback() };
    let Some(open) = body[start..].find('[') else { return fallback() };
    let Some(close) = body[start + open..].find(']') else { return fallback() };
    let inner = &body[start + open + 1..start + open + close];
    let names: Vec<String> = inner
        .split(',')
        .filter_map(|tok| {
            let t = tok.trim().trim_matches('"');
            if t.is_empty() { None } else { Some(t.to_string()) }
        })
        .collect();
    if names.is_empty() { fallback() } else { names }
}

/// Which protected slice (if any) a pid's cgroup places it in, read from
/// /proc/<pid>/cgroup. Returns the matched slice name so the caller can show
/// *why* a process is not killable rather than just refusing silently.
fn proc_protected_slice(pid: i32, protected: &[String]) -> Option<String> {
    let s = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
    for line in s.lines() {
        for name in protected {
            if line.contains(name.as_str()) {
                return Some(name.clone());
            }
        }
    }
    None
}

/// Which slice of the `slices` box a pid is accounted to, without the
/// ".slice" suffix — "user-1000", "system", "os".
///
/// A cgroup path has several .slice components and only one of them is the
/// answer: /user.slice/user-1000.slice/user@1000.service/app.slice/app-x.scope
/// yields [user, user-1000, app], and it is the SECOND that the accounting
/// (and the slices box) is keyed on, not the generic "user" above it or the
/// "app" grouping below. Second-if-present, else first, reproduces that for
/// /system.slice/foo.service and /os.slice/... alike.
fn proc_slice(pid: i32) -> String {
    // A kernel thread is in no slice because it is not a service — it is part
    // of the kernel. An empty cell there reads as "we failed to look it up",
    // which is the wrong story: an empty cmdline is how you tell.
    if fs::read(format!("/proc/{pid}/cmdline")).map(|c| c.is_empty()).unwrap_or(false) {
        return "kernel".into();
    }
    let Ok(s) = fs::read_to_string(format!("/proc/{pid}/cgroup")) else { return String::new() };
    let Some(path) = s.lines().next().and_then(|l| l.rsplit(':').next()) else { return String::new() };
    let parts: Vec<&str> = path.split('/').filter(|c| c.ends_with(".slice")).collect();
    parts
        .get(1)
        .or(parts.first())
        .map(|c| c.trim_end_matches(".slice").to_string())
        .unwrap_or_default()
}

/// Where the runtime files live.
///
/// XDG_RUNTIME_DIR first, then /run/user/<uid>, then /tmp.
///
/// The fallbacks are not defensive padding — they are the headless case, which
/// is the one this binary exists for. A non-interactive ssh session gets no
/// XDG_RUNTIME_DIR at all, so relying on it alone meant the sampler started
/// happily on every VM, logged one line nobody was reading, and published
/// nothing. It looked exactly like a working deployment.
fn runtime_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("XDG_RUNTIME_DIR") {
        let p = PathBuf::from(d);
        if p.is_dir() {
            return p;
        }
    }
    let uid = current_uid();
    let p = PathBuf::from(format!("/run/user/{uid}"));
    if p.is_dir() {
        return p;
    }
    // Last resort. /tmp is world-writable, so the file is created with the
    // process umask and its name carries the uid — two processes for different
    // users on one box must not fight over one path.
    PathBuf::from(format!("/tmp/my-konsole-{uid}"))
}

pub fn snapshot_path() -> Option<PathBuf> {
    let d = runtime_dir();
    let _ = fs::create_dir_all(&d);
    Some(d.join("my-konsole-watchdog.json"))
}

// /proc/stat's cpu line is cumulative since boot, so a percentage needs two
// samples. Kept between ticks rather than sleeping inside the reader.
#[derive(Default, Clone, Copy)]
struct CpuTotals {
    idle: u64,
    total: u64,
    // The individual modes, kept alongside idle/total so "23% busy" can be
    // broken into WHY it is busy. A single busy percentage cannot tell a CPU
    // pegged in userspace apart from one drowning in iowait, and those two
    // want completely different responses from whoever is reading the panel.
    user: u64,
    nice: u64,
    system: u64,
    iowait: u64,
    irq: u64,
    steal: u64,
}

fn parse_cpu_line(line: &str) -> CpuTotals {
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    let g = |i: usize| v.get(i).copied().unwrap_or(0);
    // user nice system idle iowait irq softirq steal …
    // idle here is idle+iowait, which is the conventional definition of "not
    // doing work" for a busy percentage — iowait is still surfaced on its own
    // below, because for a breakdown it is very much not the same as idle.
    let idle = g(3) + g(4);
    CpuTotals {
        idle,
        total: v.iter().sum(),
        user: g(0),
        nice: g(1),
        // softirq folded into system: both are kernel time, and a separate
        // bar for a number that is almost always a rounding error is a bar
        // nobody reads.
        system: g(2) + g(6),
        iowait: g(4),
        irq: g(5),
        steal: g(7),
    }
}

/// Each mode's share of the elapsed jiffies, as percentages. Same two-sample
/// delta as cpu_percent() — these are cumulative counters, not gauges.
fn cpu_breakdown_json(prev: CpuTotals, now: CpuTotals) -> String {
    let dt = now.total.saturating_sub(prev.total);
    let pct = |a: u64, b: u64| {
        if dt == 0 { 0.0 } else { a.saturating_sub(b) as f64 / dt as f64 * 100.0 }
    };
    format!(
        "{{\"user\":{:.1},\"nice\":{:.1},\"system\":{:.1},\"iowait\":{:.1},\"irq\":{:.1},\"steal\":{:.1}}}",
        pct(now.user, prev.user),
        pct(now.nice, prev.nice),
        pct(now.system, prev.system),
        pct(now.iowait, prev.iowait),
        pct(now.irq, prev.irq),
        pct(now.steal, prev.steal),
    )
}

/// Aggregate plus one entry per core. The panel wants per-core bars, and
/// /proc/stat already carries them — sampling the aggregate separately would
/// read the same file twice for numbers that must agree.
fn read_cpu_all() -> (CpuTotals, Vec<CpuTotals>) {
    let Ok(s) = fs::read_to_string("/proc/stat") else { return (CpuTotals::default(), Vec::new()) };
    let mut agg = CpuTotals::default();
    let mut cores = Vec::new();
    for l in s.lines() {
        if !l.starts_with("cpu") {
            break; // the cpu* lines are contiguous and first
        }
        if l.starts_with("cpu ") {
            agg = parse_cpu_line(l);
        } else {
            cores.push(parse_cpu_line(l));
        }
    }
    (agg, cores)
}

fn cpu_percent(prev: CpuTotals, now: CpuTotals) -> f64 {
    let dt = now.total.saturating_sub(prev.total);
    if dt == 0 {
        return 0.0;
    }
    let di = now.idle.saturating_sub(prev.idle);
    ((dt.saturating_sub(di)) as f64 / dt as f64) * 100.0
}

// Pure parse of /proc/meminfo's kB fields, kept separate from the file read so
// it can be exercised with sample text in tests without touching the real
// filesystem.
#[derive(Default, Debug, PartialEq)]
struct MemInfoRaw {
    total_kb: f64,
    free_kb: f64,
    avail_kb: f64,
    buffers_kb: f64,
    cached_kb: f64,
    sreclaimable_kb: f64,
    sunreclaim_kb: f64,
    shmem_kb: f64,
    anon_kb: f64,
    mapped_kb: f64,
    dirty_kb: f64,
    writeback_kb: f64,
    kernel_stack_kb: f64,
    page_tables_kb: f64,
    swap_total_kb: f64,
    swap_free_kb: f64,
    swap_cached_kb: f64,
    zswap_kb: f64,
    zswapped_kb: f64,
    commit_limit_kb: f64,
    committed_kb: f64,
}

fn parse_meminfo(s: &str) -> MemInfoRaw {
    let kv = |k: &str| -> f64 {
        s.lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    MemInfoRaw {
        total_kb: kv("MemTotal:"),
        free_kb: kv("MemFree:"),
        avail_kb: kv("MemAvailable:"),
        buffers_kb: kv("Buffers:"),
        cached_kb: kv("Cached:"),
        sreclaimable_kb: kv("SReclaimable:"),
        sunreclaim_kb: kv("SUnreclaim:"),
        shmem_kb: kv("Shmem:"),
        anon_kb: kv("AnonPages:"),
        mapped_kb: kv("Mapped:"),
        dirty_kb: kv("Dirty:"),
        writeback_kb: kv("Writeback:"),
        kernel_stack_kb: kv("KernelStack:"),
        page_tables_kb: kv("PageTables:"),
        swap_total_kb: kv("SwapTotal:"),
        swap_free_kb: kv("SwapFree:"),
        swap_cached_kb: kv("SwapCached:"),
        zswap_kb: kv("Zswap:"),
        zswapped_kb: kv("Zswapped:"),
        commit_limit_kb: kv("CommitLimit:"),
        committed_kb: kv("Committed_AS:"),
    }
}

fn kb_to_gib(kb: f64) -> f64 {
    kb / 1_048_576.0
}

/// Everything the panel wants out of /proc/meminfo in one read: the two
/// legacy percentages plus the pie-chart detail objects. `used` in
/// mem_detail is defined as total-available (the honest "not reclaimable"
/// figure), not total-free — free alone ignores buffers/cache the kernel
/// would hand back under pressure, which is exactly the number that used to
/// make this box look worse than it was.
fn meminfo_all() -> (f64, f64, String, String) {
    let s = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let raw = parse_meminfo(&s);

    let mem_pct = if raw.total_kb > 0.0 { (raw.total_kb - raw.avail_kb) / raw.total_kb * 100.0 } else { 0.0 };
    let swap_pct =
        if raw.swap_total_kb > 0.0 { (raw.swap_total_kb - raw.swap_free_kb) / raw.swap_total_kb * 100.0 } else { 0.0 };

    let g = kb_to_gib;
    let total = g(raw.total_kb);
    let available = g(raw.avail_kb);
    let used = total - available;
    let buffers = g(raw.buffers_kb);
    // "cached" as every tool means it: page cache plus the reclaimable half of
    // slab. Shmem/tmpfs sits inside Cached but is NOT reclaimable (it has no
    // backing store to write back to), so it is published separately rather
    // than left hiding inside a number people read as "free if needed".
    let cached = g(raw.cached_kb + raw.sreclaimable_kb);
    let free = g(raw.free_kb);
    let shmem = g(raw.shmem_kb);
    let anon = g(raw.anon_kb);
    // Kernel memory no reclaim can touch: unreclaimable slab, kernel stacks,
    // page tables. When `used` climbs with no process to blame, it is here.
    let kernel = g(raw.sunreclaim_kb + raw.kernel_stack_kb + raw.page_tables_kb);
    let mem_detail = format!(
        "{{\"total\":{total:.2},\"used\":{used:.2},\"buffers\":{buffers:.2},\
          \"cached\":{cached:.2},\"free\":{free:.2},\"available\":{available:.2},\
          \"shmem\":{shmem:.2},\"anon\":{anon:.2},\"mapped\":{:.2},\"kernel\":{kernel:.2},\
          \"slab_reclaimable\":{:.2},\"slab_unreclaimable\":{:.2},\"page_tables\":{:.2},\
          \"kernel_stack\":{:.2},\"dirty\":{:.3},\"writeback\":{:.3},\
          \"commit_limit\":{:.2},\"committed\":{:.2}}}",
        g(raw.mapped_kb),
        g(raw.sreclaimable_kb),
        g(raw.sunreclaim_kb),
        g(raw.page_tables_kb),
        g(raw.kernel_stack_kb),
        g(raw.dirty_kb),
        g(raw.writeback_kb),
        g(raw.commit_limit_kb),
        g(raw.committed_kb),
    );

    // Swap is its own store, not a section of RAM: keeping its free/cached
    // here (rather than folding used-swap into mem) is what stops the panel
    // double-counting a page that is in both places at once. SwapCached is
    // exactly that overlap — swapped out AND still resident.
    let swap_total = g(raw.swap_total_kb);
    let swap_free = g(raw.swap_free_kb);
    let swap_used = swap_total - swap_free;
    let swap_detail = format!(
        "{{\"total\":{swap_total:.2},\"used\":{swap_used:.2},\"free\":{swap_free:.2},\
          \"cached\":{:.2},\"zswap\":{:.3},\"zswapped\":{:.2}}}",
        g(raw.swap_cached_kb),
        g(raw.zswap_kb),
        g(raw.zswapped_kb),
    );

    (mem_pct, swap_pct, mem_detail, swap_detail)
}

// PSI is the number that actually predicts a stall, and no stock KSysGuard
// sensor exposes it — /proc/pressure has no KSystemStats backend, which is why
// the old top panel faked it with diskusage widgets pointed at pressure paths
// and mislabelled titles. Read it directly instead.
//
// BOTH lines, because the panel this replaces displayed both: one widget
// carried pressure/{cpu,io,memory}/some10Sec and another carried the full10Sec
// variants. `some` is "at least one task stalled", `full` is "every task
// stalled" — on a box that thrashes, full is the one that means the machine
// stopped, so dropping it would lose the more alarming number.
fn pressure(kind: &str, line: &str, window: &str) -> f64 {
    fs::read_to_string(format!("/proc/pressure/{kind}"))
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with(line))?
                .split_whitespace()
                .find_map(|f| f.strip_prefix(window)?.parse::<f64>().ok())
        })
        .unwrap_or(0.0)
}

/// One kind's full picture: some/full across all three windows the kernel
/// keeps. The panel shows avg10 as the live bar and avg60 as the "1 min"
/// reading, and there is no cost to publishing avg300 alongside.
fn pressure_block(kind: &str) -> String {
    let g = |l: &str, w: &str| pressure(kind, l, w);
    format!(
        "{{\"some10\":{:.2},\"some60\":{:.2},\"some300\":{:.2},\
          \"full10\":{:.2},\"full60\":{:.2},\"full300\":{:.2}}}",
        g("some", "avg10="), g("some", "avg60="), g("some", "avg300="),
        g("full", "avg10="), g("full", "avg60="), g("full", "avg300=")
    )
}

/// Top processes by RSS, for the expanded view's killable table. Read straight
/// from /proc rather than forking ps every 2s — this runs forever.
fn top_procs(n: usize) -> String {
    let mut v: Vec<(u64, i32, String)> = Vec::new();
    let Ok(rd) = fs::read_dir("/proc") else { return "[]".into() };
    for e in rd.flatten() {
        let name = e.file_name();
        let Some(nm) = name.to_str() else { continue };
        let Ok(pid) = nm.parse::<i32>() else { continue };
        let Ok(st) = fs::read_to_string(format!("/proc/{pid}/status")) else { continue };
        let rss = st
            .lines()
            .find(|l| l.starts_with("VmRSS:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse::<u64>().ok())
            .unwrap_or(0);
        if rss == 0 {
            continue;
        }
        let comm = proc_name(pid, &st);
        v.push((rss, pid, comm));
    }
    v.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    v.truncate(n);
    let items: Vec<String> = v
        .iter()
        .map(|(rss, pid, comm)| {
            // Escape the name: a process can be called anything, and one quote
            // in it would make the whole snapshot unparseable.
            let safe = json_escape(&comm);
            format!("{{\"pid\":{pid},\"rss\":{:.0},\"name\":\"{safe}\"}}", *rss as f64 / 1024.0)
        })
        .collect();
    format!("[{}]", items.join(","))
}

/// Total system RAM in kB, for turning a process's RSS into mem_pct. Separate
/// tiny parse rather than reusing meminfo_all(), which already collapsed
/// MemTotal into GiB totals the process table doesn't need.
fn mem_total_kb() -> f64 {
    fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("MemTotal:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<f64>().ok())
        })
        .unwrap_or(0.0)
}

/// uid -> login name, parsed from /etc/passwd once per tick. A process table
/// that shows raw uids is unreadable on a box with more than one account;
/// /etc/passwd is world-readable and tiny, so this is cheaper than a getpwuid
/// FFI call per process.
fn read_uid_names() -> HashMap<u32, String> {
    let mut m = HashMap::new();
    if let Ok(s) = fs::read_to_string("/etc/passwd") {
        for line in s.lines() {
            let f: Vec<&str> = line.split(':').collect();
            if f.len() < 3 {
                continue;
            }
            if let Ok(uid) = f[2].parse::<u32>() {
                m.insert(uid, f[0].to_string());
            }
        }
    }
    m
}

/// clock ticks/second (usually 100 on Linux, but never assumed) — needed to
/// turn /proc/<pid>/stat's utime+stime tick counts into seconds of CPU time.
fn clk_tck() -> f64 {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if hz > 0 { hz as f64 } else { 100.0 }
}

/// The six per-process values the proctable averages, held as one
/// exponentially-weighted moving average per window. One struct per window
/// (1m/5m/15m), carried per pid across ticks in ProcSample below.
///
/// EWMA rather than a real sliding window on purpose: a true 15-minute mean
/// would need every sample of every pid retained (~450 samples x ~500 pids
/// x 6 metrics), where this needs six f64 per window per pid and no history
/// at all. It is also exactly what the kernel does for load1/load5/load15,
/// which this file already publishes — so "avg" here means the same kind of
/// thing it means one field up in the same JSON.
#[derive(Default, Clone, Copy)]
struct ProcAvg {
    cpu_pct: f64,
    mem_pct: f64,
    rss_bytes: f64,
    read_bps: f64,
    write_bps: f64,
    runq_wait_pct: f64,
    /// Averaged too, because a major-fault rate is spiky by nature: a process
    /// faults in a burst and then runs quiet, so the instant number alone
    /// says "nothing is thrashing" a tick after it was.
    majflt_per_s: f64,
}

/// Averaging windows, in seconds — the EWMA time constants. 1m/5m/15m mirror
/// load1/load5/load15; 10s is the short window the process table shows next to
/// it, because "is this spiking right now" and "has this been heavy all along"
/// are different questions and a 1m average answers only the second.
/// 15 ticks at INTERVAL_MS = 30s between service-list refreshes.
const SERVICES_EVERY_TICKS: u64 = 15;
/// smaps_rollup is a page-table walk; 5 ticks at INTERVAL_MS is 10s.
const PSS_EVERY_TICKS: u64 = 5;

const PROC_AVG_WINDOWS: [f64; 4] = [10.0, 60.0, 300.0, 900.0];
const PROC_AVG_LABELS: [&str; 4] = ["10s", "1m", "5m", "15m"];

impl ProcAvg {
    /// One EWMA step toward this tick's live values. `alpha` is derived from
    /// the ACTUAL elapsed time, not assumed to be one fixed interval, so a
    /// late or skipped tick weights correctly instead of quietly stretching
    /// the window.
    fn step(&mut self, alpha: f64, live: &ProcAvg) {
        let f = |old: f64, new: f64| old + alpha * (new - old);
        self.cpu_pct = f(self.cpu_pct, live.cpu_pct);
        self.mem_pct = f(self.mem_pct, live.mem_pct);
        self.rss_bytes = f(self.rss_bytes, live.rss_bytes);
        self.read_bps = f(self.read_bps, live.read_bps);
        self.write_bps = f(self.write_bps, live.write_bps);
        self.runq_wait_pct = f(self.runq_wait_pct, live.runq_wait_pct);
        self.majflt_per_s = f(self.majflt_per_s, live.majflt_per_s);
    }

    fn to_json(self) -> String {
        format!(
            "{{\"cpu_pct\":{:.1},\"mem_pct\":{:.2},\"mem_rss_bytes\":{:.0},\
              \"read_bytes_per_s\":{:.0},\"write_bytes_per_s\":{:.0},\"runq_wait_pct\":{:.2},\
              \"majflt_per_s\":{:.1}}}",
            self.cpu_pct, self.mem_pct, self.rss_bytes, self.read_bps, self.write_bps,
            self.runq_wait_pct, self.majflt_per_s
        )
    }
}

/// One tick's raw counters for one pid, kept between samples so cpu%,
/// read/write rates and the runqueue-wait proxy below are all deltas, never
/// cumulative counters passed straight through. `avg` rides along in the same
/// map so the EWMA state is evicted with the pid the moment it stops being
/// sampled — no separate history map to garbage-collect.
#[derive(Clone, Copy)]
struct ProcSample {
    cpu_ticks: u64,
    /// Cumulative major faults — pages that had to be read back from disk.
    majflt: u64,
    read_bytes: u64,
    write_bytes: u64,
    runq_wait_ns: u64,
    net_rx: u64,
    net_tx: u64,
    /// Accumulated since this daemon first saw the pid.
    ///
    /// net_rx/net_tx above are a sum over CURRENTLY OPEN sockets, so they fall
    /// when a connection closes and can never be a lifetime figure on their
    /// own. Integrating the positive deltas is the only way to get one without
    /// the kernel keeping per-process network counters, which it does not.
    /// It undercounts — traffic on a socket opened and closed between two
    /// samples is never seen — and it never overcounts, which is the right way
    /// round for a number people read as a total.
    net_rx_total: u64,
    net_tx_total: u64,
    /// Last PSS reading, carried between the ticks that do not re-read it.
    pss_bytes: Option<f64>,
    avg: [ProcAvg; 4],
    /// False until this pid has produced one real rate sample, so the first
    /// EWMA step SEEDS with the live value instead of ramping up from zero
    /// (which would show every freshly-started process as artificially idle
    /// for its first few minutes).
    seeded: bool,
}

/// utime+stime (fields 14,15 of /proc/<pid>/stat) in clock ticks. The comm
/// field (field 2) is parenthesised and may itself contain spaces or closing
/// parens, so this splits on the LAST ')' rather than whitespace — the same
/// trap /proc/<pid>/stat parsers are famous for getting wrong.
/// The name a human would recognise, not the one the kernel happens to store.
///
/// `/proc/PID/status` `Name:` (== `comm`) is wrong twice over: it is capped at 15
/// bytes, and for anything nix launches through the glibc loader it reads
/// `ld-linux-x86-64` — five of the top rows said that, every one of them `claude`.
/// Pick the real program out of an argv stream. Split out of [`proc_name`] so the
/// loader-skipping rule can be tested without a live /proc.
fn name_from_argv(args: &mut impl Iterator<Item = String>) -> Option<String> {
    fn base(s: &str) -> String {
        s.rsplit('/').next().unwrap_or(s).to_string()
    }
    let first = base(&args.next()?);
    // The loader is a launcher, not the program: `ld-linux.so [opts] PROG args…`.
    if !(first.starts_with("ld-linux") || first.starts_with("ld.so") || first.starts_with("ld-musl")) {
        return Some(first);
    }
    while let Some(a) = args.next() {
        if !a.starts_with("--") {
            return Some(base(&a));
        }
        // These swallow the following token; skip the value too.
        if matches!(a.as_str(), "--argv0" | "--preload" | "--library-path") {
            args.next();
        }
    }
    Some(first) // loader with nothing after it — better than an empty cell
}

/// argv is the truth. comm is only right for kernel threads, which have no argv.
fn proc_name(pid: i32, status: &str) -> String {
    let raw = fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
    let mut args = raw
        .split(|b| *b == 0)
        .filter(|a| !a.is_empty())
        .map(|a| String::from_utf8_lossy(a).into_owned());

    if let Some(n) = name_from_argv(&mut args) {
        return n;
    }

    // Kernel thread: no argv, and comm is already complete ("kworker/u32:5-btrfs-endio").
    // Take the rest of the line rather than the first token — "Web Content" has a space.
    status
        .lines()
        .find_map(|l| l.strip_prefix("Name:").map(|n| n.trim().to_string()))
        .unwrap_or_else(|| "?".into())
}

/// CPU ticks and major faults, from ONE read of /proc/<pid>/stat.
///
/// Major faults are here rather than in a reader of their own because this
/// file is opened once per pid per tick on purpose — the fleet's policy exists
/// to stop a monitor becoming the load it reports, and a second open of the
/// same file for one more integer is exactly that.
///
/// WHY MAJOR FAULTS. The table could already say who is waiting on the CPU
/// (runq) and who is moving bytes (read/write). It could not say who is
/// STALLING ON MEMORY. A major fault is a page that had to come back from
/// disk — a refault or a swap-in — which is precisely what memory pressure is
/// made of. Rate, not total: the total is dominated by whatever started first.
fn read_proc_stat_bits(pid: i32) -> Option<(u64, u64)> {
    let s = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = s.rsplit_once(')')?.1;
    let f: Vec<&str> = after.split_whitespace().collect();
    // After the comm field, index 0 is state, so field N is index N-3:
    // majflt is field 12 → 9, utime 14 → 11, stime 15 → 12.
    let majflt: u64 = f.get(9)?.parse().ok()?;
    let utime: u64 = f.get(11)?.parse().ok()?;
    let stime: u64 = f.get(12)?.parse().ok()?;
    Some((utime + stime, majflt))
}

/// read_bytes/write_bytes from /proc/<pid>/io — actual storage I/O, not the
/// rchar/wchar counters (which also count pipes/tty and would call a chatty
/// terminal "disk-heavy"). Only readable for processes this uid owns (or as
/// root); permission-denied on someone else's process is expected, not an
/// error, so it degrades to 0 rather than dropping the row.
fn read_proc_io(pid: i32) -> (u64, u64) {
    let Ok(s) = fs::read_to_string(format!("/proc/{pid}/io")) else { return (0, 0) };
    let get = |k: &str| -> u64 {
        s.lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    };
    (get("read_bytes:"), get("write_bytes:"))
}

/// Field 2 of /proc/<pid>/schedstat: cumulative nanoseconds this task spent
/// RUNNABLE but waiting for a CPU. This is a per-process PROXY for pressure,
/// NOT real PSI — /proc/pressure only publishes system-wide cpu/io/memory
/// figures, there is no per-task PSI in the kernel. Named runq_wait_pct
/// (never psi) so nothing downstream mistakes it for the real thing: it is
/// "share of this sample window this task spent waiting for a CPU it didn't
/// get", which is the practical stand-in the task asked for.
fn read_proc_runq_wait_ns(pid: i32) -> Option<u64> {
    let s = fs::read_to_string(format!("/proc/{pid}/schedstat")).ok()?;
    let f: Vec<&str> = s.split_whitespace().collect();
    f.get(1)?.parse().ok()
}

/// Per-process network bytes, cumulative, as (received, sent).
///
/// The kernel publishes NO per-process network counter — /proc/<pid>/net/dev
/// is the whole network NAMESPACE, identical for every process in it, so it
/// cannot answer "who is downloading". What does exist is per-SOCKET
/// bytes_received/bytes_acked in tcp_info, and inet_diag can be asked which
/// pid owns each socket. `ss -tinHp` is exactly that query, so we shell out
/// once per tick and fold the sockets back onto their pids.
///
/// Two honest limits, both consequences of running unprivileged:
///   * TCP only. UDP sockets carry no byte counters in the kernel at all.
///   * Only sockets this uid owns. inet_diag will not name another user's
///     process, so a root daemon's traffic shows as nothing rather than wrong.
///
/// The sum is over CURRENTLY OPEN sockets, so it drops when a connection
/// closes. Callers diff it with saturating_sub, which turns that drop into a
/// zero — losing the last few bytes of a closed connection, never inventing a
/// spike. That trade is deliberate: a wrong rate is worse than a missing one.
/// WHAT THIS MACHINE IS LISTENING ON, and how far each socket reaches.
///
/// The firewall itself is unreadable without root — `nft list ruleset` and
/// `iptables -S` both refuse, and this daemon is deliberately a USER service.
/// So it answers the question the firewall exists to answer instead: what is
/// actually bound, and on which address.
///
/// The address IS the exposure. 127.0.0.1 reaches nobody, a mesh address
/// reaches the fleet, and 0.0.0.0 reaches the internet — so a port on 0.0.0.0
/// that no declaration mentions is the finding, and it needs no privilege to
/// see.
fn listening_json() -> String {
    let Ok(o) = clean_command("ss").args(["-tlnH"]).output() else { return "[]".into() };
    let txt = String::from_utf8_lossy(&o.stdout);
    let mut items: Vec<String> = vec![];
    for l in txt.lines() {
        let f: Vec<&str> = l.split_whitespace().collect();
        // state recv send local peer ...  — local is field 3.
        let Some(local) = f.get(3) else { continue };
        // [::]:443 and 0.0.0.0:443 are the same statement about exposure;
        // rsplit_once keeps IPv6 addresses intact, which split(':') would not.
        let Some((addr, port)) = local.rsplit_once(':') else { continue };
        let addr = addr.trim_matches(|c| c == '[' || c == ']');
        // The WHOLE of 127.0.0.0/8 is loopback, not just 127.0.0.1 —
        // systemd-resolved binds 127.0.0.54 and it reaches nobody either.
        let scope = if addr.starts_with("127.") || addr == "::1" {
            "loopback"
        } else if addr == "0.0.0.0" || addr == "*" || addr == "::" {
            "world"
        } else {
            "mesh"
        };
        items.push(format!(
            "{{\"addr\":\"{}\",\"port\":{},\"proto\":\"tcp\",\"scope\":\"{}\"}}",
            json_escape(addr),
            port.parse::<u32>().unwrap_or(0),
            scope
        ));
    }
    format!("[{}]", items.join(","))
}

/// The numbers atop shows that nothing here did: what the CPU is ACTUALLY
/// clocked at against what it could be, whether the kernel has killed anything
/// for memory, how deep the run queue is, and whether the network is losing
/// packets.
///
/// One function with its own previous sample, rather than four more arguments
/// threaded through render(): every figure here is a rate over the same tick,
/// and keeping them together is what makes them comparable.
#[derive(Clone, Copy, Default)]
struct Health {
    ctxt: f64,
    intr: f64,
    tcp_out: f64,
    tcp_retrans: f64,
    /// (io_ticks_ms, ios_completed, io_time_ms) for the busiest real disk.
    disk_ticks: f64,
    disk_ios: f64,
    disk_wait: f64,
}

fn read_health() -> Health {
    let mut h = Health::default();
    let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
    for l in stat.lines() {
        if let Some(v) = l.strip_prefix("ctxt ") {
            h.ctxt = v.trim().parse().unwrap_or(0.0);
        } else if let Some(v) = l.strip_prefix("intr ") {
            h.intr = v.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0.0);
        }
    }
    // /proc/net/snmp is two lines per protocol: a header naming the columns and
    // a values line. Reading it by NAME rather than by position because the
    // column set differs between kernels, and RetransSegs sits in a different
    // place on some of them.
    let snmp = fs::read_to_string("/proc/net/snmp").unwrap_or_default();
    let mut lines = snmp.lines();
    while let Some(hdr) = lines.next() {
        if !hdr.starts_with("Tcp:") {
            continue;
        }
        let Some(vals) = lines.next() else { break };
        let keys: Vec<&str> = hdr.split_whitespace().collect();
        let nums: Vec<&str> = vals.split_whitespace().collect();
        let get = |k: &str| -> f64 {
            keys.iter().position(|x| *x == k).and_then(|i| nums.get(i)).and_then(|v| v.parse().ok()).unwrap_or(0.0)
        };
        h.tcp_out = get("OutSegs");
        h.tcp_retrans = get("RetransSegs");
        break;
    }
    // /proc/diskstats: field 10 is ios-in-flight-time (io_ticks, ms the device
    // had anything queued) and 11 is weighted io time. Reads+writes completed
    // are 1 and 5. Partitions and loop/zram devices are skipped — a partition
    // double-counts its parent, and a zram device is memory wearing a disk's
    // clothes.
    for l in fs::read_to_string("/proc/diskstats").unwrap_or_default().lines() {
        let f: Vec<&str> = l.split_whitespace().collect();
        if f.len() < 14 {
            continue;
        }
        let name = f[2];
        if name.starts_with("loop") || name.starts_with("zram") || name.starts_with("dm-") {
            continue;
        }
        // A whole device, not a partition: nvme0n1 yes, nvme0n1p2 no.
        if name.chars().last().map(|c| c.is_ascii_digit()).unwrap_or(false) && !name.starts_with("nvme") {
            continue;
        }
        if name.starts_with("nvme") && name.contains('p') {
            continue;
        }
        let n = |i: usize| -> f64 { f.get(i).and_then(|x| x.parse().ok()).unwrap_or(0.0) };
        // Sum across devices: "is the storage busy" is one question on a box
        // with one pool, and picking a favourite disk would answer it wrong on
        // a box with two.
        h.disk_ios += n(3) + n(7);
        h.disk_wait += n(6) + n(10);
        h.disk_ticks += n(12);
    }
    h
}

/// Health as JSON, rates over `secs`.
fn health_json(prev: Health, now: Health, secs: f64) -> String {
    let d = |a: f64, b: f64| -> f64 { (b - a).max(0.0) / secs.max(0.001) };
    // CPU CLOCK against what the part can actually do. The panel showed a
    // frequency with nothing to compare it to, which is the one thing that
    // makes it mean something: 600MHz reads as fine until you know the ceiling
    // is 4400.
    let read1 = |p: &str| -> f64 { fs::read_to_string(p).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0.0) };
    let mut cur = 0.0;
    let mut n = 0.0;
    if let Ok(rd) = fs::read_dir("/sys/devices/system/cpu") {
        for e in rd.flatten() {
            let f = e.path().join("cpufreq/scaling_cur_freq");
            if f.exists() {
                cur += read1(f.to_str().unwrap_or(""));
                n += 1.0;
            }
        }
    }
    let cur_mhz = if n > 0.0 { cur / n / 1000.0 } else { 0.0 };
    let max_mhz = read1("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq") / 1000.0;
    let scal = if max_mhz > 0.0 { cur_mhz / max_mhz * 100.0 } else { 0.0 };

    // Instantaneous, not rates: /proc/stat publishes these directly, which is
    // cheaper and more accurate than counting process states ourselves.
    let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
    let field = |k: &str| -> f64 {
        stat.lines()
            .find_map(|l| l.strip_prefix(k))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0.0)
    };
    let vm = fs::read_to_string("/proc/vmstat").unwrap_or_default();
    let vmk = |k: &str| -> f64 {
        vm.lines()
            .find_map(|l| l.strip_prefix(&format!("{k} ")))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0.0)
    };

    let ios = d(prev.disk_ios, now.disk_ios);
    let wait = d(prev.disk_wait, now.disk_wait);
    let out = d(prev.tcp_out, now.tcp_out);
    let re = d(prev.tcp_retrans, now.tcp_retrans);
    format!(
        "{{\"cur_mhz\":{cur_mhz:.0},\"max_mhz\":{max_mhz:.0},\"scal_pct\":{scal:.1},\
          \"procs_running\":{:.0},\"procs_blocked\":{:.0},\"oom_kill\":{:.0},\
          \"ctxt_per_s\":{:.0},\"intr_per_s\":{:.0},\
          \"tcp_out_per_s\":{out:.1},\"tcp_retrans_per_s\":{re:.2},\"tcp_retrans_pct\":{:.3},\
          \"disk_busy_pct\":{:.1},\"disk_avio_ms\":{:.2},\"disk_iops\":{ios:.0}}}",
        field("procs_running"),
        field("procs_blocked"),
        vmk("oom_kill"),
        d(prev.ctxt, now.ctxt),
        d(prev.intr, now.intr),
        if out > 0.0 { re / out * 100.0 } else { 0.0 },
        // io_ticks is milliseconds the device had a request outstanding, so
        // its rate over a second IS the utilisation.
        (d(prev.disk_ticks, now.disk_ticks) / 10.0).min(100.0),
        // Average service time per io. The number that says a disk is dying
        // long before throughput does.
        if ios > 0.0 { wait / ios } else { 0.0 },
    )
}

/// The page-reclaim counters, cumulative since boot.
///
/// These are what memory pressure is MADE of, and the pair that matters most
/// is direct vs kswapd. Reclaim by kswapd is background work: it happens on
/// its own thread and shows up as PSI `some`. DIRECT reclaim is a process
/// being made to free memory before its own allocation can proceed — that is
/// a synchronous stall, and it is what drives PSI `full`. A panel that shows
/// only "memory is under pressure" cannot tell those apart, and they call for
/// completely different responses.
#[derive(Clone, Copy, Default)]
struct VmStat {
    refault_file: u64,
    refault_anon: u64,
    swap_in: u64,
    swap_out: u64,
    scan_direct: u64,
    scan_kswapd: u64,
    steal_direct: u64,
    steal_kswapd: u64,
}

fn read_vmstat() -> VmStat {
    let Ok(t) = fs::read_to_string("/proc/vmstat") else { return VmStat::default() };
    let g = |k: &str| -> u64 {
        t.lines()
            .find(|l| l.split_whitespace().next() == Some(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    };
    VmStat {
        refault_file: g("workingset_refault_file"),
        refault_anon: g("workingset_refault_anon"),
        swap_in: g("pswpin"),
        swap_out: g("pswpout"),
        scan_direct: g("pgscan_direct"),
        scan_kswapd: g("pgscan_kswapd"),
        steal_direct: g("pgsteal_direct"),
        steal_kswapd: g("pgsteal_kswapd"),
    }
}

/// Pages per second, from the delta. Saturating, because these counters are
/// per-boot and a peer that rebooted between two samples would otherwise
/// publish a vast negative spike as a vast positive one.
fn reclaim_json(prev: VmStat, now: VmStat, secs: f64) -> String {
    let r = |a: u64, b: u64| -> f64 {
        if secs <= 0.0 { 0.0 } else { a.saturating_sub(b) as f64 / secs }
    };
    format!(
        "{{\"refault_file\":{:.0},\"refault_anon\":{:.0},\
          \"swap_in\":{:.0},\"swap_out\":{:.0},\
          \"scan_direct\":{:.0},\"scan_kswapd\":{:.0},\
          \"steal_direct\":{:.0},\"steal_kswapd\":{:.0}}}",
        r(now.refault_file, prev.refault_file),
        r(now.refault_anon, prev.refault_anon),
        r(now.swap_in, prev.swap_in),
        r(now.swap_out, prev.swap_out),
        r(now.scan_direct, prev.scan_direct),
        r(now.scan_kswapd, prev.scan_kswapd),
        r(now.steal_direct, prev.steal_direct),
        r(now.steal_kswapd, prev.steal_kswapd),
    )
}

fn read_proc_net() -> HashMap<i32, (u64, u64)> {
    let mut out: HashMap<i32, (u64, u64)> = HashMap::new();
    let Ok(o) = clean_command("ss").args(["-tinHp"]).output() else { return out };
    let Ok(text) = String::from_utf8(o.stdout) else { return out };

    // ss prints one socket as two lines: the header line carries
    // users:(("name",pid=N,fd=M)), the wrapped line carries the tcp_info
    // counters. Remember the pid from the header, spend it on the next line.
    let mut pid: Option<i32> = None;
    for line in text.lines() {
        if let Some(i) = line.find("pid=") {
            pid = line[i + 4..]
                .split(|c: char| !c.is_ascii_digit())
                .next()
                .and_then(|d| d.parse().ok());
            continue;
        }
        let Some(p) = pid.take() else { continue };
        let field = |k: &str| -> u64 {
            line.split_whitespace()
                .find_map(|t| t.strip_prefix(k))
                .and_then(|v| v.parse().ok())
                .unwrap_or(0)
        };
        let e = out.entry(p).or_insert((0, 0));
        e.0 += field("bytes_received:");
        e.1 += field("bytes_acked:");
    }
    out
}

/// Proportional set size, in bytes: this process's private pages plus its
/// share of every page it maps with someone else.
///
/// RSS double-counts shared memory — add the RSS of every process on this box
/// and you get several times the RAM installed. PSS is the figure that sums
/// to the truth, which is why it is worth a page-table walk to get.
///
/// And it IS a walk: smaps_rollup is orders of magnitude dearer than reading
/// status, so this is deliberately called only for the rows that get
/// published, never for every entry in /proc. Another user's process returns
/// None (EACCES) rather than a wrong zero.
fn read_proc_pss(pid: i32) -> Option<f64> {
    let s = fs::read_to_string(format!("/proc/{pid}/smaps_rollup")).ok()?;
    let kb: f64 = s
        .lines()
        .find(|l| l.starts_with("Pss:"))?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()?;
    Some(kb * 1024.0)
}

/// Builds the `proc_table` JSON array: top-N by CPU% among all processes
/// readable right now, with the rate fields computed as deltas against
/// `prev` (the previous tick's raw counters) rather than passed through
/// cumulative. Returns the JSON plus the raw-counter map for every process
/// actually sampled this tick, which becomes `prev` for the next call.
fn build_proc_table(
    n: usize,
    prev: &HashMap<i32, ProcSample>,
    secs: f64,
    total_mem_kb: f64,
    protected: &[String],
    uid_names: &HashMap<u32, String>,
    pss_due: bool,
) -> (String, String, HashMap<i32, ProcSample>) {
    struct Row {
        pid: i32,
        ppid: i32,
        state: String,
        slice: String,
        name: String,
        uid: u32,
        rss_kb: f64,
        pss_bytes: Option<f64>,
        cpu_pct: f64,
        mem_pct: f64,
        read_bps: f64,
        write_bps: f64,
        net_rx_bps: f64,
        net_tx_bps: f64,
        net_rx_total: u64,
        net_tx_total: u64,
        read_total: u64,
        write_total: u64,
        runq_wait_pct: f64,
        /// Major faults per second — pages this process had to fetch back
        /// from disk. The memory-stall counterpart to runq_wait_pct.
        majflt_per_s: f64,
        avg: [ProcAvg; 4],
    }

    let mut next: HashMap<i32, ProcSample> = HashMap::new();
    let mut rows: Vec<Row> = Vec::new();
    // One inet_diag query for the whole tick, not one per pid.
    let net = read_proc_net();
    let Ok(rd) = fs::read_dir("/proc") else { return ("[]".into(), "[]".into(), next) };

    for e in rd.flatten() {
        let name_os = e.file_name();
        let Some(nm) = name_os.to_str() else { continue };
        let Ok(pid) = nm.parse::<i32>() else { continue };

        let Ok(status) = fs::read_to_string(format!("/proc/{pid}/status")) else { continue };
        let rss_kb: f64 = status
            .lines()
            .find(|l| l.starts_with("VmRSS:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse().ok())
            .unwrap_or(0.0);
        let comm = proc_name(pid, &status);
        let uid: u32 = status
            .lines()
            .find(|l| l.starts_with("Uid:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse().ok())
            .unwrap_or(0);

        let field = |k: &str| -> &str {
            status
                .lines()
                .find(|l| l.starts_with(k))
                .and_then(|l| l.split_whitespace().nth(1))
                .unwrap_or("")
        };
        let ppid: i32 = field("PPid:").parse().unwrap_or(0);
        // "Z" here is what makes a zombie a zombie; the panel groups on it.
        let state = field("State:").to_string();
        let slice = proc_slice(pid);

        let (cpu_ticks, majflt) = read_proc_stat_bits(pid).unwrap_or((0, 0));
        let (read_bytes, write_bytes) = read_proc_io(pid);
        let runq_wait_ns = read_proc_runq_wait_ns(pid).unwrap_or(0);
        let (net_rx, net_tx) = net.get(&pid).copied().unwrap_or((0, 0));

        let p = prev.get(&pid);
        // A pid whose cumulative CPU ticks went BACKWARDS is not the same
        // process any more — the kernel recycled the number. Drop the
        // inherited averages rather than blend a dead process's history into
        // a new one's.
        let p = p.filter(|p| cpu_ticks >= p.cpu_ticks);

        let cpu_pct = p
            .map(|p| {
                if secs <= 0.0 { 0.0 } else {
                    (cpu_ticks.saturating_sub(p.cpu_ticks) as f64 / clk_tck()) / secs * 100.0
                }
            })
            .unwrap_or(0.0);
        let (read_bps, write_bps) = p
            .map(|p| {
                if secs <= 0.0 { (0.0, 0.0) } else {
                    (
                        read_bytes.saturating_sub(p.read_bytes) as f64 / secs,
                        write_bytes.saturating_sub(p.write_bytes) as f64 / secs,
                    )
                }
            })
            .unwrap_or((0.0, 0.0));
        // saturating_sub, so a closed socket leaving the sum reads as no
        // traffic rather than as a negative rate. See read_proc_net.
        let (net_rx_total, net_tx_total) = p
            .map(|p| {
                (
                    p.net_rx_total + net_rx.saturating_sub(p.net_rx),
                    p.net_tx_total + net_tx.saturating_sub(p.net_tx),
                )
            })
            .unwrap_or((0, 0));
        let (net_rx_bps, net_tx_bps) = p
            .map(|p| {
                if secs <= 0.0 { (0.0, 0.0) } else {
                    (
                        net_rx.saturating_sub(p.net_rx) as f64 / secs,
                        net_tx.saturating_sub(p.net_tx) as f64 / secs,
                    )
                }
            })
            .unwrap_or((0.0, 0.0));
        let runq_wait_pct = p
            .map(|p| {
                if secs <= 0.0 { 0.0 } else {
                    (runq_wait_ns.saturating_sub(p.runq_wait_ns) as f64 / 1_000_000_000.0) / secs * 100.0
                }
            })
            .unwrap_or(0.0);
        // Major faults PER SECOND. The cumulative count is dominated by
        // whatever has been running longest, which is never the answer to
        // "who is thrashing right now".
        let majflt_per_s = p
            .map(|p| {
                if secs <= 0.0 { 0.0 } else { majflt.saturating_sub(p.majflt) as f64 / secs }
            })
            .unwrap_or(0.0);

        let mem_pct = if total_mem_kb > 0.0 { rss_kb / total_mem_kb * 100.0 } else { 0.0 };

        // Advance this pid's three EWMAs toward the values just measured.
        // Done for EVERY pid sampled, not just the top-N published below:
        // a process that only enters the top-N occasionally must still have
        // a meaningful 15m average when it gets there, which it cannot have
        // if its history only accrued on the ticks it happened to rank.
        let live = ProcAvg {
            cpu_pct,
            mem_pct,
            rss_bytes: rss_kb * 1024.0,
            read_bps,
            write_bps,
            runq_wait_pct,
            majflt_per_s,
        };
        let mut avg = p.map(|p| p.avg).unwrap_or_default();
        let seeded = p.map(|p| p.seeded).unwrap_or(false);
        if p.is_some() {
            if seeded {
                for (i, w) in PROC_AVG_WINDOWS.iter().enumerate() {
                    // alpha from the real elapsed time; clamped so a very
                    // long gap can at most jump straight to the live value.
                    let alpha = if *w <= 0.0 { 1.0 } else { (1.0 - (-secs / w).exp()).clamp(0.0, 1.0) };
                    avg[i].step(alpha, &live);
                }
            } else {
                avg = [live; 4];
            }
        }

        next.insert(
            pid,
            ProcSample {
                cpu_ticks,
                majflt,
                read_bytes,
                write_bytes,
                runq_wait_ns,
                net_rx,
                net_tx,
                net_rx_total,
                net_tx_total,
                pss_bytes: None,
                avg,
                seeded: seeded || p.is_some(),
            },
        );

        // First sample for a pid (no `prev` entry) has no valid rate yet —
        // skip the row rather than publish a fake 0%/spike; it will appear
        // next tick once a delta exists.
        if p.is_none() {
            continue;
        }

        rows.push(Row {
            pid,
            ppid,
            state,
            slice,
            name: comm,
            uid,
            rss_kb,
            // Filled in below, for the published rows only.
            pss_bytes: None,
            cpu_pct,
            mem_pct,
            read_bps,
            write_bps,
            net_rx_bps,
            net_tx_bps,
            net_rx_total,
            net_tx_total,
            // /proc/PID/io is already cumulative for the life of the
            // process, so these need no integrating.
            read_total: read_bytes,
            write_total: write_bytes,
            runq_wait_pct,
            majflt_per_s,
            avg,
        });
    }

    rows.sort_unstable_by(|a, b| b.cpu_pct.partial_cmp(&a.cpu_pct).unwrap_or(std::cmp::Ordering::Equal));
    rows.truncate(n);
    // After the truncate, never before — and not on every tick.
    //
    // smaps_rollup is a page-table walk: the kernel adds up every mapping the
    // process has, and for a 500MB process that is real work. A resident set
    // changes on the scale of a working set, not of a 2s sample, so paying for
    // it five times a second bought precision nobody can read and cost CPU the
    // machine being measured wanted.
    if pss_due {
        for r in rows.iter_mut() {
            r.pss_bytes = read_proc_pss(r.pid);
        }
    } else {
        // Carry the previous reading rather than publishing null: absent means
        // "not readable", and a cell that blinked to a dash on four ticks out
        // of five would be saying something untrue.
        for r in rows.iter_mut() {
            r.pss_bytes = prev.get(&r.pid).and_then(|p| p.pss_bytes);
        }
    }
    // Written back so the next four ticks have something to carry. `next` was
    // filled before the truncate, when no row had a reading yet.
    for r in rows.iter() {
        if let Some(e) = next.get_mut(&r.pid) {
            e.pss_bytes = r.pss_bytes;
        }
    }

    // The spine: every ancestor of a published row, up to pid 1.
    //
    // proc_table is the top-N by CPU, so a process's parent is usually not in
    // it and a tree drawn from the table alone bottoms out at whatever
    // happened to rank — it can never reach systemd. These carry no metrics
    // because they are not measured rows, only the path between them.
    //
    // MEMOISED, and that is not a micro-optimisation. The first version read
    // /proc/<pid>/status twice per step and re-walked shared ancestors once
    // per published row: forty rows whose chains converge on the same shell,
    // the same konsole, the same systemd meant the same handful of files read
    // dozens of times every two seconds. It cost ~10% of a core — a sampler
    // competing with the thing it is sampling, which is the exact failure this
    // fleet's policy is written to prevent. One read per distinct pid per tick.
    let published: Vec<i32> = rows.iter().map(|r| r.pid).collect();
    let mut seen: HashMap<i32, (i32, String)> = HashMap::new();
    // Not `mut`: the map it mutates arrives as a parameter, so the closure
    // itself captures nothing.
    let parent_of = |pid: i32, seen: &mut HashMap<i32, (i32, String)>| -> Option<(i32, String)> {
        if let Some(v) = seen.get(&pid) {
            return Some(v.clone());
        }
        let st = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
        let field = |k: &str| -> &str {
            st.lines()
                .find(|l| l.starts_with(k))
                .and_then(|l| l.split_whitespace().nth(1))
                .unwrap_or("")
        };
        let ppid: i32 = field("PPid:").parse().ok()?;
        let name = st
            .lines()
            .find(|l| l.starts_with("Name:"))
            .map(|l| l[5..].trim().to_string())
            .unwrap_or_else(|| "?".into());
        let v = (ppid, name);
        seen.insert(pid, v.clone());
        Some(v)
    };

    let mut spine: Vec<(i32, i32, String)> = Vec::new();
    for pid in &published {
        let mut cur = *pid;
        // Bounded: a pid cycle would otherwise loop forever, and no real
        // ancestry is anywhere near this deep.
        for _ in 0..24 {
            let Some((ppid, _)) = parent_of(cur, &mut seen) else { break };
            if ppid <= 0 {
                break;
            }
            // Already on the spine, or already a measured row: the rest of
            // this chain was walked by whoever put it there.
            if spine.iter().any(|(p, _, _)| *p == ppid) {
                break;
            }
            if published.contains(&ppid) {
                cur = ppid;
                continue;
            }
            let Some((gp, name)) = parent_of(ppid, &mut seen) else { break };
            spine.push((ppid, gp, name));
            cur = ppid;
        }
    }
    let spine_json: Vec<String> = spine
        .iter()
        .map(|(pid, ppid, name)| {
            format!("{{\"pid\":{pid},\"ppid\":{ppid},\"name\":\"{}\"}}", json_escape(name))
        })
        .collect();

    let items: Vec<String> = rows
        .iter()
        .map(|r| {
            let safe_name = json_escape(&r.name);
            let safe_state = json_escape(&r.state);
            let safe_slice = json_escape(&r.slice);
            let user = uid_names.get(&r.uid).cloned().unwrap_or_else(|| r.uid.to_string());
            let safe_user = json_escape(&user);
            let (is_protected, reason) = if r.pid == 1 {
                (true, "pid 1 (init)".to_string())
            } else if let Some(slice) = proc_protected_slice(r.pid, protected) {
                (true, format!("in protected slice {slice}"))
            } else {
                (false, String::new())
            };
            // "avg" carries the same six keys as the live row, once per
            // window, so the panel can swap which set it renders without any
            // per-metric special-casing on its side.
            let avg_json: Vec<String> = PROC_AVG_LABELS
                .iter()
                .enumerate()
                .map(|(i, label)| format!("\"{label}\":{}", r.avg[i].to_json()))
                .collect();
            format!(
                "{{\"pid\":{},\"ppid\":{},\"state\":\"{safe_state}\",\"slice\":\"{safe_slice}\",\
                  \"name\":\"{safe_name}\",\"user\":\"{safe_user}\",\
                  \"cpu_pct\":{:.1},\"mem_rss_bytes\":{:.0},\"mem_pss_bytes\":{},\"mem_pct\":{:.2},\
                  \"read_bytes_per_s\":{:.0},\"write_bytes_per_s\":{:.0},\
                  \"net_rx_bytes_per_s\":{:.0},\"net_tx_bytes_per_s\":{:.0},\
                  \"net_rx_bytes_total\":{},\"net_tx_bytes_total\":{},\
                  \"read_bytes_total\":{},\"write_bytes_total\":{},\
                  \"runq_wait_pct\":{:.2},\"majflt_per_s\":{:.1},\"protected\":{is_protected},\
                  \"protected_reason\":{},\"avg\":{{{}}}}}",
                r.pid, r.ppid, r.cpu_pct, r.rss_kb * 1024.0,
                r.pss_bytes.map(|v| format!("{v:.0}")).unwrap_or_else(|| "null".into()),
                r.mem_pct, r.read_bps, r.write_bps,
                r.net_rx_bps, r.net_tx_bps,
                r.net_rx_total, r.net_tx_total, r.read_total, r.write_total,
                r.runq_wait_pct,
                r.majflt_per_s,
                if is_protected { format!("\"{}\"", json_escape(&reason)) } else { "null".to_string() },
                avg_json.join(","),
            )
        })
        .collect();

    (
        format!("[{}]", items.join(",")),
        format!("[{}]", spine_json.join(",")),
        next,
    )
}

// Disk throughput, matching the panel's disk/all/read + disk/all/write.
// /proc/diskstats is cumulative sectors since boot, so this needs the same
// two-sample treatment as CPU. Sectors are 512 bytes by kernel convention
// regardless of the device's physical block size.
#[derive(Default, Clone, Copy)]
struct DiskTotals {
    read_sectors: u64,
    write_sectors: u64,
}

fn read_diskstats() -> DiskTotals {
    let Ok(s) = fs::read_to_string("/proc/diskstats") else { return DiskTotals::default() };
    let mut t = DiskTotals::default();
    for l in s.lines() {
        let f: Vec<&str> = l.split_whitespace().collect();
        if f.len() < 10 {
            continue;
        }
        // Skip partitions and virtual devices, or every byte is counted twice
        // (once for sda, again for sda1). Whole disks only.
        //
        // "last char is a digit" picks out sda1/sdb2 partitions on SCSI/SATA
        // disks, where the whole-disk name (sda) has none. But nvme and mmc
        // devices number the *disk* too (nvme0n1, mmcblk0) and only append a
        // 'p' before the partition digit (nvme0n1p1, mmcblk0p1) — this box is
        // a Surface, so its NVMe/eMMC disk would otherwise be silently
        // excluded and every disk widget would read zero forever.
        let name = f[2];
        if name.starts_with("loop") || name.starts_with("ram") || name.starts_with("dm-") {
            continue;
        }
        if name.starts_with("nvme") || name.starts_with("mmcblk") {
            if name.contains('p') {
                continue; // nvme0n1p1, mmcblk0p1
            }
        } else if name.chars().last().is_some_and(|c| c.is_ascii_digit()) {
            continue; // sda1, sdb2, …
        }
        t.read_sectors += f[5].parse::<u64>().unwrap_or(0);
        t.write_sectors += f[9].parse::<u64>().unwrap_or(0);
    }
    t
}

fn disk_rate_mb(prev: DiskTotals, now: DiskTotals, secs: f64) -> (f64, f64) {
    if secs <= 0.0 {
        return (0.0, 0.0);
    }
    let b = |a: u64, b: u64| (a.saturating_sub(b) as f64 * 512.0) / 1_048_576.0 / secs;
    (b(now.read_sectors, prev.read_sectors), b(now.write_sectors, prev.write_sectors))
}

// Network throughput, both directions, summed across real interfaces.
// /proc/net/dev is cumulative bytes, so same two-sample treatment as cpu/disk.
#[derive(Default, Clone, Copy)]
struct NetTotals {
    rx: u64,
    tx: u64,
}

fn read_net() -> NetTotals {
    let Ok(s) = fs::read_to_string("/proc/net/dev") else { return NetTotals::default() };
    let mut t = NetTotals::default();
    for l in s.lines().skip(2) {
        let Some((name, rest)) = l.split_once(':') else { continue };
        let name = name.trim();
        // Loopback would double every local connection, and the virtual
        // bridges docker/wireguard create carry traffic already counted on the
        // physical interface it leaves by.
        if name == "lo" || name.starts_with("veth") || name.starts_with("br-") || name.starts_with("docker") {
            continue;
        }
        let f: Vec<&str> = rest.split_whitespace().collect();
        t.rx += f.first().and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
        t.tx += f.get(8).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
    }
    t
}

fn net_rate_mb(prev: NetTotals, now: NetTotals, secs: f64) -> (f64, f64) {
    if secs <= 0.0 {
        return (0.0, 0.0);
    }
    let r = |a: u64, b: u64| (a.saturating_sub(b) as f64) / 1_048_576.0 / secs;
    (r(now.rx, prev.rx), r(now.tx, prev.tx))
}

// Load average — the one number that is already an average, so it needs no
// sampling state and says something the instantaneous percentages cannot:
// how many tasks wanted a CPU, including the ones that never got one.
fn loadavg() -> (f64, f64, f64) {
    fs::read_to_string("/proc/loadavg")
        .ok()
        .map(|s| {
            let f: Vec<f64> = s.split_whitespace().take(3).filter_map(|x| x.parse().ok()).collect();
            (
                f.first().copied().unwrap_or(0.0),
                f.get(1).copied().unwrap_or(0.0),
                f.get(2).copied().unwrap_or(0.0),
            )
        })
        .unwrap_or((0.0, 0.0, 0.0))
}

// The user slice's cap is what actually decides who gets OOM-killed on this
// box — the machine has more RAM than the slice is allowed to use, so free(1)
// reads healthy while the session is being reaped. Publish both numbers.
fn slice_mem() -> (f64, f64) {
    let uid = current_uid();
    let base = format!("/sys/fs/cgroup/user.slice/user-{uid}.slice");
    let read = |f: &str| -> f64 {
        fs::read_to_string(format!("{base}/{f}"))
            .ok()
            .and_then(|s| s.trim().parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    (read("memory.current") / 1_073_741_824.0, read("memory.max") / 1_073_741_824.0)
}

// Read from /proc/self/status rather than libc::getuid(): the uid is needed to
// build a cgroup path, and a path that silently points at the wrong slice is
// worse than one that fails loudly. This way the fallback is explicit.
fn current_uid() -> u32 {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))?
                .split_whitespace()
                .nth(1)?
                .parse()
                .ok()
        })
        .unwrap_or(1000)
}

// Root filesystem fullness, matching the panel's disk/all/total widget.
// Rust std has no statvfs, so this goes through libc — one FFI call every 2s
// is cheaper than forking df, which is the only alternative that does not
// involve reimplementing filesystem-specific superblock parsing.
fn disk_root_percent() -> f64 {
    let path = std::ffi::CString::new("/").unwrap();
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut st) } != 0 {
        return 0.0;
    }
    let total = st.f_blocks as f64;
    if total <= 0.0 {
        return 0.0;
    }
    // f_bavail, not f_bfree: the reserved-for-root blocks are not space the
    // user can use, and df reports the same way.
    let used = total - st.f_bavail as f64;
    (used / total) * 100.0
}

/// Filesystems worth putting a row in the disk widget for. Everything else
/// (tmpfs, proc, sys, cgroup, overlay, squashfs, devtmpfs, autofs, fuse.*,
/// ...) is either not a real disk or is a container/snap mount that would
/// just be noise.
const DISK_FSTYPES: [&str; 7] = ["ext4", "btrfs", "xfs", "f2fs", "vfat", "exfat", "ntfs3"];

/// /proc/{mounts,self/mounts} octal-escapes space, tab, newline and backslash
/// in the mount-point field (`\040` for a space, etc). Decode those back to
/// real characters so the mount path we hand to statvfs(2) — and later put in
/// JSON — is correct.
fn decode_mount_escapes(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\'
            && i + 3 < chars.len()
            && chars[i + 1..i + 4].iter().all(|c| ('0'..='7').contains(c))
        {
            let oct: String = chars[i + 1..i + 4].iter().collect();
            if let Ok(v) = u8::from_str_radix(&oct, 8) {
                out.push(v as char);
                i += 4;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// Pure parse of a mounts-file body into (device, decoded mount point) pairs,
/// filtered to real on-disk filesystems and deduplicated by device so a
/// btrfs subvolume or bind mount doesn't get a row for every mount point it
/// appears under. Kept separate from the file read so it's testable with
/// sample text.
fn parse_mounts(s: &str) -> Vec<(String, String)> {
    let mut seen_devices = std::collections::HashSet::new();
    let mut out = Vec::new();
    for line in s.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 3 {
            continue;
        }
        let (device, mount_raw, fstype) = (f[0], f[1], f[2]);
        if !DISK_FSTYPES.contains(&fstype) {
            continue;
        }
        if !seen_devices.insert(device.to_string()) {
            continue; // already have a row for this device
        }
        out.push((device.to_string(), decode_mount_escapes(mount_raw)));
    }
    out
}

/// statvfs(2) a mount point into (used_pct, used_gib, total_gib). Same
/// f_bavail-not-f_bfree reasoning as disk_root_percent above.
fn statvfs_gib(path: &str) -> Option<(f64, f64, f64)> {
    let c = std::ffi::CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let total = st.f_blocks as f64;
    if total <= 0.0 {
        return None;
    }
    let used = total - st.f_bavail as f64;
    let bytes_per_block = if st.f_frsize > 0 { st.f_frsize as f64 } else { st.f_bsize as f64 };
    Some((
        used / total * 100.0,
        used * bytes_per_block / 1_073_741_824.0,
        total * bytes_per_block / 1_073_741_824.0,
    ))
}

/// Minimal JSON string escaping for mount paths, which are the only
/// hand-interpolated strings in this file's output that can contain
/// arbitrary characters (spaces, quotes in theory, control bytes on exotic
/// setups).
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

/// Builds the "disks" JSON array from /proc/self/mounts, capped at 6 rows —
/// the widget is a small pie/list, not a df(1) dump.
fn disks_json() -> String {
    let Ok(s) = fs::read_to_string("/proc/self/mounts") else { return "[]".into() };
    let mut items = Vec::new();
    for (_, mount) in parse_mounts(&s) {
        if items.len() >= 6 {
            break;
        }
        let Some((pct, used_gib, total_gib)) = statvfs_gib(&mount) else { continue };
        items.push(format!(
            "{{\"mount\":\"{}\",\"pct\":{pct:.1},\"used_gib\":{used_gib:.2},\"total_gib\":{total_gib:.2}}}",
            json_escape(&mount)
        ));
    }
    format!("[{}]", items.join(","))
}

/// One btrfs subvolume mount, joined to the qgroup that measures it.
struct Subvol {
    mount: String,
    subvol: String,
    id: u64,
}

/// Pull `subvolid=` and `subvol=` out of a mount's option string. Both are
/// always present on a btrfs mount (the kernel synthesises them even when the
/// fstab entry omits them), which is what makes this join reliable.
fn parse_subvol_opts(opts: &str) -> Option<(u64, String)> {
    let mut id = None;
    let mut name = None;
    for o in opts.split(',') {
        if let Some(v) = o.strip_prefix("subvolid=") {
            id = v.parse::<u64>().ok();
        } else if let Some(v) = o.strip_prefix("subvol=") {
            name = Some(v.to_string());
        }
    }
    Some((id?, name.unwrap_or_else(|| "/".into())))
}

fn read_u64(path: &str) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse::<u64>().ok()
}

/// Per-subvolume usage WITHOUT root and without walking the tree.
///
/// This is the answer to "df says every btrfs mount is the same 69G/80G".
/// They are: on a single-pool layout every subvolume mount reports the pool's
/// figures, so df is structurally incapable of saying which subvolume is
/// holding the space. btrfs itself knows — quota groups track it — and the
/// numbers are exposed world-readable under /sys/fs/btrfs/<uuid>/qgroups/0_<id>.
/// So no `btrfs` binary, no sudo, no du(1) walk: two small sysfs reads per
/// mounted subvolume, which is why this can run every tick.
///
///   referenced = everything this subvolume can see (its apparent size)
///   exclusive  = what deleting it would ACTUALLY give back — the rest is
///                shared with snapshots/reflinks, and this gap is the number
///                people are missing when a delete frees nothing.
///
/// Returns "[]" when quotas are off, which is a legitimate state, not an
/// error: the caller falls back to the plain statvfs rows.
fn btrfs_storage_json() -> String {
    let Ok(mounts) = fs::read_to_string("/proc/self/mounts") else { return "[]".into() };

    // uuid -> mounted subvolumes. A pool can be mounted many times (one per
    // subvolume) and we want one entry per fs, each carrying its volumes.
    let mut by_uuid: Vec<(String, Vec<Subvol>)> = Vec::new();
    let mut dev_uuid: Vec<(String, String)> = Vec::new();
    for line in mounts.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 4 || f[2] != "btrfs" {
            continue;
        }
        let mount = decode_mount_escapes(f[1]);
        let Some((id, subvol)) = parse_subvol_opts(f[3]) else { continue };
        // Which pool this mount belongs to. Cached per device: a 15-subvolume
        // layout is 15 mounts of ONE pool, and this runs every tick.
        let uuid = match dev_uuid.iter().find(|(d, _)| d == f[0]) {
            Some((_, u)) => u.clone(),
            None => match btrfs_uuid_for_device(f[0]) {
                Some(u) => {
                    dev_uuid.push((f[0].to_string(), u.clone()));
                    u
                }
                None => continue,
            },
        };
        match by_uuid.iter_mut().find(|(u, _)| *u == uuid) {
            Some((_, v)) => {
                // The same subvolume mounted twice (e.g. /nix and /nix/store)
                // is one volume, not two rows of double-counted space.
                if !v.iter().any(|x| x.id == id) {
                    v.push(Subvol { mount, subvol, id });
                }
            }
            None => by_uuid.push((uuid, vec![Subvol { mount, subvol, id }])),
        }
    }

    let mut out = Vec::new();
    for (uuid, mut vols) in by_uuid {
        let base = format!("/sys/fs/btrfs/{uuid}");
        let alloc = |kind: &str, field: &str| read_u64(&format!("{base}/allocation/{kind}/{field}")).unwrap_or(0);
        // disk_total vs total_bytes is the RAID/DUP profile factor: metadata
        // is DUP here, so it burns two device bytes per logical byte. Using
        // total_bytes for free space is how a btrfs pool "loses" space that
        // was never missing.
        let (dt, du) = (alloc("data", "total_bytes"), alloc("data", "bytes_used"));
        let (mt, mu) = (alloc("metadata", "total_bytes"), alloc("metadata", "bytes_used"));
        let (st, su) = (alloc("system", "total_bytes"), alloc("system", "bytes_used"));
        let disk_alloc = alloc("data", "disk_total") + alloc("metadata", "disk_total") + alloc("system", "disk_total");
        let disk_used = alloc("data", "disk_used") + alloc("metadata", "disk_used") + alloc("system", "disk_used");
        // devices/ not devinfo/: devinfo/<id>/ has no size on current kernels
        // (checked: error_stats, fsid, in_fs_metadata, missing, replace_target,
        // scrub_speed_max, writeable — and that is all). devices/<name> is a
        // symlink into the block device's own sysfs node, which does have one,
        // in 512-byte sectors, unlike every other file in this tree.
        let dev_size: u64 = fs::read_dir(format!("{base}/devices"))
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .filter_map(|e| read_u64(&format!("{}/size", e.path().display())))
                    .map(|s| s * 512)
                    .sum()
            })
            .unwrap_or(0);
        let label = fs::read_to_string(format!("{base}/label")).unwrap_or_default().trim().to_string();

        // Biggest first: the point of the list is finding what ate the pool.
        let mut rows: Vec<(u64, String)> = Vec::new();
        for v in vols.drain(..) {
            let q = format!("{base}/qgroups/0_{}", v.id);
            let refer = read_u64(&format!("{q}/referenced")).unwrap_or(0);
            let excl = read_u64(&format!("{q}/exclusive")).unwrap_or(0);
            let limit = read_u64(&format!("{q}/max_referenced")).unwrap_or(0);
            rows.push((
                refer,
                format!(
                    "{{\"mount\":\"{}\",\"subvol\":\"{}\",\"id\":{},\"referenced\":{refer},\
                      \"exclusive\":{excl},\"limit\":{limit}}}",
                    json_escape(&v.mount),
                    json_escape(&v.subvol),
                    v.id
                ),
            ));
        }
        rows.sort_by(|a, b| b.0.cmp(&a.0));
        let vols_json: Vec<String> = rows.into_iter().map(|(_, j)| j).collect();

        out.push(format!(
            "{{\"uuid\":\"{uuid}\",\"label\":\"{}\",\"dev_size\":{dev_size},\
              \"alloc\":{disk_alloc},\"alloc_used\":{disk_used},\
              \"data_total\":{dt},\"data_used\":{du},\"meta_total\":{mt},\"meta_used\":{mu},\
              \"sys_total\":{st},\"sys_used\":{su},\"volumes\":[{}]}}",
            json_escape(&label),
            vols_json.join(",")
        ));
    }
    format!("[{}]", out.join(","))
}

/// Which btrfs pool a mounted device belongs to.
///
/// /sys/fs/btrfs/<uuid> has no back-pointer to mounts, so go by device. Note
/// the mount's own MAJ:MIN is useless here: btrfs mounts report an anonymous
/// device (0:31), not the block device, so /sys/dev/block cannot resolve it.
/// The mounts line's SOURCE field can — canonicalise it to its kernel block
/// name ("/dev/mapper/pool" -> "dm-0") and look for that name among the
/// devices each pool lists. Correct for a multi-device pool too, since every
/// member appears under devices/.
fn btrfs_uuid_for_device(dev: &str) -> Option<String> {
    let real = fs::canonicalize(dev).ok()?;
    let name = real.file_name()?.to_string_lossy().into_owned();
    fs::read_dir("/sys/fs/btrfs")
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        // "features" is a sibling of the uuid dirs, not one of them.
        .filter(|n| n.len() == 36 && n.matches('-').count() == 4)
        .find(|u| fs::metadata(format!("/sys/fs/btrfs/{u}/devices/{name}")).is_ok())
}

/// Every cgroup slice the watchdog can see, with the numbers that decide who
/// gets throttled or OOM-killed. This is the data behind the panel's slice
/// manager: memory.current against memory.high (the throttle point) and
/// memory.max (the kill point), plus the slice's own PSI — a slice can be
/// stalling on memory while the machine-wide figure looks calm.
///
/// `protected` mirrors what drain_kill_requests() enforces, so the manager
/// shows the same policy the daemon acts on rather than a second opinion.
/// The three things btop puts in its cpu box that /proc/stat cannot give:
/// what the chip is, how fast it is running right now, and how hot it is.
///
/// Model comes from cpuinfo. Frequency comes from cpufreq if the driver
/// exposes it and falls back to cpuinfo's "cpu MHz", which on a scaling core
/// is a snapshot of the same thing. Temperature prefers the coretemp hwmon
/// package sensor and falls back to the x86_pkg_temp thermal zone; on a
/// machine with neither, it is absent rather than zero — 0°C is a reading, and
/// this would not be one.
fn cpu_info_json() -> String {
    let ci = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let field = |k: &str| -> String {
        ci.lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_once(':'))
            .map(|(_, v)| v.trim().to_string())
            .unwrap_or_default()
    };
    let model = field("model name");

    let mhz = fs::read_to_string("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
        .ok()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .map(|khz| khz / 1000.0)
        .or_else(|| field("cpu MHz").parse().ok());

    // hwmon first: coretemp's package sensor is the one btop shows. temp1 is
    // "Package id 0" on every Intel part this runs on.
    let mut temp: Option<f64> = None;
    if let Ok(rd) = fs::read_dir("/sys/class/hwmon") {
        for e in rd.flatten() {
            let name = fs::read_to_string(e.path().join("name")).unwrap_or_default();
            if name.trim() != "coretemp" {
                continue;
            }
            if let Some(v) = fs::read_to_string(e.path().join("temp1_input"))
                .ok()
                .and_then(|s| s.trim().parse::<f64>().ok())
            {
                temp = Some(v / 1000.0);
                break;
            }
        }
    }
    if temp.is_none() {
        if let Ok(rd) = fs::read_dir("/sys/class/thermal") {
            for e in rd.flatten() {
                let t = fs::read_to_string(e.path().join("type")).unwrap_or_default();
                if !t.trim().starts_with("x86_pkg_temp") && !t.trim().starts_with("cpu") {
                    continue;
                }
                if let Some(v) = fs::read_to_string(e.path().join("temp"))
                    .ok()
                    .and_then(|s| s.trim().parse::<f64>().ok())
                {
                    temp = Some(v / 1000.0);
                    break;
                }
            }
        }
    }

    // Per-core, in core order. btop puts a temperature beside every core
    // meter, and coretemp labels its sensors "Core N" — which is NOT the same
    // as hwmon's temp<N>_input numbering, so the label is what decides the
    // slot rather than the file's index.
    let mut core_t: Vec<(usize, f64)> = Vec::new();
    if let Ok(rd) = fs::read_dir("/sys/class/hwmon") {
        for e in rd.flatten() {
            if fs::read_to_string(e.path().join("name")).unwrap_or_default().trim() != "coretemp" {
                continue;
            }
            let Ok(files) = fs::read_dir(e.path()) else { continue };
            for f in files.flatten() {
                let fname = f.file_name().to_string_lossy().into_owned();
                let Some(stem) = fname.strip_suffix("_label") else { continue };
                let label = fs::read_to_string(f.path()).unwrap_or_default();
                let Some(n) = label.trim().strip_prefix("Core ").and_then(|x| x.parse::<usize>().ok())
                else {
                    continue;
                };
                if let Some(v) = fs::read_to_string(e.path().join(format!("{stem}_input")))
                    .ok()
                    .and_then(|s| s.trim().parse::<f64>().ok())
                {
                    core_t.push((n, v / 1000.0));
                }
            }
        }
    }
    core_t.sort_by_key(|(n, _)| *n);
    let cores_json: Vec<String> = core_t.iter().map(|(_, v)| format!("{v:.1}")).collect();

    format!(
        "{{\"model\":\"{}\",\"mhz\":{},\"temp_c\":{},\"core_temps\":[{}]}}",
        json_escape(&model),
        mhz.map(|v| format!("{v:.0}")).unwrap_or_else(|| "null".into()),
        temp.map(|v| format!("{v:.1}")).unwrap_or_else(|| "null".into()),
        cores_json.join(","),
    )
}

/// How much this machine has moved, in total, since it booted.
///
/// /proc/net/dev and /proc/diskstats are already cumulative counters — the
/// rate fields elsewhere in this file are deltas taken FROM them — so the
/// totals cost nothing extra to publish and are exact rather than accumulated
/// by us. "Since boot" is the honest window: the kernel zeroes them at boot
/// and nothing here can see further back than that.
///
/// The panel does no arithmetic on these: the daemon owns the math, so a peer
/// collected over ssh and the local machine answer the same question the same
/// way.
fn read_uptime_s() -> f64 {
    fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next().and_then(|x| x.parse().ok()))
        .unwrap_or(0.0)
}

fn totals_json(uptime_s: f64) -> String {
    let n = read_net();
    let d = read_diskstats();
    format!(
        "{{\"net_rx_bytes\":{},\"net_tx_bytes\":{},\"disk_read_bytes\":{},\"disk_write_bytes\":{},\"since_s\":{:.0}}}",
        n.rx,
        n.tx,
        // diskstats counts 512-byte sectors regardless of the device's real
        // block size — that is the unit the field is defined in, not a guess.
        d.read_sectors.saturating_mul(512),
        d.write_sectors.saturating_mul(512),
        uptime_s,
    )
}

/// Containers and what they are using.
///
/// `docker stats --no-stream` takes a second or two because it samples every
/// container twice to get a cpu delta, so this rides the slow refresh with the
/// unit list rather than the 2s tick. Failing is normal and quiet: no docker
/// installed, no socket, or this user not in the docker group all mean the
/// same thing to the panel — an empty list, which reads as "no containers"
/// exactly as it should.
///
/// Values are kept as docker renders them ("469.7MiB / 7.595GiB", "0.33%")
/// rather than parsed into numbers here: they are already the units a person
/// reading a container list expects, and re-deriving them would be inventing
/// precision docker did not give.
fn containers_json() -> (String, String) {
    // `ps` is the authoritative list and it always answers; `stats` can spend
    // twenty seconds and hand back "--" in every column. So the list comes
    // from ps, and stats is merged onto it if and when it arrives.
    let run = |args: &[&str]| -> String {
        clean_command("docker")
            .args(args)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .unwrap_or_default()
    };

    let ps = run(&[
        "ps",
        "--format",
        "{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}\t{{.RunningFor}}\t{{.Command}}\t{{.State}}",
    ]);
    if ps.trim().is_empty() {
        return ("[]".into(), images_json());
    }
    let stats = run(&[
        "stats",
        "--no-stream",
        "--format",
        "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}",
    ]);
    // The image list carries the size, which `ps` does not: a container's
    // footprint on disk is a property of its image, and "which of these is
    // costing me four gigabytes" is one of the questions this view is for.
    let imgs = run(&["images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}"]);
    // WHICH IMAGE a container is actually running, by ID.
    //
    // `docker ps` reports {{.Image}} as the reference the container was
    // CREATED with, and renders it as a bare image ID whenever that reference
    // no longer resolves — which is the normal state of affairs here: CI
    // pushes a new :latest, the box pulls it, the tag moves, and the running
    // container is left holding an image that is now <none>. Matching images
    // to containers by "repo:tag" therefore reports a wall of false idles:
    // every long-running container on oci-apps looked like nothing ran it.
    //
    // The ID never moves. `ps -q` then one `inspect` resolves every running
    // container to the sha256 it is actually executing, in two calls rather
    // than one per container.
    let running = run(&["ps", "-q"]);
    let inspected = if running.trim().is_empty() {
        String::new()
    } else {
        let mut a: Vec<&str> = vec!["inspect", "--format", "{{.Name}}\t{{.Image}}"];
        a.extend(running.split_whitespace());
        run(&a)
    };
    // name -> short image id, the same 12 characters `docker images` prints.
    let image_id_of = |name: &str| -> String {
        inspected
            .lines()
            .find_map(|l| {
                let (n, id) = l.split_once('\t')?;
                (n.trim_start_matches('/') == name).then(|| {
                    id.trim().trim_start_matches("sha256:").chars().take(12).collect::<String>()
                })
            })
            .unwrap_or_default()
    };
    let size_of = |image: &str| -> String {
        imgs.lines()
            .map(|l| l.split('\t').collect::<Vec<_>>())
            .find(|p| p.first().map(|r| *r == image).unwrap_or(false))
            .and_then(|p| p.get(1).map(|s| s.to_string()))
            .unwrap_or_default()
    };

    let items: Vec<String> = ps
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            let name = *f.first()?;
            if name.is_empty() {
                return None;
            }
            let g = |i: usize| -> &str { f.get(i).copied().unwrap_or("") };
            // "--" is docker saying it could not read the cgroup, not a value.
            let st: Vec<&str> = stats
                .lines()
                .map(|s| s.split('\t').collect::<Vec<_>>())
                .find(|p| p.first() == Some(&name))
                .filter(|p| p.get(1) != Some(&"--"))
                .unwrap_or_default();
            let sv = |i: usize| -> &str { st.get(i).copied().unwrap_or("") };
            let image = g(2);
            Some(format!(
                "{{\"name\":\"{}\",\"cpu\":\"{}\",\"mem\":\"{}\",\"mem_pct\":\"{}\",\
                  \"net\":\"{}\",\"block\":\"{}\",\"pids\":\"{}\",\"status\":\"{}\",\
                  \"image\":\"{}\",\"image_id\":\"{}\",\"image_size\":\"{}\",\"ports\":\"{}\",\"uptime\":\"{}\",\
                  \"command\":\"{}\",\"state\":\"{}\"}}",
                json_escape(name),
                json_escape(sv(1)),
                json_escape(sv(2)),
                json_escape(sv(3)),
                json_escape(sv(4)),
                json_escape(sv(5)),
                json_escape(sv(6)),
                json_escape(g(1)),
                json_escape(image),
                json_escape(&image_id_of(g(0))),
                json_escape(&size_of(image)),
                json_escape(g(3)),
                json_escape(g(4)),
                json_escape(g(5)),
                json_escape(g(6)),
            ))
        })
        .collect();
    (format!("[{}]", items.join(",")), images_json())
}

/// Every image on the box, running or not.
///
/// A container list answers "what is running"; it cannot answer "what is this
/// costing me on disk", because the images nothing is running are exactly the
/// ones nobody notices.
fn images_json() -> String {
    let Ok(o) = clean_command("docker")
        .args([
            "images",
            "--format",
            "{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}\t{{.ID}}",
        ])
        .output()
    else {
        return "[]".into();
    };
    let Ok(t) = String::from_utf8(o.stdout) else { return "[]".into() };
    let items: Vec<String> = t
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 5 {
                return None;
            }
            Some(format!(
                "{{\"repo\":\"{}\",\"tag\":\"{}\",\"size\":\"{}\",\"created\":\"{}\",\"id\":\"{}\"}}",
                json_escape(f[0]),
                json_escape(f[1]),
                json_escape(f[2]),
                json_escape(f[3]),
                json_escape(f[4]),
            ))
        })
        .collect();
    format!("[{}]", items.join(","))
}

/// Is dockerd up at all?
///
/// Every other line on the containers and images pages is silent about the one
/// failure that produces all of them at once: an empty list because the daemon
/// is down reads exactly like an empty list because nothing is running. From
/// the outside `docker ps` cannot tell those apart -- it fails the same way it
/// succeeds-with-nothing -- so ask systemd, which knows.
///
/// `is-active` exits NONZERO for every state except active, which is the whole
/// point of it; the output is read regardless of the exit status, or an
/// inactive daemon would report as "unknown" and lose the distinction between
/// stopped, failed and never-installed.
fn docker_daemon_json() -> String {
    let state = clean_command("systemctl")
        .args(["is-active", "docker.service"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".into());
    format!(
        "{{\"unit\":\"docker.service\",\"state\":\"{}\",\"active\":{}}}",
        json_escape(&state),
        state == "active"
    )
}

/// The volumes, and which of them nothing is mounting.
///
/// The same question the images page asks, one layer down and with higher
/// stakes: an unused image is bytes you can re-pull, an unused volume is the
/// only copy of something. So `in use` is reported and nothing here removes
/// anything -- the panel's job is to make an orphan visible, not to guess that
/// it is garbage.
fn volumes_json() -> String {
    let run = |args: &[&str]| -> String {
        clean_command("docker")
            .args(args)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .unwrap_or_default()
    };
    // Anything NOT in the dangling set is mounted by something.
    let dangling = run(&["volume", "ls", "-q", "--filter", "dangling=true"]);
    let idle: Vec<&str> = dangling.lines().map(|l| l.trim()).collect();
    let items: Vec<String> = run(&["volume", "ls", "--format", "{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}"])
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 3 {
                return None;
            }
            Some(format!(
                "{{\"name\":\"{}\",\"driver\":\"{}\",\"mount\":\"{}\",\"in_use\":{}}}",
                json_escape(f[0]),
                json_escape(f[1]),
                json_escape(f[2]),
                !idle.contains(&f[0])
            ))
        })
        .collect();
    format!("[{}]", items.join(","))
}
/// The networks and how many containers sit on each.
fn networks_json() -> String {
    let Ok(o) = clean_command("docker")
        .args(["network", "ls", "--format", "{{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}"])
        .output()
    else {
        return "[]".into();
    };
    let Ok(t) = String::from_utf8(o.stdout) else { return "[]".into() };
    let items: Vec<String> = t
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 4 {
                return None;
            }
            Some(format!(
                "{{\"name\":\"{}\",\"driver\":\"{}\",\"scope\":\"{}\",\"id\":\"{}\"}}",
                json_escape(f[0]),
                json_escape(f[1]),
                json_escape(f[2]),
                json_escape(f[3]),
            ))
        })
        .collect();
    format!("[{}]", items.join(","))
}
/// The compose projects, read from the labels compose itself stamps.
///
/// Not derived from the repo: `com.docker.compose.project.config_files` is the
/// absolute path of the file that CREATED this container, recorded by the tool
/// that created it. That is a fact, where a repo scan is a guess -- and a
/// container carrying no compose label is not a gap in the scan, it is a
/// container nobody deployed the declared way, which is worth seeing.
fn compose_json() -> String {
    let Ok(o) = clean_command("docker")
        .args([
            "ps",
            "-a",
            "--format",
            "{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.config_files\"}}\t{{.Names}}\t{{.State}}",
        ])
        .output()
    else {
        return "[]".into();
    };
    let Ok(t) = String::from_utf8(o.stdout) else { return "[]".into() };
    let items: Vec<String> = t
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 5 {
                return None;
            }
            Some(format!(
                "{{\"project\":\"{}\",\"service\":\"{}\",\"file\":\"{}\",\"container\":\"{}\",\"state\":\"{}\",\"declared\":{}}}",
                json_escape(f[0]),
                json_escape(f[1]),
                json_escape(f[2]),
                json_escape(f[3]),
                json_escape(f[4]),
                !f[0].is_empty()
            ))
        })
        .collect();
    format!("[{}]", items.join(","))
}

/// A day of this machine, one line a minute.
///
/// Lives under XDG_DATA_HOME, not the runtime dir: the runtime dir is tmpfs
/// and "the last 24 hours" that vanishes on every reboot is not the last 24
/// hours. Plain JSONL because the file has to survive a daemon that was
/// killed mid-write — a truncated last line is one lost sample, where a
/// truncated binary format is the whole history.
fn now_unix() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn history_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))?;
    let dir = base.join("my-konsole");
    let _ = fs::create_dir_all(&dir);
    Some(dir.join("history.jsonl"))
}

const HISTORY_EVERY_TICKS: u64 = 30; // 60s at INTERVAL_MS
/// How long the per-minute samples are kept. Thirty days at one line a minute
/// is roughly 4MB of short JSON — nothing, next to being able to answer "was
/// last Tuesday like this too".
const HISTORY_WINDOW_S: f64 = 30.0 * 86_400.0;
/// The rolling summary the panel has always shown stays a DAY, whatever the
/// file now holds behind it. Widening the retention must not silently turn
/// "downloaded today" into "downloaded this month".
const HISTORY_SUMMARY_S: f64 = 86_400.0;

/// The local calendar date of a unix timestamp, as YYYY-MM-DD.
///
/// localtime_r, not arithmetic on the epoch: "per day" means the day the
/// person was living in, which is a timezone question — and one whose answer
/// changes twice a year in most of them.
fn local_date(ts: f64) -> String {
    let t = ts as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    format!("{:04}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday)
}

/// One day's worth, accumulated.
#[derive(Default)]
struct DayAcc {
    rx: f64,
    tx: f64,
    dr: f64,
    dw: f64,
    cpu_s: f64,
    mem_s: f64,
    swap_s: f64,
    dt: f64,
    n: usize,
}

/// Append this minute, drop anything older than a day, and return the summary
/// the panel shows.
///
/// The counters are cumulative, so "downloaded in the last 24h" is the newest
/// reading minus the oldest one still in the window — with one guard: a
/// counter that went BACKWARDS means the machine rebooted, and the difference
/// across a reboot is meaningless, so the window restarts at that point rather
/// than reporting a negative or an absurd total.
///
/// The percentages are time-weighted averages over the same window, which is
/// what "cpu%-time over 24h" has to mean for a number sampled once a minute.
fn history_step(cpu: f64, mem: f64, swap: f64, now: f64) -> String {
    let Some(path) = history_path() else { return "{}".into() };
    let t = totals_json(0.0);
    let g = |k: &str| -> f64 {
        t.split(&format!("\"{k}\":"))
            .nth(1)
            .and_then(|r| r.split(|c: char| !(c.is_ascii_digit() || c == '.')).find(|x| !x.is_empty()))
            .and_then(|x| x.parse().ok())
            .unwrap_or(0.0)
    };
    let line = format!(
        "{{\"ts\":{now:.0},\"cpu\":{cpu:.1},\"mem\":{mem:.1},\"swap\":{swap:.1},\"rx\":{:.0},\"tx\":{:.0},\"dr\":{:.0},\"dw\":{:.0}}}",
        g("net_rx_bytes"),
        g("net_tx_bytes"),
        g("disk_read_bytes"),
        g("disk_write_bytes"),
    );

    let mut kept: Vec<String> = fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .filter(|l| {
            l.split("\"ts\":")
                .nth(1)
                .and_then(|r| r.split(|c: char| !c.is_ascii_digit()).find(|x| !x.is_empty()))
                .and_then(|x| x.parse::<f64>().ok())
                .map(|ts| now - ts <= HISTORY_WINDOW_S)
                .unwrap_or(false)
        })
        .map(|l| l.to_string())
        .collect();
    kept.push(line);
    // Rewrite whole: the file is at most 1441 short lines, and appending plus
    // periodically compacting is two failure modes where this is one.
    let _ = fs::write(&path, kept.join("\n") + "\n");

    let num = |l: &str, k: &str| -> f64 {
        l.split(&format!("\"{k}\":"))
            .nth(1)
            .and_then(|r| r.split(|c: char| !(c.is_ascii_digit() || c == '.')).find(|x| !x.is_empty()))
            .and_then(|x| x.parse().ok())
            .unwrap_or(0.0)
    };
    // Walk forward summing only forward-going differences, so a reboot in the
    // middle of the window costs that one step rather than the whole figure.
    let (mut rx, mut tx, mut dr, mut dw) = (0.0, 0.0, 0.0, 0.0);
    let (mut cpu_s, mut mem_s, mut swap_s) = (0.0, 0.0, 0.0);
    let mut recent = 0usize;
    for w in kept.windows(2) {
        let (a, b) = (&w[0], &w[1]);
        // The file holds a month; this summary is still a DAY. Pairs older
        // than that are the per-day table's business, below.
        if now - num(b, "ts") > HISTORY_SUMMARY_S {
            continue;
        }
        recent += 1;
        let step = |k: &str| -> f64 { (num(b, k) - num(a, k)).max(0.0) };
        rx += step("rx");
        tx += step("tx");
        dr += step("dr");
        dw += step("dw");
        let dt = (num(b, "ts") - num(a, "ts")).clamp(0.0, 600.0);
        cpu_s += num(b, "cpu") * dt;
        mem_s += num(b, "mem") * dt;
        swap_s += num(b, "swap") * dt;
    }
    // The span of what the SUMMARY covers, which is at most a day even though
    // the file behind it now reaches back a month.
    let span = kept
        .iter()
        .map(|l| num(l, "ts"))
        .find(|ts| now - ts <= HISTORY_SUMMARY_S)
        .map(|ts| (now - ts).max(1.0))
        .unwrap_or(1.0);

    // PER DAY, over everything the file holds.
    //
    // Same forward-delta walk as the summary above, bucketed by the local date
    // of the LATER sample of each pair — so the minute that straddles midnight
    // is credited to the day it ended in, and a reboot costs that one step
    // rather than a whole day. The averages are time-weighted for the same
    // reason the summary's are: samples are a minute apart until they are not.
    let mut days: Vec<(String, DayAcc)> = vec![];
    for w in kept.windows(2) {
        let (a, b) = (&w[0], &w[1]);
        let date = local_date(num(b, "ts"));
        if days.last().map(|(d, _)| d != &date).unwrap_or(true) {
            days.push((date, DayAcc::default()));
        }
        let acc = &mut days.last_mut().expect("just pushed").1;
        let step = |k: &str| -> f64 { (num(b, k) - num(a, k)).max(0.0) };
        acc.rx += step("rx");
        acc.tx += step("tx");
        acc.dr += step("dr");
        acc.dw += step("dw");
        let dt = (num(b, "ts") - num(a, "ts")).clamp(0.0, 600.0);
        acc.cpu_s += num(b, "cpu") * dt;
        acc.mem_s += num(b, "mem") * dt;
        acc.swap_s += num(b, "swap") * dt;
        acc.dt += dt;
        acc.n += 1;
    }
    // Newest first: the day people want is today, and it should not be at the
    // bottom of a month-long table.
    days.reverse();
    let days_json: Vec<String> = days
        .iter()
        .map(|(d, a)| {
            let w = a.dt.max(1.0);
            format!(
                "{{\"date\":\"{d}\",\"samples\":{},\"seconds\":{:.0},\
                  \"cpu_pct_avg\":{:.2},\"mem_pct_avg\":{:.2},\"swap_pct_avg\":{:.2},\
                  \"net_rx_bytes\":{:.0},\"net_tx_bytes\":{:.0},\
                  \"disk_read_bytes\":{:.0},\"disk_write_bytes\":{:.0}}}",
                a.n, a.dt, a.cpu_s / w, a.mem_s / w, a.swap_s / w, a.rx, a.tx, a.dr, a.dw
            )
        })
        .collect();

    format!(
        "{{\"window_s\":{span:.0},\"samples\":{},\"net_rx_bytes\":{rx:.0},\"net_tx_bytes\":{tx:.0},\
          \"disk_read_bytes\":{dr:.0},\"disk_write_bytes\":{dw:.0},\
          \"cpu_pct_avg\":{:.2},\"mem_pct_avg\":{:.2},\"swap_pct_avg\":{:.2},\
          \"days\":[{}]}}",
        recent + 1,
        cpu_s / span,
        mem_s / span,
        swap_s / span,
        days_json.join(","),
    )
}

/// Globally routable? Everything RFC1918, CGNAT, loopback, link-local and
/// unique-local is not, and on this fleet that is exactly the set that means
/// "you cannot reach it from the internet".
fn is_global(a: &str) -> bool {
    if a.contains(':') {
        return !(a.starts_with("fe80") || a.starts_with("fc") || a.starts_with("fd") || a == "::1");
    }
    let o: Vec<u32> = a.split('.').filter_map(|x| x.parse().ok()).collect();
    if o.len() != 4 {
        return false;
    }
    !(o[0] == 10
        || o[0] == 127
        || (o[0] == 172 && (16..=31).contains(&o[1]))
        || (o[0] == 192 && o[1] == 168)
        || (o[0] == 169 && o[1] == 254)
        || (o[0] == 100 && (64..=127).contains(&o[1])))
}

/// Who and where this machine is: the identity the panel puts in its header,
/// and the network configuration the net box shows.
///
/// All of it comes from the snapshot rather than being read locally by the
/// panel, because the panel can be pointed at a peer — and a header that said
/// "surface-nixos" while the numbers underneath came from oci-apps would be
/// worse than showing nothing.
fn host_info_json() -> String {
    let os = fs::read_to_string("/etc/os-release")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("PRETTY_NAME=").map(|v| v.trim_matches('"').to_string()))
        .unwrap_or_default();
    let host = fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default().trim().to_string();
    // The user this is sampling AS, which is not cosmetic: what it can read in
    // /proc and what it is allowed to signal both follow from it.
    let user = read_uid_names()
        .get(&current_uid())
        .cloned()
        .unwrap_or_else(|| current_uid().to_string());
    let kernel = fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default().trim().to_string();

    // ip(8) rather than parsing /proc/net/{fib_trie,if_inet6} by hand: those
    // are undocumented debug formats and this one is stable and universal.
    let addrs = clean_command("ip")
        .args(["-o", "addr", "show"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    let mut ifaces: Vec<String> = Vec::new();
    let mut addr_list: Vec<(String, String)> = Vec::new();
    for line in addrs.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 4 || f[1] == "lo" {
            continue;
        }
        // Link-local tells you nothing about where a machine is reachable.
        if f[3].starts_with("fe80:") {
            continue;
        }
        addr_list.push((f[1].to_string(), f[3].split('/').next().unwrap_or("").to_string()));
        // MTU and operational state alongside the address. On a mesh
        // interface these are most of what is knowable without root: wg(8)
        // and /etc/wireguard are root-only, so the keys, the last handshake
        // and the per-peer transfer counters are simply not available to an
        // unprivileged sampler — on the desktop AND on every VM. Publishing
        // what CAN be read and saying what cannot beats blank fields that
        // look like a bug.
        let sysfs = |k: &str| -> String {
            fs::read_to_string(format!("/sys/class/net/{}/{k}", f[1]))
                .map(|x| x.trim().to_string())
                .unwrap_or_default()
        };
        ifaces.push(format!(
            "{{\"name\":\"{}\",\"addr\":\"{}\",\"mtu\":\"{}\",\"state\":\"{}\",\"mesh\":{}}}",
            json_escape(f[1]),
            json_escape(f[3]),
            json_escape(&sysfs("mtu")),
            json_escape(&sysfs("operstate")),
            f[1].starts_with("wg")
        ));
    }

    let route = clean_command("ip")
        .args(["-o", "route", "show", "default"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    let gw: Vec<&str> = route.split_whitespace().collect();
    let gateway = gw.iter().position(|x| *x == "via").and_then(|i| gw.get(i + 1)).copied().unwrap_or("");
    let wan_if = gw.iter().position(|x| *x == "dev").and_then(|i| gw.get(i + 1)).copied().unwrap_or("");

    // The public address, worked out from the interfaces rather than asked of
    // a third party. On a VM with a routable NIC that IS the public address
    // and no lookup is needed; on a machine behind NAT it genuinely cannot be
    // known from here, and saying "behind NAT" is a truer answer than quietly
    // handing this machine's identity to whatever echo service was handy.
    let public = addr_list
        .iter()
        .find(|(name, a)| !name.starts_with("wg") && is_global(a))
        .map(|(_, a)| a.clone())
        .unwrap_or_default();

    let resolv = fs::read_to_string("/etc/resolv.conf").unwrap_or_default();
    let dns: Vec<String> = resolv
        .lines()
        .filter_map(|l| l.strip_prefix("nameserver "))
        .map(|x| format!("\"{}\"", json_escape(x.trim())))
        .collect();
    let search: Vec<String> = resolv
        .lines()
        .filter_map(|l| l.strip_prefix("search "))
        .flat_map(|x| x.split_whitespace())
        .map(|x| format!("\"{}\"", json_escape(x)))
        .collect();

    format!(
        "{{\"host\":\"{}\",\"os\":\"{}\",\"kernel\":\"{}\",\"user\":\"{}\",\"gateway\":\"{}\",\"wan_if\":\"{}\",\"public\":\"{}\",\"ifaces\":[{}],\"dns\":[{}],\"search\":[{}]}}",
        json_escape(&host),
        json_escape(&os),
        json_escape(&kernel),
        json_escape(&user),
        json_escape(gateway),
        json_escape(wan_if),
        json_escape(&public),
        ifaces.join(","),
        dns.join(","),
        search.join(","),
    )
}

/// Every DECLARED service unit and its state, user manager and system manager
/// both.
///
/// proc_table is the top-N by CPU, which answers "what is eating this box" and
/// is silent on the opposite question: what is supposed to be running. A unit
/// that died at boot, or one that is up and doing nothing, never appears there
/// — absence looks identical to idle. This list is what makes the difference
/// visible.
///
/// systemctl escapes unit names (app-at\x2dspi...), and those escapes are
/// literal backslashes in the output, so json_escape has to run over them or
/// the snapshot is not valid JSON.
fn services_json() -> String {
    let mut items: Vec<String> = Vec::new();
    for (scope, first) in [("user", "--user"), ("system", "--system")] {
        let run = |sub: &str| -> Vec<Vec<String>> {
            let args = [first, sub, "--type=service", "--all", "--no-legend", "--plain", "--no-pager"];
            clean_command("systemctl")
                .args(args)
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|t| {
                    t.lines()
                        .map(|l| l.split_whitespace().map(|x| x.to_string()).collect())
                        .collect()
                })
                .unwrap_or_default()
        };

        // list-units only knows units systemd has LOADED. A unit that is
        // declared but has never been started — or was stopped and unloaded —
        // is absent from it entirely, which is exactly the case someone opens
        // this list to find ("plasmashell is dead, where is it?"). So the
        // declared set comes from list-unit-files and the runtime state is
        // layered on top of it, rather than the other way round.
        let mut seen: Vec<String> = Vec::new();
        for f in run("list-units") {
            if f.len() < 4 || !f[0].ends_with(".service") {
                continue;
            }
            seen.push(f[0].clone());
            items.push(format!(
                "{{\"name\":\"{}\",\"scope\":\"{scope}\",\"load\":\"{}\",\"active\":\"{}\",\"sub\":\"{}\"}}",
                json_escape(&f[0]),
                json_escape(&f[1]),
                json_escape(&f[2]),
                json_escape(&f[3]),
            ));
        }
        for f in run("list-unit-files") {
            // name state preset
            if f.len() < 2 || !f[0].ends_with(".service") || seen.contains(&f[0]) {
                continue;
            }
            // Not loaded at all: systemd knows the unit exists and has no
            // runtime state for it. Reported as such rather than guessed at.
            items.push(format!(
                "{{\"name\":\"{}\",\"scope\":\"{scope}\",\"load\":\"{}\",\"active\":\"not-loaded\",\"sub\":\"—\"}}",
                json_escape(&f[0]),
                json_escape(&f[1]),
            ));
        }
    }
    format!("[{}]", items.join(","))
}

fn slices_json(protected: &[String]) -> String {
    let mut items = Vec::new();
    let push = |dir: &str, name: String, items: &mut Vec<String>| {
        let cur = read_u64(&format!("{dir}/memory.current"));
        let Some(cur) = cur else { return };
        // memory.high/max read "max" when unset — no limit, not zero.
        let lim = |f: &str| -> f64 {
            fs::read_to_string(format!("{dir}/{f}"))
                .ok()
                .and_then(|v| v.trim().parse::<f64>().ok())
                .unwrap_or(-1.0)
        };
        let psi = |f: &str, key: &str| -> f64 {
            fs::read_to_string(format!("{dir}/{f}"))
                .ok()
                .and_then(|s| {
                    s.lines().find(|l| l.starts_with("some")).and_then(|l| {
                        l.split_whitespace()
                            .find_map(|t| t.strip_prefix(key))
                            .and_then(|v| v.parse::<f64>().ok())
                    })
                })
                .unwrap_or(0.0)
        };
        let swap = read_u64(&format!("{dir}/memory.swap.current")).unwrap_or(0);
        let pids = read_u64(&format!("{dir}/pids.current")).unwrap_or(0);
        let prot = protected.iter().any(|p| *p == name);
        items.push(format!(
            "{{\"name\":\"{}\",\"current\":{cur},\"swap\":{swap},\"high\":{:.0},\"max\":{:.0},\
              \"pids\":{pids},\"mem_psi\":{:.2},\"io_psi\":{:.2},\"cpu_psi\":{:.2},\"protected\":{prot}}}",
            json_escape(&name),
            lim("memory.high"),
            lim("memory.max"),
            psi("memory.pressure", "avg10="),
            psi("io.pressure", "avg10="),
            psi("cpu.pressure", "avg10="),
        ));
    };

    // Top-level slices, then this user's own slice — the one whose cap is what
    // actually kills things here, and which is nested a level down.
    if let Ok(rd) = fs::read_dir("/sys/fs/cgroup") {
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".slice"))
            .collect();
        names.sort();
        for n in names {
            push(&format!("/sys/fs/cgroup/{n}"), n.clone(), &mut items);
        }
    }
    let uid = current_uid();
    push(
        &format!("/sys/fs/cgroup/user.slice/user-{uid}.slice"),
        format!("user-{uid}.slice"),
        &mut items,
    );
    format!("[{}]", items.join(","))
}

/// Best-effort GPU VRAM read for the "vram" field. Tries amdgpu's sysfs
/// counters first (reliable, byte-accurate), then falls back to i915's
/// debugfs-style file if present. On this Intel Surface neither the amdgpu
/// files nor a readable i915_gem_gtt exist, so None — and therefore JSON
/// null — is the expected, correct result, not a failure to be logged.
fn read_vram() -> Option<(f64, f64)> {
    let rd = fs::read_dir("/sys/class/drm").ok()?;
    for e in rd.flatten() {
        let name = e.file_name();
        let Some(nm) = name.to_str() else { continue };
        // Only bare "cardN" directories carry a `device` symlink to the GPU;
        // connector directories look like "cardN-DP-1" and have none of the
        // files below.
        if !nm.starts_with("card") || !nm["card".len()..].chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let dev = e.path().join("device");

        if let (Ok(t), Ok(u)) =
            (fs::read_to_string(dev.join("mem_info_vram_total")), fs::read_to_string(dev.join("mem_info_vram_used")))
        {
            if let (Ok(tb), Ok(ub)) = (t.trim().parse::<f64>(), u.trim().parse::<f64>()) {
                return Some((tb / 1_048_576.0, ub / 1_048_576.0)); // bytes -> MiB
            }
        }

        if let Ok(gtt) = fs::read_to_string(dev.join("i915_gem_gtt")) {
            if let Some(pair) = parse_i915_gem_gtt(&gtt) {
                return Some(pair);
            }
        }
    }
    None
}

/// i915_gem_gtt's format isn't a stable, documented one — this is a
/// best-effort scrape that returns (total_mib, used_mib) only when it finds
/// clearly-labelled "total" and "used"/"active" lines, and skips (returns
/// None) otherwise rather than guess.
fn parse_i915_gem_gtt(s: &str) -> Option<(f64, f64)> {
    let first_number = |line: &str| -> Option<f64> {
        line.split_whitespace().find_map(|tok| {
            let cleaned: String = tok.chars().filter(|c| c.is_ascii_digit() || *c == '.').collect();
            if cleaned.is_empty() { None } else { cleaned.parse::<f64>().ok() }
        })
    };
    let mut total = None;
    let mut used = None;
    for line in s.lines() {
        let lower = line.to_ascii_lowercase();
        let Some(n) = first_number(&lower) else { continue };
        if lower.contains("total") {
            total = Some(n);
        } else if lower.contains("used") || lower.contains("active") {
            used = Some(n);
        }
    }
    match (total, used) {
        (Some(t), Some(u)) => Some((t / 1024.0, u / 1024.0)), // KiB -> MiB
        _ => None,
    }
}

/// GPU memory, split into the two kinds that are not interchangeable.
///
/// DEDICATED is memory that belongs to the card and to nothing else: a T4's
/// 16G, a discrete Radeon's VRAM. Filling it means the GPU starts evicting.
///
/// SHARED is system RAM the GPU has been given: an integrated chip's aperture,
/// or a discrete card's GTT spill. It comes out of the same pool as everything
/// else on the box, so filling it is a memory-pressure problem rather than a
/// GPU one — which is exactly why merging the two into a single "VRAM" figure
/// answers neither question.
///
/// A machine can have both (a T4 host), one (most of this fleet: an integrated
/// chip with shared only), or neither that is readable. Intel i915 exposes no
/// usage at all through sysfs — the numbers live in debugfs, which is root —
/// so on those boxes this reports absent rather than guessing a number.
fn vram_detail_json() -> String {
    let mut dedicated: Option<(f64, f64)> = None; // (used, total) bytes
    let mut shared: Option<(f64, f64)> = None;
    let mut source = "none";

    if let Ok(rd) = fs::read_dir("/sys/class/drm") {
        for e in rd.flatten() {
            let name = e.file_name();
            let Some(nm) = name.to_str() else { continue };
            if !nm.starts_with("card") || !nm["card".len()..].chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            let dev = e.path().join("device");
            let pair = |a: &str, b: &str| -> Option<(f64, f64)> {
                let u: f64 = fs::read_to_string(dev.join(a)).ok()?.trim().parse().ok()?;
                let t: f64 = fs::read_to_string(dev.join(b)).ok()?.trim().parse().ok()?;
                if t > 0.0 { Some((u, t)) } else { None }
            };
            if let Some(p) = pair("mem_info_vram_used", "mem_info_vram_total") {
                dedicated = Some(p);
                source = "amdgpu";
            }
            // GTT is the card's window onto system RAM: shared by definition.
            if let Some(p) = pair("mem_info_gtt_used", "mem_info_gtt_total") {
                shared = Some(p);
                source = "amdgpu";
            }
        }
    }

    // NVIDIA publishes nothing usable through sysfs, so nvidia-smi is the only
    // way in. Bounded, because on a busy or wedged GPU it blocks rather than
    // failing, and this runs on the sampler's 2s tick.
    if dedicated.is_none() {
        if let Ok(o) = clean_command("nvidia-smi")
            .args([
                "--query-gpu=memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ])
            .output()
        {
            if let Ok(t) = String::from_utf8(o.stdout) {
                if let Some(line) = t.lines().next() {
                    let f: Vec<f64> =
                        line.split(',').filter_map(|x| x.trim().parse().ok()).collect();
                    if f.len() == 2 && f[1] > 0.0 {
                        // nvidia-smi reports MiB with --nounits.
                        dedicated = Some((f[0] * 1_048_576.0, f[1] * 1_048_576.0));
                        source = "nvidia";
                    }
                }
            }
        }
    }

    let one = |p: Option<(f64, f64)>| -> String {
        match p {
            Some((u, t)) => format!("{{\"used\":{u:.0},\"total\":{t:.0}}}"),
            None => "null".into(),
        }
    };
    format!(
        "{{\"dedicated\":{},\"shared\":{},\"source\":\"{source}\"}}",
        one(dedicated),
        one(shared)
    )
}

fn vram_json(v: Option<(f64, f64)>) -> String {
    match v {
        Some((total, used)) => format!("{{\"total\":{total:.0},\"used\":{used:.0}}}"),
        None => "null".to_string(),
    }
}

// Battery — read straight from sysfs, never upowerd. On the Surface Pro 8 the
// SAM controller intermittently reports voltage_now=0, which sends upowerd's
// percentage math to NaN and its threshold actions silently stop firing —
// battery-watchdog.service (aa_desk-usr .../configuration_system-protection-
// battery.nix) exists on the privileged side for exactly that reason, with a
// multi-voter design to survive a frozen gauge. This reader is READ-ONLY: it
// publishes what sysfs says so the panel can show it, and does NOT decide to
// hibernate — that stays the sole job of the systemd-side watchdog, which is
// already the single choke point session-checkpoint-hibernate.service and
// hibernate-preflight are wired to (see configuration_session-checkpoint.nix,
// configuration_pre-hibernate-warning.nix). A second trigger here, running
// unprivileged in the tray daemon, would race the existing one instead of
// replacing it — worse than the one path that exists today.
struct BatteryReading {
    present: bool,
    pct: f64,
    status: String,
    minutes_left: Option<f64>,
}

fn find_battery_dir() -> Option<PathBuf> {
    let rd = fs::read_dir("/sys/class/power_supply").ok()?;
    for e in rd.flatten() {
        let name = e.file_name();
        let Some(nm) = name.to_str() else { continue };
        if nm.starts_with("BAT") {
            return Some(e.path());
        }
    }
    None
}

/// `None` means no battery directory at all (desktop). `Some(present=false)`
/// means the dir exists but the kernel currently reports no cell attached
/// (present flips transiently on some hardware) — the panel should show
/// "no battery" rather than stale numbers either way.
fn read_battery() -> Option<BatteryReading> {
    let dir = find_battery_dir()?;
    let read = |f: &str| -> Option<String> {
        fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string())
    };
    let present = read("present").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1) != 0;
    if !present {
        return Some(BatteryReading { present: false, pct: 0.0, status: "Absent".into(), minutes_left: None });
    }
    let pct = read("capacity").and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
    let status = read("status").unwrap_or_else(|| "Unknown".into());
    // Time-to-empty only when discharging AND power_now is known and
    // strictly positive. This is the divide-by-zero guard: a zero or
    // missing power_now (SAM freeze, AC just unplugged, no reading yet)
    // must produce "unknown", never a NaN/Infinity that would break the
    // widget's JSON.parse and take the whole panel down with it.
    let power_now = read("power_now").and_then(|s| s.parse::<f64>().ok());
    let energy_now = read("energy_now").and_then(|s| s.parse::<f64>().ok());
    let minutes_left = match (status.as_str(), power_now, energy_now) {
        ("Discharging", Some(p), Some(e)) if p > 0.0 && e >= 0.0 => {
            let m = e / p * 60.0;
            if m.is_finite() { Some(m) } else { None }
        }
        _ => None,
    };
    Some(BatteryReading { present: true, pct, status, minutes_left })
}

/// Battery block of the snapshot JSON. `null` when there is no battery at
/// all (desktop) so the widget can tell "no battery" apart from "battery
/// present but reading unavailable".
fn battery_json(b: &Option<BatteryReading>) -> String {
    let Some(b) = b else { return "null".into() };
    if !b.present {
        return "{\"present\":false}".into();
    }
    // status comes straight from the kernel (Charging/Discharging/Full/Not
    // charging/Unknown) — no free-form text, but strip quotes defensively
    // rather than trust sysfs never to hand back something that breaks JSON.
    let status: String = b.status.chars().filter(|c| *c != '"' && *c != '\\').collect();
    let minutes = match b.minutes_left {
        Some(m) => format!("{m:.0}"),
        None => "null".into(),
    };
    format!(
        "{{\"present\":true,\"pct\":{:.0},\"status\":\"{status}\",\"charging\":{},\"minutes_left\":{minutes}}}",
        b.pct,
        status == "Charging",
    )
}

/// Everything one snapshot is made of. It is a struct and not a
/// parameter list because a parameter list this long is ordered, and the
/// order is invisible at the call site: two `&str` swapped still compiles,
/// and lies. Named fields make adding a figure one line instead of five
/// edits that have to stay in lockstep.
struct Snapshot<'a> {
    cpu: f64,
    cores: &'a [f64],
    cpu_detail: &'a str,
    mem: f64,
    swap: f64,
    mem_detail: &'a str,
    swap_detail: &'a str,
    disk: f64,
    disk_r: f64,
    disk_w: f64,
    disks: &'a str,
    vram: Option<(f64, f64)>,
    vram_detail: &'a str,
    net_rx: f64,
    net_tx: f64,
    load1: f64,
    load5: f64,
    load15: f64,
    slice_cur: f64,
    slice_max: f64,
    battery: &'a Option<BatteryReading>,
    procs: &'a str,
    proc_table: &'a str,
    proc_spine: &'a str,
    cpu_info: &'a str,
    host_info: &'a str,
    totals: &'a str,
    history: &'a str,
    containers: &'a str,
    images: &'a str,
    docker_daemon: &'a str,
    volumes: &'a str,
    networks: &'a str,
    compose: &'a str,
    storage: &'a str,
    slices: &'a str,
    services: &'a str,
    reclaim: &'a str,
    health: &'a str,
    listening: &'a str,
}

/// Serialise one sample. Hand-rolled rather than serde_json: it is a fixed
/// shape written every 2s and read by QML's JSON.parse, and the whole point of
/// this file is that the machine is measured once and cheaply.
fn render(s: &Snapshot<'_>) -> String {
    let &Snapshot {
        cpu,
        cores,
        cpu_detail,
        mem,
        swap,
        mem_detail,
        swap_detail,
        disk,
        disk_r,
        disk_w,
        disks,
        vram,
        vram_detail,
        net_rx,
        net_tx,
        load1,
        load5,
        load15,
        slice_cur,
        slice_max,
        battery,
        procs,
        proc_table,
        proc_spine,
        cpu_info,
        host_info,
        totals,
        history,
        containers,
        images,
        docker_daemon,
        volumes,
        networks,
        compose,
        storage,
        slices,
        services,
        reclaim,
        health,
        listening,
    } = s;

    // Named, not positional: this format string mixes inline-captured names
    // with `{}` holes, and when the cores list was positional it was simply
    // left out of the argument list, shifting vram into its slot and every
    // later argument by one.
    let cores_joined = cores
        .iter()
        .map(|c| format!("{c:.1}"))
        .collect::<Vec<String>>()
        .join(",");
    let slice_pct = if slice_max > 0.0 { slice_cur / slice_max * 100.0 } else { 0.0 };
    let mut s = String::with_capacity(1536);
    let _ = write!(
        s,
        "{{\"cpu\":{cpu:.1},\"cores\":[{cores_joined}],\"cpu_detail\":{cpu_detail},\
          \"mem\":{mem:.1},\"swap\":{swap:.1},\
          \"mem_detail\":{mem_detail},\"swap_detail\":{swap_detail},\
          \"vram\":{},\"vram_detail\":{vram_detail},\
          \"disk\":{disk:.1},\"disk_r\":{disk_r:.2},\"disk_w\":{disk_w:.2},\
          \"disks\":{disks},\
          \"net_rx\":{net_rx:.2},\"net_tx\":{net_tx:.2},\
          \"load1\":{load1:.2},\"load5\":{load5:.2},\"load15\":{load15:.2},\
          \"psi\":{{\"cpu\":{},\"io\":{},\"memory\":{}}},\
          \"slice_gib\":{slice_cur:.2},\"slice_max_gib\":{slice_max:.2},\"slice_pct\":{slice_pct:.1},\
          \"battery\":{},\
          \"storage\":{storage},\"slices\":{slices},\"services\":{services},\"reclaim\":{reclaim},\"health\":{health},\"listening\":{listening},\
          \"cpu_info\":{cpu_info},\"host_info\":{host_info},\"totals\":{totals},\"history\":{history},\"containers\":{containers},\"images\":{images},\"docker_daemon\":{docker_daemon},\"volumes\":{volumes},\"networks\":{networks},\"compose\":{compose},\"procs\":{procs},\"proc_table\":{proc_table},\"proc_spine\":{proc_spine},\"ts\":{}}}",
        vram_json(vram),
        pressure_block("cpu"),
        pressure_block("io"),
        pressure_block("memory"),
        battery_json(battery),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    );
    s
}

/// Signals the panel's process table may send. Not just SIGTERM/SIGKILL: a
/// process table that can only destroy is a blunt instrument, and the reason
/// this one exists is a machine that thrashes — STOP/CONT to freeze a runaway
/// without losing its state is often the right first move, and HUP is how you
/// tell a daemon to reload rather than die.
fn signal_by_name(name: &str) -> Option<i32> {
    Some(match name {
        "TERM" => libc::SIGTERM, // ask politely; the default
        "KILL" => libc::SIGKILL, // unignorable, unmaskable, no cleanup
        "INT"  => libc::SIGINT,  // as if Ctrl-C
        "HUP"  => libc::SIGHUP,  // reload for daemons, hangup for the rest
        "QUIT" => libc::SIGQUIT, // terminate + core dump
        "STOP" => libc::SIGSTOP, // freeze without killing — unignorable
        "CONT" => libc::SIGCONT, // resume a stopped one
        "USR1" => libc::SIGUSR1, // application-defined
        _ => return None,
    })
}

/// Every child this daemon spawns, with the dynamic-loader environment
/// scrubbed first.
///
/// This daemon is a Tauri app, so its own environment carries an
/// LD_LIBRARY_PATH pointing at the glibc its webkit stack was built against.
/// Children inherit it, and on NixOS a system binary built against a DIFFERENT
/// glibc then loads that older libc.so.6 underneath its own libdl/libpthread
/// and dies before main():
///
///   systemctl: .../glibc-2.40/lib/libc.so.6: version `GLIBC_ABI_DT_X86_64_PLT'
///   not found (required by .../glibc-2.42/lib/libdl.so.2)
///
/// which is exactly how `k` → RESTART came back "failed" for a unit that was
/// perfectly restartable. Nothing we spawn wants our library path, so drop it
/// (and LD_PRELOAD with it) rather than special-case each call site.
fn clean_command(program: &str) -> Command {
    let mut c = Command::new(program);
    c.env_remove("LD_LIBRARY_PATH").env_remove("LD_PRELOAD");
    c
}

/// The systemd unit a pid belongs to, if any. cgroup v2 puts it in the last
/// path component: ".../user@1000.service/app.slice/app-foo-1234.scope".
/// `.scope` units are transient wrappers around something already launched —
/// systemd cannot restart one, so those come back as None and take the
/// re-exec path instead.
fn proc_user_unit(pid: i32) -> Option<String> {
    let cg = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
    let path = cg.lines().find_map(|l| l.rsplit(':').next().map(|s| s.to_string()))?;
    // Only this user's own manager can be driven without root, so anything
    // outside user@<uid>.service is not ours to restart.
    if !path.contains(&format!("user@{}.service", current_uid())) {
        return None;
    }
    let unit = path.rsplit('/').next()?.to_string();
    if unit.ends_with(".service") { Some(unit) } else { None }
}

/// Restart, not just kill. Two honest strategies, in order:
///
///   1. A user systemd unit — hand it to `systemctl --user restart`, which is
///      the only way the process comes back with its real dependencies,
///      environment and cgroup intact.
///   2. Anything else — capture argv and cwd BEFORE signalling (both vanish
///      the instant the process dies), TERM it, then re-exec.
///
/// The re-exec path is deliberately not disguised: the replacement is a child
/// of this daemon, so it inherits the daemon's session and environment (minus
/// the loader vars clean_command drops), not the original's. That is a real
/// difference and the caller is told about it rather than being handed
/// something that only looks like the old process.
fn restart_pid(pid: i32) -> Result<String, String> {
    if let Some(unit) = proc_user_unit(pid) {
        let out = clean_command("systemctl")
            .args(["--user", "restart", &unit])
            .output()
            .map_err(|e| format!("systemctl: {e}"))?;
        return if out.status.success() {
            Ok(format!("restarted unit {unit}"))
        } else {
            Err(format!("systemctl --user restart {unit}: {}", String::from_utf8_lossy(&out.stderr).trim()))
        };
    }

    let raw = fs::read(format!("/proc/{pid}/cmdline")).map_err(|e| format!("cmdline: {e}"))?;
    let argv: Vec<String> = raw
        .split(|b| *b == 0)
        .filter(|a| !a.is_empty())
        .map(|a| String::from_utf8_lossy(a).into_owned())
        .collect();
    if argv.is_empty() {
        return Err("no argv — kernel thread, nothing to re-exec".into());
    }
    let cwd = fs::read_link(format!("/proc/{pid}/cwd")).unwrap_or_else(|_| PathBuf::from("/"));
    // exe rather than argv[0]: argv[0] can be a name that is not on PATH (or
    // is an ld-linux invocation), and the resolved link is what actually ran.
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok();

    unsafe { libc::kill(pid, libc::SIGTERM) };
    // Give it a moment to go down so the replacement does not race the
    // original for a socket, lockfile or single-instance guard.
    std::thread::sleep(std::time::Duration::from_millis(600));

    let program = exe.map(|p| p.display().to_string()).unwrap_or_else(|| argv[0].clone());
    clean_command(&program)
        .args(&argv[1..])
        .current_dir(&cwd)
        .spawn()
        .map(|c| format!("re-exec {} as pid {} (now a child of the watchdog)", argv[0], c.id()))
        .map_err(|e| format!("re-exec {program}: {e}"))
}

/// Nudge every zombie's parent to reap it.
///
/// A zombie cannot be killed — it is already dead. All that is left of it is
/// an exit status its parent has not collected, and the pid holding that
/// status. Sending SIGKILL to a zombie is the folk remedy and it does exactly
/// nothing. What can work is SIGCHLD to the PARENT, which is the signal it
/// should have handled in the first place; a parent with a working handler
/// then calls wait() and the entry disappears.
///
/// A parent that ignores SIGCHLD will keep its zombies, and that is correct
/// behaviour to leave alone: the alternative is killing a live process to tidy
/// up a table entry that costs a few hundred bytes. So this reports how many
/// it nudged, not how many it freed — the difference is the honest part.
fn reap_zombies() -> String {
    let Ok(rd) = fs::read_dir("/proc") else { return "cannot read /proc".into() };
    let mut nudged = 0usize;
    let mut seen = 0usize;
    let mut parents: Vec<i32> = vec![];
    for e in rd.flatten() {
        let Some(nm) = e.file_name().to_str().map(|x| x.to_string()) else { continue };
        let Ok(pid) = nm.parse::<i32>() else { continue };
        let Ok(st) = fs::read_to_string(format!("/proc/{pid}/status")) else { continue };
        let field = |k: &str| -> &str {
            st.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_whitespace().nth(1)).unwrap_or("")
        };
        if !field("State:").starts_with('Z') {
            continue;
        }
        seen += 1;
        let Ok(ppid) = field("PPid:").parse::<i32>() else { continue };
        // pid 1 already reaps what it adopts; signalling it is pointless and
        // it is the one process this daemon must never touch.
        if ppid <= 1 || parents.contains(&ppid) {
            continue;
        }
        parents.push(ppid);
        unsafe { libc::kill(ppid, libc::SIGCHLD) };
        nudged += 1;
    }
    format!("{seen} zombies, nudged {nudged} parents with SIGCHLD")
}

/// Ask the kernel to reclaim memory from this user's session.
///
/// Not drop_caches: that is root-only and system-wide, and dropping the page
/// cache for the whole machine to free a session's worth of memory is a bad
/// trade made loudly. cgroup v2's memory.reclaim on user@<uid>.service is the
/// scoped version of the same idea, it is delegated to the user, and it only
/// touches pages this session owns.
///
/// The kernel reclaims up to the requested amount and may return EAGAIN having
/// reclaimed less; that is not an error worth reporting as one, so the result
/// is measured — memory.current before and after — rather than believed.
fn reclaim_session(bytes: u64) -> String {
    let base = format!(
        "/sys/fs/cgroup/user.slice/user-{}.slice/user@{}.service",
        current_uid(),
        current_uid()
    );
    let cur = || -> u64 {
        fs::read_to_string(format!("{base}/memory.current"))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0)
    };
    let before = cur();
    if let Err(e) = fs::write(format!("{base}/memory.reclaim"), bytes.to_string()) {
        // EAGAIN means "reclaimed some, could not reach the target", which is
        // a normal outcome and not worth surfacing as a failure.
        if e.raw_os_error() != Some(libc::EAGAIN) {
            return format!("memory.reclaim: {e}");
        }
    }
    let after = cur();
    format!(
        "session memory {} -> {} (freed {})",
        fmt_mib(before),
        fmt_mib(after),
        fmt_mib(before.saturating_sub(after))
    )
}

fn fmt_mib(b: u64) -> String {
    format!("{:.0}M", b as f64 / 1_048_576.0)
}

/// A signal requested from the panel. QML cannot signal a process, and giving a
/// widget an exec path is worse than giving the daemon a mailbox: the daemon
/// already runs as this user, so it can only ever signal what the user could.
/// Each line is "<pid> <SIG>"; the file is consumed on read, so a stale request
/// cannot fire twice.
fn drain_kill_requests() {
    let req = runtime_dir().join("my-konsole-watchdog.kill");
    let Ok(body) = fs::read_to_string(&req) else { return };
    let _ = fs::remove_file(&req);
    // Loaded fresh per drain (not cached in `spawn`'s state) so an edit to
    // protected-slices.json takes effect on the very next kill request, not
    // after a daemon restart — and so this enforcement point never trusts
    // whatever the QML layer decided to show/disable, since that is only a
    // UI convenience, not the safety boundary.
    let protected = load_protected_slices();
    for line in body.lines() {
        let mut it = line.split_whitespace();
        let Some(Ok(pid)) = it.next().map(|x| x.parse::<i32>()) else { continue };
        let sig = it.next().unwrap_or("TERM");
        // RESTART is not a signal, but it belongs on the same mailbox: it must
        // pass the exact same pid and protected-slice checks below, and having
        // one guarded entry point is what stops a second path growing its own
        // (weaker) copy of the policy.
        // Two verbs are about the machine, not about a pid, so they are
        // answered before the pid guards below — which would otherwise refuse
        // them for the pid 0 they are addressed to.
        if sig.eq_ignore_ascii_case("REAP") {
            eprintln!("[watchdog] reap: {}", reap_zombies());
            continue;
        }
        // "0 CTR <verb> <name>" and "0 IMG <verb> <ref>" — container and image
        // verbs, allow-listed the same way UNIT is. This line arrives from a
        // file any process of this user can append to, so "whatever word came
        // next" is never handed to docker.
        //
        // No `rm` for containers. Stopping one is reversible and removing one
        // is not — a compose stack recreates it, but anything in its writable
        // layer is gone, and a panel keystroke is the wrong weight for that.
        if sig.eq_ignore_ascii_case("CTR") {
            let verb = it.next().unwrap_or("");
            let name = it.next().unwrap_or("");
            if !matches!(
                verb,
                // kill is not a louder stop: stop asks and then insists, kill
                // does not ask. rm deletes the container only -- not the image,
                // not its named volumes -- and docker refuses while it runs,
                // which is the guard: nothing here destroys something working.
                "start" | "stop" | "restart" | "pause" | "unpause" | "kill" | "rm"
            )
                || name.is_empty()
                || name.starts_with('-')
                || name.contains('/')
            {
                eprintln!("[watchdog] refusing container request {verb:?} {name:?}");
                continue;
            }
            match clean_command("docker").args([verb, name]).output() {
                Ok(o) if o.status.success() => eprintln!("[watchdog] docker {verb} {name}: ok"),
                Ok(o) => eprintln!(
                    "[watchdog] docker {verb} {name} failed: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                ),
                Err(e) => eprintln!("[watchdog] docker {verb} {name}: {e}"),
            }
            continue;
        }
        if sig.eq_ignore_ascii_case("IMG") {
            let verb = it.next().unwrap_or("");
            let reference = it.next().unwrap_or("");
            // prune is the one verb with nothing to name: it is defined by what
            // is NOT referenced, so it acts on the whole dangling set at once and
            // a reference would be meaningless. Handled before the shared
            // [verb, reference] path rather than bent into it.
            if verb == "prune" {
                match clean_command("docker").args(["image", "prune", "-f"]).output() {
                    Ok(o) if o.status.success() => eprintln!(
                        "[watchdog] docker image prune: {}",
                        String::from_utf8_lossy(&o.stdout).trim().replace('\n', " ")
                    ),
                    Ok(o) => eprintln!(
                        "[watchdog] docker image prune failed: {}",
                        String::from_utf8_lossy(&o.stderr).trim()
                    ),
                    Err(e) => eprintln!("[watchdog] docker image prune: {e}"),
                }
                continue;
            }
            if !matches!(verb, "pull" | "rm") || reference.is_empty() || reference.starts_with('-') {
                eprintln!("[watchdog] refusing image request {verb:?} {reference:?}");
                continue;
            }
            // `rmi`, not `rm`: docker refuses to remove an image a container
            // still references, which is the guard we want and already have.
            let cmd = if verb == "rm" { "rmi" } else { "pull" };
            match clean_command("docker").args([cmd, reference]).output() {
                Ok(o) if o.status.success() => eprintln!("[watchdog] docker {cmd} {reference}: ok"),
                Ok(o) => eprintln!(
                    "[watchdog] docker {cmd} {reference} failed: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                ),
                Err(e) => eprintln!("[watchdog] docker {cmd} {reference}: {e}"),
            }
            continue;
        }
        // "0 CMP up <file> <service>" — bring a declared service back.
        //
        // This is the answer to "how do I start a container from an image".
        // `docker run <image>` is a valid command and the wrong one: it makes
        // a container with none of the ports, volumes, environment or network
        // the service needs, which looks like it worked and is not the thing
        // that was deployed. So the only way back up is through the file that
        // declared it, and the file comes from the labels compose itself wrote
        // — never from a path the panel invented.
        if sig.eq_ignore_ascii_case("CMP") {
            let verb = it.next().unwrap_or("");
            let file = it.next().unwrap_or("");
            let service = it.next().unwrap_or("");
            // An ALLOW-LIST, and `down` is not on it: down takes out every
            // service in the project, including the ones the cursor was not
            // on. Everything here names one service. The file has to be an
            // absolute path to a compose file that EXISTS — this line arrives
            // from a file any process of this user can append to.
            const VERBS: [&str; 5] = ["up", "restart", "stop", "start", "pull"];
            if !VERBS.contains(&verb)
                || !file.starts_with('/')
                || !(file.ends_with(".yml") || file.ends_with(".yaml"))
                || !std::path::Path::new(file).is_file()
                || service.is_empty()
                || service.starts_with('-')
            {
                eprintln!("[watchdog] refusing compose request {verb:?} {file:?} {service:?}");
                continue;
            }
            // WHERE the project lives, asked of docker rather than of the
            // panel. `-f <file>` alone makes compose treat the file's OWN
            // directory as the project root, so a stack deployed as
            //   cd /opt/containers/x && compose -f compose/docker-compose.yml
            // would come back up rooted at /opt/containers/x/compose: every
            // relative bind mount and the .env resolve against the wrong
            // directory, and `up` quietly recreates the container with the
            // wrong volumes. Compose recorded the real root on the container
            // it created; that label is the answer, and reading it here means
            // the panel never gets to name a directory this then runs in.
            let meta = clean_command("docker")
                .args([
                    "ps",
                    "-a",
                    "--filter",
                    &format!("label=com.docker.compose.project.config_files={file}"),
                    "--format",
                    "{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.Label \"com.docker.compose.project\"}}",
                ])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                .unwrap_or_default();
            let (wd, proj) = meta
                .lines()
                .find(|l| !l.trim().is_empty())
                .and_then(|l| l.split_once('\t'))
                .map(|(a, b)| (a.trim().to_string(), b.trim().to_string()))
                .unwrap_or_default();
            // An absolute directory that still exists, or nothing: a label
            // pointing at a path that has since been deleted is not a root to
            // run in, and falling back to compose's own default is at least a
            // failure mode that gets reported rather than a silent wrong mount.
            let wd_ok = wd.starts_with('/') && std::path::Path::new(&wd).is_dir();
            let proj_ok = !proj.is_empty() && !proj.starts_with('-');

            // -d belongs to `up` alone: the others do not take it, and
            // `compose stop -d` is an error rather than a no-op.
            let mut args = vec!["compose", "-f", file];
            if wd_ok {
                args.push("--project-directory");
                args.push(&wd);
            }
            if proj_ok {
                args.push("-p");
                args.push(&proj);
            }
            args.push(verb);
            if verb == "up" {
                args.push("-d");
            }
            args.push(service);
            match clean_command("docker").args(&args).output() {
                Ok(o) if o.status.success() => {
                    eprintln!("[watchdog] docker compose -f {file} {verb} {service}: ok")
                }
                Ok(o) => eprintln!(
                    "[watchdog] docker compose {verb} {service} failed: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                ),
                Err(e) => eprintln!("[watchdog] docker compose {verb} {service}: {e}"),
            }
            continue;
        }
        // "0 UNIT <scope> <verb> <name>" — a systemd verb on a declared unit.
        if sig.eq_ignore_ascii_case("UNIT") {
            let scope = it.next().unwrap_or("");
            let verb = it.next().unwrap_or("");
            let name = it.next().unwrap_or("");
            // Allow-list, not pass-through: this line arrives from a file any
            // process of this user can append to, and "whatever word came
            // next" is not something to hand systemctl.
            if !matches!(verb, "start" | "stop" | "restart" | "reset-failed")
                || !name.ends_with(".service")
                || name.contains('/')
            {
                eprintln!("[watchdog] refusing unit request {verb:?} {name:?}");
                continue;
            }
            let mut c = clean_command("systemctl");
            if scope == "user" {
                c.arg("--user");
            }
            match c.args([verb, name]).output() {
                Ok(o) if o.status.success() => eprintln!("[watchdog] {verb} {name}: ok"),
                Ok(o) => eprintln!(
                    "[watchdog] {verb} {name} failed: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                ),
                Err(e) => eprintln!("[watchdog] {verb} {name}: {e}"),
            }
            continue;
        }
        if sig.eq_ignore_ascii_case("RECLAIM") {
            let want: u64 = it.next().and_then(|x| x.parse().ok()).unwrap_or(1_073_741_824);
            eprintln!("[watchdog] reclaim: {}", reclaim_session(want));
            continue;
        }
        let restart = sig.eq_ignore_ascii_case("RESTART");
        let signum = if restart {
            0
        } else {
            match signal_by_name(sig) {
                Some(n) => n,
                None => {
                    eprintln!("[watchdog] unknown signal {sig:?} — ignored");
                    continue;
                }
            }
        };
        // Never signal init or ourselves. kill(2) already stops us reaching
        // another user's processes; this stops the panel stopping the thing
        // that feeds it, which would leave the widget frozen and blameless.
        if pid <= 1 || pid == std::process::id() as i32 {
            eprintln!("[watchdog] refusing to signal pid {pid}");
            continue;
        }
        if let Some(slice) = proc_protected_slice(pid, &protected) {
            eprintln!("[watchdog] refusing to signal pid {pid}: in protected slice {slice}");
            continue;
        }
        if restart {
            match restart_pid(pid) {
                Ok(what) => eprintln!("[watchdog] restart pid {pid}: {what}"),
                Err(why) => eprintln!("[watchdog] restart pid {pid} failed: {why}"),
            }
            continue;
        }
        unsafe { libc::kill(pid, signum) };
        eprintln!("[watchdog] SIG{sig} -> pid {pid} (requested from panel)");
    }
}

/// Publish atomically — a widget polling on its own timer must never read a
/// half-written file. Write to a sibling temp then rename(2), same as the
/// status line's publisher.
fn publish(path: &PathBuf, body: &str) {
    let tmp = path.with_extension("tmp");
    if fs::write(&tmp, body).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}

/// Runs forever on its own thread. Started only in --tray-daemon mode, so the
/// GUI process never duplicates it — the same rule the tray icons follow after
/// registering them from both processes produced sixteen of eight.
/// See the doc on interval_ms above for why this returns zeroed rates.
pub fn snapshot_once() -> String {
    let (cpu_now, cores_now) = read_cpu_all();
    let cores: Vec<f64> = cores_now.iter().map(|_| 0.0).collect();
    let (mem, swap, mem_detail, swap_detail) = meminfo_all();
    let (slice_cur, slice_max) = slice_mem();
    let protected = load_protected_slices();
    let uid_names = read_uid_names();
    let (proc_table, proc_spine, _) = build_proc_table(
        proc_table_n(),
        &HashMap::new(),
        INTERVAL_MS as f64 / 1000.0,
        mem_total_kb(),
        &protected,
        &uid_names,
        true,
    );
    let (load1, load5, load15) = loadavg();
    render(&Snapshot {
        cpu: cpu_percent(cpu_now, cpu_now),
        cores: &cores,
        cpu_detail: &cpu_breakdown_json(cpu_now, cpu_now),
        mem,
        swap,
        mem_detail: &mem_detail,
        swap_detail: &swap_detail,
        disk: disk_root_percent(),
        disk_r: 0.0,
        disk_w: 0.0,
        disks: &disks_json(),
        vram: read_vram(),
        vram_detail: &vram_detail_json(),
        net_rx: 0.0,
        net_tx: 0.0,
        load1,
        load5,
        load15,
        slice_cur,
        slice_max,
        battery: &read_battery(),
        procs: &top_procs(12),
        proc_table: &proc_table,
        proc_spine: &proc_spine,
        cpu_info: &cpu_info_json(),
        host_info: &host_info_json(),
        totals: &totals_json(read_uptime_s()),
        history: "{}",
        containers: &containers_json().0,
        images: &images_json(),
        docker_daemon: &docker_daemon_json(),
        volumes: &volumes_json(),
        networks: &networks_json(),
        compose: &compose_json(),
        storage: &btrfs_storage_json(),
        slices: &slices_json(&protected),
        services: &services_json(),
        // One sample has nothing to subtract, so every reclaim rate is zero
        // here by construction — same as cpu% in this path. It is the shape
        // of the snapshot, not a measurement of it.
        reclaim: &reclaim_json(VmStat::default(), VmStat::default(), 0.0),
        health: &health_json(Health::default(), read_health(), 0.0),
        listening: &listening_json(),
    })
}

pub fn spawn() {
    let Some(path) = snapshot_path() else {
        eprintln!("[watchdog] no writable runtime directory — not publishing metrics");
        return;
    };
    let ptn = proc_table_n();
    std::thread::spawn(move || {
        let (mut prev, mut prev_cores) = read_cpu_all();
        let mut prev_disk = read_diskstats();
        let mut prev_vm = read_vmstat();
        let mut prev_health = read_health();
        let mut prev_net = read_net();
        let mut prev_proc_table: HashMap<i32, ProcSample> = HashMap::new();
        // Two systemctl calls cost ~100ms and the unit set changes on the
        // scale of a deploy, not a tick, so this is refreshed on a slow
        // cadence and reused in between rather than paid for every 2s.
        let mut services = services_json();
        // Identity and network config change on the scale of a reboot, not a
        // tick, so they ride the same slow refresh as the unit list.
        let mut host_info = host_info_json();
        // Rewritten once a minute; carried between ticks so the panel always
        // has the last summary rather than an empty object 29 ticks out of 30.
        let mut history = String::from("{}");
        let (mut containers, mut images) = containers_json();
        let mut docker_daemon = docker_daemon_json();
        let mut volumes = volumes_json();
        let mut networks = networks_json();
        let mut compose = compose_json();
        let mut tick: u64 = 0;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(INTERVAL_MS));
            // Did anyone ask for something this tick? Checked BEFORE draining,
            // because draining deletes the mailbox. A start/stop/rm/pull is the
            // one moment the docker view is guaranteed to be wrong, and the
            // slow cadence below would leave it wrong for up to 30s — long
            // enough for a person to press the key a second time. One stat() a
            // tick buys the answer arriving on the next one instead.
            let acted = runtime_dir().join("my-konsole-watchdog.kill").exists();
            drain_kill_requests();

            let (now, now_cores) = read_cpu_all();
            let cpu = cpu_percent(prev, now);
            // Computed before `prev` is overwritten below — same two samples
            // the aggregate percentage uses, so the breakdown always sums to
            // the busy figure shown beside it.
            let cpu_detail = cpu_breakdown_json(prev, now);
            let cores: Vec<f64> = now_cores
                .iter()
                .zip(prev_cores.iter().chain(std::iter::repeat(&CpuTotals::default())))
                .map(|(n, p)| cpu_percent(*p, *n))
                .collect();
            prev = now;
            prev_cores = now_cores;

            let now_disk = read_diskstats();
            let (disk_r, disk_w) = disk_rate_mb(prev_disk, now_disk, INTERVAL_MS as f64 / 1000.0);
            prev_disk = now_disk;

            let now_net = read_net();
            let (net_rx, net_tx) = net_rate_mb(prev_net, now_net, INTERVAL_MS as f64 / 1000.0);
            prev_net = now_net;
            let (load1, load5, load15) = loadavg();

            let (mem, swap, mem_detail, swap_detail) = meminfo_all();
            let (slice_cur, slice_max) = slice_mem();

            let protected_slices = load_protected_slices();
            let uid_names = read_uid_names();
            let (proc_table_json, proc_spine_json, next_proc_table) = build_proc_table(
                ptn,
                &prev_proc_table,
                INTERVAL_MS as f64 / 1000.0,
                mem_total_kb(),
                &protected_slices,
                &uid_names,
                // Every fifth tick: 10s, the shortest window the panel shows a
                // memory average over anyway.
                tick % PSS_EVERY_TICKS == 0,
            );
            prev_proc_table = next_proc_table;

            tick += 1;
            if tick % SERVICES_EVERY_TICKS == 0 {
                services = services_json();
                host_info = host_info_json();
            }
            // Containers, images and the daemon's own state are refreshed as
            // ONE unit and never independently: they are three views of the
            // same instant, and letting them drift apart is what made the
            // images page say "nothing runs this" about an image a container
            // on the page beside it was visibly running.
            if tick % SERVICES_EVERY_TICKS == 0 || acted {
                let c = containers_json();
                containers = c.0;
                images = c.1;
                docker_daemon = docker_daemon_json();
                volumes = volumes_json();
                networks = networks_json();
                compose = compose_json();
            }
            if tick % HISTORY_EVERY_TICKS == 1 {
                history = history_step(cpu, mem, swap, now_unix());
            }

            // Reclaim rates from the same interval as everything else.
            let now_vm = read_vmstat();
            let reclaim = reclaim_json(prev_vm, now_vm, INTERVAL_MS as f64 / 1000.0);
            let now_health = read_health();
            let health = health_json(prev_health, now_health, INTERVAL_MS as f64 / 1000.0);
            prev_health = now_health;
            prev_vm = now_vm;
            let body = render(&Snapshot {
                cpu,
                cores: &cores,
                cpu_detail: &cpu_detail,
                mem,
                swap,
                mem_detail: &mem_detail,
                swap_detail: &swap_detail,
                disk: disk_root_percent(),
                disk_r,
                disk_w,
                disks: &disks_json(),
                vram: read_vram(),
                vram_detail: &vram_detail_json(),
                net_rx,
                net_tx,
                load1,
                load5,
                load15,
                slice_cur,
                slice_max,
                battery: &read_battery(),
                procs: &top_procs(12),
                proc_table: &proc_table_json,
                proc_spine: &proc_spine_json,
                cpu_info: &cpu_info_json(),
                host_info: &host_info,
                totals: &totals_json(read_uptime_s()),
                history: &history,
                containers: &containers,
                images: &images,
                docker_daemon: &docker_daemon,
                volumes: &volumes,
                networks: &networks,
                compose: &compose,
                storage: &btrfs_storage_json(),
                slices: &slices_json(&protected_slices),
                services: &services,
                reclaim: &reclaim,
                health: &health,
                listening: &listening_json(),
            });
            publish(&path, &body);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // The whole point is a percentage from two cumulative samples; getting the
    // idle/total arithmetic backwards would show a busy machine as idle.
    #[test]
    fn cpu_percent_is_busy_fraction_between_samples() {
        let a = CpuTotals { idle: 100, total: 200, ..Default::default() };
        let b = CpuTotals { idle: 150, total: 350, ..Default::default() }; // +50 idle of +150 total
        let p = cpu_percent(a, b);
        assert!((p - 66.6).abs() < 0.5, "expected ~66.7% busy, got {p}");
        // No time passed => no division by zero, and no fake 100%.
        assert_eq!(cpu_percent(a, a), 0.0);
    }

    // Disk throughput is cumulative sectors, same trap as CPU: a wrong delta
    // shows an idle disk as saturated or vice versa.
    #[test]
    fn disk_rate_is_bytes_per_second_between_samples() {
        let a = DiskTotals { read_sectors: 0, write_sectors: 0 };
        let b = DiskTotals { read_sectors: 2048, write_sectors: 4096 }; // 1MiB / 2MiB
        let (r, w) = disk_rate_mb(a, b, 2.0);
        assert!((r - 0.5).abs() < 0.01, "expected 0.5 MB/s read, got {r}");
        assert!((w - 1.0).abs() < 0.01, "expected 1.0 MB/s write, got {w}");
        assert_eq!(disk_rate_mb(a, b, 0.0), (0.0, 0.0));
    }

    #[test]
    fn render_is_parseable_json_with_every_field() {
        let mem_detail = r#"{"total":16.00,"used":8.00,"buffers":0.50,"cached":2.00,"free":5.50,"available":8.00}"#;
        let swap_detail = r#"{"total":4.00,"used":0.10}"#;
        let disks = r#"[{"mount":"/","pct":42.0,"used_gib":100.00,"total_gib":238.00}]"#;
        let cpu_detail = r#"{"user":10.0,"nice":0.0,"system":2.0,"iowait":0.5,"irq":0.0,"steal":0.0}"#;
        let s = render(&Snapshot {
            cpu: 12.5,
            cores: &[10.0, 20.0, 30.0, 40.0],
            cpu_detail,
            mem: 40.0,
            swap: 1.0,
            mem_detail,
            swap_detail,
            disk: 55.0,
            disk_r: 1.5,
            disk_w: 2.5,
            disks,
            vram: Some((1024.0, 512.0)),
            vram_detail: "{}",
            net_rx: 0.3,
            net_tx: 0.4,
            load1: 1.1,
            load5: 2.2,
            load15: 3.3,
            slice_cur: 4.9,
            slice_max: 5.6,
            battery: &None,
            procs: "[]",
            proc_table: "[]",
            proc_spine: "[]",
            cpu_info: "[]",
            host_info: "[]",
            totals: "[]",
            history: "{}",
            containers: "{}",
            images: "{}",
            docker_daemon: "{}",
            volumes: "[]",
            networks: "[]",
            compose: "[]",
            storage: "{}",
            slices: "[]",
            services: "[]",
            reclaim: "{}",
            health: "{}",
            listening: "[]",
        });
        for k in ["cpu", "cores", "cpu_detail", "mem", "swap", "mem_detail", "swap_detail",
                  "vram", "disk", "disk_r", "disk_w", "disks",
                  "net_rx", "net_tx", "load1", "load5", "load15",
                  "psi", "slice_gib", "slice_max_gib", "slice_pct", "battery", "procs",
                  "storage", "slices", "reclaim", "health", "listening",
                  "proc_table", "ts"] {
            assert!(s.contains(&format!("\"{k}\":")), "missing {k} in {s}");
        }
        assert!(s.starts_with('{') && s.ends_with('}'), "not an object: {s}");

        // vram must render as a null literal when None (the expected case on
        // machines without a readable GPU VRAM counter), not an absent key.
        let s2 = render(&Snapshot {
            cpu: 12.5,
            cores: &[],
            cpu_detail,
            mem: 40.0,
            swap: 1.0,
            mem_detail,
            swap_detail,
            disk: 55.0,
            disk_r: 1.5,
            disk_w: 2.5,
            disks: "[]",
            vram: None,
            vram_detail: "{}",
            net_rx: 0.3,
            net_tx: 0.4,
            load1: 1.1,
            load5: 2.2,
            load15: 3.3,
            slice_cur: 4.9,
            slice_max: 5.6,
            battery: &None,
            procs: "[]",
            proc_table: "[]",
            proc_spine: "[]",
            cpu_info: "[]",
            host_info: "[]",
            totals: "[]",
            history: "{}",
            containers: "{}",
            images: "{}",
            docker_daemon: "{}",
            volumes: "[]",
            networks: "[]",
            compose: "[]",
            storage: "{}",
            slices: "[]",
            services: "[]",
            reclaim: "{}",
            health: "{}",
            listening: "[]",
        });
        assert!(s2.contains("\"vram\":null"), "expected null vram, got {s2}");

        // slice_pct must be 0.0, not NaN/Infinity, when slice_max is 0.
        let s3 = render(&Snapshot {
            cpu: 12.5,
            cores: &[],
            cpu_detail,
            mem: 40.0,
            swap: 1.0,
            mem_detail,
            swap_detail,
            disk: 55.0,
            disk_r: 1.5,
            disk_w: 2.5,
            disks: "[]",
            vram: None,
            vram_detail: "{}",
            net_rx: 0.3,
            net_tx: 0.4,
            load1: 1.1,
            load5: 2.2,
            load15: 3.3,
            slice_cur: 4.9,
            slice_max: 0.0,
            battery: &None,
            procs: "[]",
            proc_table: "[]",
            proc_spine: "[]",
            cpu_info: "[]",
            host_info: "[]",
            totals: "[]",
            history: "{}",
            containers: "{}",
            images: "{}",
            docker_daemon: "{}",
            volumes: "[]",
            networks: "[]",
            compose: "[]",
            storage: "{}",
            slices: "[]",
            services: "[]",
            reclaim: "{}",
            health: "{}",
            listening: "[]",
        });
        assert!(s3.contains("\"slice_pct\":0.0"), "expected 0.0 slice_pct, got {s3}");
    }

    // The pair that matters is direct vs kswapd, so the rates must not be
    // silently swapped or shared — and a counter that went BACKWARDS (a peer
    // that rebooted between two samples) must read as zero, never as a
    // gigantic positive spike.
    #[test]
    fn reclaim_rates_are_per_second_and_never_negative() {
        let prev = VmStat {
            refault_file: 1_000,
            refault_anon: 100,
            swap_in: 50,
            swap_out: 70,
            scan_direct: 200,
            scan_kswapd: 5_000,
            steal_direct: 150,
            steal_kswapd: 4_000,
        };
        let now = VmStat {
            refault_file: 3_000,
            refault_anon: 200,
            swap_in: 150,
            swap_out: 270,
            scan_direct: 600,
            scan_kswapd: 9_000,
            steal_direct: 350,
            steal_kswapd: 6_000,
        };
        let j = reclaim_json(prev, now, 2.0);
        // (3000-1000)/2 = 1000, and each field must carry ITS OWN delta.
        assert!(j.contains("\"refault_file\":1000"), "{j}");
        assert!(j.contains("\"refault_anon\":50"), "{j}");
        assert!(j.contains("\"swap_in\":50"), "{j}");
        assert!(j.contains("\"swap_out\":100"), "{j}");
        assert!(j.contains("\"scan_direct\":200"), "{j}");
        assert!(j.contains("\"scan_kswapd\":2000"), "{j}");
        assert!(j.contains("\"steal_direct\":100"), "{j}");
        assert!(j.contains("\"steal_kswapd\":1000"), "{j}");

        // Counters that went backwards read as zero, not as a huge spike.
        let back = reclaim_json(now, prev, 2.0);
        assert!(back.contains("\"refault_file\":0"), "{back}");
        assert!(back.contains("\"scan_direct\":0"), "{back}");

        // No division by zero on the first tick.
        let zero = reclaim_json(prev, now, 0.0);
        assert!(zero.contains("\"refault_file\":0"), "{zero}");
    }

    // Pure /proc/meminfo parsing: feed sample text in directly so this is
    // testable without touching the real filesystem.
    #[test]
    fn parse_meminfo_reads_expected_fields() {
        let sample = "\
MemTotal:       16384000 kB
MemFree:         2048000 kB
MemAvailable:    8192000 kB
Buffers:          512000 kB
Cached:          2048000 kB
SwapCached:            0 kB
SReclaimable:     256000 kB
SwapTotal:       4096000 kB
SwapFree:        3072000 kB
";
        let raw = parse_meminfo(sample);
        assert_eq!(raw.total_kb, 16384000.0);
        assert_eq!(raw.free_kb, 2048000.0);
        assert_eq!(raw.avail_kb, 8192000.0);
        assert_eq!(raw.buffers_kb, 512000.0);
        assert_eq!(raw.cached_kb, 2048000.0);
        assert_eq!(raw.sreclaimable_kb, 256000.0);
        assert_eq!(raw.swap_total_kb, 4096000.0);
        assert_eq!(raw.swap_free_kb, 3072000.0);
    }

    // Missing fields must default to 0.0, not panic — real /proc/meminfo
    // varies by kernel config (e.g. no SReclaimable on some builds).
    #[test]
    fn parse_meminfo_defaults_missing_fields_to_zero() {
        let raw = parse_meminfo("MemTotal:       16384000 kB\n");
        assert_eq!(raw.total_kb, 16384000.0);
        assert_eq!(raw.avail_kb, 0.0);
        assert_eq!(raw.sreclaimable_kb, 0.0);
    }

    // /proc/self/mounts filtering: keep only real on-disk filesystems, skip
    // pseudo/virtual ones, and dedup by device so a bind mount or btrfs
    // subvolume doesn't get a second row.
    #[test]
    fn parse_mounts_filters_and_dedups() {
        let sample = "\
sysfs /sys sysfs rw 0 0
/dev/nvme0n1p2 / btrfs rw,relatime 0 0
/dev/nvme0n1p2 /home btrfs rw,relatime 0 0
/dev/nvme0n1p1 /boot vfat rw,relatime 0 0
tmpfs /run tmpfs rw 0 0
overlay /var/lib/docker/overlay2/abc/merged overlay rw 0 0
/dev/sdb1 /mnt/backup\\040drive ntfs3 rw 0 0
";
        let mounts = parse_mounts(sample);
        let devices: Vec<&str> = mounts.iter().map(|(d, _)| d.as_str()).collect();
        assert_eq!(devices, vec!["/dev/nvme0n1p2", "/dev/nvme0n1p1", "/dev/sdb1"]);

        let points: Vec<&str> = mounts.iter().map(|(_, m)| m.as_str()).collect();
        assert!(points.contains(&"/"));
        assert!(!points.contains(&"/home")); // deduped: same device as /
        assert!(points.contains(&"/boot"));
        assert!(!points.iter().any(|p| p.contains("sys") || p.contains("run") || p.contains("docker")));

        // Octal-escaped space in the mount point must be decoded.
        assert!(points.contains(&"/mnt/backup drive"), "escapes not decoded: {points:?}");
    }

    // No battery at all (desktop) must render valid `null`, not an absent key
    // or a panic — the widget branches on this to hide the battery cluster.
    #[test]
    fn battery_json_is_null_when_no_battery_present() {
        assert_eq!(battery_json(&None), "null");
    }

    // The whole point of this reader: a zero or missing power_now (SAM
    // freeze, just-unplugged, charging) must never reach a division — it
    // must come out as JSON `null`, never NaN/Infinity, which is not valid
    // JSON and would break the widget's JSON.parse for every field, not
    // just battery.
    #[test]
    fn minutes_left_is_null_not_nan_when_rate_is_zero_or_absent() {
        let zero_rate = BatteryReading {
            present: true, pct: 40.0, status: "Discharging".into(), minutes_left: None,
        };
        let j = battery_json(&Some(zero_rate));
        assert!(j.contains("\"minutes_left\":null"), "expected null minutes_left, got {j}");
        assert!(!j.contains("NaN") && !j.contains("Infinity"), "invalid JSON literal in {j}");

        // Charging (rate direction doesn't apply) also renders a clean null.
        let charging = BatteryReading {
            present: true, pct: 80.0, status: "Charging".into(), minutes_left: None,
        };
        let j2 = battery_json(&Some(charging));
        assert!(j2.contains("\"charging\":true"));
        assert!(j2.contains("\"minutes_left\":null"));
    }

    // A real, finite estimate must serialise as a plain number the widget
    // can format directly.
    #[test]
    fn minutes_left_serialises_as_a_finite_number_when_known() {
        let r = BatteryReading {
            present: true, pct: 55.0, status: "Discharging".into(), minutes_left: Some(123.4),
        };
        let j = battery_json(&Some(r));
        assert!(j.contains("\"minutes_left\":123"), "expected ~123 in {j}");
    }
}

#[cfg(test)]
mod name_tests {
    // Was a two-name import; the storage/averaging/signal tests below need the
    // rest of the module, and listing them one by one has already gone stale once.
    use super::*;

    fn n(argv: &[&str]) -> Option<String> {
        name_from_argv(&mut argv.iter().map(|s| s.to_string()))
    }

    #[test]
    fn plain_binary_is_its_basename() {
        assert_eq!(n(&["/run/current-system/sw/bin/konsole", "--tabs"]).as_deref(), Some("konsole"));
    }

    #[test]
    fn loader_yields_the_program_it_launches() {
        // The real case: comm said "ld-linux-x86-64" for every one of these.
        assert_eq!(
            n(&["/nix/store/xxx-glibc/lib/ld-linux-x86-64.so.2", "/home/diego/.local/bin/claude", "--resume"]).as_deref(),
            Some("claude")
        );
    }

    #[test]
    fn loader_options_and_their_values_are_skipped() {
        assert_eq!(
            n(&["/nix/store/x/ld-linux-x86-64.so.2", "--argv0", "node", "--library-path", "/nix/store/l", "/nix/store/x/bin/node"]).as_deref(),
            Some("node")
        );
    }

    #[test]
    fn bare_loader_falls_back_to_itself_not_empty() {
        assert_eq!(n(&["/nix/store/x/ld-linux-x86-64.so.2"]).as_deref(), Some("ld-linux-x86-64.so.2"));
    }

    #[test]
    fn empty_argv_means_kernel_thread() {
        assert_eq!(n(&[]), None);
    }

    #[test]
    fn escape_keeps_slashes_and_colons_that_the_old_filter_ate() {
        // "kworker/u32:5-btrfs-endio" was being published as "kworkeru325-btrfs-endio".
        assert_eq!(json_escape("kworker/u32:5-btrfs-endio"), "kworker/u32:5-btrfs-endio");
        assert_eq!(json_escape("say \"hi\""), "say \\\"hi\\\"");
    }

    // The whole reason the storage box exists: on a single-pool layout df
    // reports the SAME figures for every subvolume mount, so the join from a
    // mount to its qgroup is the only thing that can say which one is heavy.
    // If these options stop parsing, every volume silently reads 0 B.
    #[test]
    fn subvol_options_parse_from_a_real_mount_line() {
        let opts = "rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvolid=260,subvol=/@nixos/nix";
        assert_eq!(parse_subvol_opts(opts), Some((260, "/@nixos/nix".to_string())));
        // The kernel synthesises both even for a bare mount of the top level.
        assert_eq!(parse_subvol_opts("rw,subvolid=5,subvol=/"), Some((5, "/".to_string())));
        // Not btrfs / no subvolid: no row rather than a wrong one.
        assert_eq!(parse_subvol_opts("rw,relatime"), None);
        // "subvol=" must not be mistaken for "subvolid=" by a prefix match.
        assert_eq!(parse_subvol_opts("rw,subvol=/@home"), None);
    }

    // 10s is the window the process table's first average column reads. Losing
    // it (or reordering the array) would silently relabel every column.
    #[test]
    fn avg_windows_and_labels_line_up() {
        assert_eq!(PROC_AVG_WINDOWS.len(), PROC_AVG_LABELS.len());
        assert_eq!(PROC_AVG_LABELS[0], "10s");
        assert_eq!(PROC_AVG_WINDOWS[0], 10.0);
        // "Av60s" in the UI is this one — 1m and 60s are the same window, so
        // there is no second entry for it.
        assert_eq!(PROC_AVG_LABELS[1], "1m");
        assert_eq!(PROC_AVG_WINDOWS[1], 60.0);
    }

    // Swap must not be folded into the RAM figures: a page can be swapped out
    // AND still cached in RAM, and counting it twice is what makes a panel
    // report more memory in use than the machine has.
    #[test]
    fn memory_and_swap_are_reported_separately() {
        let raw = parse_meminfo(
            "MemTotal:       16000000 kB\n\
             MemFree:         1000000 kB\n\
             MemAvailable:    8000000 kB\n\
             Buffers:          500000 kB\n\
             Cached:          4000000 kB\n\
             SwapCached:       100000 kB\n\
             AnonPages:       6000000 kB\n\
             Mapped:          2000000 kB\n\
             Shmem:            300000 kB\n\
             Dirty:              5000 kB\n\
             Writeback:             0 kB\n\
             KernelStack:       30000 kB\n\
             PageTables:        90000 kB\n\
             SReclaimable:     700000 kB\n\
             SUnreclaim:       400000 kB\n\
             SwapTotal:       8000000 kB\n\
             SwapFree:        6000000 kB\n\
             Zswap:             50000 kB\n\
             Zswapped:         200000 kB\n\
             CommitLimit:    16000000 kB\n\
             Committed_AS:   12000000 kB\n",
        );
        // "Cached:" must not swallow "SwapCached:", nor "Zswap:" "Zswapped:".
        assert_eq!(raw.cached_kb, 4_000_000.0);
        assert_eq!(raw.swap_cached_kb, 100_000.0);
        assert_eq!(raw.zswap_kb, 50_000.0);
        assert_eq!(raw.zswapped_kb, 200_000.0);
        assert_eq!(raw.sunreclaim_kb, 400_000.0);
    }

    // RESTART rides the kill mailbox but is not a signal; if signal_by_name
    // ever starts answering for it, a restart request would be delivered as
    // some unrelated signal instead.
    #[test]
    fn restart_is_not_a_signal_name() {
        assert_eq!(signal_by_name("RESTART"), None);
        assert_eq!(signal_by_name("TERM"), Some(libc::SIGTERM));
        assert_eq!(signal_by_name("CONT"), Some(libc::SIGCONT));
    }

}
