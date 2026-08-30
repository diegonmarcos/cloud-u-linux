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
    Section { name: "network", desc: "NetworkManager and the wireguard links", args: &["-u", "NetworkManager.service", "-u", "wg-quick@wg0.service"] },
    Section { name: "ssh", desc: "who reached this box, and who was refused", args: &["-u", "sshd.service"] },
    Section { name: "watchdog", desc: "the sampler's own journal", args: &["--user", "-u", "my-watchdog.service"] },
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
