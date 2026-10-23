# my-ai

Claude Code via the Headroom compression proxy. Rebrand of `claude-superset`.

- `my-ai` — CLI: faces (`remote`/`local`/`claude`), `restore`/`sync`, `setup`, `--help`.
- `my-ai-gui` — Tauri desktop app + systray (Phase 4).

`my-ai-dash` (the ratatui TTY dashboard) has been discontinued — `my-ai --help` is
now the sole helper surface.

Built on GHA, published to the rolling `my-ai-latest` release, pulled via `./build.sh fetch`.
Never built on the Surface (freeze-guard). See `build.json` for the data-driven config.

## Engines

my-ai is an orchestrator of routines ("engines"). Each lives in `engines/<name>/` with its own
README and a `manifest.json` (name, trigger `daemon-start|timer|on-demand`, inputs, outputs, run).
The CLI embeds the manifests (`core/src/engines.rs`): `my-ai engine list | run <name> [-- args] | status`.
Config stays declarative (`data/`); engines only apply it. Engines: statusline-assets, scripts-assets,
usage, dash, tray, claude-config, mcp-templates, dotfiles. New engine = folder + manifest + README +
one `REGISTRY` line (checked by `cargo test` and `data/claude/test-claude-sot.sh`).
