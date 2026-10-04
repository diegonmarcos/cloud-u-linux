```
╔═══════════════════════════════════════════════════════════════╗
║  ██████╗ ████████╗██╗  ██╗                                     ║
║  ██╔══██╗╚══██╔══╝██║ ██╔╝   Diego's Toolkit                   ║
║  ██║  ██║   ██║   █████╔╝    OS-agnostic CLI                   ║
║  ██████╔╝   ██║   ██║  ██╗   registry-driven                   ║
║  ╚═════╝    ╚═╝   ╚═╝  ╚═╝                                     ║
╚═══════════════════════════════════════════════════════════════╝
```

# DTK — Diego's Toolkit

A single CLI over a personal ops toolkit. **The command catalog is data**
(`registry.json`) — every surface (the shell dispatcher, the menu, the MCP
server) is driven from it, so a command is defined once.

## Invoke

```sh
dtk                      # interactive menu (rendered from the registry)
dtk <domain> <command>   # e.g.  dtk observe btop
dtk <id>                 # e.g.  dtk observe.btop
dtk <shortcode>          # legacy accelerator, e.g.  dtk 30a
```

Canonical identity is `domain.command`. Shortcodes (`30a`, `121`, …) are
optional aliases kept for muscle memory and remain fully resolvable.

## Domains

| Domain | Purpose |
|--------|---------|
| `ref` | aliases, command index, help, dependency manifests |
| `observe` | read-only insight: monitors, journals, sysinfo, deps drift |
| `connect` | reach resources: connect dashboard, mounts, servers, git, ssh |
| `fleet` | operate the cloud VMs: quick-cmds, ssh, remote monitors, modes |
| `provision` | bootstrap/configure: containers, nix-hm, shell, git, sudoers, vault, llms |
| `recover` | break-glass: rescue sshd, rebuild flake, claude rescue, webhooks |

## Layout

```
dtk.sh                  entry point: parse → core dispatch (handlers live here)
registry.json           THE command catalog (single source of truth)
core/                   kernel: registry.sh (load/query), dispatch.sh (route), menu.sh (render)
commands/<domain>/<name>/   per-command module scripts + data, grouped by domain
build/                  flake-engines/, git-workflows/  (build tooling)
assets/                 konsole/  (KDE config exports), fish (under provision/fish)
host/surface/           Surface hardware utilities
products/               standalone deployables: mcp-dtk, mcp-unix-api, chroot-into
scripts/audit-registry.sh   golden test: validates registry + shortcode coverage
docs/  .archive/        documentation / retired tools
```

## Adding a command

1. Add an entry to `registry.json` (`id`, `domain`, `name`, `summary`, optional
   `shortcode`, and `exec` — `core` fn, `module` script, `raw` shell, or
   `orchestrator`).
2. If `exec.kind` is `module`, drop the script under
   `commands/<domain>/<name>/`. If `core`, add the `do_*` handler in `dtk.sh`.
3. Run `bash scripts/audit-registry.sh` — it must stay green.

The menu, dispatcher, and (once regenerated) the MCP server pick it up from the
registry automatically — no per-surface edits.

## Consumers

- **`products/mcp-dtk`** — MCP server exposing DTK to LLMs (shells out to `dtk.sh`).
- **`da_cloud-terminal`** (in the `unix` repo) — its *Tools* profile sidebar
  invokes DTK shortcodes.

> Roadmap: auto-generate the mcp-dtk tool registrations and the cloud-terminal
> Tools profile directly from `registry.json` to retire their remaining
> hand-maintained command lists.
