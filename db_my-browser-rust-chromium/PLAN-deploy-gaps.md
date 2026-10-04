# PLAN — close the gaps and get my-browser-rust-chromium deployed

> **Progress (2026-08-30).** P0 (translation half), P1, P2, P3, P4 and most of P5
> are done and GREEN: 39 unit tests pass, the whole stack compiles, and the
> artifact is published. Content is its own CEF browser, so framed sites load;
> the JS->Rust channel works; qute's built-in keymap (hints, find, scrolling) is
> in. Fixed along the way: drag-to-select, a launcher that dropped URL arguments,
> a Nix URL pointing at a repo that does not exist, an 11-error half-finished
> refactor, and two agents that had built to different wire formats.
>
> **Still not verified: that input reaches CEF at all.** Everything above is
> compile-time and headless-render evidence. Nobody has clicked this window.

Status at time of writing: the chrome shell (bars, tabs, commands, internal pages)
is committed and renders. What is missing is everything that needs the **Rust
side**, plus a declarative install path. This plan closes those.

Ordering rule: verification first, then the bridge everything else needs, then the
one change that removes the biggest ceiling, then deployment.

---

## P0 — Prove input works (blocks trusting anything else) — PARTLY DONE

> Step 1 (pure translation, unit-tested) shipped: 18 tests green in CI, and the
> drag-to-select bug it was written to expose is fixed. **Step 2 (`--selftest`)
> was not built** — so the winit-handler -> CEF leg is still unexercised. Do not
> read "P0 green" as "input works".

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

## P2 — JS -> Rust commands — DONE

`spawn`, `quit`, `close`, `devtools` and a `config-cycle` that actually applies
currently report "unavailable". These need a real channel. Investigate what
cef-rs exposes on the `dev` branch — V8 handler in the render process, process
messages, or a custom scheme handler — and implement the smallest one that works.
Do not add a dependency for this.

## P3 — Kill the iframe ceiling (multi-browser) — DONE

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

## P5 — Polish — PARTLY DONE (check verb extended; window title and wheel calibration outstanding)

- Window title is literally `winit window`; set it from the active page title.
- Wheel `LineDelta * 40.0` is an admitted guess — calibrate against real Chrome.
- `check` verb currently asserts the rows render; extend it to assert the six
  internal pages render non-empty once P1 lands.

---

## P6 — qutebrowser's BUILT-IN keymap — DONE (audited 2026-08-29, built 2026-08-30)

`2_configs/keybindings.json` contains only the 44 **custom overrides**. It does
not contain qutebrowser's own default keymap, so none of that was ever built.
Verified absent by direct lookup, not assumed:

| Missing | What it is |
| --- | --- |
| `f` / `F` | link hints — the most-used qutebrowser feature of all |
| `/` `?` `n` `N` | in-page search |
| `j` `k` `gg` `G` | scrolling |
| `d` | close tab |
| `i` / `v` | insert / caret mode |

Implemented modes are normal/insert/command only — no hint, caret or
passthrough mode — and `:` has no completion engine.

**All of this is blocked on P3, not merely unbuilt.** Hints, find and scrolling
each require reaching into the page's DOM. While content is a cross-origin
iframe that is impossible, full stop. Once content is its own CEF browser, CEF
exposes a real find API and JS can be injected into a browser we own.

So the accurate statement of where this browser stands: it reproduces the qute
*configuration* faithfully (bindings, bookmarks, pins, plugins, palette, row
order) and none of qutebrowser's *built-in behaviour*. Do not describe it as
"matching qute" until this phase is done.

---

## Sequencing

```
P0 ─┬─> P3 ─> P5
    └─> P1 ─> P2
P4 runs in parallel with everything (touches only src/nix + flake)
P6 (qute's built-in keymap) depends on P3 -- it needs DOM access to the content
```

P0, P1 and P4 are independent and can be worked at the same time. P2 depends on
P1's findings. P3 waits for P0's tests.
