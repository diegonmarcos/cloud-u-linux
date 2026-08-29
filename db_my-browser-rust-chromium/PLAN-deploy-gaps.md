# PLAN — close the gaps and get my-browser-rust-chromium deployed

> **Progress (2026-08-29).** P0, P1 and P4 are done, green in CI (18 input unit
> tests pass) and published to the rolling release. P2 and P3 remain. Fixed along
> the way: drag-to-select (held-button bits were never sent to CEF), a launcher
> that silently dropped URL arguments so `%U`/`defaultBrowser` opened the homepage,
> and a Nix release URL pointing at a repo that does not exist.

Status at time of writing: the chrome shell (bars, tabs, commands, internal pages)
is committed and renders. What is missing is everything that needs the **Rust
side**, plus a declarative install path. This plan closes those.

Ordering rule: verification first, then the bridge everything else needs, then the
one change that removes the biggest ceiling, then deployment.

---

## P0 — Prove input works (blocks trusting anything else) — DONE

Nobody has confirmed mouse/keyboard/scroll reach CEF. The forwarding code was
written, compiled, and never exercised. Until this is closed every other feature
is unverifiable, because you cannot click it.

Injection at the OS level is closed to us (no virtual-keyboard protocol on this
compositor, `/dev/uinput` is root-only, xdotool cannot see native-Wayland
windows). So split the problem where it is actually separable:

1. **Pure translation, unit-tested.** Extract `winit event -> CEF event struct`
   into `src/overlay/src/input.rs` as free functions with no CEF calls. Test key
   codes, modifier bits, click counts and wheel deltas with `cargo test`. This is
   where the known bug lives: mouse events never stamp the button-down bit into
   `modifiers`, so drag-to-select is predicted broken.
2. **`--selftest` for the CEF leg.** A flag that feeds synthetic winit events
   through the *same* handler, then asserts via injected JS that the page saw the
   corresponding DOM events. Exits non-zero on failure so CI can run it headless.

That covers both legs without a human in the loop. What it does **not** cover is
the compositor -> winit leg; that one genuinely needs a person to click once.

## P1 — Rust -> JS state channel (no IPC required) — DONE

The shell needs data that only Rust has (downloads, real page titles, load
progress). Rather than standing up CEF IPC for this, Rust writes a generated
script next to the bundle:

```
shell/state/downloads.js   ->  window.__DOWNLOADS = [ ... ];
```

and the page re-inserts that `<script>` tag on an interval. This works from
`file://`, where `fetch`/XHR are blocked by the opaque-origin rule — which is
exactly why the obvious approach fails.

> ponytail: a generated script tag is a poor man's IPC. Ceiling: it is one-way
> (Rust -> JS) and polls. Upgrade path is a real CEF message router once JS -> Rust
> is needed for more than the few commands in P2.

## P2 — JS -> Rust commands

`spawn`, `quit`, `close`, `devtools` and a `config-cycle` that actually applies
currently report "unavailable". These need a real channel. Investigate what
cef-rs exposes on the `dev` branch — V8 handler in the render process, process
messages, or a custom scheme handler — and implement the smallest one that works.
Do not add a dependency for this.

## P3 — Kill the iframe ceiling (multi-browser)

The single biggest limitation: `X-Frame-Options` / `frame-ancestors` means Google,
GitHub and most banks refuse to render in `<iframe id=view>`. Content must become
its own CEF browser, not an iframe.

Blocked today by a single global `TEXTURE` and `browser: Option<Browser>`
(`src/overlay/src/main.rs:255`). Required:

- key `TEXTURE` by `browser.identifier()`,
- one `OsrRenderHandler` / `Client` per browser,
- N quads in the wgpu render pass: chrome browser drawn full-window, content
  browser drawn in the content rect below the chrome rows,
- route input by hit-testing the cursor against the content rect.

This is the largest change and it rewrites `main.rs`. It lands **after** P0, so
there are input tests to catch what it breaks.

## P4 — Declarative deploy (the actual "deployed" part) — DONE

`build.sh install` is an imperative one-off. The repo's idiom is Nix, and qute
already shows the shape (`db_my-browser-qute/src/nix/`: `package.nix`,
`home-module.nix`, `standalone.nix`).

- `src/nix/package.nix` — wrap the CI-produced tarball (do **not** build CEF in
  Nix; CI is the only compiler here).
- `src/nix/home-module.nix` — `xdg.desktopEntries`, config files into
  `~/.config/my-browser-rust-chromium/`, matching qute's `StartupWMClass` pattern.
- `src/flake.nix` — fill in `packages.default` (the TODO at line 43) and export
  the home module.
- Commit `dist/` per repo convention, and gate the release verbs on `enabled`.

Once this lands the browser installs the same way everything else here does, and
`build.sh install` becomes the escape hatch rather than the path.

## P5 — Polish

- Window title is literally `winit window`; set it from the active page title.
- Wheel `LineDelta * 40.0` is an admitted guess — calibrate against real Chrome.
- `check` verb currently asserts the rows render; extend it to assert the six
  internal pages render non-empty once P1 lands.

---

## Sequencing

```
P0 ─┬─> P3 ─> P5
    └─> P1 ─> P2
P4 runs in parallel with everything (touches only src/nix + flake)
```

P0, P1 and P4 are independent and can be worked at the same time. P2 depends on
P1's findings. P3 waits for P0's tests.
