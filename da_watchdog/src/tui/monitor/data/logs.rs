// The journal, read-only.
//
// Every section below is one journalctl invocation. Nothing here restarts,
// rotates or vacuums anything: this tab is a READER, and the moment it grows
// a verb it stops being safe to leave one keystroke away from the process
// list.

use std::sync::{Arc, Mutex};

/// One journal section: a name, why you would read it, and the journalctl
/// arguments that ARE it.
///
/// Data rather than a match arm, because "which sections exist" is a question
/// the fleet answers differently per machine and a match arm cannot be
/// extended without a rebuild of the thing that reads it.
pub(crate) struct Section {
    pub(crate) name: &'static str,
    pub(crate) desc: &'static str,
    /// Passed to journalctl verbatim. `--user` makes it the user manager's
    /// journal; everything else is the system one.
    pub(crate) args: &'static [&'static str],
}

pub(crate) const SECTIONS: &[Section] = &[
    Section { name: "kernel", desc: "ring buffer — hardware, OOM kills, filesystems", args: &["-k"] },
    Section { name: "system", desc: "the system manager and everything it started", args: &["_PID=1"] },
    Section { name: "user", desc: "this login's own services", args: &["--user"] },
    Section { name: "docker", desc: "the container daemon", args: &["-u", "docker.service"] },
    // EVERY network manager this fleet actually runs, because it runs more than
    // one: a desktop has NetworkManager and a server has systemd-networkd, and
    // filtering on the desktop's gave every VM an empty page. Repeated -u is
    // OR'd by journalctl, so naming all of them costs nothing on a box that
    // has only one.
    Section { name: "network", desc: "the network manager and the wireguard links", args: &["-u", "NetworkManager.service", "-u", "systemd-networkd.service", "-u", "systemd-resolved.service", "-u", "wg-quick@wg0.service"] },
    // BY IDENTIFIER, NOT BY UNIT. The unit is sshd.service on NixOS and
    // ssh.service on Debian and Ubuntu, so a unit filter is wrong on half this
    // fleet — oci-mail had 300 lines of sshd and showed an empty page. The
    // SYSLOG_IDENTIFIER is "sshd" on both, because it is the program's own
    // name rather than the distribution's opinion about it.
    Section { name: "ssh", desc: "who reached this box, and who was refused", args: &["-t", "sshd"] },
    // EVERY WATCHDOG ON THE BOX, not just this one's sampler.
    //
    // This read `--user -u my-watchdog.service`: the sampler's own user unit,
    // which logs almost nothing because its job is to publish a snapshot, not
    // to narrate. Meanwhile disk-watchdog wrote 2701 lines in a day declaring
    // a disk emergency every five minutes, and this tab said "No entries" —
    // the one page a person opens to ask "is something wrong?" was blind to
    // the only thing that was.
    //
    // A --user filter also cannot see them: the protection watchdogs are
    // SYSTEM units, so mixing the two scopes in one section would drop
    // whichever half came second. The system ones are named here and the
    // sampler is reached by its identifier instead, which works in either
    // manager's journal.
    //
    // RAW MATCHES JOINED BY `+`, and that is load-bearing.
    //
    // journalctl OR's repeated matches of the SAME field and AND's across
    // DIFFERENT ones, so `-t disk-emergency -u disk-watchdog-v2.service` asks
    // for lines that are both — 234 of them, where the identifier alone has
    // 2848 and the unit alone 5540. The intersection looks like a working
    // filter and quietly hides almost everything.
    //
    // `+` is the disjunction, but it only joins FIELD=VALUE matches: written
    // with -t/-u it silently returns nothing at all. So both halves are
    // spelled as raw fields, the way the `system` section above already does
    // with _PID=1.
    //
    // Identifier where the guard sets one (the alert tags are what a person
    // greps for), unit otherwise.
    Section {
        name: "watchdog",
        desc: "every guard on this box — disk, freeze, thermal, battery, sampler",
        args: &[
            "SYSLOG_IDENTIFIER=disk-emergency",
            "+", "SYSLOG_IDENTIFIER=disk-watchdog",
            "+", "SYSLOG_IDENTIFIER=freeze-guard",
            "+", "SYSLOG_IDENTIFIER=my-watchdog",
            "+", "_SYSTEMD_UNIT=disk-watchdog-v2.service",
            "+", "_SYSTEMD_UNIT=freeze-guard.service",
            "+", "_SYSTEMD_UNIT=freeze-guard-selfcheck.service",
            "+", "_SYSTEMD_UNIT=battery-watchdog.service",
            "+", "_SYSTEMD_UNIT=prochot-guard.service",
            "+", "_SYSTEMD_UNIT=journal-flood-guard.service",
        ],
    },
];

pub(crate) fn section(name: &str) -> Option<&'static Section> {
    SECTIONS.iter().find(|s| s.name == name)
}

/// Run a shell script here or on a peer.
///
/// `sh -s` with the script on STDIN and never as an argument, for the reason
/// tree.rs gives: several peers here log in to FISH, which rejects the
/// POSIX substitutions below outright. Naming the shell means the peer's
/// login shell never gets a vote on the syntax.
fn sh(script: &str, target: Option<&str>) -> String {
    use std::io::Write;
    let out = match target {
        Some(alias) => (|| {
            let mut ch = std::process::Command::new("ssh")
                .args([
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=4",
                    "-o", "StrictHostKeyChecking=accept-new",
                    alias,
                    "sh -s",
                ])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()?;
            let _ = ch.stdin.take().map(|mut w| w.write_all(script.as_bytes()));
            ch.wait_with_output()
        })(),
        None => std::process::Command::new("sh").arg("-c").arg(script).output(),
    };
    out.ok().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default()
}

/// Only the args, quoted. Nothing here comes from the user — SECTIONS is a
/// compile-time table — but the quoting stays because the day someone adds a
/// section with a space in a unit name is not the day to discover it.
fn argv(s: &Section) -> String {
    s.args.iter().map(|a| format!("'{a}' ")).collect()
}

/// The last N lines of one section.
fn read_section(name: &str, target: Option<&str>) -> Vec<String> {
    let Some(s) = section(name) else { return vec![] };
    // -n caps it: a journal with a million entries is not a view, it is a
    // hang, and the tail is the part anyone actually reads.
    let script = format!(
        "journalctl {}-n 500 --no-pager -o short-iso 2>&1",
        argv(s)
    );
    sh(&script, target).lines().map(|l| l.to_string()).collect()
}

/// How many alerts each section logged in the last 24h.
///
/// One round trip for all of them, not one per section: seven ssh handshakes
/// to count seven numbers is six too many.
///
/// -p 4 is warning-and-worse. "Alert" here means "something the machine chose
/// to complain about", which is the only definition available without a
/// per-service opinion about what its INFO lines mean.
fn read_counts(target: Option<&str>) -> Vec<(String, usize)> {
    let body: String = SECTIONS
        .iter()
        .map(|s| {
            format!(
                "printf '%s\\t%s\\n' '{}' \"$(journalctl {}-p 4 --since '24 hours ago' -q --no-pager 2>/dev/null | wc -l)\"; ",
                s.name,
                argv(s)
            )
        })
        .collect();
    sh(&body, target)
        .lines()
        .filter_map(|l| {
            let (n, c) = l.split_once('\t')?;
            Some((n.to_string(), c.trim().parse().ok()?))
        })
        .collect()
}

/// Every section's tail in ONE round trip, for the export.
///
/// The panel fetches one section at a time because a reader opens one; an
/// export carries all eight, and eight ssh handshakes to read eight tails is
/// seven too many. Same journalctl invocations as [`read_section`], joined by
/// a sentinel the peer's shell cannot produce by accident.
///
/// 200 rather than the panel's 500: this crosses a wire to a phone, and eight
/// sections at 500 lines is most of a megabyte of envelope to show a tail.
pub(crate) fn tail_all(target: Option<&str>) -> Vec<(String, Vec<String>)> {
    const MARK: &str = "@@wd-section@@";
    let body: String = SECTIONS
        .iter()
        .map(|s| {
            format!(
                "printf '{MARK}%s\\n' '{}'; journalctl {}-n 200 --no-pager -o short-iso 2>&1; ",
                s.name,
                argv(s)
            )
        })
        .collect();
    let out = sh(&body, target);
    let mut sections: Vec<(String, Vec<String>)> = vec![];
    for line in out.lines() {
        match line.strip_prefix(MARK) {
            Some(name) => sections.push((name.to_string(), vec![])),
            None => {
                if let Some(last) = sections.last_mut() {
                    last.1.push(line.to_string());
                }
            }
        }
    }
    sections
}

/// The 24h alert counts, read now rather than through the cache.
pub(crate) fn counts_now(target: Option<&str>) -> Vec<(String, usize)> {
    read_counts(target)
}

/// One section's lines plus the 24h counts, fetched off-thread.
///
/// Keyed exactly like TreeCache: journalctl over ssh takes seconds, and a
/// panel that blocks its own draw loop on it is a panel that looks frozen.
#[derive(Clone, Default)]
pub(crate) struct LogsCache {
    lines: Arc<Mutex<(String, Option<Vec<String>>)>>,
    counts: Arc<Mutex<(String, Option<Vec<(String, usize)>>)>>,
}

impl LogsCache {
    /// `(lines, loading)` for the current key.
    pub(crate) fn view(&self, key: &str) -> (Option<Vec<String>>, bool) {
        match self.lines.lock() {
            Ok(g) if g.0 == key => (g.1.clone(), g.1.is_none()),
            _ => (None, true),
        }
    }

    pub(crate) fn counts(&self, key: &str) -> Option<Vec<(String, usize)>> {
        match self.counts.lock() {
            Ok(g) if g.0 == key => g.1.clone(),
            _ => None,
        }
    }

    pub(crate) fn fetch(&self, key: String, name: &str, target: Option<&str>) {
        {
            let Ok(mut g) = self.lines.lock() else { return };
            if g.0 == key {
                return;
            }
            *g = (key.clone(), None);
        }
        let (out, name, target) = (self.lines.clone(), name.to_string(), target.map(str::to_string));
        std::thread::spawn(move || {
            let v = read_section(&name, target.as_deref());
            if let Ok(mut g) = out.lock() {
                if g.0 == key {
                    g.1 = Some(v);
                }
            }
        });
    }

    pub(crate) fn fetch_counts(&self, key: String, target: Option<&str>) {
        {
            let Ok(mut g) = self.counts.lock() else { return };
            if g.0 == key {
                return;
            }
            *g = (key.clone(), None);
        }
        let (out, target) = (self.counts.clone(), target.map(str::to_string));
        std::thread::spawn(move || {
            let v = read_counts(target.as_deref());
            if let Ok(mut g) = out.lock() {
                if g.0 == key {
                    g.1 = Some(v);
                }
            }
        });
    }
}
