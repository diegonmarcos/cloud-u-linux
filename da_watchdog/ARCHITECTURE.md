# my-watchdog — what talks to what

One product, four surfaces, **one implementation**. Every surface below shows
the same screen and honours the same keys because none of them draw or
dispatch anything: three are transcripts of the fourth.

```
                       ┌──────────────────────────────────────┐
   /proc /sys cgroupfs │  my-watchdog          (the daemon)   │
   ────────────────────┤  src/watchdog.rs                     │
                       │  writes  $XDG_RUNTIME_DIR/           │
                       │            my-konsole-watchdog.json  │
                       │  drains  …-watchdog.kill  (mailbox)  │
                       └───────────────┬──────────────────────┘
                                       │ snapshot (read)
                                       │ mailbox   (append)
                       ┌───────────────▼──────────────────────┐
                       │  my-watchdog-tui      (the panel)    │
                       │  src/tui/monitor/                    │
                       │  ratatui draws → Buffer of cells     │
                       └───┬───────────┬──────────────┬───────┘
          terminal         │           │ tui_html.rs  │ tui --serve
          (a human)  ◄─────┘           ▼              ▼
                                  HTML report     one screen per key
                                  (export)        (stdin → frames)
                                       │              │
                            ~/.watchdog/html/    ac_cloud-watchdog
                            index.html           (the Android app)
                            index-mobile.html
```

## The rule that makes this work

**Nothing outside `src/tui/monitor/` decides what a key means or what a screen
looks like.**

* The keys are `Monitor::on_key` — the real dispatch table.
* The screen is the ratatui buffer — the real layout, frames and colours.

`tui_html.rs` transcribes that buffer cell by cell into spans. So a change to
the panel appears in the HTML report and in the phone app with **no work in
either**, and neither can disagree with the terminal about a frame, a column
or a colour.

This was learned the expensive way: the report re-implemented the layout in
TypeScript and diverged on all three, and no amount of fixing converged.

## Where each piece lives

| what | where |
|---|---|
| daemon (sampler + mailbox) | `da_watchdog/src/watchdog.rs` |
| panel (all UI, all keys) | `da_watchdog/src/tui/monitor/` |
| key tables — the one source | `…/monitor/model/keys.rs`, `model/tabs.rs` |
| buffer → HTML | `…/monitor/tui_html.rs` |
| HTML report writer | `…/monitor/export.rs`, `html.rs` |
| report stylesheet / renderer | `da_watchdog/web/src/report.{scss,ts}` → committed `dist/` |
| Android app | `cloud-u-android/ac_cloud-watchdog` |
| Android ssh bridge | `cloud-u-android/ab_cloud-libs-shared/libs/watchdog` |

## Cross-repo references

* **cloud-u-android** — `ac_cloud-watchdog` runs `my-watchdog-tui tui --serve`
  inside nix-on-droid (Termux as fallback) over ssh to `127.0.0.1`. It sends
  key NAMES and receives frames. See that repo's `ac_cloud-watchdog/README.md`.
* **cloud-infra** — `1_cloud-configs/dist/watchdog.json` declares the fleet:
  every machine's provider, instance id and the **exact command strings** for
  ssh and console actions. The panel never composes an `oci` or `gcloud`
  command line; it runs the string the declaration carries. `config.json::vms`
  is the machine inventory the MACHINE box lists.
* **da__my-konsole** — no longer involved. The panel was one of its dashboards
  until it was extracted here; konsole was an inspiration for the shape, never
  an owner. Its `frame.rs` and this one are deliberate duplicates.

## Two things that are NOT here, and why

* **`actions.console.status`** does not exist in the fleet declaration — only
  mutating verbs (start/stop/restart/reset/reboot-forced). So the fleet page
  cannot yet be *populated* from a provider console, only *acted on* through
  one. Adding it is a change to the deriver in cloud-infra, not here.
* **`ctrl-c` / `ctrl-d`** are never forwarded from the app. They quit, and an
  app leaves by backing out.
