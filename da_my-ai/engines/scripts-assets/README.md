# scripts-assets

Trigger: `on-demand` (the CLI also runs it on every launch; content-compared, cheap no-op).
Code: `scripts_assets.rs`; data: `scripts/` (claude, claude-superset, goose helpers), embedded
with `include_str!` and extracted to `~/.local/bin`. `my-ai engine run scripts-assets` = `my-ai sync-scripts`.
