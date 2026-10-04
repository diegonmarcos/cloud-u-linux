// my-konsole — Rust KDE Konsole alternative (Tauri v2).
// PTYs (one per terminal tab) come from the shared pty-core crate; this file just
// wires its broker into Tauri state and forwards its events to the webview as
// `pty:<id>` / `pty-exit:<id>`. The frontend (xterm.js) renders it.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod clipboard;

use pty_core::{PtyBroker, PtyEvent};
use serde::Serialize;
use tauri::{Emitter, Manager, State};

#[derive(Serialize, Clone)]
struct PtyChunk {
    id: String,
    data: String,
}

// Spawn a shell attached to a fresh PTY (via pty-core); stream its output to the webview.
#[tauri::command]
fn pty_start(
    app: tauri::AppHandle,
    broker: State<PtyBroker>,
    id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
) -> Result<(), String> {
    let app2 = app.clone();
    broker.start(id.clone(), cols, rows, cwd, move |ev| match ev {
        PtyEvent::Output { id, data } => {
            let _ = app2.emit(&format!("pty:{id}"), PtyChunk { id: id.clone(), data });
        }
        PtyEvent::Exit { id } => {
            let _ = app2.emit(&format!("pty-exit:{id}"), ());
        }
    })
}

#[tauri::command]
fn pty_write(broker: State<PtyBroker>, id: String, data: String) -> Result<(), String> {
    broker.write(&id, &data)
}

#[tauri::command]
fn pty_resize(broker: State<PtyBroker>, id: String, cols: u16, rows: u16) -> Result<(), String> {
    broker.resize(&id, cols, rows)
}

#[tauri::command]
fn pty_kill(broker: State<PtyBroker>, id: String) {
    broker.kill(&id); // drops the PTY → shell gets SIGHUP
}

// Load profiles (top-nav + command sections). Data-driven: each profile is a
// <slug>/profile.json (dirs sorted, so numeric prefixes control order). Prefer
// the USER dir (~/.local/share/my-konsole/profiles) so edits apply on restart
// WITHOUT a recompile; fall back to the bundled Resource copy.
fn read_profiles_dir(base: &std::path::Path) -> Vec<serde_json::Value> {
    let mut profiles = Vec::new();
    if let Ok(entries) = std::fs::read_dir(base) {
        let mut dirs: Vec<_> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for d in dirs {
            if let Ok(txt) = std::fs::read_to_string(d.join("profile.json")) {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                    profiles.push(v);
                }
            }
        }
    }
    profiles
}

// Runtime UI config (theme/font/terminal/keybindings). Same user-dir-first
// resolution as profiles, so config.json edits apply on restart without rebuild.
#[tauri::command]
fn get_config(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/config.json");
        if let Ok(txt) = std::fs::read_to_string(&user) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                return Ok(v);
            }
        }
    }
    if let Ok(p) = app.path().resolve("config.json", tauri::path::BaseDirectory::Resource) {
        if let Ok(txt) = std::fs::read_to_string(&p) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                return Ok(v);
            }
        }
    }
    Ok(serde_json::json!({}))
}

#[tauri::command]
fn get_profiles(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    // 1. user dir (instant edits, no rebuild)
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/profiles");
        let p = read_profiles_dir(&user);
        if !p.is_empty() {
            return Ok(serde_json::json!({ "profiles": p }));
        }
    }
    // 2. bundled resource fallback
    if let Ok(base) = app.path().resolve("profiles", tauri::path::BaseDirectory::Resource) {
        return Ok(serde_json::json!({ "profiles": read_profiles_dir(&base) }));
    }
    Ok(serde_json::json!({ "profiles": [] }))
}

// Lists one directory (yazi-style miller columns read one level at a time).
// Not gated by Tauri's fs-plugin ACL — plain std::fs, shared with the engine via pty-core::fs.
#[tauri::command]
fn fs_list_dir(path: String) -> Result<Vec<pty_core::fs::FsEntry>, String> {
    pty_core::fs::list_dir(&path)
}

#[tauri::command]
fn fs_read_file(path: String) -> Result<String, String> {
    pty_core::fs::read_file(&path)
}

#[tauri::command]
fn fs_write_file(path: String, content: String) -> Result<(), String> {
    pty_core::fs::write_file(&path, &content)
}

// Directory NAMES pruned BEFORE descending. This list used to be applied to
// the glob crate's *results*, after it had already walked every one of these
// subtrees in full — that was the bug: da_my-ai/target alone is 1200+
// directories of Rust build output, walked twice (once per pattern) on every
// panel open. walkdir's filter_entry skips the subtree outright, which is
// the whole point of switching crates.
const SKIP_DIRS: [&str; 10] = [
    ".git", "target", "node_modules", "result", ".cache", ".direnv", "dist", "build", ".venv",
    "__pycache__",
];
const GLOB_MAX_RESULTS: usize = 500;
// Total directory entries visited across ALL patterns in one fs_glob call, and
// max depth per walk — a runaway pattern (or a profile pointing at a huge
// tree) returns a short list instead of hanging the UI. Silent by design,
// same as the result cap: the frontend just sees "up to 500".
const GLOB_MAX_ENTRIES: usize = 20_000;
const GLOB_MAX_DEPTH: usize = 12;
// The Data panel is lazyloaded (glob fires per group, on first expand), so
// re-expanding a group or switching back to a profile mid-session should be
// instant rather than re-walking a tree that hasn't changed. TTL is short —
// not infinite — because these ARE the files the user is actively editing;
// silently serving a minute-old list is fine, serving a stale one forever
// isn't.
const GLOB_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(60);

#[derive(Default)]
struct GlobCache(std::sync::Mutex<std::collections::HashMap<Vec<String>, (std::time::Instant, Vec<String>)>>);

impl GlobCache {
    fn get(&self, patterns: &[String]) -> Option<Vec<String>> {
        let map = self.0.lock().ok()?;
        let (ts, result) = map.get(patterns)?;
        (ts.elapsed() < GLOB_CACHE_TTL).then(|| result.clone())
    }

    fn put(&self, patterns: Vec<String>, result: Vec<String>) {
        if let Ok(mut map) = self.0.lock() {
            map.insert(patterns, (std::time::Instant::now(), result));
        }
    }
}

// Expands the glob patterns behind the sidebar "Data" panel (a profile's
// `configs[].paths`) into concrete files. `~` is the only shorthand a
// profile.json pattern uses — expanded by hand before matching, same as
// before.
#[tauri::command]
fn fs_glob(cache: State<GlobCache>, patterns: Vec<String>) -> Result<Vec<String>, String> {
    if let Some(hit) = cache.get(&patterns) {
        return Ok(hit);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let mut out: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut budget = GLOB_MAX_ENTRIES;
    for pat in &patterns {
        let expanded = if pat == "~" {
            home.clone()
        } else if let Some(rest) = pat.strip_prefix("~/") {
            format!("{home}/{rest}")
        } else {
            pat.clone()
        };
        glob_one(&expanded, &home, &mut out, &mut budget);
    }
    let result: Vec<String> = out.into_iter().take(GLOB_MAX_RESULTS).collect();
    cache.put(patterns, result.clone());
    Ok(result)
}

// A pattern with no wildcard is a plain existence check — most configs.paths
// entries are exact filenames (an SSH config, a settings.json) and should
// cost one stat, not a walk. A pattern WITH a wildcard is split at its first
// wildcard-bearing component: everything before that is a literal walk root,
// everything from there on is matched by hand below. Refuses to walk from
// "/" or the home dir itself — those are the two roots big enough to hang.
fn glob_one(
    pattern: &str,
    home: &str,
    out: &mut std::collections::BTreeSet<String>,
    budget: &mut usize,
) {
    if !has_wildcard(pattern) {
        if std::path::Path::new(pattern).is_file() {
            out.insert(pattern.to_string());
        }
        return;
    }
    if *budget == 0 || out.len() >= GLOB_MAX_RESULTS {
        return;
    }

    let parts: Vec<&str> = pattern.split('/').collect();
    let Some(wildcard_idx) = parts.iter().position(|p| has_wildcard(p)) else { return };
    let root = match wildcard_idx {
        0 => "/".to_string(),
        _ => parts[..wildcard_idx].join("/"),
    };
    if root == "/" || root == home {
        return;
    }
    let root_path = std::path::Path::new(&root);
    if !root_path.is_dir() {
        return; // profile references a repo the user hasn't cloned — skip silently
    }
    let rel_pattern = parts[wildcard_idx..].join("/");
    // A non-recursive pattern only ever matches at a fixed depth (segment
    // count below root) — no reason to let walkdir descend past that.
    let depth_cap = if rel_pattern.starts_with("**/") {
        GLOB_MAX_DEPTH
    } else {
        rel_pattern.split('/').count().min(GLOB_MAX_DEPTH)
    };

    for entry in walkdir::WalkDir::new(root_path)
        .max_depth(depth_cap)
        .into_iter()
        .filter_entry(|e| {
            e.depth() == 0
                || e.file_type().is_file()
                || !SKIP_DIRS.contains(&e.file_name().to_string_lossy().as_ref())
        })
    {
        if *budget == 0 || out.len() >= GLOB_MAX_RESULTS {
            return;
        }
        *budget -= 1;
        let Ok(entry) = entry else { continue };
        if !entry.file_type().is_file() {
            continue;
        }
        let Ok(rel) = entry.path().strip_prefix(root_path) else { continue };
        if match_glob(&rel_pattern, &rel.to_string_lossy()) {
            out.insert(entry.path().to_string_lossy().into_owned());
        }
    }
}

fn has_wildcard(s: &str) -> bool {
    s.contains('*') || s.contains('?')
}

// ponytail: hand-rolled matcher, not a real glob engine — covers exactly what
// configs.paths uses today: literal segments, `*` within one segment (never
// crosses `/`), `?`, and a leading `**/` for recursive-below-root. No brace
// expansion, no `[a-z]` classes. If a pattern ever needs those, reach for a
// real matcher crate (e.g. `globset`) instead of growing this by hand.
fn match_glob(pattern: &str, path: &str) -> bool {
    match pattern.strip_prefix("**/") {
        Some(rest) => {
            let rest_segs: Vec<&str> = rest.split('/').collect();
            let path_segs: Vec<&str> = path.split('/').collect();
            (0..path_segs.len()).any(|i| match_segments(&rest_segs, &path_segs[i..]))
        }
        None => match_segments(
            &pattern.split('/').collect::<Vec<_>>(),
            &path.split('/').collect::<Vec<_>>(),
        ),
    }
}

fn match_segments(pat: &[&str], path: &[&str]) -> bool {
    pat.len() == path.len() && pat.iter().zip(path).all(|(p, s)| match_segment(p, s))
}

// `*` matches any run of chars within the segment, `?` matches exactly one.
fn match_segment(pat: &str, s: &str) -> bool {
    fn go(pat: &[u8], s: &[u8]) -> bool {
        match (pat.first(), s.first()) {
            (None, None) => true,
            (Some(b'*'), _) => go(&pat[1..], s) || (!s.is_empty() && go(pat, &s[1..])),
            (Some(b'?'), Some(_)) => go(&pat[1..], &s[1..]),
            (Some(a), Some(b)) if a == b => go(&pat[1..], &s[1..]),
            _ => false,
        }
    }
    go(pat.as_bytes(), s.as_bytes())
}

// Resolves each binary name against $PATH in pure Rust — no `sh -c`, no
// `command -v`, so it can never choke on a caller's shell dialect (this is
// what replaced a generated bash one-liner that fish users couldn't run).
// "executable" here means a regular file with any of the owner/group/other
// exec bits set, same bar `command -v` uses.
#[tauri::command]
fn which_all(bins: Vec<String>) -> Result<Vec<(String, Option<String>)>, String> {
    use std::os::unix::fs::PermissionsExt;
    let path_var = std::env::var("PATH").unwrap_or_default();
    let dirs: Vec<&str> = path_var.split(':').filter(|d| !d.is_empty()).collect();
    let is_exec = |p: &std::path::Path| -> bool {
        std::fs::metadata(p)
            .map(|m| m.is_file() && (m.permissions().mode() & 0o111) != 0)
            .unwrap_or(false)
    };
    Ok(bins
        .into_iter()
        .map(|b| {
            let found = dirs.iter().find_map(|d| {
                let candidate = std::path::Path::new(d).join(&b);
                is_exec(&candidate).then(|| candidate.to_string_lossy().into_owned())
            });
            (b, found)
        })
        .collect())
}

// ── Browser tabs: <iframe> in-tab + top-level WebviewWindow pop-out.
//
// Both "pure" designs were tried and are PROVEN dead ends on Linux:
//
// - Native child webview (add_child): tauri-runtime-wry packs it into the
//   window's GtkBox (pack_start, expand=true), never a GtkFixed, and wry's
//   set_bounds only acts `if is_in_fixed_parent` — so set_position/set_size/
//   set_bounds all return Ok and do NOTHING (traced live, MYK_BROWSER_DEBUG=1:
//   webview frozen at its GTK-assigned full-width band regardless of every
//   call). A child webview here cannot be positioned, clipped or hidden; it
//   can only split the window. Even close() left the packed widget behind.
//
// - Pure iframe: obeys X-Frame-Options/frame-ancestors, which most external
//   sites send (including linktree.diegonmarcos.com: SAMEORIGIN) → blank
//   rectangle, enforced by WebKit itself, unfixable from our side.
//
// So: the iframe renders what CAN legally be embedded (our own local agentic
// UIs — the in-tab daily drivers), and everything else opens through
// browser_popout as a real top-level WebviewWindow — the one native surface
// whose geometry and close the Linux backend actually honors.

fn parse_url(u: &str) -> Result<tauri::Url, String> {
    u.parse::<tauri::Url>().map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_popout(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    let u = parse_url(&url)?;
    // Re-using the label focuses + navigates the existing window instead of
    // erroring on a duplicate-label build.
    if let Some(w) = app.get_webview_window(&label) {
        w.navigate(u).map_err(|e| e.to_string())?;
        return w.set_focus().map_err(|e| e.to_string());
    }
    tauri::WebviewWindowBuilder::new(&app, &label, tauri::WebviewUrl::External(u.clone()))
        .title(u.host_str().unwrap_or("browser"))
        .inner_size(1100.0, 750.0)
        .build()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

// ── In-tab embedded browser: our own GtkFixed layer ────────────────────────
// tauri's add_child parents child webviews in the window's GtkBox, where wry's
// set_bounds is a silent no-op (tauri#13071 / wry#1727) — they can only split
// the window as a full-width band. wry itself positions fine when the webview
// lives in a GtkFixed (is_in_fixed_parent), tauri just never provides one. So
// we do: reparent the window's content into a GtkOverlay and lay a GtkFixed
// over it; browser webviews are built with wry's build_gtk(&fixed) and receive
// real geometry (logical/CSS px — GTK handles the scale factor, which is why
// no devicePixelRatio math appears anywhere here).
//
// GTK widgets and wry WebViews are !Send: everything lives in thread_locals
// touched only via run_on_main_thread.
thread_local! {
    static EMBED_FIXED: std::cell::RefCell<Option<gtk::Fixed>> = std::cell::RefCell::new(None);
    static EMBEDS: std::cell::RefCell<std::collections::HashMap<String, wry::WebView>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
}

// Feature gate: the embed layer is experimental on this stack. Default OFF —
// a plain launch behaves exactly like the proven iframe+popout build; set
// MYK_EMBED=1 to enable in-tab external webviews. Three startup freezes came
// from variants of restructuring the main window's widget tree; the gate
// guarantees a bad embed iteration can never take the whole app down again.
fn embeds_enabled() -> bool {
    std::env::var("MYK_EMBED").map(|v| v == "1").unwrap_or(false)
}

// Called ONCE from .setup(), on the main thread, BEFORE the event loop owns
// dispatch — never from a run_on_main_thread closure: tauri window getters
// like gtk_window() are blocking round-trips through the event loop, so
// calling one from the loop itself deadlocks (futex-parked main thread).
//
// NO REPARENTING. The GtkOverlay variants (remove vbox → wrap → re-add), both
// post- and pre-realize, froze the main webview on Wayland. This appends a
// zero-height, no-window GtkFixed to the END of the existing vbox and touches
// nothing else — the main webview never moves, so it cannot be broken by this.
// Positioned embeds still work from there: wry's set_bounds for a
// fixed-parented webview is a size_allocate in toplevel coordinates, and a
// widget with its own GDK window is clipped by that window, not by the
// fixed's (empty) allocation.
fn embed_fixed_setup(win: &tauri::Window) -> Result<(), String> {
    use gtk::prelude::*;
    let gtk_win = win.gtk_window().map_err(|e| e.to_string())?;
    let vbox = gtk_win
        .children()
        .into_iter()
        .find_map(|c| c.downcast::<gtk::Box>().ok())
        .ok_or("main window has no GtkBox child")?;
    let fixed = gtk::Fixed::new();
    vbox.pack_end(&fixed, false, false, 0);
    fixed.show();
    EMBED_FIXED.with(|c| *c.borrow_mut() = Some(fixed.clone()));
    Ok(())
}

// Main-thread accessor for the layer installed at setup.
fn embed_fixed() -> Result<gtk::Fixed, String> {
    EMBED_FIXED
        .with(|c| c.borrow().clone())
        .ok_or_else(|| "embed layer not installed (setup failed?)".into())
}

fn on_main<F: FnOnce(tauri::AppHandle) + Send + 'static>(
    app: &tauri::AppHandle,
    f: F,
) -> Result<(), String> {
    let h = app.clone();
    app.run_on_main_thread(move || f(h)).map_err(|e| e.to_string())
}

fn embed_rect(x: f64, y: f64, w: f64, h: f64) -> wry::Rect {
    wry::Rect {
        position: wry::dpi::LogicalPosition::new(x, y).into(),
        size: wry::dpi::LogicalSize::new(w.max(1.0), h.max(1.0)).into(),
    }
}

// Place an embed through GTK's OWN layout (fixed.move_ + set_size_request),
// not wry's set_bounds: that path is a one-shot size_allocate which the next
// GTK layout pass overwrites from the fixed's put-coordinates and the size
// request — the webview snapped back to ~1x1 at the fixed's origin, i.e. an
// invisible page in a "dead" tab. move_/size_request update the values the
// layout pass reads, so the rect survives every re-layout.
// Coordinates: JS sends window-viewport CSS px; fixed children are placed
// relative to the fixed's allocation origin (bottom of the vbox), so subtract
// it — negative child coords are fine for GtkFixed.
fn embed_place(fixed: &gtk::Fixed, wv: &wry::WebView, x: f64, y: f64, w: f64, h: f64, visible: bool) {
    use gtk::prelude::*;
    use wry::WebViewExtUnix;
    let widget = wv.webview();
    if !visible {
        widget.hide();
        return;
    }
    let fa = fixed.allocation();
    fixed.move_(&widget, x as i32 - fa.x(), y as i32 - fa.y());
    widget.set_size_request(w.max(1.0) as i32, h.max(1.0) as i32);
    widget.show();
}

#[tauri::command]
fn embed_open(
    app: tauri::AppHandle,
    label: String,
    url: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> Result<(), String> {
    if !embeds_enabled() {
        // Synchronous rejection: the frontend catches this and falls back to a
        // pop-out window, so external URLs still open somewhere useful.
        return Err("embeds disabled (launch with MYK_EMBED=1)".into());
    }
    parse_url(&url)?;
    ensure_agentic_backend(app.clone(), url.clone())?;
    on_main(&app, move |_app| {
        // Re-opening an existing label navigates it (session restore re-runs open).
        let existed = EMBEDS.with(|m| {
            if let Some(wv) = m.borrow().get(&label) {
                let _ = wv.load_url(&url);
                true
            } else {
                false
            }
        });
        if existed {
            return;
        }
        let fixed = match embed_fixed() {
            Ok(f) => f,
            Err(e) => return eprintln!("[embed] open {label}: {e}"),
        };
        eprintln!("[embed] open {label} at ({x},{y}) {w}x{h}: {url}");
        use wry::WebViewBuilderExtUnix; // build_gtk lives on the Unix ext trait
        match wry::WebViewBuilder::new()
            .with_url(&url)
            .with_bounds(embed_rect(x, y, w, h))
            .build_gtk(&fixed)
        {
            Ok(wv) => {
                eprintln!("[embed] open {label}: built ok");
                embed_place(&fixed, &wv, x, y, w, h, w >= 1.0 && h >= 1.0);
                EMBEDS.with(|m| {
                    m.borrow_mut().insert(label, wv);
                });
            }
            Err(e) => eprintln!("[embed] build {label}: {e}"),
        }
    })
}

#[tauri::command]
fn embed_bounds(
    app: tauri::AppHandle,
    label: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    visible: bool,
) -> Result<(), String> {
    on_main(&app, move |_| {
        let Ok(fixed) = embed_fixed() else { return };
        EMBEDS.with(|m| {
            if let Some(wv) = m.borrow().get(&label) {
                embed_place(&fixed, wv, x, y, w, h, visible);
            }
        });
    })
}

#[tauri::command]
fn embed_navigate(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    parse_url(&url)?;
    ensure_agentic_backend(app.clone(), url.clone())?;
    on_main(&app, move |_| {
        EMBEDS.with(|m| {
            if let Some(wv) = m.borrow().get(&label) {
                let _ = wv.load_url(&url);
            }
        });
    })
}

#[tauri::command]
fn embed_back(app: tauri::AppHandle, label: String) -> Result<(), String> {
    on_main(&app, move |_| {
        EMBEDS.with(|m| {
            if let Some(wv) = m.borrow().get(&label) {
                let _ = wv.evaluate_script("history.back()");
            }
        });
    })
}

#[tauri::command]
fn embed_close(app: tauri::AppHandle, label: String) -> Result<(), String> {
    on_main(&app, move |_| {
        EMBEDS.with(|m| {
            if let Some(wv) = m.borrow_mut().remove(&label) {
                // ponytail: hide-then-drop; if wry's Drop ever leaves the GTK
                // widget alive it is invisible, not a stuck surface. Explicit
                // container removal if that ever shows up in practice.
                let _ = wv.set_visible(false);
                drop(wv);
            }
        });
    })
}

#[tauri::command]
fn ensure_agentic_backend(app: tauri::AppHandle, url: String) -> Result<(), String> {
    let u = parse_url(&url)?;
    if let Some(dist) = agentic_ui_dist_dir(&app) {
        if u.port() == Some(AGENTIC_UI_PORT) {
            agentic_ui_serve_once(dist, AGENTIC_UI_PORT, false);
        } else if u.port() == Some(AGENTIC_UI_LOCAL_PORT) {
            agentic_ui_serve_once(dist, AGENTIC_UI_LOCAL_PORT, true);
        }
    }
    Ok(())
}

// ── Agentic UI static server: the goose-desktop-derived React fork (vendored
// at da_my-konsole/agentic-ui) is a static build, but the frontend's <iframe>
// needs a real http:// URL to point at (no file:// asset-serving story here).
// tiny_http on a fixed localhost port serves the dist dir, same user-dir-first
// resolution as get_profiles/get_config so `build.sh fetch` updates apply
// without a rebuild. /config.json is synthesized (not a file on disk) so the
// goosed URL/secret never sit in the static bundle — sourced the same way the
// my-ai CLI does (GOOSE_SERVER__SECRET_KEY env var; WG endpoint is fixed).
const AGENTIC_UI_PORT: u16 = 58765;
const AGENTIC_UI_LOCAL_PORT: u16 = 58767;
// Local-run mode: the goose-desktop-ui clone can also talk to a `goose serve`
// spawned right here in the Tauri process instead of the remote my-ai-api one
// (10.0.0.6:3227) — this app IS the desktop client goose-desktop always was,
// no reason the agent has to live on a remote box. Loopback-only, so a fixed
// key is fine (never leaves 127.0.0.1, no WG/network exposure).
const LOCAL_GOOSE_PORT: u16 = 58766;
const LOCAL_GOOSE_SECRET: &str = "my-konsole-local-agent";

fn local_goose_ensure_running() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        let spawned = std::process::Command::new("goose")
            .args([
                "serve", "--platform", "desktop",
                "--host", "127.0.0.1",
                "--port", &LOCAL_GOOSE_PORT.to_string(),
            ])
            .env("GOOSE_SERVER__SECRET_KEY", LOCAL_GOOSE_SECRET)
            .spawn();
        match spawned {
            Ok(_) => eprintln!("local-goose: serving on 127.0.0.1:{LOCAL_GOOSE_PORT}"),
            Err(e) => eprintln!("local-goose: failed to spawn `goose serve` — {e}"),
        }
    });
}

fn agentic_ui_dist_dir(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/agentic-ui/dist");
        if user.is_dir() {
            return Some(user);
        }
    }
    app.path()
        .resolve("agentic-ui-dist", tauri::path::BaseDirectory::Resource)
        .ok()
        .filter(|p| p.is_dir())
}

fn content_type_for(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("js") | Some("mjs") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn agentic_ui_serve_once(dist_dir: std::path::PathBuf, port: u16, local: bool) {
    static CLOUD_STARTED: std::sync::Once = std::sync::Once::new();
    static LOCAL_STARTED: std::sync::Once = std::sync::Once::new();
    let once = if local { &LOCAL_STARTED } else { &CLOUD_STARTED };
    once.call_once(|| agentic_ui_serve(dist_dir, port, local));
}

// `local` selects which goosed this static agentic-ui build talks to:
// false = remote my-ai-api goosed (10.0.0.6:3227, cloud-agentic tab),
// true  = `goose serve` spawned locally by this app (goose-desktop tab).
fn agentic_ui_serve(dist_dir: std::path::PathBuf, port: u16, local: bool) {
    std::thread::spawn(move || {
        let server = match tiny_http::Server::http(("127.0.0.1", port)) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("agentic-ui: static server bind failed on :{port}: {e}");
                return;
            }
        };
        for req in server.incoming_requests() {
            let url_path = req.url().trim_start_matches('/');
            if url_path == "config.json" {
                let (goosed_url, secret) = if local {
                    local_goose_ensure_running();
                    (format!("http://127.0.0.1:{LOCAL_GOOSE_PORT}"), LOCAL_GOOSE_SECRET.to_string())
                } else {
                    // GOOSE_SERVER__SECRET_KEY: same env var my-ai-api's container reads
                    // from sops (see da_my-ai/core/src/lib.rs). Empty if unset — the UI
                    // then shows a connection error rather than silently no-op'ing.
                    ("http://10.0.0.6:3227".to_string(), std::env::var("GOOSE_SERVER__SECRET_KEY").unwrap_or_default())
                };
                let body = serde_json::json!({
                    "goosedUrl": goosed_url,
                    "secretKey": secret,
                })
                .to_string();
                let resp = tiny_http::Response::from_string(body).with_header(
                    tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..])
                        .unwrap(),
                );
                let _ = req.respond(resp);
                continue;
            }
            let rel = if url_path.is_empty() { "index.html" } else { url_path };
            let mut file_path = dist_dir.join(rel);
            if !file_path.is_file() {
                file_path = dist_dir.join("index.html"); // SPA fallback
            }
            match std::fs::read(&file_path) {
                Ok(bytes) => {
                    let ct = content_type_for(&file_path);
                    let resp = tiny_http::Response::from_data(bytes).with_header(
                        tiny_http::Header::from_bytes(&b"Content-Type"[..], ct.as_bytes()).unwrap(),
                    );
                    let _ = req.respond(resp);
                }
                Err(_) => {
                    let _ = req.respond(tiny_http::Response::from_string("not found").with_status_code(404));
                }
            }
        }
    });
}

// ── System tray icons — my-konsole IS the systray daemon. No separate
// per-tray process, no python/GTK, no nix module: build.sh install writes
// ~/.local/share/my-konsole/systrays.json (mirrored from configs/systrays.json,
// same user-dir-first convention as profiles/config) and a systemd --user
// service running `my-konsole --tray-daemon` (Restart=always). Every enabled
// tray in that manifest becomes a real StatusNotifierItem via Tauri's native
// tray-icon feature; each menu item just shell-execs its `command`.
fn load_systrays() -> serde_json::Value {
    if let Some(home) = std::env::var_os("HOME") {
        let user = std::path::Path::new(&home).join(".local/share/my-konsole/systrays.json");
        if let Ok(txt) = std::fs::read_to_string(&user) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                return v;
            }
        }
    }
    serde_json::json!({ "trays": [] })
}

// Rasterise configs/systray-icons/<name>.svg to 32x32 RGBA (R,G,B,A per
// pixel). Same user-dir-first lookup as profiles/config: build.sh install
// mirrors the repo's icons into ~/.local/share/my-konsole/systray-icons/.
// Returns raw RGBA rather than a tauri::image::Image — ksni::Icon wants its
// own ARGB32 layout (see rgba_to_ksni_icon), not Tauri's image type.
pub(crate) fn load_systray_icon(name: &str) -> Option<(Vec<u8>, u32, u32)> {
    const SIZE: u32 = 32;
    let home = std::env::var_os("HOME")?;
    let path = std::path::Path::new(&home)
        .join(".local/share/my-konsole/systray-icons")
        .join(format!("{name}.svg"));
    let data = std::fs::read(&path).ok()?;
    let tree = resvg::usvg::Tree::from_data(&data, &resvg::usvg::Options::default()).ok()?;
    let mut pixmap = resvg::tiny_skia::Pixmap::new(SIZE, SIZE)?;
    let s = tree.size();
    // Fit the SVG's own viewBox into 32x32 rather than assuming it is already
    // that size — the icons are authored at whatever viewBox reads clearly.
    let scale = (SIZE as f32 / s.width()).min(SIZE as f32 / s.height());
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale, scale),
        &mut pixmap.as_mut(),
    );
    Some((pixmap.take(), SIZE, SIZE))
}

// resvg/tiny_skia gives RGBA8 (R,G,B,A per pixel, premultiplied). ksni::Icon
// wants ARGB32 "network byte order", i.e. each pixel's bytes in the order
// A,R,G,B — getting this wrong doesn't error, it just silently swaps
// channels, so verify against a real render rather than trusting the compile.
pub(crate) fn rgba_to_ksni_icon(rgba: Vec<u8>, width: u32, height: u32) -> ksni::Icon {
    let mut argb = Vec::with_capacity(rgba.len());
    for px in rgba.chunks_exact(4) {
        let [r, g, b, a] = [px[0], px[1], px[2], px[3]];
        argb.extend_from_slice(&[a, r, g, b]);
    }
    ksni::Icon { width: width as i32, height: height as i32, data: argb }
}

// One ksni::Tray impl per enabled entry in systrays.json. NOT Tauri's
// tray-icon feature — see the comment on the ksni dependency in Cargo.toml:
// tray-icon's tooltip is a documented no-op on Linux, which is the whole
// reason this exists. Someone will otherwise "simplify" this back to
// TrayIconBuilder and silently reintroduce the bug.
// A menu entry is either a leaf that shell-execs, a submenu, or a separator.
// Nested rather than flat because the cloud-mesh tray grew past 30 entries and
// a single column that tall is unusable — see parse_menu for the JSON shape.
enum MenuNode {
    Item { label: String, command: String },
    Sub { label: String, children: Vec<MenuNode> },
    Separator,
}

// systrays.json menu grammar (all backwards-compatible — a plain
// {label, command} list still works exactly as before):
//   { "label": "...", "command": "..."   }  → clickable item
//   { "label": "...", "submenu": [ ... ]  }  → parent, recurses
//   { "separator": true }  or  "-"           → separator rule
fn parse_menu(items: &[serde_json::Value]) -> Vec<MenuNode> {
    items
        .iter()
        .filter_map(|item| {
            if item.as_str() == Some("-")
                || item.get("separator").and_then(|v| v.as_bool()).unwrap_or(false)
            {
                return Some(MenuNode::Separator);
            }
            let label = item.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
            if let Some(kids) = item.get("submenu").and_then(|v| v.as_array()) {
                return Some(MenuNode::Sub { label, children: parse_menu(kids) });
            }
            let command = item.get("command").and_then(|v| v.as_str()).unwrap_or("").to_string();
            if label.is_empty() && command.is_empty() {
                return None;
            }
            Some(MenuNode::Item { label, command })
        })
        .collect()
}

struct SystrayItem {
    id: String,
    title: String,
    profile: String,
    icon: Option<ksni::Icon>,
    default_command: String,
    menu: Vec<MenuNode>,
}

// Recursive because MenuNode is; ksni::menu::SubMenu nests MenuItem<T> the
// same way, so one function covers any depth.
fn build_menu(nodes: &[MenuNode]) -> Vec<ksni::MenuItem<SystrayItem>> {
    nodes
        .iter()
        .map(|node| match node {
            MenuNode::Separator => ksni::MenuItem::Separator,
            MenuNode::Sub { label, children } => ksni::menu::SubMenu {
                label: label.clone(),
                submenu: build_menu(children),
                ..Default::default()
            }
            .into(),
            MenuNode::Item { label, command } => {
                let cmd = command.clone();
                ksni::menu::StandardItem {
                    label: label.clone(),
                    activate: Box::new(move |_this: &mut SystrayItem| {
                        let _ = std::process::Command::new("sh").arg("-c").arg(&cmd).spawn();
                    }),
                    ..Default::default()
                }
                .into()
            }
        })
        .collect()
}

impl ksni::Tray for SystrayItem {
    fn id(&self) -> String {
        self.id.clone()
    }
    fn title(&self) -> String {
        self.title.clone()
    }
    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        self.icon.clone().into_iter().collect()
    }
    // The entire point of this rewrite: KDE reads ToolTip.title on hover,
    // where tray-icon's `.tooltip()` was silently discarded on Linux.
    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: self.title.clone(), description: self.profile.clone(), ..Default::default() }
    }
    // Primary click. `default_command` was declared in systrays.json and read
    // by nothing until now — wiring it here makes the manifest honest.
    fn activate(&mut self, _x: i32, _y: i32) {
        if !self.default_command.is_empty() {
            let _ = std::process::Command::new("sh").arg("-c").arg(&self.default_command).spawn();
        }
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        build_menu(&self.menu)
    }
}

fn setup_systrays(app: &tauri::App) {
    use ksni::blocking::TrayMethods;

    let data = load_systrays();
    let trays = data
        .get("trays")
        .and_then(|t| t.as_array())
        .cloned()
        .unwrap_or_default();
    // NOT app.default_window_icon(): on this platform it returns a raw RGBA
    // buffer whose length doesn't match its own reported width/height (a 2x
    // HiDPI variant leaking through). Decode the bundled 32x32 PNG ourselves
    // instead — Image has no from_path in this tauri version, only
    // new_owned(rgba, width, height).
    let app_icon = app
        .path()
        .resolve("icons/32x32.png", tauri::path::BaseDirectory::Resource)
        .ok()
        .and_then(|p| image::open(p).ok())
        .map(|img| {
            let rgba = img.to_rgba8();
            let (w, h) = (rgba.width(), rgba.height());
            rgba_to_ksni_icon(rgba.into_raw(), w, h)
        });

    // ksni::blocking spawns each tray on its own background D-Bus connection
    // and hands back a Handle used only for later updates/shutdown — nothing
    // in this daemon calls either, but the Handle must outlive setup_systrays
    // or the tray's D-Bus service goes away with it. Leak the Vec: this is a
    // --tray-daemon process that lives for the systemd service's lifetime.
    let mut handles = Vec::new();

    for tray in trays {
        if !tray.get("enable").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        let id = tray.get("id").and_then(|v| v.as_str()).unwrap_or("systray").to_string();
        let title = tray.get("title").and_then(|v| v.as_str()).unwrap_or(&id).to_string();
        let profile = tray.get("profile").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let default_command = tray.get("default_command").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let menu_items = tray.get("menu").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        let menu = parse_menu(&menu_items);

        // Per-tray icon, app icon only as the fallback. Every tray used to get
        // the app icon unconditionally and the manifest's `icon` field was
        // read by nothing — so seven trays showed seven copies of the same
        // my-konsole logo and were impossible to tell apart in the tray.
        let icon = tray
            .get("icon")
            .and_then(|v| v.as_str())
            .and_then(load_systray_icon)
            .map(|(rgba, w, h)| rgba_to_ksni_icon(rgba, w, h))
            .or_else(|| app_icon.clone());

        let item = SystrayItem { id: id.clone(), title, profile, icon, default_command, menu };
        match item.spawn() {
            Ok(handle) => handles.push(handle),
            Err(e) => eprintln!("systray: failed to build tray '{id}': {e}"),
        }
    }

    Box::leak(Box::new(handles));
}

fn main() {
    // NOTE: do NOT set WEBKIT_DISABLE_COMPOSITING_MODE here. It was added as a
    // preemptive mitigation for wry#1727's GtkFixed glitches, but it applies to
    // the MAIN UI webview too, and on Wayland WebKitGTK's non-composited path
    // is broken — it froze the whole app at launch. If fixed-parent embeds
    // glitch, set it per-run from the environment instead.
    // Intercepted BEFORE Tauri boots: this is how `wl-paste --watch` re-
    // invokes this same binary on every clipboard change (see
    // clipboard::spawn_capture) — a short-lived, non-GUI run that just
    // forwards captured stdin to the already-running tray daemon over a
    // Unix socket, then exits. See clipboard.rs's module doc.
    if std::env::args().any(|a| a == "--clip-sink") {
        clipboard::run_clip_sink();
        return;
    }
    let tray_daemon = std::env::args().any(|a| a == "--tray-daemon");
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(PtyBroker::new())
        .manage(GlobCache::default())
        .setup(move |app| {
            // agentic-ui's static server(s) + the local `goose serve` are started
            // lazily from ensure_agentic_backend when their tab is actually opened, not here.
            if agentic_ui_dist_dir(app.handle()).is_none() {
                eprintln!("agentic-ui: no dist dir found (fetch it via build.sh fetch) — tab will fail to load");
            }
            // Embed layer surgery happens HERE, not lazily inside a
            // run_on_main_thread closure: tauri window getters (gtk_window)
            // are blocking round-trips through the event loop, and calling one
            // FROM the loop (which is what a run_on_main_thread closure is)
            // deadlocks the main thread — the app froze at startup the moment
            // a restored browser tab triggered embed_open. In setup we are on
            // the main thread before the loop owns dispatch, so it's safe.
            if embeds_enabled() {
                if let Some(win) = app.handle().get_window("main") {
                    match embed_fixed_setup(&win) {
                        Ok(()) => eprintln!("[embed] fixed layer installed"),
                        Err(e) => eprintln!("[embed] setup failed (embeds disabled): {e}"),
                    }
                }
            }
            // --tray-daemon: this launch exists only to host the persistent tray
            // icons (systemd --user service) — hide the terminal window instead
            // of showing it, so it doesn't pop a Konsole-alternative window at login.
            //
            // setup_systrays MUST stay inside this branch. The daemon (Restart=always,
            // enabled by build.sh install) is the sole owner of the tray icons; a plain
            // GUI launch is always a second, ordinary window on top of that daemon, never
            // a substitute for it, so it has no reason to spawn its own copies. Calling
            // setup_systrays unconditionally here — once per process, with no coordination
            // between them — is exactly what produced every tray showing up twice. Nothing
            // else in the GUI process reads its return value or depends on it having run.
            if tray_daemon {
                setup_systrays(app);
                // The sampler is my-watchdog's now, not ours. It is its own
                // product with its own tray and its own systemd unit, and it
                // runs whether or not a terminal emulator happens to be up —
                // which is the whole reason it moved out. my-konsole reads the
                // snapshot like every other consumer.
                // Second native ksni tray, same "ONE publisher" rule as the
                // trays above — see clipboard.rs's module doc for why it is
                // NOT one more entry in systrays.json.
                clipboard::spawn();
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            pty_start, pty_write, pty_resize, pty_kill, get_profiles, get_config,
            fs_list_dir, fs_read_file, fs_write_file, fs_glob, which_all,
            ensure_agentic_backend,
            browser_popout,
            embed_open, embed_bounds, embed_navigate, embed_back, embed_close
        ])
        .run(tauri::generate_context!())
        .expect("error while running my-konsole");
}
