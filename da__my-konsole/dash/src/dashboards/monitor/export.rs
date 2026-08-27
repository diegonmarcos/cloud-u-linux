// Writing a snapshot out, and the /proc reads only the detail view needs.
use std::fs;

use serde_json::Value;

use crate::dashboards::monitor::data::{arr, num, text};
use crate::dashboards::monitor::view::fmt::{fmt_bytes_short, fmt_g, fmt_gib, fmt_uptime};

/// Everything on screen, written out twice: the snapshot verbatim as JSON and
/// a readable report as Markdown.
///
/// Both, not one. The JSON is the truth and survives being diffed against a
/// later export or fed to something else; the Markdown is what you can paste
/// into an issue at 3am without the reader parsing a thousand-line object.
/// Writing only the pretty one is how exports stop being useful the moment
/// somebody needs a field it left out.
///
/// A YAML scalar, quoted only where bare would parse back as something else.
///
/// The point of the YAML is token count, and a quote is a token — so bare is
/// the default and quoting is the exception: a number-, bool- or null-looking
/// string, or one carrying structural characters. Emitted as UTF-8 throughout,
/// never \u-escaped, for the same reason.
fn yaml_str(v: &str) -> String {
    let needs = v.is_empty()
        || v.trim() != v
        || v.contains(['\n', '"', '\'', ':', '#', '\\'])
        || v.starts_with(['-', '?', ',', '[', ']', '{', '}', '&', '*', '!', '|', '>', '%', '@', '`'])
        || matches!(v, "true" | "false" | "null" | "yes" | "no" | "on" | "off" | "~")
        || v.parse::<f64>().is_ok();
    if !needs {
        return v.to_string();
    }
    format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n"))
}

/// Forty lines against a serde_yaml dependency and its transitive tree, for
/// one output format used in one function — the same trade the sampler makes
/// by writing its JSON by hand. Empty containers go inline so a map of mostly
/// empties does not become a page of bare keys.
///
/// ONE space of indent, not two. This file is the machine-facing half of the
/// pair — the Markdown beside it is the one meant to be read — and on a
/// snapshot nested this deep the second space buys nothing but 95 KB.
pub(crate) fn to_yaml(v: &Value, indent: usize, out: &mut String) {
    let pad = " ".repeat(indent);
    let block = |v: &Value| {
        matches!(v, Value::Object(o) if !o.is_empty()) || matches!(v, Value::Array(a) if !a.is_empty())
    };
    match v {
        Value::Object(m) if m.is_empty() => out.push_str("{}\n"),
        Value::Array(a) if a.is_empty() => out.push_str("[]\n"),
        Value::Object(m) => {
            out.push('\n');
            for (k, val) in m {
                out.push_str(&pad);
                out.push_str(&yaml_str(k));
                out.push(':');
                // A nested block starts on the next line at one deeper indent;
                // a scalar sits on this one, after a single space.
                if !block(val) {
                    out.push(' ');
                }
                to_yaml(val, indent + 1, out);
            }
        }
        Value::Array(a) => {
            out.push('\n');
            for item in a {
                out.push_str(&pad);
                out.push_str("- ");
                to_yaml(item, indent + 1, out);
            }
        }
        Value::String(s) => {
            out.push_str(&yaml_str(s));
            out.push('\n');
        }
        Value::Null => out.push_str("null\n"),
        other => {
            out.push_str(&other.to_string());
            out.push('\n');
        }
    }
}

/// The units that MEAN something, plus counts for the rest.
///
/// `v` publishes all 428. The first cut kept everything not running, which
/// sounds small and is not: 144 of those are "not-loaded", meaning a unit FILE
/// exists that was never loaded — installed software, not a stopped service,
/// with `sub` literally an em dash. Another 148 are loaded-but-dead, mostly
/// oneshots that ran and exited as designed.
///
/// Six are failed. That is the set anybody opens this file to find, so it is
/// the set the machine files carry, with every state counted beside it so the
/// totals are stated rather than quietly dropped. The Markdown still tables
/// every unit that is not running, capped at sixty, and the live `v` view
/// still shows all of them — this is the export, not the panel.
fn trim_units(v: &Value) -> Value {
    let mut out = v.clone();
    let Some(svc) = v.get("services").and_then(|x| x.as_array()) else { return out };
    let count = |state: &str| svc.iter().filter(|u| text(u, "active") == state).count();
    let failed: Vec<Value> =
        svc.iter().filter(|u| text(u, "active") == "failed").cloned().collect();
    if let Some(o) = out.as_object_mut() {
        o.insert("services_declared".into(), serde_json::json!(svc.len()));
        o.insert("services_active".into(), serde_json::json!(count("active")));
        o.insert("services_inactive".into(), serde_json::json!(count("inactive")));
        o.insert("services_not_loaded".into(), serde_json::json!(count("not-loaded")));
        o.insert("services_failed".into(), serde_json::json!(failed.len()));
        o.insert("services".into(), Value::Array(failed));
    }
    out
}

/// The name is {host}-{user}-{timestamp}: the triple that stays unambiguous
/// once you have exported the same peer twice and a second machine once. The
/// host comes from the SNAPSHOT, so exporting a peer names the peer.
///
/// `fleet` EMPTY is the default and the common case: one export, one machine.
/// Pass peers to fold the whole mesh into the same file — everything the
/// panel could show, at the cost of a file several times the size.
pub(crate) fn export_snapshot(
    s: &Value,
    target: Option<String>,
    files: &[String],
    fleet: &[(String, Value)],
) -> Result<String, String> {
    let hi = |k: &str| text(s, &format!("host_info.{k}"));
    let host = if hi("host").is_empty() { "unknown".to_string() } else { hi("host") };
    let user = if hi("user").is_empty() { "unknown".to_string() } else { hi("user") };
    // date(1) rather than arithmetic on a unix counter: this name is for a
    // human to find later, so it wants LOCAL time, and those rules live in the
    // system's timezone database rather than in a formula worth rewriting.
    let stamp = std::process::Command::new("date")
        .arg("+%Y-%m-%d_%H-%M-%S")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .ok_or("could not read the clock")?;

    let safe = |x: &str| -> String {
        x.chars()
            .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
            .collect()
    };
    // ~/.watchdog, not $HOME: exports accumulate — one pair per press — and
    // a home directory is the wrong place to accumulate anything. One
    // directory means they are findable, listable and deletable as a set.
    let home = std::env::var("HOME").map_err(|_| "no HOME".to_string())?;
    let dir = format!("{home}/.watchdog");
    fs::create_dir_all(&dir).map_err(|e| format!("{dir}: {e}"))?;
    let stem = format!("{dir}/{}-{}-{stamp}", safe(&host), safe(&user));

    // ONE MACHINE BY DEFAULT — the one being measured, whichever that is.
    // `target` picks it, so exporting while viewing a peer writes that peer's
    // file under that peer's name, and the file tree is the one on screen.
    //
    // The fleet was 772KB of a 1030KB export and is now opt-in, because an
    // export is normally a snapshot OF something and folding four other
    // machines into it made the common case pay for the rare one.
    //
    // Still an envelope rather than the bare snapshot: the file tree is read
    // from disk by the panel and never appears in what the sampler publishes.
    let mut envelope = serde_json::Map::new();
    envelope.insert("snapshot".into(), trim_units(s));
    envelope.insert("files".into(), serde_json::json!(files));
    envelope.insert("exported".into(), serde_json::json!(stamp));
    envelope.insert(
        "measured".into(),
        serde_json::json!(target.clone().unwrap_or_else(|| "local".into())),
    );

    // DEDUPED BY MACHINE, not by alias. ~/.ssh/config gives several ways in to
    // the same box — oci-analytics, -pub and -v6 are one host — and the fleet
    // map is keyed by alias, so a naive dump wrote that machine's whole
    // snapshot three times. The peer's own hostname is the identity; the
    // aliases that reached it are recorded beside it, because which route
    // answered is worth knowing and costs a string.
    if !fleet.is_empty() {
        let mut by_host: serde_json::Map<String, Value> = serde_json::Map::new();
        let mut aliases: std::collections::BTreeMap<String, Vec<String>> = Default::default();
        for (alias, v) in fleet {
            let peer = text(v, "host_info.host");
            let key = if peer.is_empty() { alias.clone() } else { peer };
            aliases.entry(key.clone()).or_default().push(alias.clone());
            by_host.entry(key).or_insert_with(|| trim_units(v));
        }
        envelope.insert("fleet".into(), Value::Object(by_host));
        envelope.insert("fleet_aliases".into(), serde_json::json!(aliases));
    }
    let envelope = Value::Object(envelope);
    // Compact, not pretty. Indentation was 35% of the file and this is the
    // machine-readable half of the pair — the Markdown beside it is the one
    // meant to be read. `jq .` puts the whitespace back for free.
    let json = serde_json::to_string(&envelope).map_err(|e| e.to_string())?;
    fs::write(format!("{stem}.json"), json).map_err(|e| format!("{stem}.json: {e}"))?;

    // The same data as YAML, for feeding to a model. No braces, no commas, no
    // quotes on most strings — the structure costs a fraction of the tokens
    // JSON spends on punctuation, and nothing is dropped to get there.
    let mut yaml = String::new();
    to_yaml(&envelope, 0, &mut yaml);
    fs::write(format!("{stem}.yaml"), yaml.trim_start_matches('\n'))
        .map_err(|e| format!("{stem}.yaml: {e}"))?;

    let n = |k: &str| num(s, k);
    let mut m = String::new();
    m.push_str(&format!("# {host} · {stamp}\n\n"));
    if let Some(a) = &target {
        m.push_str(&format!(
            "> Collected from `{a}` over ssh by the hub, not published by that machine.\n\n"
        ));
    }
    let row = |m: &mut String, k: &str, v: String| m.push_str(&format!("| {k} | {v} |\n"));
    m.push_str("| | |\n|---|---|\n");
    row(&mut m, "user", user.clone());
    row(&mut m, "os", hi("os"));
    row(&mut m, "kernel", hi("kernel"));
    row(&mut m, "uptime", fmt_uptime(n("totals.since_s")));
    row(&mut m, "cpu", text(s, "cpu_info.model"));
    row(&mut m, "cores", format!("{}", arr(s, "cores").len()));
    row(&mut m, "memory", fmt_gib(n("mem_detail.total")));
    row(&mut m, "swap", fmt_gib(n("swap_detail.total")));

    m.push_str("\n## Now\n\n| | |\n|---|---|\n");
    row(&mut m, "cpu", format!("{:.1}%", n("cpu")));
    row(&mut m, "load", format!("{:.2} {:.2} {:.2}", n("load1"), n("load5"), n("load15")));
    row(
        &mut m,
        "memory",
        format!("{:.1}%  {} of {}", n("mem"), fmt_gib(n("mem_detail.used")), fmt_gib(n("mem_detail.total"))),
    );
    row(&mut m, "swap", format!("{:.1}%", n("swap")));
    row(
        &mut m,
        "psi cpu / io / mem",
        format!("{:.2} / {:.2} / {:.2}", n("psi.cpu.some10"), n("psi.io.full10"), n("psi.memory.full10")),
    );

    m.push_str("\n## Moved since boot\n\n| | |\n|---|---|\n");
    for (k, f) in [
        ("downloaded", "totals.net_rx_bytes"),
        ("uploaded", "totals.net_tx_bytes"),
        ("read", "totals.disk_read_bytes"),
        ("written", "totals.disk_write_bytes"),
    ] {
        row(&mut m, k, fmt_bytes_short(n(f)));
    }

    let ifs = arr(s, "host_info.ifaces");
    if !ifs.is_empty() {
        m.push_str("\n## Network\n\n| interface | address |\n|---|---|\n");
        for i in ifs {
            m.push_str(&format!("| {} | {} |\n", text(i, "name"), text(i, "addr")));
        }
        let pubip = hi("public");
        m.push_str(&format!(
            "\ngateway `{}` via `{}` · public {} · dns {}\n",
            hi("gateway"),
            hi("wan_if"),
            if pubip.is_empty() { "behind NAT".into() } else { format!("`{pubip}`") },
            arr(s, "host_info.dns")
                .iter()
                .filter_map(|d| d.as_str())
                .map(|d| format!("`{d}`"))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }

    for pool in arr(s, "storage") {
        m.push_str(&format!(
            "\n## Storage ({})\n\n{} of {} used\n\n| mount | used | limit |\n|---|---|---|\n",
            text(pool, "label"),
            fmt_g(num(pool, "alloc_used")),
            fmt_g(num(pool, "dev_size"))
        ));
        for v in arr(pool, "volumes") {
            let lim = num(v, "limit");
            m.push_str(&format!(
                "| {} | {} | {} |\n",
                text(v, "mount"),
                fmt_g(num(v, "referenced")),
                if lim > 0.0 { fmt_g(lim) } else { "—".into() }
            ));
        }
    }

    let cs = arr(s, "containers");
    if !cs.is_empty() {
        m.push_str("\n## Containers\n\n| name | status | cpu | mem | ports | image |\n|---|---|---|---|---|---|\n");
        for c in cs {
            let or = |k: &str| {
                let v = text(c, k);
                if v.is_empty() { "—".to_string() } else { v }
            };
            m.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} |\n",
                text(c, "name"),
                text(c, "status"),
                or("cpu"),
                or("mem_pct"),
                or("ports"),
                text(c, "image")
            ));
        }
    }

    m.push_str("\n## Processes\n\n| pid | user | name | cpu% | mem% | rss |\n|---|---|---|---|---|---|\n");
    for p in arr(s, "proc_table").iter().take(40) {
        m.push_str(&format!(
            "| {} | {} | {} | {:.1} | {:.2} | {} |\n",
            num(p, "pid") as i64,
            text(p, "user"),
            text(p, "name"),
            num(p, "cpu_pct"),
            num(p, "mem_pct"),
            fmt_bytes_short(num(p, "mem_rss_bytes"))
        ));
    }
    // ── containers-i ───────────────────────────────────────────────────
    let imgs = arr(s, "images");
    if !imgs.is_empty() {
        let used: std::collections::HashSet<String> = arr(s, "containers")
            .iter()
            .map(|c| text(c, "image"))
            .collect();
        m.push_str("\n## Images\n\n| image | size | created | used by |\n|---|---|---|---|\n");
        for i in imgs {
            let full = format!("{}:{}", text(i, "repo"), text(i, "tag"));
            m.push_str(&format!(
                "| {full} | {} | {} | {} |\n",
                text(i, "size"),
                text(i, "created"),
                if used.contains(&full) { "yes" } else { "**nothing**" }
            ));
        }
    }

    // ── history ────────────────────────────────────────────────────────
    if num(s, "history.samples") >= 2.0 {
        let h = |k: &str| num(s, &format!("history.{k}"));
        m.push_str(&format!(
            "\n## Last {} ({} samples)\n\n| | |\n|---|---|\n",
            fmt_uptime(h("window_s")),
            h("samples") as i64
        ));
        for (k, f) in [
            ("downloaded", "net_rx_bytes"),
            ("uploaded", "net_tx_bytes"),
            ("read", "disk_read_bytes"),
            ("written", "disk_write_bytes"),
        ] {
            m.push_str(&format!("| {k} | {} |\n", fmt_bytes_short(h(f))));
        }
        for (k, f) in [
            ("cpu, time-weighted", "cpu_pct_avg"),
            ("memory, time-weighted", "mem_pct_avg"),
            ("swap, time-weighted", "swap_pct_avg"),
        ] {
            m.push_str(&format!("| {k} | {:.2}% |\n", h(f)));
        }
    }

    // ── fleet ──────────────────────────────────────────────────────────
    // Only in a fleet export; a single-machine file has no peers to table.
    if !fleet.is_empty() {
        m.push_str("\n## Fleet\n\n| peer | cpu | mem | swap | load | cores | psi cpu/io/mem |\n|---|---|---|---|---|---|---|\n");
        for (alias, v) in fleet {
            let g = |k: &str| num(v, k);
            m.push_str(&format!(
                "| {alias} | {:.1}% | {:.1}% | {:.1}% | {:.2} {:.2} {:.2} | {} | {:.2} / {:.2} / {:.2} |\n",
                g("cpu"), g("mem"), g("swap"),
                g("load1"), g("load5"), g("load15"),
                arr(v, "cores").len(),
                g("psi.cpu.some10"), g("psi.io.full10"), g("psi.memory.full10"),
            ));
        }
    }

    // ── declared units ─────────────────────────────────────────────────
    let svc = arr(s, "services");
    if !svc.is_empty() {
        let bad: Vec<&Value> = svc
            .iter()
            .filter(|u| {
                let a = text(u, "active");
                a == "failed" || a == "inactive" || a == "not-loaded"
            })
            .collect();
        m.push_str(&format!(
            "\n## Units\n\n{} declared, {} active. Not running:\n\n| unit | state | scope |\n|---|---|---|\n",
            svc.len(),
            svc.iter().filter(|u| text(u, "active") == "active").count()
        ));
        for u in bad.iter().take(60) {
            m.push_str(&format!(
                "| {} | {}/{} | {} |\n",
                text(u, "name"),
                text(u, "active"),
                text(u, "sub"),
                text(u, "scope")
            ));
        }
        if bad.len() > 60 {
            m.push_str(&format!("\n… and {} more not running\n", bad.len() - 60));
        }
    }

    // ── files ──────────────────────────────────────────────────────────
    if !files.is_empty() {
        m.push_str(&format!(
            "\n## Home\n\n{} entries, three levels deep.\n\n```\n",
            files.len()
        ));
        // Capped: a full tree in a report is a scroll, not a section. The
        // whole thing is in the JSON beside it.
        for l in files.iter().take(400) {
            m.push_str(l);
            m.push('\n');
        }
        if files.len() > 400 {
            m.push_str(&format!("… {} more lines, all of them in the JSON\n", files.len() - 400));
        }
        m.push_str("```\n");
    }

    // The Markdown caps its lists; the two machine-readable files do not, and
    // saying which is which here is cheaper than finding out later that the
    // table stopped at sixty units.
    m.push_str(&format!(
        "\n<sub>my-konsole-dash · the JSON and YAML beside this file are the same data \
         in full — this machine's snapshot, its file tree{}. \
         Declared units are the ones NOT running, the same set as above. \
         The YAML is the same content at roughly a third of the tokens.</sub>\n",
        if fleet.is_empty() { "" } else { " and every fleet peer" }
    ));
    fs::write(format!("{stem}.md"), m).map_err(|e| format!("{stem}.md: {e}"))?;

    Ok(stem)
}

/// A pid's name straight from /proc, for when it has dropped out of the
/// published table but the process itself is still there.
pub(crate) fn proc_comm(pid: i32) -> Option<String> {
    fs::read_to_string(format!("/proc/{pid}/status"))
        .ok()?
        .lines()
        .find(|l| l.starts_with("Name:"))
        .map(|l| l[5..].trim().to_string())
}

pub(crate) fn exe_dir(pid: i32) -> Option<String> {
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    Some(exe.parent()?.display().to_string())
}

/// Hand a directory to the desktop's file manager.
///
/// stdio is nulled deliberately: xdg-open's helpers write to stderr, and this
/// process owns an alternate screen — one stray line from a child repaints as
/// corruption the user has to redraw to clear.
pub(crate) fn open_dir(dir: &str) -> Result<(), String> {
    std::process::Command::new("xdg-open")
        .arg(dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

