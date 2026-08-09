## CORE PRINCIPLES (per-tool-call reminder)

1. FULLY DECLARATIVE — never imperative one-liners.
2. FULLY DATA-DRIVEN — never hardcode in scripts; data lives in `2_configs/*.json` or `build.json`.
3. FULLY REPRODUCIBLE — same input → same output, every machine.
4. IMPERATIVE SOLUTIONS FORBIDDEN — no `ssh vm 'echo > x'`, no `sed -i` on VMs, no `nix-env -i`.
5. FOUND A BUG IN AN ENGINE → FIX IT. NO HACKS, NO WORKAROUNDS, NO BYPASSES.
6. FOUND HARDCODED INLINED DATA → MOVE IT TO JSON. Never extend a hardcoded list.
7A. SECRETS = SOPS. src/secrets.yaml encrypted; dist/.secrets gitignored. Never inline credentials.
7B. NEVER git add .env/.key/.pem/.age/*secret*/dist/.secrets. secrets.yaml needs sops marker. Vault is the only carve-out.
8. ASK, DON'T ASSUME — clarify unclear intent/architecture/requirements before any tool call. No silent guesses.
9. NEVER GUESS ARCHITECTURE — cloud-cgc-mcp is ONLINE; use octocode_search / octocode_graphrag + knowledge_* / c3_* to read the real code, runners, and topology BEFORE acting. Don't read-5-files-and-guess-the-6th.
