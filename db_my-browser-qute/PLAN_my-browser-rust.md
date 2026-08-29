# PLAN — my-browser-rust

Replace the Python shell of `my-browser-qute` with Rust, keeping the Chromium
engine, the exact chrome, and the JSON source-of-truth pipeline.

Companion to `PLAN_qute-master-roadmap.md`. Where the two disagree, the
architecture invariants there still win.

---

## 0. What the measurements actually say  (2026-08-28, this machine)

Taken before designing, because they bound what a rewrite can buy.

| Measurement | Value |
|---|---|
| `import qutebrowser.app` (all 210 modules) | **0.27 s** |
| Wrapper + Qt + argparse (`--help`, no engine) | **0.5–0.7 s** |
| Python time during browsing (scroll, JS, paint) | **0 s** — all Chromium |
| RSS, whole browser | 223 MB / 10 procs |
| ├─ Chromium renderers | 98 MB (9 procs) |
| └─ Main process (Python **+ Qt + WebEngine browser process**) | 125 MB (1 proc) |
| GPU today | already accelerated — `type=gpu-process` live, Intel i915/crocus |
| qutebrowser source | 59,336 LOC Python |
| Fork's own code | ~1,324 LOC (`mybar.py` 390, `url.py`, `gen-dashboard.sh` 287, templates 708) |
| Rust already in the fleet | 18,455 LOC (`da_watchdog`, `da__my-konsole/dash`, `da_my-ai/core`) |

**Read this honestly:** Python costs ~0.5 s of cold start and nothing while
browsing. Page speed is Chromium's, before and after. A rewrite buys owning the
code, dropping a scripting runtime from the engine, and maybe 40 MB — not
faster pages. That is a legitimate goal. It is not a performance goal, and
planning it as one leads to disappointment at the finish line.

`--version` takes 7–14 s because it spawns a WebEngine process to probe the
Chromium version. It is **not** on the startup path. Do not use it as a
benchmark.

---

## 1. Engine decision

Non-negotiables: full GPU on Linux, site compatibility no worse than today,
chrome that matches qute.

| Engine | Rust binding | GPU | Site compat | Verdict |
|---|---|---|---|---|
| **CEF** (Chromium 138, in nixpkgs as `cef-binary`) | `cef` crate, unofficial + thin | full Chromium stack | identical to today | **pick** |
| WebKitGTK 6.0 (2.48.3) | `webkit6`/`wry`, mature | yes (DMA-BUF) | different engine — Google properties, Teams, some SPAs regress | fallback |
| Servo | native Rust | WebRender | cannot render most real sites | no |
| QtWebEngine (today) | none usable — cxx-qt covers QtCore/Gui/Qml only | full | identical | no |

**CEF**, because it is the same Chromium already rendering these pages: identical
compat, identical GPU path, no regression to explain away. WebKitGTK is the
honest fallback if CEF's Wayland/Ozone integration fights back — it is far easier
to drive from Rust, at the cost of a different engine.

**Known risk, stated up front:** the Rust CEF bindings are unofficial, and CEF +
Wayland is the least-trodden part of this. Stage 1 exists to answer exactly that
before any rewrite starts.

## 2. Chrome — "exact same UI"

Two ways to match qute's look:

- **Qt widgets via `cxx-qt`** + a small C++ shim (~200–400 LOC) exposing the CEF
  view. Same toolkit as today, so "exact" is literal. Two FFI boundaries.
- **GTK4** (4.16.12) + `gtk4-rs`. One less obscure boundary; matching qute's look
  becomes a CSS styling job rather than a given.

Stage 1 decides. Either way the custom chrome is small — the three-row layout,
pinbar, and statusbar are ~1,300 LOC today, and the dashboard/websearch pages are
**HTML templates that carry over untouched**.

## 3. What carries over unchanged

- `src/2_configs/*.json` — the source of truth. Same files, same schema.
- `dashboard/*.template.html` + `gen-dashboard.sh` — pages are HTML already.
- The home-module → Nix → `~/.config/` projection.
- Vaultwarden via the `bw` CLI (Track B). Already designed, already works,
  browser-agnostic. **Do not** start with a native SDK — shell out to `bw` for
  Stage 3 and swap in the Bitwarden Rust SDK only if `bw` measurably hurts.

## 4. Staged plan — Stage 1 is a hard gate

**Stage 1 — spike (~1 week). Nothing is rewritten until this passes.**
- One Rust binary: one window, one CEF view, one URL.
- Verify `chrome://gpu` shows hardware acceleration on this machine's Wayland session.
- Verify `bw unlock` + `bw get item` round-trips from Rust.
- Decide Qt-via-cxx-qt vs GTK4 on what the spike actually proved.
- **If GPU or Wayland blocks CEF:** re-run the spike on WebKitGTK/wry and
  re-decide. Do not push through.

**Stage 2 — the chrome (~4–6 weeks).**
Three-row layout, tabs, pinbar driven by `mybar.json`, statusbar with the
selectable/double-click-yank URL, command mode, hints, and the vim keys actually
in daily use. Not all of qutebrowser — the subset that gets used.

**Stage 3 — vaultwarden autofill.**
`bw` CLI + JS injection into the focused form. Track B's B1–B5 as written.

**Stage 4 — run both.** `my-browser-rust` alongside `my-browser-qute` until the
Rust one wins on merit. No cutover date.

## 5. Scope, stated plainly

qutebrowser is 59,336 LOC. An MVP that *feels* the same — tabs, hints, command
mode, sessions, the custom chrome — is realistically **5–8k LOC of Rust**, and
that is with the engine, the config pipeline, and every dashboard page carried
over rather than rebuilt. The fleet already has 18,455 LOC of Rust, so the
toolchain and the Nix packaging path are paved.

Everything not in that 5–8k — adblock, downloads manager, completion engine,
per-domain settings, userscripts, greasemonkey — is deferred, and each one is a
reason to keep `my-browser-qute` installed until it lands.

---

## Open questions for Stage 1

- CEF + Wayland + Nix: does `cef-binary` run unpatched, or does it need the
  usual Chromium sandbox/`ozone-platform` wrapping this repo already does for
  qute?
- Qt-via-cxx-qt vs GTK4 — decided by the spike, not in advance.
- Does dropping to one process for the shell change the RSS story enough to
  matter, or is 125 MB mostly Qt + the WebEngine browser process either way?
  (Measure; do not assume the 125 MB is Python.)

---

## 6. Write less code — what to clone instead of write

Ordered by LOC saved, not by how interesting it is.

### 6.1 The chrome is HTML, not widgets  (biggest single saving)

The three-row layout, pinbar, tabbar and statusbar do **not** need to be Qt or
GTK widgets. Render them in a second CEF view and they are HTML + CSS — the
same thing `dashboard/*.template.html` and `gen-dashboard.sh` already produce.

This deletes the entire "which toolkit" question from §2, removes the `cxx-qt`
C++ shim, and makes "EXACT SAME UI as qute" a CSS problem — which is
*measurable* (screenshot-diff the two) rather than a matter of taste. Rust is
then left owning only the window, the view embedding, the keymap, and IPC.

Cost: chrome repaints go through a compositor pass. Irrelevant for a static bar.

### 6.2 Depend on, don't write

| Project | What it saves | Status (checked 2026-08-29) |
|---|---|---|
| **`tauri-apps/cef-rs`** | the whole CEF FFI layer | 1,105 commits, Linux x86_64 + ARM64, release-plz automation, under the Tauri org |
| **`tauri-apps/tao`** | window + event loop, GTK on Linux | mature (Tauri's winit fork) |
| **qutebrowser's `javascript/`** | hint labelling, element detection — plain JS injected into the page, **portable verbatim** | GPL, same licence as this fork |

Do **not** wait for Tauri's own CEF backend for `wry`: that work is stop-start,
has no ETA, and the maintainers have said it may land as a closed-source or
commercial offering rather than in the Tauri org. Depend on `cef-rs` directly.

### 6.3 Read, don't clone

- **`antoyo/titanium`** — Rust + WebKit2GTK vim browser, ~363 stars, stale but
  not archived. The reference for how command-mode/hints/marks are structured
  in Rust. Read it; don't fork it (wrong engine).
- **Tridactyl / Vimium** hint algorithms, if qute's JS turns out too coupled.

### 6.4 Rejected, with the reason

- **Verso** (Servo) — not daily-usable, and Servo in this nixpkgs is ~2 years stale.
- **Tauri / `wry`** as the framework — Linux means WebKitGTK, which is the
  compat regression §1 rejects. Its own maintainers call WebKitGTK-on-Linux
  unusable. Take `cef-rs` and `tao` out of that org; leave the framework.
- **Firefox/Chromium + Tridactyl** — the true zero-code answer, and it fails
  the brief: no three-row pinbar, no `mybar.json` as source of truth. Named
  here so it stays rejected on purpose rather than by omission.
