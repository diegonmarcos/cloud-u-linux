// Mesh — the WireGuard peers, and reading another peer's watchdog snapshot.
//
// WHY NOT `wg show`
// The obvious source for peer state is wg(8), and it is unavailable: the
// interface is root-owned, so an unprivileged panel gets "Operation not
// permitted" for wg0 and wg-public alike. Running the dash as root to read a
// handshake timestamp is not a trade worth making.
//
// ~/.ssh/config is the better source anyway. It is already the declarative
// list of who is on the mesh, it is maintained because people ssh with it,
// and — unlike wg — it carries the one thing the remote-target feature needs:
// the alias to connect BY. So the peer table is derived from it, and liveness
// is measured directly with a TCP connect rather than inferred from a
// handshake counter we cannot read.
//
// Both the probe and the remote fetch run on their own threads. The render
// loop ticks at 1s and a peer that is merely down costs a full connect
// timeout, so doing either inline would stall the whole UI on exactly the
// case it exists to show.
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::io::Write as _;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

/// How long a peer gets to answer before it counts as down. Mesh RTTs here are
/// single-digit milliseconds; anything past this is not "slow", it is gone.
const PROBE_TIMEOUT: Duration = Duration::from_millis(900);
const PROBE_PORT: u16 = 22;
const PROBE_EVERY: Duration = Duration::from_secs(5);
/// The collector itself sleeps a second to get its cpu delta, and ssh costs a
/// round trip on top, so a 2s cadence would keep a connection to the peer open
/// essentially all the time for a panel nobody may be looking at.
const FETCH_EVERY: Duration = Duration::from_secs(4);
/// A full sweep is one ssh session per reachable peer, so it runs on a much
/// slower clock than the single-target fetch.
const FLEET_EVERY: Duration = Duration::from_secs(20);
const FLEET_PARALLEL: usize = 3;

#[derive(Clone, Debug, Default)]
pub struct Peer {
    pub alias: String,
    pub ip: String,
    /// This machine. It has no Host entry of its own — nobody ssh's to
    /// themselves — so it comes from the wg interfaces instead, and it is
    /// never probed: reaching yourself proves nothing.
    pub local: bool,
    pub up: bool,
    pub rtt_ms: f64,
    /// False until the first probe lands, so a fresh panel shows "…" rather
    /// than reporting every peer down before it has asked any of them.
    pub probed: bool,
}

/// Mesh peers from ~/.ssh/config, one row per ADDRESS rather than per Host.
///
/// The config lists several aliases per machine (`oci-apps`, its -dropbear
/// twin, its -pub and -v6 addresses). Keyed by address and keeping the
/// shortest alias, that collapses to one row per way in, which is what a peer
/// list should show — and the shortest alias is invariably the plain one, the
/// one that works for a normal ssh.
pub fn peers_from_ssh_config() -> Vec<Peer> {
    let Some(home) = std::env::var_os("HOME") else { return vec![] };
    let path = std::path::Path::new(&home).join(".ssh/config");
    let Ok(text) = std::fs::read_to_string(path) else { return vec![] };

    let mut by_ip: BTreeMap<String, String> = BTreeMap::new();
    let mut host: Option<String> = None;
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = strip_key(t, "Host") {
            host = rest.split_whitespace().next().map(|s| s.to_string());
        } else if let Some(rest) = strip_key(t, "HostName") {
            let Some(addr) = rest.split_whitespace().next() else { continue };
            if !is_mesh_addr(addr) {
                continue;
            }
            let Some(h) = host.clone() else { continue };
            by_ip
                .entry(addr.to_string())
                .and_modify(|cur| {
                    if h.len() < cur.len() {
                        *cur = h.clone();
                    }
                })
                .or_insert(h);
        }
    }
    let mine = local_wg_addrs();
    // Its real name, like every other row. "this machine" is a description,
    // and a peer table is a list of names — the one you would type after ssh.
    let me = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|h| h.trim().to_string())
        .unwrap_or_else(|_| "localhost".into());
    // ONE row for this machine, not one per wg interface: three rows all
    // reading "surface-nixos, 7.5% cpu" is the same machine three times, and
    // in the fleet view that is just noise. The mesh address (wg0) is the one
    // the fleet is addressed by.
    let mut out: Vec<Peer> = mine
        .first()
        .map(|ip| Peer {
            alias: me.clone(),
            ip: ip.clone(),
            local: true,
            up: true,
            probed: true,
            rtt_ms: 0.0,
        })
        .into_iter()
        .collect();
    out.extend(
        by_ip
            .into_iter()
            .filter(|(ip, _)| !mine.contains(ip))
            .map(|(ip, alias)| Peer { alias, ip, ..Default::default() }),
    );
    out
}

/// This machine's own mesh addresses, straight off the wg interfaces.
///
/// The peer table is otherwise built from ~/.ssh/config, and the one machine
/// guaranteed to be missing from an ssh config is the one you are sitting at.
/// Link-local (fe80::) is dropped: it is not a mesh address, it is how the
/// interface talks to itself.
fn local_wg_addrs() -> Vec<String> {
    let Ok(o) = Command::new("ip").args(["-o", "addr", "show"]).output() else { return vec![] };
    let Ok(t) = String::from_utf8(o.stdout) else { return vec![] };
    let mut v: Vec<String> = vec![];
    // wg0 first: local_wg_addrs's first entry becomes this machine's row.
    for line in t.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 4 || !f[1].starts_with("wg") {
            continue;
        }
        let addr = f[3].split('/').next().unwrap_or("");
        if is_mesh_addr(addr) && !v.iter().any(|x| x == addr) {
            v.push(addr.to_string());
        }
    }
    v
}

/// Case-insensitive `Key value` match. ssh_config keywords are not
/// case-sensitive and people really do write `hostname`.
fn strip_key<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let (k, rest) = line.trim().split_once(|c: char| c.is_whitespace() || c == '=')?;
    if k.eq_ignore_ascii_case(key) { Some(rest.trim()) } else { None }
}

/// Mesh addresses only — the private WireGuard ranges this fleet uses. A
/// HostName of `github.com` is a real ssh target and not a peer, and putting
/// it in the mesh box would be a lie about what the mesh is.
fn is_mesh_addr(a: &str) -> bool {
    a.starts_with("10.0.0.") || a.starts_with("10.1.0.") || a.starts_with("fd0c:")
}

/// One TCP connect, timed. Reachability that the kernel actually confirmed —
/// a SYN/ACK from the peer's sshd — rather than a config file's opinion.
fn probe(ip: &str) -> Option<f64> {
    let addr: IpAddr = ip.parse().ok()?;
    let sock = SocketAddr::new(addr, PROBE_PORT);
    let t0 = Instant::now();
    TcpStream::connect_timeout(&sock, PROBE_TIMEOUT).ok()?;
    Some(t0.elapsed().as_secs_f64() * 1000.0)
}

/// The collector, fed to the peer over ssh rather than installed on it. See
/// the script's own header for why the hub collects instead of the peer
/// publishing.
const COLLECT: &str = include_str!("collect.sh");

/// The port my-webserver listens on. One constant rather than a per-peer
/// setting: the fleet is deployed from one manifest, and a port that varies
/// per host is a lookup table nobody maintains.
const WEB_PORT: u16 = 8000;

/// Ask the peer's my-webserver for the snapshot my-watchdog published there.
///
/// This is the fast path, and it is fast for a structural reason: the machine
/// is ALREADY sampling itself every two seconds, so there is nothing to run —
/// the request is a file read on the far end. The ssh path has to open a
/// session, ship a hundred lines of shell, and then sit through a one-second
/// sleep, because a cpu percentage needs two samples and a machine visited
/// once has only one.
///
/// It also removes every portability question the collector had to answer:
/// BusyBox df, mawk versus gawk, whether docker stats returns at all. The
/// peer's own watchdog answered those locally, in Rust, before we asked.
fn fetch_http(ip: &str) -> Option<String> {
    let host = if ip.contains(':') { format!("[{ip}]") } else { ip.to_string() };
    let out = Command::new("curl")
        .args([
            "-sS",
            "--max-time",
            "4",
            "--fail",
            &format!("http://{host}:{WEB_PORT}/__api__/watchdog"),
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let body = String::from_utf8(out.stdout).ok()?;
    // A peer running my-webserver but not my-watchdog answers 503, which
    // --fail already rejects. This guards the other case: something else
    // listening on that port and answering 200 with something that is not a
    // snapshot.
    if body.contains("\"proc_table\"") { Some(body) } else { None }
}

/// One snapshot from `alias`. Returns (stdout, why-it-is-empty).
///
/// The script goes in on STDIN, not as an argument: it is 100 lines of shell
/// and awk containing every quoting character there is, and threading that
/// through `ssh <host> '<script>'` is a quoting problem with no good end.
fn fetch_remote(alias: &str) -> (String, String) {
    fetch_remote_at(alias, None)
}

/// `ip` offers the HTTP fast path. Without one this is the ssh path only,
/// which is what a bare alias can always do.
fn fetch_remote_at(alias: &str, ip: Option<&str>) -> (String, String) {
    if let Some(ip) = ip {
        if let Some(body) = fetch_http(ip) {
            return (body, String::new());
        }
    }
    let mut child = match Command::new("ssh")
        .args([
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            "-o", "StrictHostKeyChecking=accept-new",
            alias,
            "sh -s",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (String::new(), format!("ssh: {e}")),
    };
    if let Some(mut si) = child.stdin.take() {
        // A peer that hangs up early (no shell, denied) makes this fail; that
        // is not the error worth reporting, the exit status below is.
        let _ = si.write_all(COLLECT.as_bytes());
    }
    let out = match child.wait_with_output() {
        Ok(o) => o,
        Err(e) => return (String::new(), format!("ssh: {e}")),
    };
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    if stdout.trim().is_empty() {
        let e = String::from_utf8_lossy(&out.stderr);
        let first = e.lines().find(|l| !l.trim().is_empty()).unwrap_or("no output").trim();
        return (stdout, first.to_string());
    }
    (stdout, String::new())
}

/// Shared, cheap to clone, and the only thing the UI touches.
#[derive(Clone)]
pub struct Mesh {
    pub peers: Arc<Mutex<Vec<Peer>>>,
    /// None = measure this machine. Some(alias) = measure that peer.
    target: Arc<Mutex<Option<String>>>,
    /// The remote snapshot, plus whatever went wrong getting it. Null until
    /// the first fetch returns; the error is kept so a remote that cannot be
    /// read says why instead of just showing stale local numbers.
    remote: Arc<Mutex<(Value, String)>>,
    /// One result per reachable peer, for the fleet view: the snapshot, or
    /// the reason there is not one. A peer that FAILED to collect and a peer
    /// that has not been reached yet are different states and a row that
    /// showed them the same way would hide every broken peer behind
    /// "collecting…".
    fleet: Arc<Mutex<std::collections::HashMap<String, Result<Value, String>>>>,
    /// Set while the fleet view is on. The sweep is several ssh sessions and
    /// there is no reason to pay for it when nobody is looking at the result.
    want_fleet: Arc<Mutex<bool>>,
}

impl Mesh {
    /// Starts both workers. They run for the life of the process and are
    /// detached on purpose: there is nothing to join, and a panel that has to
    /// shut threads down cleanly on quit is machinery for no benefit.
    pub fn start() -> Mesh {
        let m = Mesh {
            peers: Arc::new(Mutex::new(peers_from_ssh_config())),
            target: Arc::new(Mutex::new(None)),
            remote: Arc::new(Mutex::new((Value::Null, String::new()))),
            fleet: Arc::new(Mutex::new(std::collections::HashMap::new())),
            want_fleet: Arc::new(Mutex::new(false)),
        };

        let peers = m.peers.clone();
        std::thread::spawn(move || loop {
            // Snapshot the list, probe outside the lock, write back. Holding
            // it across a 900ms connect would block every render.
            let list: Vec<Peer> = peers.lock().map(|p| p.clone()).unwrap_or_default();
            for mut p in list {
                if p.local {
                    continue;
                }
                let rtt = probe(&p.ip);
                p.up = rtt.is_some();
                p.rtt_ms = rtt.unwrap_or(0.0);
                p.probed = true;
                if let Ok(mut cur) = peers.lock() {
                    if let Some(slot) = cur.iter_mut().find(|x| x.ip == p.ip) {
                        *slot = p;
                    }
                }
            }
            std::thread::sleep(PROBE_EVERY);
        });

        let target = m.target.clone();
        let remote = m.remote.clone();
        let peers_for_target = m.peers.clone();
        std::thread::spawn(move || loop {
            let t = target.lock().ok().and_then(|x| x.clone());
            if let Some(alias) = t {
                // The single-target fetch knows the address too, so it takes
                // the same fast path.
                let ip = peers_for_target
                    .lock()
                    .ok()
                    .and_then(|p| p.iter().find(|x| x.alias == alias).map(|x| x.ip.clone()));
                let (out, why) = fetch_remote_at(&alias, ip.as_deref());
                let parsed: Value = serde_json::from_str(out.trim()).unwrap_or(Value::Null);
                let err = if parsed.is_null() {
                    format!("{alias}: {}", if why.is_empty() { "no data".into() } else { why })
                } else {
                    String::new()
                };
                if let Ok(mut slot) = remote.lock() {
                    *slot = (parsed, err);
                }
            }
            std::thread::sleep(FETCH_EVERY);
        });

        // The fleet sweep. Sequential on purpose: each collector sleeps a
        // second to get its cpu delta, and opening every peer at once to save
        // ten seconds would put a burst of ssh sessions on a mesh whose whole
        // job is carrying other traffic.
        let peers = m.peers.clone();
        let fleet = m.fleet.clone();
        let want = m.want_fleet.clone();
        std::thread::spawn(move || loop {
            if want.lock().map(|w| *w).unwrap_or(false) {
                let list: Vec<Peer> =
                    peers.lock().map(|p| p.clone()).unwrap_or_default();
                let todo: Vec<Peer> = list.into_iter().filter(|p| !p.local && p.up).collect();
                // A few at a time. Fully sequential meant the last peer waited
                // out every ssh handshake before it, which on a mesh with
                // 300ms round trips is most of a minute; all at once would put
                // a burst of sessions on a link whose job is carrying other
                // traffic.
                for chunk in todo.chunks(FLEET_PARALLEL) {
                    let hs: Vec<_> = chunk
                        .iter()
                        .map(|p| {
                            let alias = p.alias.clone();
                            let ip = p.ip.clone();
                            let fleet = fleet.clone();
                            std::thread::spawn(move || {
                                let (out, why) = fetch_remote_at(&alias, Some(&ip));
                                let r = match serde_json::from_str::<Value>(out.trim()) {
                                    Ok(v) => Ok(v),
                                    Err(_) if !why.is_empty() => Err(why),
                                    // Reached it, got something, could not
                                    // parse it. Show the first line: it is
                                    // almost always the shell saying why.
                                    Err(e) => Err(out
                                        .lines()
                                        .find(|l| !l.trim().is_empty())
                                        .map(|l| l.trim().to_string())
                                        .unwrap_or_else(|| e.to_string())),
                                };
                                if let Ok(mut f) = fleet.lock() {
                                    f.insert(alias, r);
                                }
                            })
                        })
                        .collect();
                    for h in hs {
                        let _ = h.join();
                    }
                }
            }
            std::thread::sleep(FLEET_EVERY);
        });

        m
    }

    pub fn set_fleet(&self, on: bool) {
        if let Ok(mut w) = self.want_fleet.lock() {
            *w = on;
        }
    }

    pub fn fleet(&self) -> std::collections::HashMap<String, Result<Value, String>> {
        self.fleet.lock().map(|f| f.clone()).unwrap_or_default()
    }

    pub fn target(&self) -> Option<String> {
        self.target.lock().ok().and_then(|t| t.clone())
    }

    /// Switching target clears the last remote snapshot, so the panel cannot
    /// spend a couple of seconds showing one machine's numbers under another
    /// machine's name.
    pub fn set_target(&self, alias: Option<String>) {
        if let Ok(mut t) = self.target.lock() {
            *t = alias;
        }
        if let Ok(mut r) = self.remote.lock() {
            *r = (Value::Null, "fetching…".into());
        }
    }

    pub fn remote_snapshot(&self) -> (Value, String) {
        self.remote.lock().map(|r| r.clone()).unwrap_or((Value::Null, String::new()))
    }

    pub fn list(&self) -> Vec<Peer> {
        self.peers.lock().map(|p| p.clone()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // One row per address with the shortest alias, and non-mesh HostNames
    // dropped entirely — the two rules the peer table depends on.
    #[test]
    fn ssh_config_collapses_aliases_and_ignores_non_mesh_hosts() {
        assert_eq!(strip_key("HostName 10.0.0.6", "HostName"), Some("10.0.0.6"));
        assert_eq!(strip_key("  hostname   10.0.0.6", "HostName"), Some("10.0.0.6"));
        assert_eq!(strip_key("Host oci-apps", "HostName"), None);
        assert!(is_mesh_addr("10.0.0.1"));
        assert!(is_mesh_addr("fd0c:1d01::9"));
        assert!(!is_mesh_addr("github.com"));
        assert!(!is_mesh_addr("192.168.47.219"));
    }
}
