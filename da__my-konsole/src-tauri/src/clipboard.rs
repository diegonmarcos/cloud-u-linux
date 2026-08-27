// clipboard.rs — Klipper-style clipboard manager, added as a SECOND native
// ksni tray alongside the config-driven ones in main.rs. Same overall shape
// as watchdog.rs (a background thread + a JSON file on disk, started only
// from the --tray-daemon branch of main()), but this one also drives a
// dynamic menu instead of only publishing a snapshot.
//
// ── WHY A NEW NATIVE TRAY, NOT AN ENTRY IN systrays.json ────────────────────
// systrays.json's menu grammar (parse_menu/build_menu in main.rs) is a
// static tree of {label, command} shell-execs. It has no way to express
// "one row per clipboard entry, rebuilt every time the history changes,
// where clicking a row runs Rust code against in-memory state" — there is
// no `command` string that could do that. So this tray is built directly
// in Rust (ClipboardTray implements ksni::Tray itself, spawned from
// clipboard::spawn() below) rather than forced through the config-driven
// path. `configs/clipboard.json` still carries every TUNABLE (sizes,
// limits, ignore patterns, default list names) — only the menu SHAPE is
// code, exactly like watchdog.rs's snapshot shape is code while its
// thresholds live in files.
//
// ── CAPTURE METHOD: `wl-paste --watch`, not a Wayland-client crate ─────────
// This session is Wayland/KWin. KWin implements zwlr_data_control_manager_v1,
// which is what a Rust-native watcher would need to speak by hand — a lot of
// protocol surface to get right with no compiler available here to check it
// against. `wl-paste` (wl-clipboard) already speaks that protocol and is
// installed (~/.nix-profile/bin/wl-paste, wl-clipboard 2.2.1 at the time of
// writing). Its `--watch` behaviour was verified directly against the real
// binary before writing this file (not assumed from docs): `wl-paste --type
// text --no-newline --watch <cmd>` runs `<cmd>` once immediately with
// whatever is on the clipboard right now, then again every time the
// selection changes, piping the full content to `<cmd>`'s stdin each time,
// one short-lived invocation per change. `--no-newline` avoids the trailing
// newline `wl-paste` otherwise appends (also verified directly).
//
// The watched `<cmd>` is THIS SAME BINARY re-invoked with `--clip-sink` —
// see run_clip_sink() below, dispatched from main() before Tauri even boots.
// It forwards the captured bytes once over a Unix socket to the already-
// running tray daemon. No IPC crate: std::os::unix::net is enough for a
// one-shot "connect, write, close" message.
//
// If wl-paste is missing at runtime, spawn_capture() logs and returns —
// capture is simply disabled (pin/list/history browsing off whatever was
// already persisted still work); it must never panic or take the daemon
// (which hosts every other tray too) down with it.
//
// ── SECURITY ─────────────────────────────────────────────────────────────
// - The store file (clipboard-store.json) is created with mode 0600 AT
//   CREATION (see save_store) — no world-readable window.
// - KDE's password-manager hint (x-kde-passwordManagerHint=secret, used by
//   KeePass/Bitwarden-family clients including Vaultwarden's apps) is
//   checked in run_clip_sink via `wl-paste --list-types` / `--type
//   x-kde-passwordManagerHint` BEFORE the content ever reaches the daemon —
//   a flagged entry is never even sent over the socket. This is inherently
//   best-effort with this capture method: wl-paste's --watch only hands us
//   the ONE mime type we asked for (text) on stdin, not the full offer list
//   that produced it, so the mime check is a second, separate query against
//   the (very likely still current) selection rather than an atomic read of
//   the exact offer. That is the best signal available without hand-rolling
//   the Wayland protocol directly.
// - configs/clipboard.json's `ignore_substrings` is a plain substring list,
//   not regex: no new crate, no regex-syntax footgun to get right without a
//   compiler, and "does this known secret marker appear in the text" does
//   not need pattern matching more powerful than `contains`.
// - `max_entry_bytes` caps what gets STORED (truncated on a UTF-8 char
//   boundary); a separate, looser cap in the sink/accept path only guards
//   against a huge paste ballooning memory before that trim is applied.
// - Clipboard content is never logged at any level — only sizes/counts.

use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

// ── config (tunables, committed, installed by build.sh) ────────────────────

#[derive(Deserialize, Clone)]
#[serde(default)]
struct ClipConfig {
    enable: bool,
    max_history: usize,
    max_entry_bytes: usize,
    ignore_substrings: Vec<String>,
    default_lists: Vec<String>,
}

impl Default for ClipConfig {
    fn default() -> Self {
        ClipConfig {
            enable: true,
            max_history: 50,
            max_entry_bytes: 65_536,
            ignore_substrings: Vec::new(),
            default_lists: Vec::new(),
        }
    }
}

fn config_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share/my-konsole/clipboard.json"))
}

fn load_config() -> ClipConfig {
    let Some(path) = config_path() else { return ClipConfig::default() };
    let Ok(txt) = std::fs::read_to_string(&path) else { return ClipConfig::default() };
    serde_json::from_str(&txt).unwrap_or_default()
}

// ── store (runtime data, NOT committed — lives under ~/.local/share/my-konsole) ─

#[derive(Serialize, Deserialize, Clone, Default)]
struct ClipEntry {
    id: u64,
    text: String,
    ts: u64,
}

#[derive(Serialize, Deserialize, Clone, Default)]
struct ClipStore {
    #[serde(default)]
    history: Vec<ClipEntry>,
    #[serde(default)]
    pinned: Vec<ClipEntry>,
    #[serde(default)]
    lists: BTreeMap<String, Vec<ClipEntry>>,
}

fn store_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share/my-konsole/clipboard-store.json"))
}

// DefaultHasher::new() uses fixed (unrandomized) keys — unlike HashMap's
// RandomState, the SAME text hashes to the SAME id across process restarts,
// which matters here: ids persisted in the store must still dedup correctly
// against a freshly-captured entry after the daemon restarts.
fn entry_id(text: &str) -> u64 {
    let mut h = DefaultHasher::new();
    text.hash(&mut h);
    h.finish()
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Load the store, seeding empty named lists from config.default_lists on
/// first run (or for any name added to the config later) — see the module
/// doc for why lists are BOTH config-declared and runtime-creatable.
fn load_store(cfg: &ClipConfig) -> ClipStore {
    let mut store = store_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|txt| serde_json::from_str::<ClipStore>(&txt).ok())
        .unwrap_or_default();
    for name in &cfg.default_lists {
        store.lists.entry(name.clone()).or_default();
    }
    store
}

/// Persist the store. The file is created with mode 0600 AT CREATION (via
/// OpenOptions::mode, not a chmod afterward — a chmod-after-write leaves a
/// window where the plaintext history sat world-readable) and published
/// atomically (tmp file + rename), same pattern as watchdog::publish so a
/// reader never observes a half-written file.
fn save_store(store: &ClipStore) {
    let Some(path) = store_path() else { return };
    let Ok(body) = serde_json::to_string_pretty(store) else { return };
    let tmp = path.with_extension("tmp");
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp);
    let Ok(mut f) = file else { return };
    if f.write_all(body.as_bytes()).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

fn should_ignore(text: &str, cfg: &ClipConfig) -> bool {
    cfg.ignore_substrings.iter().any(|pat| !pat.is_empty() && text.contains(pat.as_str()))
}

/// Truncates on a UTF-8 char boundary rather than mid-sequence — a raw byte
/// cut could split a multi-byte character and make the stored JSON invalid
/// UTF-8 (String::from_utf8 would already have rejected that, but a byte
/// slice cut here is a separate risk from the capture-side one).
fn cap_entry(text: &str, cfg: &ClipConfig) -> Option<String> {
    if text.trim().is_empty() {
        return None;
    }
    if text.len() <= cfg.max_entry_bytes {
        return Some(text.to_string());
    }
    let mut end = cfg.max_entry_bytes.min(text.len());
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    Some(text[..end].to_string())
}

/// Adds `raw_text` to history: applies the ignore-list and size cap, dedups
/// by content hash (a re-copy of an existing entry MOVES it to the top
/// instead of adding a second copy — requirement #1), then rotates the
/// oldest entries out past max_history. Pinned entries live in their own
/// Vec (see ClipStore) so this rotation can never evict them. Returns
/// whether the store actually changed (so the caller only re-persists /
/// refreshes the tray when something did).
fn add_history(store: &mut ClipStore, cfg: &ClipConfig, raw_text: &str) -> bool {
    if should_ignore(raw_text, cfg) {
        return false;
    }
    let Some(text) = cap_entry(raw_text, cfg) else { return false };
    let id = entry_id(&text);
    // Re-copying the item already on top is a no-op — skip the churn.
    if store.history.first().map(|e| e.id) == Some(id) {
        return false;
    }
    store.history.retain(|e| e.id != id);
    store.history.insert(0, ClipEntry { id, text, ts: now_secs() });
    store.history.truncate(cfg.max_history.max(1));
    true
}

// ── clipboard capture: socket + wl-paste child ──────────────────────────────

fn socket_path() -> Option<PathBuf> {
    std::env::var_os("XDG_RUNTIME_DIR").map(|d| PathBuf::from(d).join("my-konsole-clip.sock"))
}

/// Copies `text` onto the clipboard via `wl-copy`, piped over stdin (never
/// as an argv — arbitrary clipboard content must not be interpreted as
/// shell/exec arguments). `wl-copy` forks and stays resident to keep serving
/// the selection after its parent exits, so this deliberately does NOT wait
/// on the child — same fire-and-forget spawn() pattern main.rs already uses
/// for tray menu commands (see build_menu's activate closures).
fn copy_to_clipboard(text: &str) {
    use std::process::{Command, Stdio};
    match Command::new("wl-copy").stdin(Stdio::piped()).spawn() {
        Ok(mut child) => {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
        }
        Err(e) => eprintln!("[clipboard] wl-copy not found or failed to spawn: {e}"),
    }
}

/// Entered from main() when this process was re-invoked as the `wl-paste
/// --watch` command (argv contains --clip-sink). Reads the captured
/// clipboard content from stdin, skips it if it carries KDE's password-
/// manager hint, then forwards it once to the running tray daemon over
/// the capture socket. Never panics: no daemon listening (not running, or
/// capture disabled) just means there is nothing to forward to.
pub fn run_clip_sink() {
    let cfg = load_config();
    if !cfg.enable {
        return;
    }
    if has_password_hint() {
        eprintln!("[clipboard] skipped: x-kde-passwordManagerHint=secret");
        return;
    }

    let mut buf = Vec::new();
    // Looser than max_entry_bytes on purpose — this only bounds what this
    // short-lived helper reads before the daemon applies its own (tighter,
    // config-driven) storage cap; it is not itself the storage cap.
    let cap: u64 = (cfg.max_entry_bytes as u64).saturating_mul(4).max(1_048_576);
    if std::io::stdin().take(cap).read_to_end(&mut buf).is_err() || buf.is_empty() {
        return;
    }

    let Some(sock_path) = socket_path() else { return };
    let Ok(mut stream) = UnixStream::connect(&sock_path) else { return };
    let _ = stream.write_all(&buf);
    let _ = stream.shutdown(std::net::Shutdown::Write);
}

/// Best-effort check for KDE/Klipper's `x-kde-passwordManagerHint` MIME
/// offer (value "secret") on the CURRENT selection. wl-paste's --watch only
/// hands this process the text payload it asked for, not the mime list that
/// produced it, so this re-queries the live selection separately — see the
/// module doc's SECURITY section for the race this implies.
fn has_password_hint() -> bool {
    use std::process::Command;
    let Ok(out) = Command::new("wl-paste").arg("--list-types").output() else { return false };
    if !out.status.success() {
        return false;
    }
    let types = String::from_utf8_lossy(&out.stdout);
    if !types.lines().any(|l| l.trim() == "x-kde-passwordManagerHint") {
        return false;
    }
    Command::new("wl-paste")
        .args(["--type", "x-kde-passwordManagerHint", "--no-newline"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "secret")
        .unwrap_or(false)
}

/// Binds the capture socket, starts its accept loop, and spawns the
/// `wl-paste --watch` child that feeds it. Runs forever on its own thread
/// once started — same shape as watchdog::spawn's sampling loop.
fn spawn_capture(cfg: ClipConfig, handle: ksni::blocking::Handle<ClipboardTray>) {
    let Some(sock_path) = socket_path() else {
        eprintln!("[clipboard] no XDG_RUNTIME_DIR — capture disabled");
        return;
    };
    let _ = std::fs::remove_file(&sock_path); // stale socket from a crashed previous run
    let listener = match UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[clipboard] failed to bind capture socket {sock_path:?}: {e}");
            return;
        }
    };

    let read_cap: u64 = (cfg.max_entry_bytes as u64).saturating_mul(4).max(1);
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(stream) = conn else { continue };
            let mut buf = Vec::new();
            // Cap the read itself: whatever connects to this socket (only
            // ever meant to be our own --clip-sink helper) must never be
            // able to balloon the daemon's memory.
            if stream.take(read_cap).read_to_end(&mut buf).is_err() {
                continue;
            }
            let Ok(text) = String::from_utf8(buf) else { continue };
            handle.update(move |tray: &mut ClipboardTray| {
                if add_history(&mut tray.store, &tray.cfg, &text) {
                    save_store(&tray.store);
                }
            });
        }
    });

    let Ok(exe) = std::env::current_exe() else {
        eprintln!("[clipboard] can't resolve my own binary path — capture disabled");
        return;
    };
    // Verified directly against wl-clipboard 2.2.1 on this machine: --watch
    // runs the given command once immediately with whatever is on the
    // clipboard now, then again on every subsequent change, full content on
    // stdin, one short-lived run per change — see the module doc.
    match std::process::Command::new("wl-paste")
        .args(["--type", "text", "--no-newline", "--watch"])
        .arg(&exe)
        .arg("--clip-sink")
        .spawn()
    {
        Ok(_child) => eprintln!("[clipboard] watching clipboard via wl-paste"),
        Err(e) => eprintln!(
            "[clipboard] wl-paste not found — clipboard capture disabled (pin/list features still work off existing history): {e}"
        ),
    }
}

// ── the tray itself ──────────────────────────────────────────────────────

struct ClipboardTray {
    cfg: ClipConfig,
    store: ClipStore,
    icon: Option<ksni::Icon>,
}

const PREVIEW_LEN: usize = 60;

/// Single-line, length-capped label for a menu row: newlines flattened to
/// spaces (a multi-line entry would otherwise break the menu's row layout),
/// truncated on a char boundary with an ellipsis.
fn preview(text: &str) -> String {
    let flat: String = text.chars().map(|c| if c == '\n' || c == '\r' { ' ' } else { c }).collect();
    let flat = flat.trim();
    if flat.is_empty() {
        return "(empty)".to_string();
    }
    let mut end = PREVIEW_LEN.min(flat.len());
    while end > 0 && !flat.is_char_boundary(end) {
        end -= 1;
    }
    if end < flat.len() {
        format!("{}…", &flat[..end])
    } else {
        flat.to_string()
    }
}

fn placeholder(label: &str) -> ksni::MenuItem<ClipboardTray> {
    ksni::menu::StandardItem { label: label.to_string(), enabled: false, ..Default::default() }.into()
}

/// A plain click = copy that entry to the clipboard — requirement #2, the
/// core Klipper behaviour. This is why history/pinned/list rows are NOT
/// submenus: a submenu's row click only expands it in a dbusmenu, it can't
/// ALSO fire an action, so the "click pastes it" behaviour has to own the
/// plain top-level row and every other action (pin/save/remove) lives in
/// its own dedicated submenu instead of competing for that same click.
fn copy_item(text: String) -> ksni::MenuItem<ClipboardTray> {
    let label = preview(&text);
    ksni::menu::StandardItem {
        label,
        activate: Box::new(move |_this: &mut ClipboardTray| copy_to_clipboard(&text)),
        ..Default::default()
    }
    .into()
}

fn pin_item(entry: ClipEntry) -> ksni::MenuItem<ClipboardTray> {
    let label = preview(&entry.text);
    ksni::menu::StandardItem {
        label,
        activate: Box::new(move |this: &mut ClipboardTray| {
            if !this.store.pinned.iter().any(|e| e.id == entry.id) {
                this.store.pinned.insert(0, entry.clone());
            }
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

fn unpin_item(entry: ClipEntry) -> ksni::MenuItem<ClipboardTray> {
    let label = preview(&entry.text);
    let id = entry.id;
    ksni::menu::StandardItem {
        label,
        activate: Box::new(move |this: &mut ClipboardTray| {
            this.store.pinned.retain(|e| e.id != id);
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

fn remove_history_item(entry: ClipEntry) -> ksni::MenuItem<ClipboardTray> {
    let label = preview(&entry.text);
    let id = entry.id;
    ksni::menu::StandardItem {
        label,
        activate: Box::new(move |this: &mut ClipboardTray| {
            this.store.history.retain(|e| e.id != id);
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

fn save_to_list_item(entry: ClipEntry, list: String) -> ksni::MenuItem<ClipboardTray> {
    ksni::menu::StandardItem {
        label: list.clone(),
        activate: Box::new(move |this: &mut ClipboardTray| {
            let bucket = this.store.lists.entry(list.clone()).or_default();
            if !bucket.iter().any(|e| e.id == entry.id) {
                bucket.insert(0, entry.clone());
            }
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

fn save_to_new_list_item(entry: ClipEntry) -> ksni::MenuItem<ClipboardTray> {
    ksni::menu::StandardItem {
        label: "New list…".to_string(),
        activate: Box::new(move |this: &mut ClipboardTray| {
            let Some(name) = prompt_list_name() else { return };
            let name = name.trim().to_string();
            if name.is_empty() {
                return;
            }
            let bucket = this.store.lists.entry(name).or_default();
            if !bucket.iter().any(|e| e.id == entry.id) {
                bucket.insert(0, entry.clone());
            }
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

fn remove_from_list_item(id: u64, label: String, list: String) -> ksni::MenuItem<ClipboardTray> {
    ksni::menu::StandardItem {
        label,
        activate: Box::new(move |this: &mut ClipboardTray| {
            if let Some(bucket) = this.store.lists.get_mut(&list) {
                bucket.retain(|e| e.id != id);
            }
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

fn new_list_item() -> ksni::MenuItem<ClipboardTray> {
    ksni::menu::StandardItem {
        label: "New list…".to_string(),
        activate: Box::new(move |this: &mut ClipboardTray| {
            let Some(name) = prompt_list_name() else { return };
            let name = name.trim().to_string();
            if name.is_empty() {
                return;
            }
            this.store.lists.entry(name).or_default();
            save_store(&this.store);
        }),
        ..Default::default()
    }
    .into()
}

/// Runtime list creation needs a free-text name, and dbusmenu rows have no
/// text-input widget of their own — so this shells out to a native input
/// dialog, same "the daemon can spawn what the user could" convention the
/// existing trays use for their commands. kdialog first (it ships with
/// Plasma, and this box is a Plasma session per the repo's own conventions),
/// zenity as a fallback for non-KDE desktops. If neither is installed this
/// degrades to "list creation unavailable" rather than panicking or hanging.
fn prompt_list_name() -> Option<String> {
    use std::process::Command;
    let out = Command::new("kdialog")
        .arg("--inputbox")
        .arg("New clipboard list name:")
        .output()
        .or_else(|_| Command::new("zenity").arg("--entry").arg("--text=New clipboard list name:").output());
    match out {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        }
        _ => {
            eprintln!("[clipboard] no kdialog/zenity available — can't prompt for a list name");
            None
        }
    }
}

/// Builds the full dynamic menu from current tray state. Called by ksni
/// itself (via the Tray::menu trait method) whenever the tray's context menu
/// is opened, so it always reflects whatever handle.update() last wrote —
/// no separate "rebuild" step needed beyond calling handle.update() (see
/// spawn_capture and the pin/save/remove closures above), which is the
/// pattern the module doc says to follow rather than invent.
fn build_clipboard_menu(tray: &ClipboardTray) -> Vec<ksni::MenuItem<ClipboardTray>> {
    let mut items: Vec<ksni::MenuItem<ClipboardTray>> = Vec::new();

    // History — plain click-to-copy rows (requirement #1 + #2).
    if tray.store.history.is_empty() {
        items.push(placeholder("(no history yet)"));
    } else {
        for entry in &tray.store.history {
            items.push(copy_item(entry.text.clone()));
        }
    }
    items.push(ksni::MenuItem::Separator);

    // Pin an entry (requirement #3).
    let pin_children: Vec<_> = tray.store.history.iter().cloned().map(pin_item).collect();
    items.push(
        ksni::menu::SubMenu {
            label: "Pin entry".to_string(),
            submenu: if pin_children.is_empty() { vec![placeholder("(no history yet)")] } else { pin_children },
            ..Default::default()
        }
        .into(),
    );

    // Save an entry into a named list (requirement #4).
    let list_names: Vec<String> = tray.store.lists.keys().cloned().collect();
    let save_children: Vec<_> = tray
        .store
        .history
        .iter()
        .cloned()
        .map(|entry| {
            let mut dest: Vec<_> = list_names.iter().cloned().map(|l| save_to_list_item(entry.clone(), l)).collect();
            dest.push(save_to_new_list_item(entry.clone()));
            ksni::menu::SubMenu { label: preview(&entry.text), submenu: dest, ..Default::default() }.into()
        })
        .collect();
    items.push(
        ksni::menu::SubMenu {
            label: "Save to list".to_string(),
            submenu: if save_children.is_empty() { vec![placeholder("(no history yet)")] } else { save_children },
            ..Default::default()
        }
        .into(),
    );

    // Remove a single entry from history (requirement #5).
    let remove_children: Vec<_> = tray.store.history.iter().cloned().map(remove_history_item).collect();
    items.push(
        ksni::menu::SubMenu {
            label: "Remove from history".to_string(),
            submenu: if remove_children.is_empty() { vec![placeholder("(no history yet)")] } else { remove_children },
            ..Default::default()
        }
        .into(),
    );

    items.push(ksni::MenuItem::Separator);

    // Pinned section — its own copy-to-use rows, plus unpin/remove
    // (requirement #3 + #5).
    let mut pinned_children: Vec<_> = tray.store.pinned.iter().cloned().map(|e| copy_item(e.text.clone())).collect();
    let unpin_children: Vec<_> = tray.store.pinned.iter().cloned().map(unpin_item).collect();
    if !unpin_children.is_empty() {
        pinned_children.push(ksni::MenuItem::Separator);
        pinned_children.push(ksni::menu::SubMenu { label: "Unpin".to_string(), submenu: unpin_children, ..Default::default() }.into());
    }
    items.push(
        ksni::menu::SubMenu {
            label: format!("Pinned ({})", tray.store.pinned.len()),
            submenu: if pinned_children.is_empty() { vec![placeholder("(none)")] } else { pinned_children },
            ..Default::default()
        }
        .into(),
    );

    // Lists — one submenu per named list (requirement #4), each with its own
    // copy-to-use rows plus a "Remove" submenu (requirement #5), and a
    // trailing "New list…" that creates an empty list at runtime.
    let mut lists_children: Vec<ksni::MenuItem<ClipboardTray>> = Vec::new();
    for (name, entries) in &tray.store.lists {
        let mut kids: Vec<_> = entries.iter().cloned().map(|e| copy_item(e.text.clone())).collect();
        let remove_kids: Vec<_> =
            entries.iter().cloned().map(|e| remove_from_list_item(e.id, preview(&e.text), name.clone())).collect();
        if !remove_kids.is_empty() {
            kids.push(ksni::MenuItem::Separator);
            kids.push(ksni::menu::SubMenu { label: "Remove".to_string(), submenu: remove_kids, ..Default::default() }.into());
        }
        if kids.is_empty() {
            kids.push(placeholder("(empty)"));
        }
        lists_children.push(ksni::menu::SubMenu { label: name.clone(), submenu: kids, ..Default::default() }.into());
    }
    lists_children.push(new_list_item());
    items.push(ksni::menu::SubMenu { label: "Lists".to_string(), submenu: lists_children, ..Default::default() }.into());

    items.push(ksni::MenuItem::Separator);
    items.push(
        ksni::menu::StandardItem {
            label: "Clear history".to_string(),
            activate: Box::new(|this: &mut ClipboardTray| {
                this.store.history.clear();
                save_store(&this.store);
            }),
            ..Default::default()
        }
        .into(),
    );

    items
}

impl ksni::Tray for ClipboardTray {
    fn id(&self) -> String {
        "clipboard-systray".to_string()
    }
    fn title(&self) -> String {
        "Clipboard".to_string()
    }
    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        self.icon.clone().into_iter().collect()
    }
    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "Clipboard".to_string(),
            description: format!(
                "{} history, {} pinned, {} list(s)",
                self.store.history.len(),
                self.store.pinned.len(),
                self.store.lists.len()
            ),
            ..Default::default()
        }
    }
    // Primary (left) click on the icon itself: re-copy the most recent
    // history entry, a small bonus convenience beyond the required
    // menu-driven behaviour — never the ONLY way to reach any feature here.
    fn activate(&mut self, _x: i32, _y: i32) {
        if let Some(top) = self.store.history.first() {
            copy_to_clipboard(&top.text);
        }
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        build_clipboard_menu(self)
    }
}

/// Starts the clipboard tray. Called once from main()'s --tray-daemon
/// branch, right alongside watchdog::spawn() — same "ONE publisher" rule
/// applies here as it does to the other trays (see setup_systrays' comment
/// in main.rs): calling this from the plain GUI launch path too would
/// register a second StatusNotifierItem with the same id.
pub fn spawn() {
    let cfg = load_config();
    if !cfg.enable {
        eprintln!("[clipboard] disabled via config — tray not started");
        return;
    }
    let store = load_store(&cfg);
    let icon = crate::load_systray_icon("clipboard").map(|(rgba, w, h)| crate::rgba_to_ksni_icon(rgba, w, h));

    use ksni::blocking::TrayMethods;
    let tray = ClipboardTray { cfg: cfg.clone(), store, icon };
    let handle = match tray.spawn() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("[clipboard] failed to register systray: {e}");
            return;
        }
    };

    spawn_capture(cfg, handle);
}
