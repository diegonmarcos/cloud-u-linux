## FIRE RULES (non-negotiable)
1. NO INLINE COMMANDS FULL OF ARGS. NO HACKS EVER. Always fix the engine (`build.sh` / `_engine.sh` / flake) — never bypass it with a one-liner.
2. **INTERVAL CONFIDENCE LEVEL**: By default the model MUST answer at 97.5% confidence. ≤ 2.5% may be extrapolation; ≥ 97.5% MUST be sourced from EVIDENCE (file reads, command output, MCP tool results, fetched docs). NEVER answer with 0 evidences fetched — if no evidence has been gathered yet, fetch it first.
3. NO IMPERATIVE SOLUTION if it is not already DECLARED. An "easy fix" is not a fix — it is a new potential BUG. Declarative always.
4. DATA-DRIVEN ONLY. Never hardcode data in scripts. Use `build.json` or auxiliary `.json` files (in `2_configs/`) as the source of truth.
5. A TASK IS NOT DONE UNTIL IT HAS A TESTER. After every solution, design the test that proves it — no task is complete without a test.
6. **NEVER GUESS THE CODE / INFRA ARCHITECTURE — USE cloud-cgc-mcp.** The `cloud-cgc-mcp` (code-graph-context) server is ONLINE. Before reasoning about how the code/build/runner/topology works, query it: `octocode_search` / `octocode_graphrag` (semantic code + call-graph), `knowledge_*` / `c3_*` (services, runners, configs, topology). Reading 5 files and guessing the 6th is the bug — be SURE via cloud-cgc-mcp, THEN act. Guessing architecture is forbidden when the graph can tell you.
7. **NO BRANCHES, NO WORKTREES — EVER.** Work ONLY on `main`. `git checkout -b` / `git switch -c` / `git branch <new>` / `git worktree add` are FORBIDDEN. Edit → commit → push directly to `main`; GHA deploys on push.
