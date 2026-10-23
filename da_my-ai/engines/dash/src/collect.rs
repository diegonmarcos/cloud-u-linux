//! NETWORK/CMD probes — fired only on Refresh, each independent + hard-timeout'd.
//! Port of the collectors()/httpTimed/sh/ping/imageArches section.
use my_ai_core::Endpoints;
use serde_json::Value;
use std::process::Command;
use std::time::{Duration, Instant};

#[derive(Clone)]
pub enum Slot {
    NotProbed,
    Pending,
    Timeout,
    Stdio,
    Up { ms: u64, body: Option<Value> },
    Down { ms: u64 },
    Cmd(String),
    Image(Vec<String>),
}

pub enum Probe {
    Http { url: String, sub: String, any_status: bool, want_body: bool },
    Ping { ip: String },
    Df,
    Git { path: String },
    Image { image: String },
}

pub const REPOS: [&str; 5] = ["cloud", "unix", "front", "vault", "tools"];

/// Root of the Headroom compress service (dashboard URL minus /dashboard).
pub fn compress_root(ep: &Endpoints) -> String {
    ep.dashboard.trim_end_matches("/dashboard").to_string()
}

pub fn collectors(ep: &Endpoints, mcps: &[crate::offline::Mcp]) -> Vec<(String, Probe)> {
    let compress = compress_root(ep);
    let home = my_ai_core::home();
    let mut c: Vec<(String, Probe)> = vec![
        ("proxy".into(), Probe::Http { url: ep.proxy.clone(), sub: "/readyz".into(), any_status: false, want_body: false }),
        ("api".into(), Probe::Http { url: ep.api.clone(), sub: "/health".into(), any_status: false, want_body: true }),
        ("ollama".into(), Probe::Http { url: ep.ollama.clone(), sub: "/api/version".into(), any_status: false, want_body: false }),
        ("compress".into(), Probe::Http { url: compress.clone(), sub: "/readyz".into(), any_status: false, want_body: false }),
        ("direct".into(), Probe::Http { url: ep.anthropic.clone(), sub: "/v1/models".into(), any_status: true, want_body: false }),
        ("health".into(), Probe::Http { url: ep.api.clone(), sub: "/health".into(), any_status: false, want_body: true }),
        ("tokens".into(), Probe::Http { url: compress.clone(), sub: "/stats".into(), any_status: false, want_body: true }),
        ("server".into(), Probe::Http { url: ep.api.clone(), sub: "/sessions".into(), any_status: false, want_body: true }),
        ("image".into(), Probe::Image { image: ep.image.clone() }),
        ("hostdisk".into(), Probe::Df),
    ];
    for (n, ip) in &ep.mesh {
        c.push((format!("mesh:{n}"), Probe::Ping { ip: ip.clone() }));
    }
    for (n, ip) in &ep.public {
        c.push((format!("pub:{n}"), Probe::Ping { ip: ip.clone() }));
    }
    for m in mcps {
        if m.kind == "http" {
            if let Some(u) = &m.url {
                c.push((format!("mcp:{}", m.name), Probe::Http { url: u.clone(), sub: "".into(), any_status: true, want_body: false }));
            }
        }
    }
    for rp in REPOS {
        c.push((format!("repo:{rp}"), Probe::Git { path: home.join("git").join(rp).to_string_lossy().into_owned() }));
    }
    c
}

pub fn run(p: &Probe) -> Slot {
    match p {
        Probe::Http { url, sub, any_status, want_body } => http(url, sub, *any_status, *want_body),
        Probe::Ping { ip } => ping(ip),
        Probe::Df => {
            let home = my_ai_core::home();
            let home_s = home.to_string_lossy();
            cmd("df", &["-h", home_s.as_ref(), "/mnt/shared-lib"])
        }
        Probe::Git { path } => cmd("git", &["-C", path, "status", "--porcelain=v1", "-b"]),
        Probe::Image { image } => image_arches(image),
    }
}

fn http(url: &str, sub: &str, any_status: bool, want_body: bool) -> Slot {
    let full = format!("{}{}", url.trim_end_matches('/'), sub);
    let t0 = Instant::now();
    let req = ureq::get(&full).timeout(Duration::from_millis(1800));
    match req.call() {
        Ok(r) => {
            let ms = t0.elapsed().as_millis() as u64;
            let body = if want_body { r.into_json::<Value>().ok() } else { None };
            Slot::Up { ms, body }
        }
        Err(ureq::Error::Status(_code, _r)) => {
            let ms = t0.elapsed().as_millis() as u64;
            if any_status {
                Slot::Up { ms, body: None }
            } else {
                Slot::Down { ms }
            }
        }
        Err(_) => Slot::Timeout,
    }
}

fn ping(ip: &str) -> Slot {
    match cmd_raw("ping", &["-c", "1", "-W", "1", ip], 2000) {
        Some(out) => {
            // parse "time=12.3 ms" / "time<1 ms"
            if let Some(idx) = out.find("time") {
                let tail = &out[idx + 4..];
                let num: String = tail
                    .trim_start_matches(['=', '<'])
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || *c == '.')
                    .collect();
                if let Ok(ms) = num.parse::<f64>() {
                    return Slot::Up { ms: ms.round() as u64, body: None };
                }
            }
            Slot::Timeout
        }
        None => Slot::Timeout,
    }
}

fn cmd(bin: &str, args: &[&str]) -> Slot {
    match cmd_raw(bin, args, 2500) {
        Some(out) => Slot::Cmd(out),
        None => Slot::Timeout,
    }
}

fn cmd_raw(bin: &str, args: &[&str], _timeout_ms: u64) -> Option<String> {
    // ponytail: relies on the tool's own -W/-c bounds for a hard cap; a wall-clock
    // kill would need a watchdog thread — the probes here are already bounded.
    let out = Command::new(bin).args(args).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn image_arches(image: &str) -> Slot {
    let repo = image.trim_start_matches("ghcr.io/");
    let tok_url = format!("https://ghcr.io/token?scope=repository:{repo}:pull");
    let token: Option<String> = ureq::get(&tok_url)
        .timeout(Duration::from_millis(2000))
        .call()
        .ok()
        .and_then(|r| r.into_json::<Value>().ok())
        .and_then(|j| j.get("token").and_then(|t| t.as_str()).map(|s| s.to_string()));
    let token = match token {
        Some(t) => t,
        None => return Slot::Timeout,
    };
    let acc = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json";
    let m = ureq::get(&format!("https://ghcr.io/v2/{repo}/manifests/latest"))
        .set("Authorization", &format!("Bearer {token}"))
        .set("Accept", acc)
        .timeout(Duration::from_millis(2200))
        .call()
        .ok()
        .and_then(|r| r.into_json::<Value>().ok());
    match m {
        Some(j) => {
            if let Some(manifests) = j.get("manifests").and_then(|v| v.as_array()) {
                let arches: Vec<String> = manifests
                    .iter()
                    .filter_map(|x| x.get("platform").and_then(|p| p.get("architecture")).and_then(|a| a.as_str()).map(|s| s.to_string()))
                    .collect();
                Slot::Image(arches)
            } else {
                let a = j.get("architecture").and_then(|v| v.as_str()).unwrap_or("single").to_string();
                Slot::Image(vec![a])
            }
        }
        None => Slot::Timeout,
    }
}

// helpers used by render for command-output parsing
pub struct DfRow {
    pub pct: String,
    pub used: String,
    pub size: String,
    pub avail: String,
    pub mount: String,
}
pub fn parse_df(out: &str) -> Vec<DfRow> {
    out.lines()
        .skip(1)
        .filter_map(|l| {
            let p: Vec<&str> = l.split_whitespace().collect();
            if p.len() < 6 {
                return None;
            }
            Some(DfRow {
                size: p[1].into(),
                used: p[2].into(),
                avail: p[3].into(),
                pct: p[4].into(),
                mount: p[5].into(),
            })
        })
        .collect()
}

pub struct RepoState {
    pub br: String,
    pub ahead: i64,
    pub behind: i64,
    pub dirty: usize,
}
pub fn parse_repo(out: &str) -> RepoState {
    let mut lines = out.lines();
    let head = lines.next().unwrap_or("");
    let grab = |marker: &str| -> Option<String> {
        head.find(marker).map(|i| {
            head[i + marker.len()..].chars().take_while(|c| c.is_ascii_digit()).collect()
        })
    };
    // branch: after "## " up to '.' or space
    let br = head
        .strip_prefix("## ")
        .map(|s| s.split(['.', ' ']).next().unwrap_or("?").to_string())
        .unwrap_or_else(|| "?".into());
    let ahead = grab("ahead ").and_then(|s| s.parse().ok()).unwrap_or(0);
    let behind = grab("behind ").and_then(|s| s.parse().ok()).unwrap_or(0);
    let dirty = out.lines().skip(1).filter(|l| !l.is_empty()).count();
    RepoState { br, ahead, behind, dirty }
}
