// my-watchdog-tui — the panel, as its own program.
//
// The sampler publishes a snapshot and drains a mailbox; this draws that
// snapshot and posts to that mailbox. They are two halves of one product and
// were split across two repos only because the panel was first written as a
// dashboard inside a terminal emulator.
//
// A separate BINARY rather than a subcommand of my-watchdog, because the
// daemon runs on every box in the fleet and most of them are headless: making
// `my-watchdog` carry ratatui would triple the thing that has to be small,
// to ship a UI no server will draw.
//
//   my-watchdog-tui                    the panel
//   my-watchdog-tui export             the HTML report, no terminal needed
//   my-watchdog-tui tui [cols] [rows]  one screen as HTML, to stdout
//   my-watchdog-tui tui --serve        keys on stdin, frames on stdout
//   my-watchdog-tui snapshot [alias]   the numbers, no UI — this box or a peer
//   my-watchdog-tui app-shell          the UI, no machine in it
fn main() -> std::io::Result<()> {
    my_watchdog::tui::run(std::env::args().skip(1).collect())
}
