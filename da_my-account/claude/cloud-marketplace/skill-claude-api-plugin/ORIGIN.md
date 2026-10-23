# Origin

`skills/claude-api/` is vendored verbatim from the upstream Anthropic skills repo.

| field | value |
|---|---|
| upstream | https://github.com/anthropics/skills |
| path | `skills/claude-api` |
| rev | `da20c92503b2e8ff1cf28ca81a0df4673debdbf7` |
| sha256 (nix) | `08b3g2y0dx02bg5ypi8yvsd10dc19j9zm811hqq50aymbq8ny9h6` |
| vendored | 2026-07-30 |

## Why vendored instead of `pkgs.fetchFromGitHub`

It used to be fetched by Nix and dropped straight into `~/.claude/skills/claude-api`.
That made it a **loose filesystem skill**, which this fleet no longer allows — every skill
ships as a plugin (`skill-<name>-plugin`) so it can be enabled/disabled declaratively via
`enabledPlugins`, and so disabling the plugin unloads the skill. `cloud-marketplace` is a
single static directory, so a Nix-fetched subtree cannot be merged into it without extra
build machinery; vendoring matches how `ponytail` and the other plugins here already work.

## Updating

Bump to a newer upstream rev by re-vendoring:

```sh
nix-prefetch-github anthropics skills --rev <NEW_REV>     # get sha256
# then replace skills/claude-api/ with that rev's skills/claude-api/
# and update the table above
```
