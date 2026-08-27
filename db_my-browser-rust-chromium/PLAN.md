# my-browser-rust-chromium — build plan

Baseline (shipped, green CI): upstream cef-rs `cefsimple` = a **bare** Chromium
window (real Blink + BoringSSL → clean fingerprint). No URL bar, no tabs, no
chrome. Everything below is OURS, built on top — no Google UI anywhere.

## Two layers

- **A) Rust/CEF chrome** (the window UI — the hard, from-scratch part). We fork
  cefsimple via `build.sh` patch-overlay: our files in `src/patches/` are copied
  over the cloned example before `cargo build`. Reproducible, data-driven.
- **B) `cloud-chromium` plugin** (a WebExtension, JS/MV3 — more tractable). Loaded
  into CEF. Hosts the cloud login, sync, Bitwarden, and the `:` command palette.

## Phases (each = one shippable, CI-verified increment)

| # | Feature | Layer | Notes |
|---|---------|-------|-------|
| 1c | **Baked homepage** (qute dashboard → `my-browser-chromium-homepage.html`) | launcher | ✅ DONE — bundled + `--url=` launcher |
| 1a | Own desktop icon + `.desktop` entry | packaging | icon asset + xdg desktop entry in the bundle |
| 1b | Cookie policy: auto-refuse non-essential (only necessary) | A (CEF handler) | `CefCookieManager` / request handler blocks 3rd-party + consent auto-decline |
| 2  | **Two-line tab strip**: line 1 = pinned, line 2 = normal | A | cefsimple has NO tabs → build multi-browser-view + our tab bar |
| 3  | Default pinned tabs: `localhost:8000` + our homepage | A (data in build.json) | pinned set is data-driven |
| 7  | **Left-side vertical tab list** (Brave-style), toggle with the top strip | A | alternate tab layout |
| 6  | No Google login button; **our cloud login** beside the URL bar | A + B | our chrome, our identity — zero Google UI |
| 5  | `:` **vim command palette** (qute-style) | B (plugin overlay) | keybind `:` opens command menu |
| 4  | **cloud-chromium plugin**: sync history+bookmarks to our cloud + **Bitwarden wrapper** (embed the open-source Bitwarden extension) | B | ⚠️ CEF has *partial* MV3/extension support — Bitwarden-in-CEF must be proven early (risk) |

## Known risks (surface early, don't promise blind)
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
