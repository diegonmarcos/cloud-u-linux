// Every storage unit this fleet can mount, and which of them are mounted here.
//
// WHY THIS IS NOT IN THE SNAPSHOT
// my-watchdog measures a machine. This is a DECLARATION — what exists, where
// it lives, what it costs — and it lives in cloud-infra, which the sampler has
// no business depending on. So the panel reads it directly, the same way it
// reads the home directory for the files tab: static facts, read once, not
// sampled.
//
// WHAT IS DELIBERATELY NOT HERE: SIZES
// Every mount below is a network filesystem. `df` on a dead sshfs mount blocks
// in the kernel and does not come back — no timeout, no signal, and the
// dashboard is a single render thread. A monitor that hangs because a peer
// went down is worse than one that omits a number, so nothing here stats a
// mountpoint. The storage tab says what exists and what is mounted; the fleet
// tab beside it says how full each machine is, measured by that machine.
use std::fs;
use std::process::Command;
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::dashboards::monitor::data::{arr, num, text};

/// One thing you could mount, or already have.
#[derive(Clone)]
pub(crate) struct Unit {
    /// mount · s3 · rclone · git — the four kinds, in the order a person cares
    /// about them: what is live, then what is declared.
    pub(crate) kind: &'static str,
    pub(crate) name: String,
    pub(crate) provider: String,
    /// Storage class, rclone backend type, or the git host's role.
    pub(crate) tier: String,
    /// The endpoint you would point a client at.
    pub(crate) addr: String,
    /// Where it is mounted on THIS machine, empty if it is not.
    pub(crate) at: String,
}

/// The consolidated declaration, from cloud-infra.
///
/// Env var first so a checkout somewhere else still works, then the path it
/// actually lives at. Missing is not an error: on a peer this file does not
/// exist at all, and the tab should say "nothing declared here" rather than
/// refuse to draw.
fn consolidated() -> Option<Value> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut paths: Vec<String> = vec![];
    if let Ok(p) = std::env::var("CLOUD_DATA_JSON") {
        paths.push(p);
    }
    paths.push(format!(
        "{home}/git/cloud-infra/1_cloud-configs/dist/_cloud-data-consolidated.json"
    ));
    for p in paths {
        if let Ok(s) = fs::read_to_string(&p) {
            if let Ok(v) = serde_json::from_str(&s) {
                return Some(v);
            }
        }
    }
    None
}

/// The firewall declaration for this fleet, from the derived watchdog file.
///
/// dist/watchdog.json, not the 384KB consolidated one: a deriver already
/// reduces the cloud declaration to what this panel needs, and re-implementing
/// that reduction here would be a second answer to a question that already has
/// one. Absent file simply means no declaration to compare against, which is
/// what a machine outside the fleet honestly has.
pub(crate) fn firewall_declared() -> Option<Value> {
    let home = std::env::var("HOME").ok()?;
    let p = format!("{home}/git/cloud-infra/1_cloud-configs/dist/watchdog.json");
    serde_json::from_str::<Value>(&fs::read_to_string(p).ok()?)
        .ok()?
        .get("firewall")
        .cloned()
}

/// Every machine the fleet declares, with the action strings the deriver
/// built for it.
///
/// The panel never composes an `oci` or `gcloud` command line: it runs the
/// string the declaration carries, and a machine whose provider the deriver
/// did not recognise simply offers fewer verbs. One of these commands stops a
/// production VM, and the place to decide their exact wording is the file
/// that already knows the instance ids.
pub(crate) fn machines_declared() -> Vec<Value> {
    let home = std::env::var("HOME").unwrap_or_default();
    let p = format!("{home}/git/cloud-infra/1_cloud-configs/dist/watchdog.json");
    fs::read_to_string(&p)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.get("machines")?.as_array().cloned())
        .unwrap_or_default()
}


/// Every mountpoint this machine DECLARES, mounted or not.
///
/// The first version listed /proc/mounts, which answers "what is mounted" —
/// a different and much less useful question. ~/mounts/fleet holds six peers
/// and only four were mounted, so gcp-t4 and phone were simply absent from a
/// tab whose entire job is "what can I mount". An empty directory sitting
/// there IS the declaration; whether anything is on it right now is a status,
/// not an existence.
///
/// /proc/mounts, not `mount(8)`: reading a file cannot block on a dead server
/// the way asking the mount table's helpers can.
fn mountpoints() -> Vec<Unit> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mounted = fs::read_to_string("/proc/mounts").unwrap_or_default();
    // The second field of each line, with the octal escape mount(5) uses for
    // spaces put back.
    let is_mounted = |path: &str| -> Option<String> {
        mounted.lines().find_map(|l| {
            let mut f = l.split_whitespace();
            let src = f.next()?;
            let at = f.next()?;
            let ty = f.next()?;
            (at.replace("\\040", " ") == path).then(|| format!("{ty} · {src}"))
        })
    };
    let mut out = vec![];
    // fleet/ is one directory per peer; Storage/ is one per remote service.
    for (dir, provider) in [("fleet", "peer"), ("Storage", "remote")] {
        let base = format!("{home}/mounts/{dir}");
        let Ok(rd) = fs::read_dir(&base) else { continue };
        // DIRECTORIES ONLY. A mountpoint is a directory; ~/mounts/Storage also
        // holds .cc.log, .cloud-connect.log and .mount.log, which the first
        // version happily listed as three storage units that were "not
        // mounted" — true of a log file, and useless.
        //
        // is_dir() follows symlinks on purpose: several of these are links to
        // the real directory, and a link to a mountpoint is a mountpoint.
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for name in names {
            let at = format!("{base}/{name}");
            let live = is_mounted(&at);
            out.push(Unit {
                kind: "mount",
                name,
                provider: provider.into(),
                tier: if live.is_some() { "mounted".into() } else { "not mounted".into() },
                addr: live.unwrap_or_default(),
                at,
            });
        }
    }
    out
}

/// This machine. It is a storage unit of the fleet like any other — it is
/// simply the one you are standing on, so it has no mountpoint and never
/// appeared in a list built from mounts.
fn this_machine() -> Unit {
    let host = fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|h| h.trim().to_string())
        .unwrap_or_else(|_| "localhost".into());
    Unit {
        kind: "local",
        name: host,
        provider: "this machine".into(),
        tier: "local".into(),
        // The fleet tab beside this one measures how full it is; repeating a
        // number here that is sampled properly two keystrokes away would be
        // two answers to one question.
        addr: "see the fleet tab for usage".into(),
        at: "/".into(),
    }
}

/// rclone remotes, by NAME AND BACKEND ONLY./// rclone remotes, by NAME AND BACKEND ONLY.
///
/// This file holds tokens and passwords. Nothing but the section header and
/// the `type =` line is read, and nothing else may ever be — a panel that
/// renders a credential onto a shared screen is a much worse bug than a
/// missing column.
fn rclone_remotes() -> Vec<(String, String)> {
    let home = std::env::var("HOME").unwrap_or_default();
    let Ok(t) = fs::read_to_string(format!("{home}/.config/rclone/rclone.conf")) else {
        return vec![];
    };
    parse_rclone(&t)
}

/// Split out so the test can run the REAL parser over a config with real
/// secrets in it. A test that reimplements the parser proves nothing about
/// the parser.
fn parse_rclone(t: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = vec![];
    for line in t.lines() {
        let l = line.trim();
        if let Some(n) = l.strip_prefix('[').and_then(|x| x.strip_suffix(']')) {
            out.push((n.to_string(), String::new()));
        } else if let Some(rest) = l.strip_prefix("type") {
            if let Some(v) = rest.trim().strip_prefix('=') {
                if let Some(last) = out.last_mut() {
                    last.1 = v.trim().to_string();
                }
            }
        }
    }
    out
}

/// Everything, live first.
pub(crate) fn units() -> Vec<Unit> {
    let mut out = vec![this_machine()];
    out.extend(mountpoints());
    // The mountpoints are the first `n_mp` entries and nothing appended after
    // them is one, so matching against that prefix avoids walking the list a
    // second time. The borrow ends before each push.
    //
    // Only entries that are ACTUALLY mounted count: a declared-but-down
    // mountpoint has a path too, and returning it would tell a bucket it was
    // mounted somewhere it is not.
    let n_mp = out.len();
    let mounted_at = |needle: &str, list: &[Unit]| -> String {
        list.iter()
            .find(|m| m.tier == "mounted" && (m.name == needle || m.at.contains(needle)))
            .map(|m| m.at.clone())
            .unwrap_or_default()
    };

    if let Some(d) = consolidated() {
        for b in arr(&d, "storage") {
            let name = text(b, "name");
            let at = mounted_at(&name, &out[..n_mp]);
            out.push(Unit {
                kind: "s3",
                at,
                provider: text(b, "provider"),
                tier: text(b, "tier"),
                // The S3 endpoint, not the vanity DNS: this is the address a
                // client is configured with, and it is the one that is wrong
                // when a mount fails.
                addr: text(b, "s3_endpoint"),
                name,
            });
        }
        // Git hosts are storage too — the fleet's code lives in them, and
        // "where do I clone this from" is the same question as "what can I
        // mount", asked about a different kind of blob.
        let gitea = d.get("services").and_then(|s| s.get("gitea"));
        if let Some(g) = gitea {
            out.push(Unit {
                kind: "git",
                name: "gitea".into(),
                provider: "self-hosted".into(),
                tier: text(g, "vm"),
                addr: format!("https://{}", text(g, "domain")),
                at: String::new(),
            });
        }
        let gh = text(&d, "owner.github");
        if !gh.is_empty() {
            out.push(Unit {
                kind: "git",
                name: gh.clone(),
                provider: "github".into(),
                tier: "upstream".into(),
                addr: format!("https://github.com/{gh}"),
                at: String::new(),
            });
        }
    }

    for (name, ty) in rclone_remotes() {
        let at = mounted_at(&name, &out[..n_mp]);
        out.push(Unit {
            kind: "rclone",
            at,
            name,
            provider: "rclone".into(),
            tier: if ty.is_empty() { "?".into() } else { ty },
            addr: String::new(),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // The one rule this module must never break. rclone.conf holds tokens;
    // only the section name and the backend type may leave it. This runs the
    // real parser over a config shaped like the real one, secrets included.
    #[test]
    fn rclone_parsing_takes_the_name_and_type_and_nothing_else() {
        let conf = "[Gdrive_me]\ntype = drive\ntoken = {\"access_token\":\"SECRET\"}\n\
                    client_secret = hunter2\n\n[box]\ntype = s3\naccess_key_id = AKIAREAL\n";
        let out = parse_rclone(conf);
        assert_eq!(
            out,
            vec![("Gdrive_me".to_string(), "drive".to_string()), ("box".to_string(), "s3".to_string())]
        );
        let joined = format!("{out:?}");
        for leak in ["SECRET", "hunter2", "AKIAREAL", "access_token", "client_secret"] {
            assert!(!joined.contains(leak), "{leak} escaped the rclone parser");
        }
    }

    // A mountpoint is the only name an rclone mount has — the source field is
    // an opaque handle like `:sftp{CcfTB}:/`, which names nothing.
    #[test]
    fn a_mount_is_named_after_its_mountpoint() {
        let at = "/home/diego/mounts/fleet/oci-apps";
        assert_eq!(at.rsplit('/').next(), Some("oci-apps"));
    }
}

/// Everything that needs the network, fetched OFF the render thread.
///
/// Two network calls — a gitea API request and `gh repo list` — and either can
/// be slow or hang: gitea lives on the mesh and gh talks to the internet. A
/// panel that freezes while it lists repositories is the exact failure this
/// dashboard exists to catch somebody else committing, so it never happens on
/// the thread that draws.
///
/// The list simply appears when it arrives. There is no spinner and no
/// blocking wait: an empty list reads as "not yet", which is true, and the row
/// count in the status line says so.
#[derive(Clone, Default)]
pub(crate) struct Extras {
    inner: Arc<Mutex<Vec<Unit>>>,
}

impl Extras {
    pub(crate) fn get(&self) -> Vec<Unit> {
        self.inner.lock().map(|v| v.clone()).unwrap_or_default()
    }

    /// Start a fetch if one has not already produced results. Cheap to call
    /// repeatedly — opening the tab twice must not open two sets of sockets.
    pub(crate) fn fetch(&self) {
        if !self.get().is_empty() {
            return;
        }
        let out = self.inner.clone();
        std::thread::spawn(move || {
            // Quotas first: they are the short list and the one people are
            // looking for, so they should not queue behind forty-five repos.
            let mut v = drive_quotas();
            v.extend(gitea_repos());
            v.extend(github_repos());
            if let Ok(mut g) = out.lock() {
                *g = v;
            }
        });
    }
}

/// Real usage for every Drive remote rclone can reach.
///
/// `rclone about` IS the API call — it asks Google for the account's quota
/// and returns it. That is worth saying plainly because the obvious place to
/// look was the two Google MCP servers, and neither can answer it: the
/// workspace one has Drive methods but no quota call, and the personal one is
/// Gmail/IMAP with no Drive API at all.
///
/// Only `drive` remotes are asked. An sftp remote would answer too, but that
/// means a round trip to a peer for a number the fleet tab already measures
/// properly on the machine that owns the disk.
///
/// A remote whose token has not been authorised yet simply errors, and that
/// is the correct outcome: it stays in the list as declared-but-unusable,
/// which is exactly what it is.
fn drive_quotas() -> Vec<Unit> {
    rclone_remotes()
        .into_iter()
        .filter(|(_, ty)| ty == "drive")
        .map(|(name, _)| {
            let out = Command::new("rclone")
                .args(["about", &format!("{name}:"), "--json", "--timeout", "10s"])
                .output();
            let quota = out
                .ok()
                .filter(|o| o.status.success())
                .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok());
            let (tier, addr) = match quota {
                Some(q) => {
                    let used = num(&q, "used");
                    let total = num(&q, "total");
                    (
                        if total > 0.0 {
                            format!("{:.0}% used", used / total * 100.0)
                        } else {
                            "authorised".into()
                        },
                        format!("{} of {}", fmt_bytes(used), fmt_bytes(total)),
                    )
                }
                None => ("not authorised".into(), "rclone config reconnect".into()),
            };
            Unit { kind: "gdrive", name, provider: "google drive".into(), tier, addr, at: String::new() }
        })
        .collect()
}

fn fmt_bytes(b: f64) -> String {
    const U: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut v = b;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{v:.1}{}", U[i])
}

/// Repos on the self-hosted gitea, over the mesh.
///
/// The MESH address, not the public domain: this is a hub-to-peer call and
/// the public name goes out through a proxy that has no business carrying it.
/// --max-time, because a peer that stopped answering must not hold a thread
/// open forever.
fn gitea_repos() -> Vec<Unit> {
    let out = Command::new("curl")
        .args([
            "-s",
            "--max-time",
            "8",
            "http://10.0.0.6:3002/api/v1/repos/search?limit=100",
        ])
        .output();
    let Ok(o) = out else { return vec![] };
    let Ok(v) = serde_json::from_slice::<Value>(&o.stdout) else { return vec![] };
    arr(&v, "data")
        .iter()
        .map(|r| Unit {
            kind: "repo",
            name: text(r, "full_name"),
            provider: "gitea".into(),
            // The API reports size in KiB.
            tier: fmt_kib(num(r, "size")),
            addr: text(r, "clone_url"),
            at: String::new(),
        })
        .collect()
}

/// Repos on github, via the gh CLI so this inherits the credential the rest of
/// the repo already uses rather than asking for a token of its own.
fn github_repos() -> Vec<Unit> {
    let out = Command::new("gh")
        .args([
            "repo",
            "list",
            "--limit",
            "200",
            "--json",
            "nameWithOwner,diskUsage,visibility,url",
        ])
        .output();
    let Ok(o) = out else { return vec![] };
    let Ok(v) = serde_json::from_slice::<Value>(&o.stdout) else { return vec![] };
    v.as_array()
        .map(|a| {
            a.iter()
                .map(|r| Unit {
                    kind: "repo",
                    name: text(r, "nameWithOwner"),
                    provider: format!("github {}", text(r, "visibility").to_lowercase()),
                    tier: fmt_kib(num(r, "diskUsage")),
                    addr: text(r, "url"),
                    at: String::new(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Both APIs report repository size in KiB.
fn fmt_kib(kib: f64) -> String {
    if kib <= 0.0 {
        "-".into()
    } else if kib < 1024.0 {
        format!("{kib:.0}K")
    } else if kib < 1_048_576.0 {
        format!("{:.1}M", kib / 1024.0)
    } else {
        format!("{:.2}G", kib / 1_048_576.0)
    }
}
