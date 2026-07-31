//! my-ai-gui — Tauri v2 desktop app: a graphical port of the my-ai dashboard
//! (webview renders frontend/), plus a KDE systray with quick launch actions.
//! Dashboard data comes from `my-ai-dash --snapshot` (dash owns the probe logic);
//! launch actions shell out to `my-ai <face>` in a terminal.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;
use std::process::Command;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

/// A binary installed next to this one (my-ai / my-ai-dash), else bare name on PATH.
fn sibling(name: &str) -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join(name)))
        .filter(|p| p.exists())
        .unwrap_or_else(|| PathBuf::from(name))
}
fn which(bin: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|d| d.join(bin)).find(|p| p.exists()))
}

/// Open `my-ai <args>` inside a terminal emulator (claude needs a TTY).
fn open_terminal(args: &[String]) {
    let term = std::env::var("CAS_KONSOLE")
        .ok()
        .map(PathBuf::from)
        .or_else(|| which("konsole"))
        .or_else(|| which("x-terminal-emulator"))
        .or_else(|| which("xterm"));
    if let Some(t) = term {
        let _ = Command::new(t).arg("-e").arg(sibling("my-ai")).args(args).spawn();
    }
}
fn open_dash() {
    let term = which("konsole").or_else(|| which("x-terminal-emulator")).or_else(|| which("xterm"));
    if let Some(t) = term {
        let _ = Command::new(t).arg("-e").arg(sibling("my-ai-dash")).spawn();
    }
}

// ── webview commands (window.__TAURI__.core.invoke) ──────────────────────────
#[tauri::command]
fn snapshot() -> Result<serde_json::Value, String> {
    let out = Command::new(sibling("my-ai-dash")).arg("--snapshot").output().map_err(|e| e.to_string())?;
    serde_json::from_slice(&out.stdout).map_err(|e| format!("bad snapshot json: {e}"))
}

#[tauri::command]
fn launch(face: String, restore: Option<u32>) -> Result<(), String> {
    let mut args = vec![face];
    if let Some(n) = restore {
        args.push("restore".into());
        args.push(n.to_string());
    }
    open_terminal(&args);
    Ok(())
}

#[tauri::command]
fn sync_now() -> Result<(), String> {
    Command::new(sibling("my-ai")).arg("sync").spawn().map_err(|e| e.to_string())?;
    Ok(())
}

/// One scan+publish cycle for the in-process ccusage daemon. Returns the plain-text
/// segment for the tray, or None when idle (no active 5h block).
fn publish_once() -> Option<String> {
    let line = my_ai_core::usage::current_statusline(&my_ai_core::projects_dir()).ok()?;
    if line.trim().is_empty() {
        return None;
    }
    if let Err(e) = my_ai_core::usage::publish_seg(&line) {
        eprintln!("[my-ai-gui] usage publish failed: {e}");
    }
    Some(my_ai_core::usage::strip_ansi(&line).trim().to_string())
}

/// Reflect the latest segment in the tray: tooltip (hover) + the usage menu row.
fn show_usage(app: &AppHandle, item: &MenuItem<tauri::Wry>, text: Option<&str>) {
    let label = text.unwrap_or("5h usage: idle");
    let _ = item.set_text(label);
    if let Some(tray) = app.tray_by_id("my-ai-tray") {
        let _ = tray.set_tooltip(Some(label));
    }
}

fn handle_menu(app: &AppHandle, id: &str) {
    match id {
        "quit" => app.exit(0),
        // The usage row is a live readout, not a button — clicking it does nothing.
        "usage" => {}
        "sync" => {
            let _ = Command::new(sibling("my-ai")).arg("sync").spawn();
        }
        "dash" => open_dash(),
        "restore" => open_terminal(&["remote".into(), "restore".into(), "5".into()]),
        "show" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }
        face @ ("remote" | "local" | "claude") => open_terminal(&[face.to_string()]),
        _ => {}
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![snapshot, launch, sync_now])
        .setup(|app| {
            let usage = MenuItem::with_id(app, "usage", "5h usage: …", false, None::<&str>)?;
            let show = MenuItem::with_id(app, "show", "Open dashboard window", true, None::<&str>)?;
            let remote = MenuItem::with_id(app, "remote", "Launch: remote", true, None::<&str>)?;
            let local = MenuItem::with_id(app, "local", "Launch: local", true, None::<&str>)?;
            let claude = MenuItem::with_id(app, "claude", "Launch: claude (plain)", true, None::<&str>)?;
            let restore = MenuItem::with_id(app, "restore", "Restore last 5", true, None::<&str>)?;
            let sync = MenuItem::with_id(app, "sync", "Sync sessions now", true, None::<&str>)?;
            let dash = MenuItem::with_id(app, "dash", "Open TTY dashboard", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(
                app,
                &[&usage, &show, &remote, &local, &claude, &restore, &sync, &dash, &quit],
            )?;

            let icon = app.default_window_icon().cloned().expect("bundle icon required");
            TrayIconBuilder::with_id("my-ai-tray")
                .icon(icon)
                .tooltip("my-ai")
                .menu(&menu)
                .on_menu_event(|app, event| handle_menu(app, event.id.as_ref()))
                .build(app)?;

            // ccusage daemon, in-process. This is the producer the status line reads:
            // one publisher for the machine on a fixed interval, instead of a heavy
            // process per repaint per session. Runs on its own thread so a slow scan
            // never blocks the UI, and publishes before sleeping so the tray is
            // populated immediately rather than one interval late.
            let handle = app.handle().clone();
            std::thread::spawn(move || loop {
                let text = publish_once();
                let item = usage.clone();
                let h = handle.clone();
                // Menu/tray mutation must happen on the main thread.
                let _ = handle.run_on_main_thread(move || show_usage(&h, &item, text.as_deref()));
                std::thread::sleep(std::time::Duration::from_secs(
                    my_ai_core::usage::DAEMON_INTERVAL_SECS,
                ));
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running my-ai-gui");
}
