# claude-config

Trigger: `on-demand`. No code of its own: declares the existing `build.sh assets` routine, which
applies the declarative `data/claude` tree to `~/.claude` on hosts without home-manager.
`my-ai engine run claude-config` runs it from the checkout (`$MY_AI_SRC`, else
`$GIT_BASE/cloud-u-linux/da_my-ai`, else `~/git/cloud-u-linux/da_my-ai`).
