# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

cmd_help() {
    cat <<HELP

    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║     █████╗ ██╗       ██████╗██╗     ██╗                      ║
    ║    ██╔══██╗██║      ██╔════╝██║     ██║                      ║
    ║    ███████║██║█████╗██║     ██║     ██║                      ║
    ║    ██╔══██║██║╚════╝██║     ██║     ██║                      ║
    ║    ██║  ██║██║      ╚██████╗███████╗██║                      ║
    ║    ╚═╝  ╚═╝╚═╝       ╚═════╝╚══════╝╚═╝                      ║
    ║                                                               ║
    ║    Unified AI Agent Launcher  v${AI_CLI_VERSION}                          ║
    ║    Claude Code · Goose · Native · Sandbox · Container         ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝

AI AGENTS
  goose [args]             Launch Goose AI agent
  claude [args]            Launch Claude Code (default)

CLAUDE MODES
  (default)                Native tiered execution
  -s, --sandbox            Bwrap isolated sandbox (restricted mounts)
  -m, --mirror             Full home access (no isolation)
  docker [args]            Run Claude in Docker container
  podman [args]            Run Claude in Podman container
  browser <URL>            Open URL in Carbonyl TTY browser

COMMANDS
  status                   Show versions, paths, drift detection
  -h, --help               This help message
  -V, --version            Show version

NATIVE EXECUTION TIERS (claude, in order)
  1. Native binary         ~/.nix-profile/bin/claude, ~/.npm-global/bin/claude, PATH
  2. Dependency solver     npm install -g (user -> sudo -> prompt)
  3. npx                   npx --yes @anthropic-ai/claude-code
  4. nix-shell             nix-shell -p nodejs --run "npx ..."

GOOSE EXECUTION
  Searches: goose in PATH, ~/.cargo/bin/goose, pipx goose
  Config:   ~/.config/goose/config.yaml

SANDBOX MODE (--sandbox)
  Uses bubblewrap (bwrap) to isolate Claude with:
    Read-only:   /nix, /usr, /etc/ssl, ~/.ssh, ~/.gitconfig
    Read-write:  ~/.claude, ~/.config, ~/.npm-global, ~/mnt_git
    Isolated:    PID namespace, per-session /tmp
    Env:         CLAUDE_SANDBOXED=1

CONTAINER MODE (docker / podman)
  Runs in node:20-slim with mounts:
    ~/.claude      -> /home/node/.claude
    ~/.claude.json -> /home/node/.claude.json (ro)
    cwd            -> /workspace

EXAMPLES
  ai-cli                             Run Claude (default agent)
  ai-cli goose                       Run Goose agent
  ai-cli goose session resume        Run Goose with subcommands
  ai-cli --sandbox                   Run Claude in bwrap sandbox
  ai-cli docker                      Run Claude in Docker
  ai-cli browser https://auth.x.com  Open auth page in terminal
  ai-cli status                      Show diagnostics
  AI_AGENT=goose ai-cli              Set default agent via env

LOGGING
  All actions logged to ~/claude.log

HELP
}
