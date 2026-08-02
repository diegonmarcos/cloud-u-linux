//! Real system tray for `my-ai usage --daemon`, via ksni (StatusNotifierItem),
//! not Tauri. Modeled on da_my-konsole/src-tauri/src/main.rs's setup_systrays:
//! same ksni::Tray impl shape, same rgba_to_ksni_icon ARGB32 conversion, same
//! ksni::blocking::TrayMethods::spawn usage — but this daemon has no webview at
//! all (see build.sh / part-C notes on why my-ai-gui's Tauri webview is the
//! wrong thing to run as this unit's ExecStart). da_my-ai has no configs/*.json
//! menu-manifest pattern (unlike da_my-konsole's configs/systrays.json), and a
//! single fixed tray with four fixed actions doesn't warrant inventing one —
//! the menu is hardcoded below.
//!
//! Tray creation is best-effort: usage_daemon() must keep publishing even if
//! the desktop has no D-Bus session, no StatusNotifierWatcher, or any other
//! reason ksni fails to register. Nothing here may take the publish loop down.

use my_ai_core as core;

/// 32x32 RGBA PNG, baked into the binary — same asset src-tauri/gui already
/// ships as its tray/window icon, so the headless tray matches it instead of
/// depending on an install-time asset copy this crate has no part in.
static ICON_PNG: &[u8] = include_bytes!("../../src-tauri/icons/32x32.png");

/// resvg/tiny_skia gives RGBA8 (R,G,B,A per pixel); ksni::Icon wants ARGB32
/// "network byte order" (A,R,G,B per pixel) — getting this wrong doesn't
/// error, it silently swaps channels. Copied verbatim from da_my-konsole's
/// rgba_to_ksni_icon.
fn rgba_to_ksni_icon(rgba: Vec<u8>, width: u32, height: u32) -> ksni::Icon {
    let mut argb = Vec::with_capacity(rgba.len());
    for px in rgba.chunks_exact(4) {
        let [r, g, b, a] = [px[0], px[1], px[2], px[3]];
        argb.extend_from_slice(&[a, r, g, b]);
    }
    ksni::Icon { width: width as i32, height: height as i32, data: argb }
}

fn load_icon() -> Option<ksni::Icon> {
    let img = image::load_from_memory(ICON_PNG).ok()?;
    let rgba = img.to_rgba8();
    let (w, h) = (rgba.width(), rgba.height());
    Some(rgba_to_ksni_icon(rgba.into_raw(), w, h))
}

/// Tooltip text, updated every publish tick by `update()`.
pub struct UsageTray {
    tooltip: String,
}

impl ksni::Tray for UsageTray {
    fn id(&self) -> String {
        "my-ai-usage".into()
    }
    fn title(&self) -> String {
        "my-AI usage".into()
    }
    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        load_icon().into_iter().collect()
    }
    // KDE reads ToolTip.title on hover — this is the whole reason this is
    // ksni and not Tauri's tray-icon feature (a documented no-op on Linux).
    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: self.tooltip.clone(), ..Default::default() }
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;
        let run = |cmd: &'static str| -> Box<dyn Fn(&mut Self) + Send + Sync> {
            Box::new(move |_this: &mut Self| {
                let _ = std::process::Command::new("sh").arg("-c").arg(cmd).spawn();
            })
        };
        vec![
            StandardItem {
                label: "Daemon: status".into(),
                activate: run("systemctl --user status my-ai-usage.service --no-pager"),
                ..Default::default()
            }
            .into(),
            // Wired but never invoked by this process — restarting the unit
            // that is running this very tray is a user action, not something
            // the daemon triggers on itself.
            StandardItem {
                label: "Daemon: restart".into(),
                activate: run("systemctl --user restart my-ai-usage.service"),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Open log".into(),
                activate: run("journalctl --user -u my-ai-usage.service -n 200 --no-pager"),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Open usage JSON".into(),
                activate: Box::new(|_this: &mut Self| {
                    let path = core::usage::snapshot_path();
                    let _ = std::process::Command::new("xdg-open").arg(path).spawn();
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

/// A live handle to the spawned tray, used only to push tooltip updates —
/// nothing here depends on menu/click state surviving a restart.
pub struct TrayHandle(ksni::blocking::Handle<UsageTray>);

impl TrayHandle {
    /// Push the current 5h totals into the tooltip. Takes the already-rendered
    /// `05h-T` line (from `Scanner::statusline`, the same string this tick just
    /// published to the `.seg` file) plus the summed `05h-S` totals already
    /// present in the just-published snapshot JSON — no separate transcript
    /// scan, just reusing what usage_daemon's tick already computed.
    pub fn update(&self, seg_line: &str, snapshot_json: &str) {
        let text = build_tooltip(seg_line, snapshot_json);
        let h = self.0.clone();
        // update() blocks on the tray's own D-Bus connection; run it off the
        // publish loop's thread so a slow/dead session bus can't stall ticks.
        std::thread::spawn(move || {
            h.update(|tray: &mut UsageTray| tray.tooltip = text);
        });
    }
}

/// Fold the pre-rendered `05h-T` seg line and the `block_sessions` totals
/// already sitting in this tick's snapshot JSON into one tooltip string. Pure
/// string/JSON-value work over data the daemon already computed — no scan.
fn build_tooltip(seg_line: &str, snapshot_json: &str) -> String {
    let seg = core::usage::strip_ansi(seg_line).trim().to_string();
    let seg = if seg.is_empty() { "05h-T: idle".to_string() } else { seg };

    let sessions_total: u64 = serde_json::from_str::<serde_json::Value>(snapshot_json)
        .ok()
        .and_then(|v| v.get("block_sessions").cloned())
        .and_then(|v| v.as_object().cloned())
        .map(|m| {
            m.values()
                .filter_map(|s| {
                    let g = |k: &str| s.get(k).and_then(|n| n.as_u64()).unwrap_or(0);
                    Some(g("input") + g("output") + g("cache_read") + g("cache_write"))
                })
                .sum()
        })
        .unwrap_or(0);

    format!("{seg}\n05h-S: Σ{sessions_total} tok across active sessions")
}

/// Attempt to spawn the tray. Only called when a display is present (the
/// caller checks $WAYLAND_DISPLAY / $DISPLAY — same signal build.sh's wrapper
/// already gates the GUI on). Returns None on any failure; the caller logs
/// once and keeps publishing without a tray, per the daemon's own contract
/// that a scan/publish failure is never fatal.
pub fn try_spawn() -> Option<TrayHandle> {
    use ksni::blocking::TrayMethods;
    let tray = UsageTray { tooltip: "my-AI usage: starting…".into() };
    match tray.spawn() {
        Ok(handle) => Some(TrayHandle(handle)),
        Err(e) => {
            eprintln!("[my-ai] usage daemon: tray unavailable, continuing headless: {e}");
            None
        }
    }
}
