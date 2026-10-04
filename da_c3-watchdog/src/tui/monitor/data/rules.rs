// The guards' rulebook: what fires, at what value, and how often it has.
//
// WHY THIS EXISTS
// disk-watchdog freezes and SIGTERMs whole systemd slices on thresholds that
// lived only in /etc/cloud-data/disk-protection.json. It froze workload.slice
// 986 times in one day and nobody knew, because the only alert channel was an
// ntfy topic that had been answering "daily message quota reached" for hours.
//
// So the page is a TABLE, not prose: every rule, the value that triggers it,
// and the number of times it actually fired. A threshold with no fire count is
// a claim; a fire count is what the machine did.
//
// READ, NEVER WRITTEN. The policy file is the policy. If this page and the
// guard ever disagree, this page is wrong by construction.

use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::Value;

/// Where the disk guard reads its policy — the same default the shipped
/// disk-watchdog script uses, so the panel and the guard cannot look at two
/// different files.
pub(crate) const POLICY_PATH: &str = "/etc/cloud-data/disk-protection.json";

/// How far back fire counts look. A day: long enough that a rule which fires
/// hourly is obviously distinct from one that has never fired, short enough
/// that the count describes NOW rather than the machine's whole history.
const WINDOW: &str = "24 hours ago";

/// One row of the rulebook.
pub(crate) struct Row {
    pub(crate) rule: String,
    /// The value that triggers it, as a person would check it.
    pub(crate) trigger: String,
    /// What happens. Empty where the rule name already says it.
    pub(crate) effect: String,
    /// Times it fired in [`WINDOW`]. `None` where the journal cannot answer —
    /// which is different from zero, and must not be shown as zero.
    pub(crate) fires: Option<u64>,
}

pub(crate) struct Table {
    pub(crate) head: String,
    pub(crate) rows: Vec<Row>,
}

fn n(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(|x| x.as_f64())
}

fn strs(v: &Value, k: &str) -> Vec<String> {
    v.get(k)
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|s| s.as_str()).map(String::from).collect())
        .unwrap_or_default()
}

/// The guard's journal for [`WINDOW`], as one string.
///
/// ONE call, not one per rule. Counting nine markers with nine journalctl
/// invocations means nine scans of the same journal, on a page that redraws
/// every second — and this runs on a machine already in trouble, since a
/// person reading the rulebook is usually a person whose disk is full.
fn journal() -> Option<String> {
    let out = Command::new("journalctl")
        .args([
            "SYSLOG_IDENTIFIER=disk-watchdog",
            "+",
            "SYSLOG_IDENTIFIER=disk-emergency",
            "+",
            "_SYSTEMD_UNIT=disk-watchdog-v2.service",
            "--since",
            WINDOW,
            "--no-pager",
            "-o",
            "cat",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Counted markers, cached.
///
/// The rules page redraws with everything else, and a journal scan per frame
/// would make reading the rulebook the most expensive thing the panel does.
/// Thirty seconds is well under the guard's own five-minute timer, so no fire
/// can be missed by more than one tick of the thing being watched.
fn counts() -> Option<String> {
    static CACHE: OnceLock<Mutex<Option<(Instant, Option<String>)>>> = OnceLock::new();
    let cell = CACHE.get_or_init(|| Mutex::new(None));
    let mut slot = cell.lock().ok()?;
    if let Some((at, ref text)) = *slot {
        if at.elapsed() < Duration::from_secs(30) {
            return text.clone();
        }
    }
    let fresh = journal();
    *slot = Some((Instant::now(), fresh.clone()));
    fresh
}

/// Lines containing every fragment in `all`. Substring rather than regex: the
/// guard's messages are fixed strings it prints itself, so the marker IS the
/// contract and a pattern language would only add a way to get it wrong.
fn fires(log: &Option<String>, all: &[&str]) -> Option<u64> {
    let text = log.as_ref()?;
    Some(text.lines().filter(|l| all.iter().all(|m| l.contains(m))).count() as u64)
}

/// The rulebook, or the reason there is none.
///
/// A missing policy file is a normal state rather than an error: most of the
/// fleet has no desktop disk guard, and saying so plainly beats an empty page
/// that reads like a bug.
pub(crate) fn rules() -> Result<Vec<Table>, String> {
    let raw = std::fs::read_to_string(POLICY_PATH).map_err(|e| format!("{POLICY_PATH}: {e}"))?;
    let p: Value =
        serde_json::from_str(&raw).map_err(|e| format!("{POLICY_PATH}: unparseable — {e}"))?;
    let log = counts();
    let em = p.get("emergency").cloned().unwrap_or(Value::Null);
    let mut out = vec![];

    // ── the ladder ────────────────────────────────────────────────────────
    let ladder: Vec<f64> = p
        .get("emergency")
        .and_then(|e| e.get("alert_ladder_pct"))
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_f64()).collect())
        .unwrap_or_default();

    let mut rows = vec![];
    if let Some(first) = ladder.first() {
        rows.push(Row {
            rule: "warn".into(),
            trigger: format!("fill ≥ {first:.0}%"),
            effect: "alert only — nothing is touched".into(),
            fires: fires(&log, &["[disk-watchdog] WARN"]),
        });
    }
    if ladder.len() > 1 {
        rows.push(Row {
            rule: "pre-emergency".into(),
            trigger: format!("fill ≥ {:.0}%", ladder[1]),
            effect: "reclaim begins".into(),
            fires: fires(&log, &["PRE-EMERGENCY"]),
        });
    }
    if let Some(x) = n(&em, "pct") {
        rows.push(Row {
            rule: "emergency".into(),
            trigger: format!("fill ≥ {x:.0}%"),
            effect: "reclaim first, then freeze, then kill".into(),
            fires: fires(&log, &["EMERGENCY", "stop-the-bleeding"]),
        });
    }
    if let Some(x) = n(&em, "no_mercy_pct") {
        rows.push(Row {
            rule: "no mercy".into(),
            trigger: format!("fill ≥ {x:.0}%"),
            effect: "cooldown void — kill now".into(),
            fires: fires(&log, &["NO-MERCY"]),
        });
    }
    out.push(Table { head: "when the disk guard acts".into(), rows });

    // ── what it does, and how often it has actually done it ───────────────
    // These are the rows that matter most and the ones the old prose page did
    // not have: "freeze workload.slice" as a policy line reads survivable,
    // and 986 of them in a day does not.
    let mut rows = vec![];
    let prot = strs(&em, "protected_slices");
    if !prot.is_empty() {
        rows.push(Row {
            rule: "protected".into(),
            trigger: prot.join(" "),
            effect: "never frozen, never killed".into(),
            fires: Some(0),
        });
    }
    let fr = strs(&em, "freeze_slices");
    if !fr.is_empty() {
        rows.push(Row {
            rule: "freeze".into(),
            trigger: format!("{} · reclaim insufficient", fr.join(" ")),
            effect: "writes halted, reversible".into(),
            fires: fires(&log, &["FROZE"]),
        });
        rows.push(Row {
            rule: "thaw".into(),
            trigger: "after the reclaim pass".into(),
            effect: "resumed".into(),
            fires: fires(&log, &["THAWED"]),
        });
    }
    let kl = strs(&em, "kill_slices");
    if !kl.is_empty() {
        rows.push(Row {
            rule: "SIGTERM".into(),
            trigger: format!("{} · freeze did not help", kl.join(" ")),
            effect: "last resort".into(),
            fires: fires(&log, &["SIGTERM", "->"]),
        });
    }
    if let Some(c) = n(&em, "cooldown_minutes") {
        rows.push(Row {
            rule: "kill cooldown".into(),
            trigger: format!("within {c:.0} min of the last kill"),
            // The distinction that cost a day of thrashing, stated where it is
            // checkable: the cooldown holds the SIGTERM and nothing else, so
            // freeze and reclaim run on every single tick regardless.
            effect: "suppresses the kill ONLY — freeze and reclaim still run".into(),
            fires: fires(&log, &["SIGTERM SUPPRESSED"]),
        });
    }
    rows.push(Row {
        rule: "reclaim insufficient".into(),
        trigger: "still over threshold after reclaim".into(),
        effect: "escalates to freeze".into(),
        fires: fires(&log, &["RECLAIM INSUFFICIENT"]),
    });
    rows.push(Row {
        rule: "reclaim self-healed".into(),
        trigger: "under threshold after reclaim".into(),
        effect: "nothing is frozen or killed".into(),
        fires: fires(&log, &["RECLAIM SELF-HEALED"]),
    });
    out.push(Table { head: "which slices, and what has happened to them".into(), rows });

    // ── the reclaim ladder, in the order it is attempted ──────────────────
    let acts = strs(&em, "actions");
    if !acts.is_empty() {
        let rows = acts
            .iter()
            .enumerate()
            .map(|(i, a)| Row {
                rule: format!("{:>2}. {}", i + 1, a.replace('_', " ")),
                trigger: "emergency tier".into(),
                effect: String::new(),
                // Only the nix collector prints a countable result of its own;
                // the rest leave no marker naming the action, and inventing one
                // from the tier's fire count would report a number this cannot
                // actually see.
                fires: if a.starts_with("nix_gc") {
                    fires(&log, &["store paths deleted"])
                } else {
                    None
                },
            })
            .collect();
        out.push(Table { head: "what it frees, in order, before anything is frozen".into(), rows });
    }

    // ── per-mount watches ─────────────────────────────────────────────────
    let watches: Vec<Row> = p
        .get("watches")
        .and_then(|w| w.as_array())
        .map(|a| {
            a.iter()
                .filter(|w| w.is_object() && w.get("mount").is_some())
                .map(|w| {
                    let mount = w.get("mount").and_then(|x| x.as_str()).unwrap_or("?");
                    let warn = n(w, "warn_pct").map(|x| format!("{x:.0}%")).unwrap_or("—".into());
                    let crit =
                        n(w, "critical_pct").map(|x| format!("{x:.0}%")).unwrap_or("—".into());
                    Row {
                        rule: mount.to_string(),
                        trigger: format!("warn {warn} · critical {crit}"),
                        effect: String::new(),
                        fires: fires(&log, &["[disk-watchdog]", mount, ">="]),
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    if !watches.is_empty() {
        out.push(Table { head: "per-mount thresholds".into(), rows: watches });
    }

    if out.is_empty() {
        return Err(format!("{POLICY_PATH}: no rules in it"));
    }
    Ok(out)
}
