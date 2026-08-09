## Repo Map (`~/git/`)

| Repo | Visibility | Role |
|------|------------|------|
| `cloud` | public | Service infra — Nix flakes → Docker Compose, 60+ services on 4 VMs |
| `unix`  | public | NixOS host + home-manager (desktop, termux, per-VM) |
| `front` | public | 32-project front-end monorepo → GitHub Pages |
| `vault` | **PRIVATE** | All credentials — sops + age + OAuth + SSH/WG/TOTP |
| `tools` | public | Cross-repo tooling (submodule from cloud/unix/front) |

Same engine interface everywhere: `build.sh` (universal engine) + `build.json` (config) per project/service.

**cloud**: `build.sh ship` = build+secrets+deploy+compose (full pipeline). `CLOUD_PROFILE=<name> build.sh profile-ship` = generic topology, never DR/fallback. Submodules (`cloud/tools`, `cloud/I_cloud-data`) read-only — edit `~/git/tools/`, `~/git/I_cloud-data/` instead. GHA auto-deploys `a_solutions/*/src/` changes pushed to `main`.

**unix**: `build.sh switch|boot|test|check|update|diff|install|build{raw|iso|qcow|vm}|burn`. Root is tmpfs (impermanence); `/nix` + `/home/*` persistent btrfs. VMs receive HM as GHCR Docker images (1GB hosts OOM on `nix eval`/`home-manager switch`).

**front**: TypeScript strict, Svelte 5 runes / Vue 3 Composition API. No inline CSS (SCSS mixins only). No `fetch()` for JSON — read `globalThis.PORTAL_DATA[key]` from `data-<key>.json.js`. Matomo required in every HTML `<head>`. Deploy: `1.ops/build_main.sh` (TUI) or per-project `build.sh build|dev|deploy`. Never `dev`/`serve` after source edits unless asked.

**vault**: paths only referenced from public repos, never copied values. Bearer token: `python ~/git/vault/A0_keys/providers/authelia/oauth/get_token.py`.

## Live Infra Data — use MCP, don't hardcode here

VM table, service table (42+ services), Caddy routes, MCP tool catalogs: query `c3_topology` / `c3_configs` / `knowledge_vm_info` / `knowledge_services_by_category` (code-graph-context MCP) instead of a static copy — this file is not the source of truth, `cloud-data` is.

## cloud/ Service Structure (MANDATORY)

```
<category-prefix>_<name>/
├── build.sh        <- Universal engine (copy from template, never customize)
├── build.json      <- name, description, deploy{host,remote_path}, ports, secrets, backup, image
└── src/
    ├── flake.nix    <- REQUIRED, builds -> dist/
    ├── secrets.yaml <- Optional, sops-encrypted
    └── ...
```
Prefixes: `aa-sui` app · `ab-mic` mic · `ac-fin` fin · `ad-agi` agi · `ba-clo` cloud · `bb-sec` sec · `bc-obs` tools · `ca-dat` data
Pipeline verbs: `build | secrets | deploy | compose | all(=build+secrets) | ship(=full) | clean`. Template: `bb-sec_authelia/build.sh`.

## Behavioral Rules

1. "Explain"/"how does it work"/"what is" = READ-ONLY. Describe, don't edit.
2. No unnecessary deploys — never `ship` a service not explicitly in scope.
3. Read specs first: `README.md` / `1.ops/` spec / `build.json` before any edit.
4. Search ALL keys/sections when querying JSON — never cherry-pick.
5. After source edits → `build.sh build` automatically.

## Key Gotchas

- `escape_dollars: true` in build.json for `.secrets` values with `$` (Argon2/PBKDF2 hashes) — else compose env_file mangles them.
- Use `awk` not `sed` for secret substitution — `sed` corrupts `$` in replacements.
- Authelia: pin version (never `:latest`); 4.38+ OIDC `client_secret` must be PBKDF2 digest.
- Broken shell (cwd deleted): `Write` a dummy file at the dead path to restore cwd, then use absolute paths.
- `echo "$VAR" | while read` runs in a subshell — use `mapfile`+`for` for variable propagation.
- Dagu `command: >-` (folded scalar) swallows `$VAR` — always use `command: |`.
- Never manual `docker compose`/`nix eval` on 1GB VMs — use `build.sh ship` / GHCR image delivery.
- Caddy wormhole returns HTTP 200 on missing routes — inspect response *body*, not status code.
