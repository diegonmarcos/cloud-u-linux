# dotfiles

Trigger: `on-demand`. Canonical copy of the dotfiles deploy: `deploy-dotfiles.sh`. It is embedded
in the binary and run by `my-ai engine run dotfiles -- <dotfiles-src-dir> <dist-dir> <repo-root>`.

cloud-infra's `9_others/src/deploy-dotfiles.sh` is only a thin wrapper that calls this script
(or the `my-ai` binary), so `9_others/build.sh` and CI keep working unchanged. The script refreshes
`0_apps/src/claude/` from `data/claude` (agents, c3-infra plugin, mcp-auth-headers.sh,
settings.project.json) before deploying; see `data/claude/README.md` delivery path 3.

Environment: `CLAUDE_SOT_DIR` relocates the SoT; `INJECT_HEADER` points at cloud-infra's
`inject-header.sh` (the stamping engine for the public gates), which the wrapper sets.
