// my-konsole-dash — ratatui TUI dashboards, one per subcommand. Renders in a
// my-konsole pane, over SSH, or on a bare TTY (no webview). Ports cloud-terminal's
// 7 dashboards to terminal graphics.
mod ui;
mod frame;
mod dashboards;

use dashboards::*;

fn main() -> std::io::Result<()> {
    let name = std::env::args().nth(1).unwrap_or_else(|| "monitor".into());
    let mut dash: Box<dyn frame::Dashboard> = match name.as_str() {
        "monitor"  => Box::new(monitor::Monitor::new()),
        "stack"    => Box::new(stack::Stack::new()),
        "journal"  => Box::new(journal::Journal::new()),
        "cloud"    => Box::new(cloud::Cloud::new()),
        "datasync" => Box::new(datasync::DataSync::new()),
        "agi"      => Box::new(agi::Agi::new()),
        "devctl"   => Box::new(devctl::DevCtl::new()),
        other => {
            eprintln!("my-konsole-dash: unknown dashboard '{other}'");
            eprintln!("  usage: my-konsole-dash [monitor|stack|journal|cloud|datasync|agi|devctl]");
            std::process::exit(2);
        }
    };
    frame::run(dash.as_mut())
}
