//! `my-watchdog-tui android-bridge` — the env side of the phone app.
//!
//! The phone app measures nothing. This loop, running in nix-on-droid, asks
//! the app which machine it wants, measures it (this env, or a mesh peer over
//! the ssh only this env can make), and pushes the envelope INTO the app
//! through Android's own `content` tool — a ContentProvider the app exports
//! for this uid alone. No socket, no key, no ssh client in the app.
//!
//!   content query --uri content://…/wants           what the user picked
//!   content write --uri content://…/snapshot/<a>    the envelope, on stdin
//!
//! Every step is a shell command, so the whole chain can be exercised by
//! hand over ssh and read back with `content query …/log`.
use std::io::Write;
use std::process::{Command, Stdio};
use std::time::Duration;

const AUTHORITY: &str = "com.diegonmarcos.watchdog.bridge";
const CONTENT: &str = "/system/bin/content";
const TICK: Duration = Duration::from_secs(5);

/// The Android runtime environment `content` (an app_process) needs and a
/// proot shell does not carry: read once off the proot launcher, which is
/// this uid and still holds it.
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

fn content(env: &[(String, String)], args: &[&str], stdin: Option<&[u8]>) -> Result<String, String> {
    let mut cmd = Command::new(CONTENT);
    cmd.args(args).envs(env.iter().cloned());
    let path = std::env::var("PATH").unwrap_or_default();
    cmd.env("PATH", format!("{path}:/system/bin"));
    cmd.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() });
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("{CONTENT}: {e}"))?;
    if let Some(body) = stdin {
        let mut w = child.stdin.take().ok_or("no stdin")?;
        w.write_all(body).map_err(|e| e.to_string())?;
        drop(w);
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    if !out.status.success() || text.contains("Error") || text.contains("Exception") {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("{} {}", text.trim(), err.trim()).trim().to_string());
    }
    Ok(text)
}

fn uri(path: &str) -> String {
    format!("content://{AUTHORITY}/{path}")
}

/// `Row: 0 alias=oci-apps` → `oci-apps`
fn wanted(env: &[(String, String)]) -> Result<String, String> {
    let out = content(env, &["query", "--uri", &uri("wants")], None)?;
    let a = out
        .lines()
        .find_map(|l| l.split_once("alias=").map(|(_, v)| v.trim().to_string()))
        .unwrap_or_default();
    Ok(if a.is_empty() || a == "NULL" { "local".into() } else { a })
}

fn push(env: &[(String, String)], alias: &str) -> Result<usize, String> {
    let peer = if alias == "local" { None } else { Some(alias) };
    let json = super::monitor::envelope_json_for(peer)?;
    content(env, &["write", "--uri", &uri(&format!("snapshot/{alias}"))], Some(json.as_bytes()))?;
    Ok(json.len())
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
                Ok(n) => {
                    if a == "local" {
                        last_local = std::time::Instant::now();
                    }
                    eprintln!("android-bridge: pushed {a} ({n} B)");
                }
                Err(e) => eprintln!("android-bridge: {a}: {e}"),
            }
        }
        std::thread::sleep(TICK);
    }
}
