# statusline-assets

Trigger: `daemon-start`. Code: `statusline_assets.rs` (mounted into `my-ai-core`).

Embeds `data/statusline/*.sh` and `data/pricing.json` via `include_str!` and writes them to
`~/.claude` (or `$CLAUDE_CONFIG_DIR`) when content differs. The usage daemon calls it on every
start, so the scripts can never drift from the binary. No flake may declare these files; see
`data/claude/README.md` delivery path 1. `my-ai engine run statusline-assets` runs it by hand.
