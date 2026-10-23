# usage

Trigger: `on-demand`. Code: `usage.rs` (mounted into `my-ai-core`, CLI glue in `cli/src/main.rs`).

Native ccusage-equivalent token counter over `~/.claude/projects`. `my-ai engine run usage -- <flags>`
forwards to `my-ai usage` (`--json`, `--statusline`, `--daemon`). The `--daemon` mode is the
long-lived publisher that fires the `daemon-start` engines (statusline-assets, tray).
