// The guards' own rulebook, read from the policy they are driven by.
//
// WHY THIS EXISTS
// disk-watchdog freezes and SIGTERMs whole systemd slices on thresholds that
// lived only in /etc/cloud-data/disk-protection.json. On the day it mattered
// it declared an emergency every five minutes for a day, and the only way to
// learn which slices were at risk, what would be reclaimed first, or what
// "protected" meant was to read a 500-line JSON file by hand.
//
// READ, NEVER WRITTEN. This module opens one file and formats it. The panel
// must not become a second place where policy is decided — the file is the
// policy, and if the two ever disagree, this one is wrong by construction.

use serde_json::Value;

/// Where the disk guard reads its policy. The same default the shipped
/// disk-watchdog script uses, so the panel and the guard cannot look at two
/// different files.
pub(crate) const POLICY_PATH: &str = "/etc/cloud-data/disk-protection.json";

/// One rendered section of the rulebook: a heading and its lines.
pub(crate) struct Rule {
    pub(crate) head: String,
    pub(crate) lines: Vec<String>,
}

fn arr<'a>(v: &'a Value, k: &str) -> Vec<&'a Value> {
    v.get(k).and_then(|x| x.as_array()).map(|a| a.iter().collect()).unwrap_or_default()
}

fn strs(v: &Value, k: &str) -> Vec<String> {
    arr(v, k).iter().filter_map(|x| x.as_str()).map(String::from).collect()
}

fn n(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(|x| x.as_f64())
}

/// The policy as a list of sections, or the reason there is none.
///
/// A missing file is a normal state, not an error: most of the fleet has no
/// desktop disk guard, and saying so plainly beats an empty page that looks
/// like a bug.
pub(crate) fn rules() -> Result<Vec<Rule>, String> {
    let raw = std::fs::read_to_string(POLICY_PATH)
        .map_err(|e| format!("{POLICY_PATH}: {e}"))?;
    let p: Value = serde_json::from_str(&raw)
        .map_err(|e| format!("{POLICY_PATH}: unparseable — {e}"))?;

    let mut out = vec![];
    let em = p.get("emergency").cloned().unwrap_or(Value::Null);

    // ── the ladder ────────────────────────────────────────────────────────
    let mut ladder = vec![];
    let alert: Vec<String> = arr(&em, "alert_ladder_pct")
        .iter()
        .filter_map(|x| x.as_f64())
        .map(|x| format!("{x:.0}%"))
        .collect();
    if !alert.is_empty() {
        ladder.push(format!("warn at         {}  — alert only, nothing is touched", alert.join(", ")));
    }
    if let Some(x) = n(&em, "pct") {
        ladder.push(format!("emergency at    {x:.0}%  — reclaim first; freeze/kill only if that fails"));
    }
    if let Some(x) = n(&em, "no_mercy_pct") {
        ladder.push(format!("no mercy at     {x:.0}%  — the cooldown is void, killing happens now"));
    }
    if !ladder.is_empty() {
        out.push(Rule { head: "when the disk guard acts".into(), lines: ladder });
    }

    // ── what it does to whom ──────────────────────────────────────────────
    let mut slices = vec![];
    let prot = strs(&em, "protected_slices");
    if !prot.is_empty() {
        slices.push(format!("never touched   {}", prot.join(", ")));
        slices.push("                ssh, wireguard, the session, the guards themselves".into());
    }
    let fr = strs(&em, "freeze_slices");
    if !fr.is_empty() {
        slices.push(format!("frozen first    {}  — paused, reversible, no work lost", fr.join(", ")));
    }
    let kl = strs(&em, "kill_slices");
    if !kl.is_empty() {
        slices.push(format!("SIGTERM last    {}  — only after freezing failed to help", kl.join(", ")));
    }
    if let Some(c) = n(&em, "cooldown_minutes") {
        slices.push(format!("kill cooldown   {c:.0} min"));
        // The distinction that cost a day of thrashing: the cooldown guards
        // the kill and nothing else, so a zero-yield reclaim re-runs on every
        // single tick for as long as the disk stays full.
        slices.push("                guards the SIGTERM only — reclaim still runs every tick".into());
    }
    if !slices.is_empty() {
        out.push(Rule { head: "which slices, and in what order".into(), lines: slices });
    }

    // ── the reclaim ladder, in the order it is attempted ──────────────────
    let acts = strs(&em, "actions");
    if !acts.is_empty() {
        let lines = acts
            .iter()
            .enumerate()
            .map(|(i, a)| format!("{:>2}. {}", i + 1, a.replace('_', " ")))
            .collect();
        out.push(Rule { head: "what it frees, in order, before anything is frozen".into(), lines });
    }

    // ── per-mount watches ─────────────────────────────────────────────────
    let watches: Vec<String> = arr(&p, "watches")
        .iter()
        .filter(|w| w.is_object() && w.get("mount").is_some())
        .map(|w| {
            let mount = w.get("mount").and_then(|x| x.as_str()).unwrap_or("?");
            let warn = n(w, "warn_pct").map(|x| format!("{x:.0}%")).unwrap_or_else(|| "—".into());
            let crit = n(w, "critical_pct").map(|x| format!("{x:.0}%")).unwrap_or_else(|| "—".into());
            format!("{mount:<24} warn {warn:>4}   critical {crit:>4}")
        })
        .collect();
    if !watches.is_empty() {
        out.push(Rule { head: "per-mount thresholds".into(), lines: watches });
    }

    if out.is_empty() {
        return Err(format!("{POLICY_PATH}: no rules in it"));
    }
    Ok(out)
}
