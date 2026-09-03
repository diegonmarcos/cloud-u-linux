## CORE PRINCIPLES (non-negotiable — reinforced at EVERY tier of hook injection)

1. **FULLY DECLARATIVE** — every change goes through source files in git; never imperative ad-hoc one-liners.
2. **FULLY DATA-DRIVEN** — data lives in `build.json` / `2_configs/*.json`; never hardcoded inline in scripts.
3. **FULLY REPRODUCIBLE** — same input → same output, every time, every machine, every clean build.
4. **IMPERATIVE SOLUTIONS FORBIDDEN** — no `ssh vm 'echo > x'`, no `sed -i` on VMs, no `nix-env -i`, no ad-hoc patches.
5. **FOUND A BUG IN AN ENGINE → FIX IT.** NO HACKS ALLOWED. No workarounds, no temporary bypasses, no "for now" patches. The engine is the contract; bugs in it are root-cause material.
6. **FOUND A NON-DATA-DRIVEN INLINED HARDCODED SOLUTION → FIX IT.** Move the data to JSON, refactor the script to read it. Never extend a hardcoded list — replace it.
7A. **USE SOPS.** Secrets live in `src/secrets.yaml` (sops+age). Decrypt only into `dist/.secrets` (gitignored). Path: `build.sh secrets`. Never inline credentials in source/scripts/env.
7B. **PREVENT EXPOSURE.** Never `git add` `.env` / `.key` / `.pem` / `.age` / `*secret*` / `dist/.secrets`. `secrets.yaml` may be committed only when it carries the sops marker (`^sops:` block / `ENC[AES256_GCM` values) — content-checked, not filename-trusted. Never `git add -f`. Vault carve-out: raw key material that *is* the credential (age keys, `~/git/cloud-vault/A0_keys/...`).
8. **ASK, DON'T ASSUME.** If intent, architecture, or requirements are unclear, ASK before writing a line. No silent guesses about scope, placement, or wiring — clarify first, code second. Silent guesses become silent commits become silent regressions.
9. **NEVER GUESS THE CODE / INFRA ARCHITECTURE — USE cloud-cgc-mcp.** Before reasoning about how the code/build/runner/topology works, query it: `octocode_search` / `octocode_graphrag` (semantic code + call-graph), `knowledge_*` / `c3_*` (services, runners, configs, topology). Reading 5 files and guessing the 6th is the bug — be SURE via cloud-cgc-mcp, THEN act.
