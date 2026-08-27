# my-konsole-dash — agreed page spec & build order (2026-08-27)

Build in THIS order. Item 1 is a hard prerequisite, not a nicety.

## 1. `Snapshot` struct — blocks everything below
`da_watchdog/src/watchdog.rs::render()` takes **43 positional args** across 5
call sites (one-shot, daemon loop, 3 snapshot tests). Any new field means
editing all five in lockstep. This broke twice in one session: CI caught a
test-arity failure, then a scripted insertion desynced the sites (43/41/40) and
had to be reverted. Every page below adds fields.

## 2. Volumes / networks / compose data
Follow `images_json()`'s shape. `compose_json()` reads compose's OWN labels —
`com.docker.compose.project`, `.service`, `.project.config_files` — never a repo
scan. Those are recorded by the tool that created the container, so they are
fact, not inference. A container with NO label is not a scan gap: it is one
nobody deployed the declared way. **That is the drift signal.** Local
`waydroid-container` has none; oci-mail's mail containers do.

## 3. Containers page → 5 sections
`compose · images · containers · volumes · network`

## 4. Firewall page → 3 tabs
`consolidated · OS firewall · container firewall (docker ps)`

See `watchdog.rs:788` — the daemon is deliberately a USER service, so
`nft list ruleset` / `iptables -S` are unreadable. The page reports **listening
sockets** instead, which is arguably better: docker inserts its own DOCKER chain
ahead of ufw/nftables, so a ruleset view shows a policy docker already bypassed.

Consequence for the container tab:
- Normally published ports **are** caught — `docker-proxy` binds a real host socket.
- With `userland-proxy: false` it is pure DNAT: no host socket, **invisible** to a
  socket scan. Cross-reference container `Ports` against the listening table; a
  published port with no matching socket is the case worth flagging.

## 5. Logs page
Subpages are **only** journal read commands. Stats = count of alerts per section
over the **last 24h**. The important journal sections must be a DATA file, not a
hardcoded list — same pattern as `system-protection.json` driving freeze-guard.

## 6. Fleet Enter-menu
`ssh{stop, reboot-forced}` / `console{start, stop, reboot-forced}` plus a daemon
start/stop list. The `d`-key unit modal is already the primitive this needs.

## 7. `up` on the images page
Instantiate the **declared** service, never `docker run` — that would invent
ports/volumes/env, an imperative one-off. Compose lives at
`a_solutions/<service>/dist/compose/docker-compose.yml`, `build.json` names the
image, and the ship pipeline already deploys it to `deploy.remote_path`.
Needs an image→service index.

## Deferred, different mechanism
`logs` / `inspect` / `top` need a RESPONSE channel. The action mailbox is
fire-and-forget, so these need output framing, a pager overlay and a size cap —
not an allow-list entry.
