# my-konsole-dash — agreed page spec & build order (2026-08-27)

**Items 1–7 are DONE and shipped** (watchdog + panel both green, binaries
fetched). The spec is kept below as the record of WHY each page is shaped the
way it is; the rationale is the part that rots if deleted. Only the last
section is still open.

## 1. `Snapshot` struct — DONE
One named-field struct, destructured at the top of `render()`. Field order can
no longer be silently wrong: adding a figure is one struct line plus a compiler
error at each of the 5 sites. (The count below said 43; it was measured at 37.)
`da_watchdog/src/watchdog.rs::render()` takes **43 positional args** across 5
call sites (one-shot, daemon loop, 3 snapshot tests). Any new field means
editing all five in lockstep. This broke twice in one session: CI caught a
test-arity failure, then a scripted insertion desynced the sites (43/41/40) and
had to be reverted. Every page below adds fields.

## 2. Volumes / networks / compose data — DONE
Follow `images_json()`'s shape. `compose_json()` reads compose's OWN labels —
`com.docker.compose.project`, `.service`, `.project.config_files` — never a repo
scan. Those are recorded by the tool that created the container, so they are
fact, not inference. A container with NO label is not a scan gap: it is one
nobody deployed the declared way. **That is the drift signal.** Local
`waydroid-container` has none; oci-mail's mail containers do.

## 3. Containers page → 5 sections — DONE
`compose · images · containers · volumes · network`

## 4. Firewall page → 3 tabs — DONE
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

## 5. Logs page — DONE
Subpages are **only** journal read commands. Stats = count of alerts per section
over the **last 24h**. The important journal sections must be a DATA file, not a
hardcoded list — same pattern as `system-protection.json` driving freeze-guard.

## 6. Fleet Enter-menu — DONE
`ssh{stop, reboot-forced}` / `console{start, stop, reboot-forced}` plus a daemon
start/stop list. The `d`-key unit modal is already the primitive this needs.

Every command string comes from `dist/watchdog.json`, which already carried the
real instance IDs — the panel runs a declared string and never composes an
`oci`/`gcloud` line. `derive-watchdog.ts` had never been registered in
`derivers.json` and was being run by hand; it is registered now. Destructive
verbs take two presses, because one of them stops a production VM.

## 7. `up` on the images page — DONE
Instantiate the **declared** service, never `docker run` — that would invent
ports/volumes/env, an imperative one-off.

The image→service index turned out not to need building: docker already keeps
it. The panel joins image → the container that ran it → that container's
compose labels, and sends `CMP up <file> <service>` to the daemon, which
re-checks the path itself. No repo scan, no path the panel invented. An image
no container ever carried says so instead of guessing.

## Deferred, different mechanism
`logs` / `inspect` / `top` need a RESPONSE channel. The action mailbox is
fire-and-forget, so these need output framing, a pager overlay and a size cap —
not an allow-list entry.
