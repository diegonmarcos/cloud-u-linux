// The panel: my-watchdog's own terminal UI.
//
// WHY IT LIVES HERE NOW
// This was a dashboard inside my-konsole — one of seven subcommands of a
// terminal emulator's companion binary — and my-watchdog was a module inside
// the same emulator until it was split out. Only half that split happened: the
// sampler left, the VIEWER of what the sampler publishes stayed behind, so the
// watchdog's own panel belonged to another product and an app called
// cloud-watchdog had to invoke `my-konsole-dash` to see a watchdog.
//
// The coupling was never real. This whole tree referenced exactly three paths
// outside itself — Dashboard, the mesh peer list, and its own module root —
// and konsole was an inspiration for the shape, not a dependency of it.
//
// WHY IT IS A FEATURE, AND OFF BY DEFAULT
// The daemon is deliberately std + libc: no D-Bus, no JSON crate, which is what
// lets it cross-compile to a static musl binary that runs on any Linux of that
// architecture. ratatui and crossterm would triple an 800KB sampler to carry a
// UI no headless VM will ever draw. So the fleet builds the daemon alone and a
// desktop builds `--features tui`, from the same source.
pub mod frame;
pub mod mesh;
pub mod monitor;
pub mod ui;

/// Every entry point the panel has, in one place.
///
/// Argument shapes kept from the my-konsole-dash era on purpose: scripts, the
/// phone app and the export cron all name these, and renaming a verb to tidy
/// up a move is how a rename becomes an outage.
pub fn run(args: Vec<String>) -> std::io::Result<()> {
    let cmd = args.first().map(String::as_str).unwrap_or("");

    // Write the HTML report and exit — no terminal, so cron and hooks can
    // refresh it. A page only a human at a keyboard can regenerate is a page
    // that is always stale.
    if cmd == "export" {
        match monitor::export_headless() {
            Ok(stem) => println!("{stem}.json .yaml .md · page + json → ~/.watchdog/html"),
            Err(e) => {
                eprintln!("my-watchdog-tui export: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // One screen as HTML, for a caller that has a WebView and no terminal —
    // or, with --serve, the panel driven from stdin a key at a time.
    if cmd == "tui" {
        let n = |k: usize, d: u16| {
            args.iter().filter(|a| *a != "--serve").nth(k).and_then(|x| x.parse().ok()).unwrap_or(d)
        };
        if args.iter().any(|a| a == "--serve") {
            if let Err(e) = monitor::serve(n(1, 200), n(2, 64)) {
                eprintln!("my-watchdog-tui tui --serve: {e}");
                std::process::exit(1);
            }
            return Ok(());
        }
        match monitor::tui_at(n(1, 200), n(2, 64)) {
            Ok(html) => println!("{html}"),
            Err(e) => {
                eprintln!("my-watchdog-tui tui: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    let mut dash = monitor::Monitor::new();
    frame::run(&mut dash)
}
