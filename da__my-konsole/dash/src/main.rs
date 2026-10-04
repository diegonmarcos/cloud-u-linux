// my-konsole-dash — ratatui TUI dashboards, one per subcommand. Renders in a
// my-konsole pane, over SSH, or on a bare TTY (no webview).
//
// `monitor` is no longer here. It was my-watchdog's panel the whole time — it
// read my-watchdog's snapshot and posted to my-watchdog's mailbox — and it
// lived in this binary only because the sampler was once a module in this
// repo. The sampler was split out and the viewer was not, which left an app
// called cloud-watchdog invoking my-konsole-dash to see a watchdog. It is
// my-watchdog-tui now; konsole was an inspiration for the shape, never an
// owner of it.
mod ui;
mod frame;
mod dashboards;

use dashboards::*;

fn main() -> std::io::Result<()> {
    let name = std::env::args().nth(1).unwrap_or_else(|| "stack".into());


    let mut dash: Box<dyn frame::Dashboard> = match name.as_str() {
        "stack"    => Box::new(stack::Stack::new()),
        "journal"  => Box::new(journal::Journal::new()),
        "cloud"    => Box::new(cloud::Cloud::new()),
        "datasync" => Box::new(datasync::DataSync::new()),
        "agi"      => Box::new(agi::Agi::new()),
        "devctl"   => Box::new(devctl::DevCtl::new()),
        other => {
            eprintln!("my-konsole-dash: unknown dashboard '{other}'");
            eprintln!("  usage: my-konsole-dash [stack|journal|cloud|datasync|agi|devctl]");
            std::process::exit(2);
        }
    };
    frame::run(dash.as_mut())
}
