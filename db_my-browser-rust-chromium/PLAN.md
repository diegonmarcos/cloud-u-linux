# my-browser-rust-chromium — build plan

Baseline: upstream cef-rs **`osr`** example — CEF renders web content to a wgpu
texture inside a Rust-owned winit window (real Blink + BoringSSL → clean
fingerprint). No URL bar, no tabs, no chrome, no Google UI at all. Everything
below is OURS, composited on top.

> `cefsimple` (Chrome runtime) was the original base and is **rejected** — it
> ships Google's own chrome. `build.json` is the source of truth for the base
> example; this file follows it.

## Two layers

- **A) Rust/CEF chrome** (the window UI — the hard, from-scratch part). We fork
  the `osr` example via `build.sh` patch-overlay: our files in `src/patches/` are
  copied over the cloned example before `cargo build`. Reproducible, data-driven.
- **B) `cloud-chromium` plugin** (a WebExtension, JS/MV3 — more tractable). Loaded
  into CEF. Hosts the cloud login, sync, Bitwarden, and the `:` command palette.

## Phases (each = one shippable, CI-verified increment)

| # | Feature | Layer | Notes |
|---|---------|-------|-------|
| 1c | **Baked homepage** (qute dashboard → `my-browser-chromium-homepage.html`) | launcher + A | ❌ **NOT done** (was wrongly marked ✅) — the HTML is bundled, but the osr example hardcodes its start URL and parses no `url` switch, so `--url=` is silently ignored. Verified: the shipped binary contains the literal `https:://github.com` (upstream typo, double colon) and no `url` string. |
| 1a | Own desktop icon + `.desktop` entry | packaging | icon asset + xdg desktop entry in the bundle |
| 1b | Cookie policy: auto-refuse non-essential (only necessary) | A (CEF handler) | `CefCookieManager` / request handler blocks 3rd-party + consent auto-decline |
| 2  | **Two-line tab strip**: line 1 = pinned, line 2 = normal | A | cefsimple has NO tabs → build multi-browser-view + our tab bar |
| 3  | Default pinned tabs: `localhost:8000` + our homepage | A (data in build.json) | pinned set is data-driven |
| 7  | **Left-side vertical tab list** (Brave-style), toggle with the top strip | A | alternate tab layout |
| 6  | No Google login button; **our cloud login** beside the URL bar | A + B | our chrome, our identity — zero Google UI |
| 5  | `:` **vim command palette** (qute-style) | B (plugin overlay) | keybind `:` opens command menu |
| 4  | **cloud-chromium plugin**: sync history+bookmarks to our cloud + **Bitwarden wrapper** (embed the open-source Bitwarden extension) | B | ⚠️ CEF has *partial* MV3/extension support — Bitwarden-in-CEF must be proven early (risk) |

## Known risks (surface early, don't promise blind)
- **The osr example has NO input handling at all (FOUND 2026-08-29).** Upstream
  `window_event()` matches only `CloseRequested`, `RedrawRequested`, `Resized`.
  There is no `MouseInput`, `CursorMoved`, `MouseWheel`, `KeyboardInput` — and
  `send_mouse_click_event` / `send_key_event` are never called anywhere in the
  repo outside the generated FFI bindings. It is a display-only demo: you cannot
  click, type or scroll. **The entire input layer is ours to write**, and it is a
  prerequisite for *any* usable browser, before tabs or chrome are even discussed.
- **One browser, one texture.** `App.browser` is `Option<Browser>` and the frame
  lands in a single module-level `thread_local! TEXTURE: RefCell<Option<BindGroup>>`
  that every paint callback overwrites with no browser-id key. Tabs (phase 2) need
  this keyed by `browser.identifier()`, one `OsrRenderHandler`/`Client` pair per
  browser, and N quads in the render pass. Upstream demonstrates none of it.
- **wgpu backend is hardcoded (FOUND 2026-08-29, launcher-patched):** the `osr`
  example requests `Backends::VULKAN` only, and the bundle ships no Vulkan ICD →
  `NoAdapter` panic before any window appears. `WGPU_BACKEND=gl` is ignored.
  `build.sh`'s launcher now points the loader at the host's ICDs; the real fix is
  `Backends::all()` in `src/overlay/main.rs` once the overlay exists, so it can
  fall back to GL on a machine with no Vulkan at all.
- **Bitwarden in CEF (item 4):** CEF's `LoadExtension` supports limited Chrome
  extensions; a full MV3 password manager may not run unmodified. Prove with a
  minimal extension load test BEFORE committing to the full wrapper.
- **Tab strip (2/7):** cefsimple is single-window/single-view; real tabs mean
  managing N CEF browser views + our own tab-bar rendering. This is the bulk of
  the work.
- All Rust/CEF changes are only compile-verified via CI (the Surface can't build
  CEF) → iterate through green CI, small patches.

## Acceptance tests
- 1c: launch → our dashboard loads (not google).
- 1b: visit a tracker-heavy site → 3rd-party cookies blocked (devtools Application tab).
- 2/3/7: pinned line shows localhost:8000 + homepage; normal tabs on line 2; vertical toggle works.
- 5: press `:` → command palette appears.
- 4: JA4 stays real-Chrome; history/bookmarks appear in our cloud; Bitwarden unlocks.

---

## Measurements that bound the effort  (2026-08-28, this machine)

Taken so the goal is stated honestly. Python is **not** the bottleneck:

| | |
|---|---|
| `import qutebrowser.app` (210 modules) | 0.27 s |
| Wrapper + Qt + argparse, no engine | 0.5–0.7 s |
| Python time *during* browsing | **0 s** — all Chromium |
| RSS | 223 MB / 10 procs (98 MB renderers, 125 MB main = Python **+ Qt + WebEngine browser proc**) |
| GPU on qute today | already accelerated — `type=gpu-process` live, Intel i915/crocus |
| qutebrowser source / this fork's own code | 59,336 LOC / ~1,324 LOC |
| Rust already in the fleet | 18,455 LOC (`da_watchdog`, `da__my-konsole`, `da_my-ai`) |

So this project is **not** justified by speed, and GPU is not a problem to solve
— qute already has it. The justification is the one in `README.md`: **TLS
fingerprint**. Keep it stated that way; a speed claim would not survive contact
with a benchmark. (`--version` taking 7–14 s is a WebEngine version probe, not
startup. Never quote it.)

## Write less code — clone, don't write

| Project | Saves | Status (checked 2026-08-29) |
|---|---|---|
| **`tauri-apps/cef-rs`** | the entire CEF FFI layer | 1,105 commits, Linux x86_64 + ARM64, release-plz automation |
| **`tauri-apps/tao`** | window + event loop, GTK on Linux — if winit fights Wayland | mature (Tauri's winit fork) |
| **qutebrowser `javascript/`** | hint labelling + element detection — plain JS injected into the page, **ports verbatim**, GPL like this fork | in-tree already |

Read, don't fork: **`antoyo/titanium`** (Rust + WebKit2GTK vim browser, ~363
stars, stale) — the reference for structuring command-mode/hints/marks in Rust.

Rejected on purpose: **Verso/Servo** (not daily-usable; nixpkgs servo is ~2 yrs
stale) · **Tauri/wry as a framework** (WebKitGTK on Linux → the GnuTLS
fingerprint this project exists to escape) · **Firefox + Tridactyl** (zero code,
but no two-line pinned strip and no `mybar.json` SoT).

Do not wait on Tauri's own CEF backend for `wry` — stop-start, no ETA, and the
maintainers have signalled it may land closed-source. Depend on `cef-rs` directly.

## Open decision — how the chrome is drawn  (blocks phase 2)

`build.json` says winit + **wgpu**. That means writing text layout, hit-testing
and widget painting in Rust from scratch — realistically the largest single cost
in this repo.

The cheaper option: composite a **second OSR view rendering HTML/CSS** as the
chrome. `2_configs/my-browser-chromium-homepage.html` and qute's
`dashboard/*.template.html` already exist, so the tab strip / pinned row /
omnibar become CSS, and "matches qute" becomes screenshot-diffable instead of a
matter of taste. Cost: a second CEF view, and chrome repaints go through a
compositor pass (irrelevant for a static bar).

Decide this in the phase-2 spike, on evidence. Do not start painting widgets in
wgpu before that.

## Vault: prefer `bw` over embedding the MV3 extension

Phase 4 flags Bitwarden-in-CEF as a risk, correctly — CEF's `LoadExtension` has
only partial MV3 support and a full password manager may not run unmodified.
`db_my-browser-qute`'s Track B already solves this without any extension: the
**`bw` CLI** + JS injection into the focused form, browser-agnostic, already
designed. Take that first; attempt the extension wrapper only if `bw` proves
insufficient. It removes the single riskiest item from the phase table.
