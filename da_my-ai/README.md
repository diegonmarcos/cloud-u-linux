# my-ai

Claude Code via the Headroom compression proxy. Rebrand of `claude-superset`.

- `my-ai` — CLI: faces (`remote`/`local`/`claude`), `restore`/`sync`, `setup`, `--help`.
- `my-ai-gui` — Tauri desktop app + systray (Phase 4).

`my-ai-dash` (the ratatui TTY dashboard) has been discontinued — `my-ai --help` is
now the sole helper surface.

Built on GHA, published to the rolling `my-ai-latest` release, pulled via `./build.sh fetch`.
Never built on the Surface (freeze-guard). See `build.json` for the data-driven config.
