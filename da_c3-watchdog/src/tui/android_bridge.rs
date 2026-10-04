//! `c3-watchdog-tui android-bridge` — the env side of the phone app.
//!
//! The phone app measures nothing. This loop, running in nix-on-droid, asks
//! the app which machine it wants, measures it (this env, or a mesh peer over
//! the ssh only this env can make), and pushes the envelope INTO the app with
//! explicit broadcasts — `am broadcast`, which any uid may send, and whose
//! result data comes straight back on stdout. No socket, no key, no ssh
//! client in the app.
//!
//!   am broadcast -a …WANTS -n <app>/<receiver>            → data="oci-apps"
//!   am broadcast -a …PUSH  --es alias A --es gz <b64> …    the envelope, gzip+base64
//!
//! Not a ContentProvider: Android's `content` tool needs a permission only
//! the shell uid holds. Broadcasts do not, so every step is a shell command
//! runnable by hand over ssh, and `…LOG` reads the app's own log the same way.
use std::io::Write;
use std::process::{Command, Stdio};
use std::time::Duration;

const APP: &str = "com.diegonmarcos.watchdog";
const RECEIVER: &str = "com.diegonmarcos.superapp.watchdog.BridgeReceiver";
const AM: &str = "/system/bin/am";
const TICK: Duration = Duration::from_secs(5);
/// Linux caps one argv string at 128 KiB; stay well under it.
const PART: usize = 100_000;

/// The Android runtime environment `am` (an app_process) needs and a proot
/// shell does not carry: read once off the proot launcher, which is this uid
/// and still holds it.
fn android_env() -> Vec<(String, String)> {
    let want = |k: &str| {
        k.starts_with("ANDROID_")
            || matches!(k, "BOOTCLASSPATH" | "DEX2OATBOOTCLASSPATH" | "SYSTEMSERVERCLASSPATH" | "EXTERNAL_STORAGE" | "ASEC_MOUNTPOINT")
    };
    let Ok(procs) = std::fs::read_dir("/proc") else { return vec![] };
    for p in procs.flatten() {
        let Ok(raw) = std::fs::read(p.path().join("environ")) else { continue };
        let env: Vec<(String, String)> = raw
            .split(|b| *b == 0)
            .filter_map(|kv| {
                let s = String::from_utf8_lossy(kv);
                let (k, v) = s.split_once('=')?;
                want(k).then(|| (k.to_string(), v.to_string()))
            })
            .collect();
        if env.iter().any(|(k, _)| k == "BOOTCLASSPATH") {
            return env;
        }
    }
    vec![]
}

/// One explicit broadcast; the receiver's result data, or why not.
fn am(env: &[(String, String)], action: &str, extras: &[(&str, &str, &str)]) -> Result<String, String> {
    let mut cmd = Command::new(AM);
    // `--user 0`: without it `am` targets "the current user" (-2), which an
    // app uid may not do — INTERACT_ACROSS_USERS — and the broadcast is refused.
    cmd.args(["broadcast", "--user", "0", "-a"]).arg(format!("{APP}.{action}")).arg("-n").arg(format!("{APP}/{RECEIVER}"));
    for (flag, k, v) in extras {
        cmd.arg(flag).arg(k).arg(v);
    }
    cmd.envs(env.iter().cloned());
    let path = std::env::var("PATH").unwrap_or_default();
    cmd.env("PATH", format!("{path}:/system/bin"));
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let out = cmd.output().map_err(|e| format!("{AM}: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let err = String::from_utf8_lossy(&out.stderr).to_string();
    let bad = |s: &str| s.contains("Error") || s.contains("Exception") || s.contains("does not exist");
    if !out.status.success() || bad(&text) || bad(&err) {
        return Err(format!("{} {}", text.trim(), err.trim()).trim().to_string());
    }
    // `Broadcast completed: result=-1, data="oci-apps"` — no data means no
    // receiver answered, which is "the app is not installed" in practice.
    let line = text.lines().find(|l| l.contains("Broadcast completed")).unwrap_or("");
    let data = line
        .split_once("data=\"")
        .map(|(_, d)| d.trim_end_matches('"').to_string())
        .ok_or_else(|| format!("no receiver answered ({})", line.trim()))?;
    Ok(data)
}

fn wanted(env: &[(String, String)]) -> Result<String, String> {
    let a = am(env, "WANTS", &[])?;
    Ok(if a.is_empty() || a == "denied" { "local".into() } else { a })
}

/// gzip + base64 through the env's own tools — both are in nix-on-droid and
/// neither is worth a crate in a binary that is mostly not on Android.
fn pack(json: &str) -> Result<String, String> {
    let mut child = Command::new("sh")
        .args(["-c", "gzip -c | base64 -w0"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("gzip|base64: {e}"))?;
    child.stdin.take().ok_or("no stdin")?.write_all(json.as_bytes()).map_err(|e| e.to_string())?;
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn push(env: &[(String, String)], alias: &str) -> Result<String, String> {
    let peer = if alias == "local" { None } else { Some(alias) };
    let json = super::monitor::envelope_json_for(peer)?;
    let b64 = pack(&json)?;
    let parts: Vec<&str> = b64.as_bytes().chunks(PART).map(|c| std::str::from_utf8(c).unwrap_or("")).collect();
    let id = format!(
        "{}",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
    );
    let n = parts.len().to_string();
    let mut last = String::new();
    for (i, p) in parts.iter().enumerate() {
        let idx = i.to_string();
        last = am(
            env,
            "PUSH",
            &[("--es", "alias", alias), ("--es", "id", &id), ("--ei", "part", &idx), ("--ei", "parts", &n), ("--es", "gz", p)],
        )?;
    }
    if !last.starts_with("ok") {
        return Err(format!("app said: {last}"));
    }
    Ok(format!("{} B json, {} B packed, {} part(s) — {last}", json.len(), b64.len(), parts.len()))
}

pub fn run() -> std::io::Result<()> {
    let env = android_env();
    if env.is_empty() {
        eprintln!("android-bridge: no Android runtime environment found in /proc — is this nix-on-droid?");
    }
    // The app's own drawer is built from the fleet in the LOCAL envelope, so
    // that one goes first and keeps going: a phone that only ever asked for a
    // peer still gets the machine list.
    let mut last_local = std::time::Instant::now() - Duration::from_secs(3600);
    let mut last_want = String::new();
    loop {
        let want = match wanted(&env) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("android-bridge: wants: {e}");
                std::thread::sleep(TICK);
                continue;
            }
        };
        if want != last_want {
            eprintln!("android-bridge: wants {want}");
            last_want = want.clone();
        }
        let mut todo = vec![want.clone()];
        if want != "local" && last_local.elapsed() > Duration::from_secs(60) {
            todo.push("local".into());
        }
        for a in todo {
            match push(&env, &a) {
                Ok(msg) => {
                    if a == "local" {
                        last_local = std::time::Instant::now();
                    }
                    eprintln!("android-bridge: pushed {a}: {msg}");
                }
                Err(e) => eprintln!("android-bridge: {a}: {e}"),
            }
        }
        std::thread::sleep(TICK);
    }
}
