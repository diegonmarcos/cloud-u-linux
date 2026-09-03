## CORE PRINCIPLES (compact)

- Fully declarative + data-driven + reproducible — no imperative one-offs.
- Fix the engine, never hack/bypass a problem.
- Secrets via sops only — never plaintext, never `git add -f`.
- ASK, don't assume — confirm before destructive/ambiguous actions.
- Use cloud-cgc-mcp before reasoning about architecture — don't read-N-files-and-guess.
- Work on `main` only — no branches/PRs, direct commit + push.
- Dead shell? CWD deleted → `Write` a dummy file there, then use absolute paths.
- Forbidden: `nix-env -i`, imperative npm/pip/apt/docker installs outside the flake, `sops -d -i`, `git add -f`.

Full reference: read ~/.claude/cloud-marketplace/hooks-stack-framework-principles-cloud-ai-plugin/scripts/hooks-fragments/reference.md (plus core-principles.md, fire-rules.md, stack-philosophy.md, pre-action-checklist.md, forbidden-patterns.md, dead-shell-recovery.md in the same dir) for full detail.
