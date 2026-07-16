//! `my-ai-dash` — live single-screen dashboard (TTY).
//! Phase 1: skeleton banner. ratatui port of claude-superset-tui.mjs lands in Phase 3.
fn main() -> anyhow::Result<()> {
    let ep = my_ai_core::endpoints()?;
    println!("my-ai-dash {} (skeleton)", my_ai_core::version());
    println!("  api:    {}", ep.api);
    println!("  proxy:  {}", ep.proxy);
    println!("  ollama: {}", ep.ollama);
    println!("(ratatui dashboard arrives in Phase 3)");
    Ok(())
}
