//! `my-ai` — Claude Code via the Headroom proxy. CLI faces + session actions.
//! Phase 1: argument surface + wiring skeleton (routing lands in Phase 2).
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "my-ai", version, about = "Claude Code via the Headroom compression proxy")]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Route through the oci-apps proxy over WireGuard (default face).
    Remote { args: Vec<String> },
    /// Run the same container on THIS host (docker compose, 127.0.0.1).
    Local { args: Vec<String> },
    /// Bypass everything — plain claude, no proxy/engine/plugins.
    Claude { args: Vec<String> },
    /// Reopen this device's last N sessions, one per tab.
    Restore { n: Option<u32> },
    /// Push the last N local sessions to the hub.
    Sync,
    /// Ensure `claude` is installed (native, no npm).
    Setup { args: Vec<String> },
    /// Live TTY dashboard (launches my-ai-dash).
    Dash,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let ep = my_ai_core::endpoints()?;
    match cli.cmd {
        None => println!("my-ai {} — run `my-ai dash` for the dashboard, `my-ai remote` to launch.", my_ai_core::version()),
        Some(Cmd::Remote { .. }) => println!("[phase1] remote face -> proxy {}", ep.proxy),
        Some(Cmd::Local { .. })  => println!("[phase1] local face -> {}", ep.api),
        Some(Cmd::Claude { .. }) => println!("[phase1] claude face -> {} (bypass)", ep.anthropic),
        Some(Cmd::Restore { n })  => println!("[phase1] restore last {}", n.unwrap_or(5)),
        Some(Cmd::Sync)           => println!("[phase1] sync last {} to {}", ep.sync_keep, ep.api),
        Some(Cmd::Setup { .. })   => println!("[phase1] setup (native installer)"),
        Some(Cmd::Dash)           => println!("[phase1] would launch my-ai-dash"),
    }
    Ok(())
}
