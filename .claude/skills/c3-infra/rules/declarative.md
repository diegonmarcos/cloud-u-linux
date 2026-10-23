# Declarative design
- The repo is the source of truth; nothing lives only on a server; derived files come from the one emitter. Why: reproducible fleet. Guard: per-repo drift guards (obs_health_drift).
- Never edit a generated copy (DO NOT EDIT header, byte copies from fleet_files); edit the source and regenerate, then sync. Why: the next generation silently overwrites the edit. Guard: byte-equal tests such as 9_others/test/repos-sot.test.sh.
- dist is committed code, not build output. Why: deploys read it as is. Guard: none.
- Same dotfiles in all repos, delivered by clone.sh --sync (repos.json fleet_files). Why: one repo had drifted three times. Guard: repos-sot.js.
- No docker or systemd auto-restart; lifecycle is the declarative ship pipeline. Why: restart loops hid failures. Guard: compose `restart: "no"` checks.
- Never commit or edit submodule paths; edit the standalone clone. Why: submodule pointers get clobbered. Guard: none.
- Mail sends use the external outbound route only. Why: the mail host IP has no sending reputation. Guard: mail health checks.
- Cloudflare and Hickory DNS are wildcard-only, never per-host records. Why: Caddy is the routing SoT. Guard: fleet-addressing guard.
