// Where the numbers come from. Knows nothing about drawing.
pub(crate) mod logs;
pub(crate) mod parse;
pub(crate) mod sort;
pub(crate) mod storage;
pub(crate) mod tree;

// Snapshot access — one dotted-path reader instead of a mirrored schema.
//
// The daemon's JSON is broad and grows; mirroring it as structs would mean a
// compile break every time a field is added, and a panel that fails to build
// because a publisher gained a key is worse than one showing a blank cell.
use std::fs;

use serde_json::Value;

pub(crate) const HIST: usize = 480; // enough samples for a very wide braille graph (2/col)

// ─────────────────────────────── snapshot access ───────────────────────────────

/// Dotted-path lookup. The snapshot's schema is broad and grows on the daemon
/// side; mirroring it as structs would mean a compile break every time a field
/// is added, so this reads Values defensively and returns a neutral 0 / "" for
/// anything missing. A dashboard must never blank out because one key moved.
pub(crate) fn num(v: &Value, path: &str) -> f64 {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return 0.0,
        }
    }
    cur.as_f64().unwrap_or(0.0)
}

pub(crate) fn text(v: &Value, path: &str) -> String {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return String::new(),
        }
    }
    cur.as_str().unwrap_or("").to_string()
}

/// Booleans, read the same defensive way. Missing is false: the fields that
/// use this all mean "yes, confirmed" and an absent key is not a confirmation.
pub(crate) fn flag(v: &Value, path: &str) -> bool {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return false,
        }
    }
    cur.as_bool().unwrap_or(false)
}

pub(crate) fn arr<'a>(v: &'a Value, path: &str) -> &'a [Value] {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return &[],
        }
    }
    cur.as_array().map(|a| a.as_slice()).unwrap_or(&[])
}

pub(crate) fn snapshot_path() -> String {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".into());
    format!("{dir}/my-konsole-watchdog.json")
}

pub(crate) fn kill_path() -> String {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".into());
    format!("{dir}/my-konsole-watchdog.kill")
}

pub(crate) fn read_json(path: &str) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

pub(crate) fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// ───────────────────────────────── btop visuals ────────────────────────────────

