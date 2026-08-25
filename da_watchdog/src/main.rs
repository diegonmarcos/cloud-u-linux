// my-watchdog — the machine sampler, as its own product.
//
// WHY THIS IS NOT PART OF my-konsole ANY MORE
// The sampler was a module inside a Tauri terminal emulator. Everything that
// reads its output — the dash, the QML widget, the panel itself — talks to it
// through one file and one mailbox, never through a function call, so the
// coupling was already nothing but the process it happened to live in. That
// had two real costs: the sampler could only run when a GUI terminal was
// running, and every change to it meant rebuilding a Tauri app.
//
// Split out, my-konsole becomes what it always was in practice — a consumer —
// and this becomes a small std+libc binary that can run headless on any box.
//
// WHAT IT PUBLISHES, AND WHY THE NAMES DID NOT CHANGE
// $XDG_RUNTIME_DIR/my-konsole-watchdog.json and .kill keep their names. They
// are a contract with consumers already reading them; renaming a file to match
// a repo layout would break all of them and buy nothing.
//
// THE MAILBOX IS THE SAFETY BOUNDARY
// A kill, a restart, a unit verb or a reclaim is a line appended to the
// mailbox. This process drains it and applies the protected-slice policy. No
// consumer decides anything — a panel dimming a row is a courtesy, and if it
// were the boundary it would be one an unprivileged edit could step around.
mod watchdog;

use std::sync::{Arc, Mutex};

/// What the tray shows and what its menu acts on. Refreshed from the snapshot
/// this process just wrote, so the tray can never disagree with the file.
#[derive(Default)]
struct Vitals {
    cpu: f64,
    mem: f64,
    swap: f64,
    psi: f64,
    procs: usize,
}

struct Tray {
    v: Arc<Mutex<Vitals>>,
}

impl ksni::Tray for Tray {
    fn id(&self) -> String {
        "my-watchdog".into()
    }
    fn title(&self) -> String {
        let v = self.v.lock().map(|v| (v.cpu, v.mem, v.psi)).unwrap_or((0.0, 0.0, 0.0));
        format!("cpu {:.0}%  mem {:.0}%  psi {:.1}", v.0, v.1, v.2)
    }
    /// A themed icon name rather than a bundled pixmap: this binary has no
    /// asset directory, and every desktop already ships a system-monitor icon.
    fn icon_name(&self) -> String {
        "utilities-system-monitor".into()
    }
    fn tool_tip(&self) -> ksni::ToolTip {
        let (cpu, mem, swap, psi, procs) = self
            .v
            .lock()
            .map(|v| (v.cpu, v.mem, v.swap, v.psi, v.procs))
            .unwrap_or_default();
        ksni::ToolTip {
            title: "my-watchdog".into(),
            description: format!(
                "cpu {cpu:.1}%   mem {mem:.1}%   swap {swap:.1}%\npressure {psi:.2}   {procs} processes\npublishing every {}ms",
                watchdog::interval_ms()
            ),
            ..Default::default()
        }
    }
    /// Primary click opens the panel that reads this snapshot. The dash is the
    /// consumer, so the tray for the publisher points at it rather than
    /// reimplementing a view of its own.
    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = std::process::Command::new("sh")
            .arg("-c")
            .arg("my-konsole-dash monitor 2>/dev/null || konsole -e my-konsole-dash monitor")
            .spawn();
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;
        vec![
            StandardItem {
                label: "Open monitor".into(),
                activate: Box::new(|t: &mut Tray| t.activate(0, 0)),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit".into(),
                // Leaves the last snapshot in place on purpose: consumers show
                // its age, and a file that vanished would read as "the panel
                // is broken" rather than "the sampler was stopped".
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |f: &str| args.iter().any(|a| a == f);

    if flag("--help") || flag("-h") {
        println!(
            "usage: my-watchdog [--no-tray] [--once]\n\
             \n\
             Samples this machine every {}ms and publishes one JSON snapshot,\n\
             then drains the kill/restart mailbox beside it.\n\
             \n\
             --no-tray   run headless (systemd, a server, a container)\n\
             --once      write one snapshot to stdout and exit",
            watchdog::interval_ms()
        );
        return;
    }

    if flag("--once") {
        // One sample has no deltas to compute a rate from, so this is the
        // shape of the snapshot rather than a useful measurement of it — for
        // checking the contract, not for reading numbers off.
        println!("{}", watchdog::snapshot_once());
        return;
    }

    watchdog::spawn();

    if flag("--no-tray") {
        // Nothing to do on this thread but stay alive: the sampler owns its
        // own. Parking rather than looping so an idle watchdog costs nothing.
        loop {
            std::thread::park();
        }
    }

    let v = Arc::new(Mutex::new(Vitals::default()));
    {
        let v = v.clone();
        std::thread::spawn(move || loop {
            // Read back the file this process just wrote, rather than reaching
            // into the sampler: the tray then shows exactly what consumers
            // see, and a publish that failed shows as a stale tray instead of
            // a tray that disagrees with every other reader.
            if let Some(s) = watchdog::snapshot_path().and_then(|p| std::fs::read_to_string(p).ok()) {
                let n = |k: &str| -> f64 {
                    s.split(&format!("\"{k}\":"))
                        .nth(1)
                        .and_then(|r| {
                            r.split(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-'))
                                .find(|x| !x.is_empty())
                        })
                        .and_then(|x| x.parse().ok())
                        .unwrap_or(0.0)
                };
                if let Ok(mut g) = v.lock() {
                    g.cpu = n("cpu");
                    g.mem = n("mem");
                    g.swap = n("swap");
                    g.psi = n("some10");
                    g.procs = s.matches("\"pid\":").count();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(watchdog::interval_ms()));
        });
    }

    use ksni::blocking::TrayMethods;
    match (Tray { v }).disable_dbus_name(true).spawn() {
        Ok(_) => loop {
            std::thread::park();
        },
        Err(e) => {
            // No StatusNotifier host — a plain tty, a server, a session with no
            // tray. That is not a reason to stop sampling, which is the part
            // anything else depends on.
            eprintln!("[my-watchdog] no systray ({e}); sampling anyway");
            loop {
                std::thread::park();
            }
        }
    }
}
