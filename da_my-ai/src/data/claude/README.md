# claude/ — entry point, not storage

Symlinks only. Nothing here is a real file; edit through the links.

| Link             | Target                              | Holds                                                          |
|------------------|-------------------------------------|----------------------------------------------------------------|
| `sot/`           | `da_my-ai/src/data/claude`          | Config SHARED by both machines — edit here                       |
| `sot-statusline/`| `da_my-ai/src/data/statusline`      | Status line + `claude-*-status.sh`, embedded in the my-ai binary |
| `termux/`        | `bb_flakes_termux/src/claude`       | `claude.nix` + termux-only assets                                |
| `desktop/`       | `ba_flakes_desktop/src/claude`      | `claude.nix` + desktop-only assets                               |

## da_my-ai owns the config. The flakes only deploy it.

Ownership splits by **who can change a file at runtime**, and that decides which of two
delivery paths a file takes:

1. **Binary-carried** — `sot-statusline/`. `statusline-command.sh`,
   `claude-{mcp,plugins,hooks,flags}-status.sh`, `claude-pricing.json`. Embedded via
   `include_str!` (`core/src/statusline_assets.rs`), written to `~/.claude` by the
   daemon on every start, so the scripts can never drift out of step with the binary
   that shells out to them. **No flake may declare these** — a `home.file` entry lays a
   second copy on top, which is exactly how the deployed status line sat 141 lines
   stale from 2026-08-01 to 2026-08-09.

2. **Flake output** — `sot/`. `agents/`, `cloud-marketplace/`, `claude-plugins.json`,
   `rgignore`, `settings.base.json` + `settings.{termux,desktop}.json`. Exposed by
   `da_my-ai/flake.nix` as `claudeAssets`, consumed as `my-ai.claudeAssets`. Inert
   config the flakes must place in `~/.claude` anyway; routing it through the binary
   instead would mean a GH release for every asset edit.

3. **Flake-local** — `termux/assets/`, `desktop/assets/`. Only what is genuinely
   platform-specific: `mcp.json.tpl` (termux bans stdio MCP servers, desktop keeps
   three), `secrets.yaml` (different sops recipients), desktop's `mcp-local-launch.sh`.

## settings.json

One base plus a per-platform overlay, merged with `lib.recursiveUpdate`.

The base uses `@HOME@` placeholders, substituted with `config.home.homeDirectory` at
eval time. Every path that used to differ between the machines — `GIT_BASE`,
`NODE_PATH`, both `AUTHELIA_*_DIR`, `statusLine.command` — is byte-identical once
`$HOME` is factored out, so all of them live in the base and the overlays hold only
real differences: `refreshInterval` (5 vs 1), desktop's `tui` and four LSP plugins,
termux's `MCP_TIMEOUT` / `effortLevel` / `enableAllProjectMcpServers`.

Do **not** leave a literal `$HOME` in the JSON. Claude Code shell-expands
`statusLine.command` but sets `env` values verbatim, so a literal would leak the string
`$HOME/git` into `GIT_BASE`.

Verified: base ⊕ overlay reproduces each machine's pre-split `settings.json` — desktop
byte-identical, termux differing only in `statusLine.command`, where the literal
`$HOME` is now pre-expanded to the same resolved path.

## Editing loop

    edit here  →  build.sh (switch)

That is the whole loop. Both flakes read this directory **from the working checkout at
activation time** (`home.activation.claudeAssets`, overridable with `CLAUDE_SOT_DIR`),
so no push and no `nix flake update` stands between an edit and the next switch.

It did not always work that way. Until 2026-08-12 `sot/` reached the flakes through
`inputs.my-ai-src.claudeAssets`, which meant a commit, a push and a lock bump for every
asset edit — the wrong loop for files edited daily, and until a lock bump happened the
deployed copy was silently whatever the lock last pinned.

The tradeoff is stated where it is made (`claude.nix`): `home.file` tracked these files
and removed them when undeclared, a copy does not. `agents/` and `cloud-marketplace/`
are therefore wiped-then-copied rather than merged; a removed single file must be
deleted by hand.

The other tradeoff is less obvious and cost something. A consumer with no working
checkout — a container, CI, a fresh clone — cannot read this directory at all, and its
only option is to vendor a copy. `user-ai_claude-superset-api` did, its copy's
provenance header named a directory that later ceased to exist, and nothing noticed for
months. `flake.nix` still exports `claudeAssets` for exactly that consumer, and
`test-claude-sot.sh` now fails on any provenance header pointing at a path that is not
there.

`sot-statusline/` is the slower loop still — it needs a GHA release of the binary,
because those files are compiled into it.
