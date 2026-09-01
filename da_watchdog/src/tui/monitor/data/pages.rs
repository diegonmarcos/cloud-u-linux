// Which array backs each node of the CLI's tab tree — and the code that
// computes the ones the sampler does not publish.
//
// WHY THIS FILE EXISTS
// The panel has eight tabs and thirty-one leaves. The phone had seventeen
// rows, and nothing said so: html.rs mapped a tab node to a snapshot array,
// and a node nothing claimed simply rendered dimmed and inert. That is the
// right behaviour for a page a snapshot genuinely cannot carry, and the wrong
// behaviour for eleven pages that were only ever missing a producer — the two
// are indistinguishable on screen, so the gap sat there through every release.
//
// The difference between them is whether the data is DERIVABLE. zombies is
// proc_table filtered; the four fleet networks are the machine list filtered
// by the prefix TABS already declares; the two firewall halves are the join
// mod.rs draws by hand; the journal is eight reads. All of it exists on the
// measured machine at export time, and none of it existed in the envelope.
//
// So it is computed HERE, once, on the machine that has it — not in the
// TypeScript, which is the mistake tui_html.rs was written to end. The phone
// gets rows and renders them with the table renderer it already had.
//
// [`tests::every_leaf_is_backed`] then makes a missing producer a red build
// rather than a dimmed row: a tab added to TABS with no entry here fails.
use serde_json::Value;

use super::{arr, num, text};
use super::super::model::tabs::TABS;

/// `(tab, sub, key)` — sub is "" for a row belonging to the tab itself, which
/// is how a tab with no sub-tabs gets children.
///
/// A `__`-prefixed key is a page the web renderer draws from the envelope
/// rather than from a snapshot array.
pub(crate) const BACKED_BY: &[(&str, &str, &str)] = &[
    ("proc", "normal", "proc_table"),
    ("proc", "tree", "proc_spine"),
    ("proc", "zombies", "proc_zombies"),
    ("proc", "parentless", "proc_parentless"),
    ("containers", "compose", "compose"),
    ("containers", "images", "images"),
    ("containers", "containers", "containers"),
    ("containers", "volumes", "volumes"),
    ("containers", "network", "networks"),
    // One row per peer that HAS an address on that network. wg0 carries no v6
    // on this mesh, so wg0-ipv6 is legitimately empty — and empty because the
    // filter found nothing, which is a different statement from unbacked.
    ("fleet", "wg0-ipv4", "fleet_wg0_ipv4"),
    ("fleet", "wg0-ipv6", "fleet_wg0_ipv6"),
    ("fleet", "wg-public-ipv4", "fleet_wgpub_ipv4"),
    ("fleet", "wg-public-ipv6", "fleet_wgpub_ipv6"),
    ("fleet", "storage", "storage"),
    // The panel's consolidated view is the cross-reference between what is
    // bound and what the fleet declares; that join is the page, so the join
    // travels rather than the two halves.
    ("firewall", "consolidated", "firewall_declared"),
    ("firewall", "os", "listening"),
    ("firewall", "container", "firewall_published"),
    ("logs", "summary", "logs_summary"),
    ("logs", "kernel", "logs_kernel"),
    ("logs", "system", "logs_system"),
    ("logs", "user", "logs_user"),
    ("logs", "docker", "logs_docker"),
    ("logs", "network", "logs_network"),
    ("logs", "ssh", "logs_ssh"),
    ("logs", "watchdog", "logs_watchdog"),
    ("history", "", "history_days"),
    ("files", "", "__files"),
    ("about", "about", "cores"),
    ("about", "about", "disks"),
    ("about", "about", "services"),
    ("about", "about", "slices"),
    ("about", "rules", "__rules"),
    ("about", "update", "update_steps"),
    ("about", "app-map", "__appmap"),
];

/// Every snapshot key the tree names, in table order and without duplicates.
///
/// The app shell seeds one placeholder row per key so the APK's drawer carries
/// the whole tree: the shell is generated against an empty machine and ships
/// inside the APK, so a row that only appears when data is present is a row
/// the phone can never grow.
pub(crate) fn keys() -> Vec<&'static str> {
    let mut out: Vec<&'static str> = vec![];
    for (_, _, k) in BACKED_BY {
        if !k.starts_with("__") && !out.contains(k) {
            out.push(k);
        }
    }
    out
}

fn row(pairs: Vec<(&str, Value)>) -> Value {
    Value::Object(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

/// Add every derived page to the snapshot.
///
/// `machines` is the fleet list the envelope already carries; `target` is the
/// peer being measured, or None for this box — the journal reads honour it so
/// exporting a peer exports that peer's journal.
pub(crate) fn derive(
    snap: &mut serde_json::Map<String, Value>,
    machines: &[Value],
    target: Option<&str>,
) {
    let s = Value::Object(snap.clone());

    // ── proc: the two filters the panel calls sub-tabs ──────────────────────
    let procs = arr(&s, "proc_table");
    let zombies: Vec<Value> =
        procs.iter().filter(|p| text(p, "state").starts_with('Z')).cloned().collect();
    let parentless: Vec<Value> =
        procs.iter().filter(|p| num(p, "ppid") as i64 == 1).cloned().collect();
    snap.insert("proc_zombies".into(), Value::Array(zombies));
    snap.insert("proc_parentless".into(), Value::Array(parentless));

    // ── fleet: one page per mesh network, by the prefix TABS declares ───────
    // Read from TABS rather than repeated here, so the day wg0 gets a v6
    // address the page fills in with no change on this side.
    let fleet_tab = TABS.iter().find(|t| t.name == "fleet");
    for (sub, key) in [
        ("wg0-ipv4", "fleet_wg0_ipv4"),
        ("wg0-ipv6", "fleet_wg0_ipv6"),
        ("wg-public-ipv4", "fleet_wgpub_ipv4"),
        ("wg-public-ipv6", "fleet_wgpub_ipv6"),
    ] {
        let net = fleet_tab
            .and_then(|t| t.subs.iter().find(|sb| sb.name == sub))
            .and_then(|sb| sb.net);
        let rows: Vec<Value> = match net {
            None => vec![],
            Some(pfx) => machines
                .iter()
                .filter(|m| text(m, "ip").starts_with(pfx) || text(m, "public").starts_with(pfx))
                .map(|m| {
                    let addr = if text(m, "ip").starts_with(pfx) {
                        text(m, "ip")
                    } else {
                        text(m, "public")
                    };
                    row(vec![
                        ("machine", Value::String(text(m, "name"))),
                        ("addr", Value::String(addr)),
                        ("alias", Value::String(text(m, "alias"))),
                        ("role", Value::String(text(m, "role"))),
                        ("kind", Value::String(text(m, "kind"))),
                    ])
                })
                .collect(),
        };
        snap.insert(key.into(), Value::Array(rows));
    }

    // ── firewall: the two halves the panel joins ────────────────────────────
    let host = text(&s, "host_info.host");
    let socks = arr(&s, "listening");
    let bound = |p: u64| socks.iter().any(|sk| num(sk, "port") as u64 == p);
    let dec = super::storage::firewall_declared();
    let rules: Vec<Value> = dec
        .as_ref()
        .and_then(|d| d.get("hosts"))
        .and_then(|h| h.get(&host).or_else(|| h.as_object()?.values().next()))
        .and_then(|r| r.as_array().cloned())
        .unwrap_or_default();
    let declared: Vec<u64> = rules.iter().map(|r| num(r, "port") as u64).collect();
    snap.insert(
        "firewall_declared".into(),
        Value::Array(
            rules
                .iter()
                .map(|r| {
                    let p = num(r, "port") as u64;
                    row(vec![
                        ("port", Value::from(p)),
                        ("proto", Value::String(text(r, "proto"))),
                        ("source", Value::String(text(r, "source"))),
                        // The finding, not the rule: a hole opened for a
                        // service that is not there is the reason to look.
                        ("state", Value::String(
                            if bound(p) { "bound".into() } else { "NOTHING BOUND".to_string() },
                        )),
                        ("desc", Value::String(text(r, "desc"))),
                    ])
                })
                .collect(),
        ),
    );
    // docker inserts its chain AHEAD of the user rules, so a published port is
    // open whatever the OS policy says. "0.0.0.0:8080->80/tcp" — the host side
    // is the exposure; the container side reaches nobody on its own.
    let published: Vec<Value> = arr(&s, "containers")
        .iter()
        .flat_map(|c| {
            let name = text(c, "name");
            text(c, "ports")
                .split(',')
                .filter_map(|part| {
                    let (host_side, _) = part.trim().split_once("->")?;
                    let (addr, port) = host_side.rsplit_once(':')?;
                    let p: u64 = port.trim().parse().ok()?;
                    Some(row(vec![
                        ("port", Value::from(p)),
                        ("bind", Value::String(addr.to_string())),
                        ("container", Value::String(name.clone())),
                        // No host socket means userland-proxy is off: it is
                        // pure DNAT and the OS view CANNOT see it at all.
                        ("socket", Value::String(
                            if bound(p) { "bound".into() } else { "DNAT only".to_string() },
                        )),
                        ("declared", Value::Bool(declared.contains(&p))),
                    ]))
                })
                .collect::<Vec<_>>()
        })
        .collect();
    snap.insert("firewall_published".into(), Value::Array(published));

    // ── logs: eight sections and the 24h alert counts, CACHED ───────────────
    for (k, v) in journal(target) {
        snap.insert(k, v);
    }

    // ── history: the per-day rollup the sampler already keeps ───────────────
    snap.insert("history_days".into(), Value::Array(arr(&s, "history.days").to_vec()));

    // ── about/update: the steps, as the page that lists them ────────────────
    let mut steps: Vec<Value> = vec![];
    for way in [super::update::Way::Install, super::update::Way::Dev] {
        for st in super::update::steps(way) {
            steps.push(row(vec![
                ("way", Value::String(way.title().into())),
                ("step", Value::String(st.name.into())),
                ("why", Value::String(st.why.into())),
                ("cmd", Value::String(st.argv.join(" "))),
            ]));
        }
    }
    snap.insert("update_steps".into(), Value::Array(steps));
}

/// The journal pages, at most once every thirty seconds per machine.
///
/// THE CACHE IS THE POINT, not an optimisation. `derive` runs on every
/// envelope, and the phone asks for an envelope every few seconds — so an
/// uncached read would be sixteen journalctl invocations a tick, forever, on a
/// box the whole app exists to keep from thrashing. Thirty seconds is the same
/// window data::rules uses for the same reason and against the same journal.
///
/// Keyed by target: measuring a peer must not serve this machine's journal
/// back, which is a wrong answer rather than a stale one.
fn journal(target: Option<&str>) -> Vec<(String, Value)> {
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant};

    type Cached = (String, Instant, Vec<(String, Value)>);
    static CACHE: OnceLock<Mutex<Option<Cached>>> = OnceLock::new();
    let cell = CACHE.get_or_init(|| Mutex::new(None));
    let key = target.unwrap_or("local").to_string();
    if let Ok(g) = cell.lock() {
        if let Some((k, at, v)) = g.as_ref() {
            if *k == key && at.elapsed() < Duration::from_secs(30) {
                return v.clone();
            }
        }
    }

    let mut out: Vec<(String, Value)> = vec![(
        "logs_summary".to_string(),
        Value::Array(
            super::logs::counts_now(target)
                .into_iter()
                .map(|(name, n)| {
                    let desc = super::logs::section(&name).map(|s| s.desc).unwrap_or("");
                    row(vec![
                        ("section", Value::String(name)),
                        ("alerts_24h", Value::from(n)),
                        ("desc", Value::String(desc.into())),
                    ])
                })
                .collect(),
        ),
    )];
    for (name, lines) in super::logs::tail_all(target) {
        out.push((
            format!("logs_{name}"),
            Value::Array(lines.iter().map(|l| parse_log(l)).collect()),
        ));
    }
    // Every section always present, empty or not: a page that disappears when
    // its journal is quiet is the absence/emptiness confusion this commit
    // exists to end, one layer down.
    for sec in super::logs::SECTIONS {
        let k = format!("logs_{}", sec.name);
        if !out.iter().any(|(n, _)| *n == k) {
            out.push((k, Value::Array(vec![])));
        }
    }

    if let Ok(mut g) = cell.lock() {
        *g = Some((key, Instant::now(), out.clone()));
    }
    out
}

/// `2026-09-01T12:34:56+0200 host unit[pid]: message`, as columns.
///
/// A whole line in one cell is a log file, not a table — the time and the unit
/// are what a person scans, and they are fixed-width at the front. Anything
/// that does not match keeps its line intact rather than being cut wrong.
fn parse_log(l: &str) -> Value {
    let mut it = l.splitn(4, ' ');
    match (it.next(), it.next(), it.next(), it.next()) {
        (Some(ts), Some(_host), Some(unit), Some(msg)) if ts.contains('T') && ts.len() >= 19 => {
            row(vec![
                // The date repeats on every row of a 200-line tail; the clock
                // is the part that differs.
                ("time", Value::String(ts.get(11..19).unwrap_or(ts).to_string())),
                ("unit", Value::String(unit.trim_end_matches(':').to_string())),
                ("msg", Value::String(msg.to_string())),
            ])
        }
        _ => row(vec![("msg", Value::String(l.to_string()))]),
    }
}

#[cfg(test)]
mod tests {
    use super::{keys, BACKED_BY};
    use super::super::super::model::tabs::TABS;

    /// Every leaf of the tab tree names an array.
    ///
    /// The whole point: an unbacked node renders dimmed and inert, which looks
    /// exactly like a page whose data has not arrived yet. Eleven of them sat
    /// like that. A tab added without a producer fails here instead.
    #[test]
    fn every_leaf_is_backed() {
        for t in TABS {
            if t.subs.is_empty() {
                assert!(
                    BACKED_BY.iter().any(|(tab, sub, _)| *tab == t.name && sub.is_empty()),
                    "tab `{}` has no backing array — it will render as a dead row",
                    t.name
                );
            }
            for sb in t.subs {
                assert!(
                    BACKED_BY.iter().any(|(tab, sub, _)| *tab == t.name && *sub == sb.name),
                    "`{}/{}` has no backing array — it will render as a dead row",
                    t.name,
                    sb.name
                );
            }
        }
    }

    /// And no entry names a node that does not exist.
    #[test]
    fn every_entry_names_a_real_node() {
        for (tab, sub, key) in BACKED_BY {
            let t = TABS
                .iter()
                .find(|t| t.name == *tab)
                .unwrap_or_else(|| panic!("{key}: no tab named `{tab}`"));
            if !sub.is_empty() {
                assert!(
                    t.subs.iter().any(|sb| sb.name == *sub),
                    "{key}: `{tab}` has no sub-tab `{sub}`"
                );
            }
        }
    }

    /// The shell seeds each key once.
    #[test]
    fn keys_are_unique_and_exclude_envelope_pages() {
        let k = keys();
        let mut sorted = k.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(k.len(), sorted.len(), "a key is seeded twice");
        assert!(!k.iter().any(|k| k.starts_with("__")), "envelope pages are not snapshot arrays");
    }
}
