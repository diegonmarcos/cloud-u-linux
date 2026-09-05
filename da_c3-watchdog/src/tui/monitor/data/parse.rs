// Docker renders its numbers as prose. These read them back.
//
// Moved out of monitor/mod.rs, which had grown to 6007 lines. Same code,
// same order; only the file it lives in changed.

/// docker's MemUsage is "469.7MiB / 7.595GiB" — used on the left of the
/// slash, the limit on the right. Two different questions in one cell: what a
/// container is using, and what it is allowed. They get a column each, and
/// splitting them is what makes "rank by memory used" possible at all.
pub(crate) fn ctr_mem(v: &str) -> (String, String) {
    match v.split_once('/') {
        Some((a, b)) => (a.trim().to_string(), b.trim().to_string()),
        // No slash means no limit was set, which since the ceilings came off
        // is the normal case: it is all usage.
        None => (v.trim().to_string(), String::new()),
    }
}

/// "12 hours ago" / "3 days ago" as seconds, so CREATED ranks by age rather
/// than alphabetically — where "3 days" would sort before "3 hours".
pub(crate) fn age_secs(v: &str) -> f64 {
    let n: f64 = v
        .split_whitespace()
        .next()
        .and_then(|x| x.parse().ok())
        .unwrap_or(0.0);
    let unit = v.split_whitespace().nth(1).unwrap_or("");
    n * if unit.starts_with("second") {
        1.0
    } else if unit.starts_with("minute") {
        60.0
    } else if unit.starts_with("hour") {
        3600.0
    } else if unit.starts_with("day") {
        86_400.0
    } else if unit.starts_with("week") {
        604_800.0
    } else if unit.starts_with("month") {
        2_592_000.0
    } else if unit.starts_with("year") {
        31_536_000.0
    } else {
        0.0
    }
}

/// The first number in a docker-rendered field. "469.7MiB / 7.595GiB" ranks by
/// what the container is using, not by its limit; "12.34%" ranks by 12.34.
pub(crate) fn ctr_num(v: &str) -> f64 {
    let mut out = String::new();
    for c in v.chars() {
        if c.is_ascii_digit() || c == '.' {
            out.push(c);
        } else if !out.is_empty() {
            break;
        }
    }
    let n: f64 = out.parse().unwrap_or(0.0);
    // A bare number followed by a unit has to be scaled or 900kB outranks 5GB.
    let rest = v.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.');
    let mult = if rest.starts_with("GiB") || rest.starts_with("GB") {
        1_073_741_824.0
    } else if rest.starts_with("MiB") || rest.starts_with("MB") {
        1_048_576.0
    } else if rest.starts_with("kB") || rest.starts_with("KiB") {
        1024.0
    } else {
        1.0
    };
    n * mult
}
