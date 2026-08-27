pub mod mesh;
pub mod monitor;
pub mod stack;
pub mod journal;
pub mod cloud;
pub mod datasync;
pub mod agi;
pub mod devctl;

use std::time::Duration;

// Run a shell command, return stdout (trimmed). Empty on error.
pub fn sh(cmd: &str) -> String {
    std::process::Command::new("sh")
        .arg("-c").arg(cmd)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

// Same, but hard-killed after `secs` (for SSH/network probes — never wedges).
pub fn sh_timeout(secs: u64, cmd: &str) -> String {
    let _ = Duration::from_secs(secs);
    sh(&format!("timeout -s KILL {secs} sh -c {}", shell_quote(cmd)))
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
