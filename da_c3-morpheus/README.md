# c3-morpheus

The cloud's workflow orchestrator. **v1 — deliberately small, and honest about
what it does not do yet.**

```
c3-watchdog   keeps what is running ALIVE   — reactive stability, one machine
c3-morpheus   decides what RUNS             — intentional orchestration, the fleet
```

Watchdog reacts to a machine that is already sick: it samples cpu, memory,
swap, PSI and the process table and kills or restarts locally so a server does
not freeze. Morpheus asks fleet-wide questions — is this service serving, is
this endpoint answering, is this workflow green — and is where a run is
started from. Neither replaces the other.

## Commands

| | |
|---|---|
| `dags` | the Dagu DAGs and how each last ran |
| `gha [limit]` | recent GitHub Actions runs, per repo |
| `list` | both |
| `probes` | the probe registry — what "healthy" is declared to mean |
| `probes validate` | check every probe's ntfy topic is actually registered |
| `probe [name]` | measure the endpoint probes: up / down / **unavailable** |
| `boards` | where the PM board lives, and why it has no API |
| `run <name>` | **NOT WIRED YET** — prints why, starts nothing |
| `doctor` | what is configured and what is missing |

Exit codes: `0` measured and fine, `1` the command could not run, `2` something
is down **or** something could not be measured. A run that failed to measure
never exits 0.

## Three states, never two

`up` / `down` / `unavailable`. The third one is the whole point.

- **up** — answered, with a status this probe expects.
- **down** — answered, with a status it does not. The service is reachable and wrong.
- **unavailable** — *could not measure*. No route, DNS failure, timeout, missing tool.

A probe that cannot run is not a healthy probe and is not a failing service.
Collapsing `unavailable` into either manufactures a false all-clear or a false
outage. `cloud-health-mail-full.sh` printed `maddy=0 stalwart=0` while both
stores demonstrably held mail, and `0` read as data loss.

Concretely: `paca.diegonmarcos.com` has **no public edge certificate** — it
measures `000` from the edge IP while the service is perfectly healthy on
`10.0.0.6:8095`. So every target declares `reach: public | mesh` and is probed
at the address that is true for its class. A transport failure against a
mesh-only target is reported as `UNAVAILABLE`, explicitly *not* as evidence the
service is down.

## Why `probes validate` exists

ntfy runs `auth-default-access: read-write`, so **publishing to a topic nobody
registered returns HTTP 200**. `cloud-health-mail-full.sh` posted to
`infra_mail-health` for a long time while the registry declared
`health_report_cloud-mail-health-full` — every alert landed where nothing
subscribes, and every publish looked successful. The wire cannot tell you this;
only the registry can. `probes validate` cross-checks `data/probes.json`
against `cloud-infra/a_solutions/infra-obs_ntfy/src/build.json::topics[]`.

## What it reuses rather than rebuilds

- **Dagu** at `workflows.diegonmarcos.com`. Status words mirrored from
  `ab_cloud-libs-shared/libs/ops/.../dagu/DaguModels.kt` so the CLI and the
  phone agree.
- **GitHub Actions** via `gh run list`. No second GitHub client.
- **The probes themselves** — `cloud-infra/1_cicd/src/ops/cloud-health-*.sh`,
  scheduled by Dagu, reporting to ntfy. `data/probes.json` is an *inventory* of
  them. Nothing here reimplements a check.
- **Paca** — the PM board *is* the Paca app. It has no board API (`/api/health`,
  `/api/v1/boards`, `/api/boards` all 404, and every route 302s to Authelia), so
  the Android app renders the real SPA inline. There is no wrapper here around
  an API that does not exist.

## What is NOT wired

**Triggering.** `run` starts nothing and says so. Starting a workflow is a
privileged capability and the authenticated path is being built once, in
`ab_cloud-libs-shared/libs/ops`: Dagu `POST /api/v1/dags/{name}/start` with a
fresh `client_credentials` token per run, plus a server-side GHA dispatch
proxy. A second client here would be a second thing to keep in sync with
Authelia, so morpheus will call that one. Until then, start a run in the Dagu
web UI or with `gh workflow run`.

**Running a script probe.** cloud-infra owns those and Dagu schedules them;
morpheus declares and validates them, and will trigger them through the same
path above.

## Building

Never locally. `cargo` is not invoked by `build.sh` at all — the crate is built
on GHA (`.github/workflows/ship-c3-morpheus.yml`) and published as static musl
binaries to the rolling `c3-morpheus-latest` release. `./build.sh fetch`
downloads the one for this architecture.
