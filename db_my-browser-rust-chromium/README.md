# da_my-browser-rust-chromium

**Rust front-end + Chromium (CEF) backend** — the sibling to `db_my-browser-qute`.

## Why this exists

`db_my-browser-qute` (QtWebEngine) has a **broken TLS fingerprint** — its
ClientHello doesn't match real Chrome, so Cloudflare/Fastly/GitHub-Pages
challenge or block it (measured: Brave passes, qute blocked, same IP). The fix
can't come from qute config: the fingerprint is baked into QtWebEngine's
BoringSSL build.

This project takes the only architecture that gives **(a) a clean Chrome
fingerprint AND (b) total UI control in Rust**:

```
  ┌─────────────────────────────┐
  │  Rust front-end (OUR code)  │   ← window, tab-strip, omnibar, keybinds,
  │  winit + wgpu/skia chrome   │     the mybar-equivalent — all Rust
  ├─────────────────────────────┤
  │  CEF  (libcef, prebuilt)    │   ← real Chromium + BoringSSL
  │  renders web content only   │     → genuine Chrome JA3/JA4 → passes walls
  └─────────────────────────────┘
```

Contrast with the alternatives (all rejected):
- **Fork Brave / patch Chromium source** → 100 GB + hours/build, infeasible on the Surface.
- **Tauri/wry** → uses WebKitGTK on Linux → GnuTLS fingerprint → *also* flagged.
- **Rust + Gecko** → impossible; Mozilla killed desktop Gecko embedding (GeckoView is Android-only).
- **CDP (external Rust drives Chrome)** → controls page content, **cannot** own the browser UI.

CEF is the one path where Rust owns the UI *and* the fingerprint is real Chrome.
Crucially, `cef-rs` links a **prebuilt `libcef`** (fetched, not compiled) — so
this is a normal Rust build, **buildable on the Surface**, unlike a Chromium
source fork.

## Status: SKELETON (not yet a working browser)

This is scaffolding, honestly labelled. What's here vs. what's next:

| Phase | State |
|---|---|
| Project skeleton (build.json / build.sh / flake / Cargo) | ✅ this commit |
| `libcef` fixed-output derivation in flake (pin + sha256) | ⬜ TODO |
| Minimal window: CEF renders one URL in a winit window | ⬜ TODO |
| Rust chrome bar (tab strip + omnibar) — mybar parity | ⬜ TODO |
| Keybindings JSON (SoT shared shape with qute) | ⬜ TODO |
| Fingerprint verification test (tls.peet.ws JA4 == real Chrome) | ⬜ TODO — the acceptance test |
| `nix bundle` portable release (mirror qute's pipeline) | ⬜ TODO |

## Acceptance test (FIRE rule 5)

Done = its JA4 at `https://tls.peet.ws/api/all` matches a current Chrome
profile **and** `https://diegonmarcos.github.io` loads without a challenge —
the exact thing qute fails.

## Layout (mirrors db_my-browser-qute)

```
da_my-browser-rust-chromium/
├── build.sh              engine (verbs: build / run / release / clean)
├── build.json            project metadata + engine config
└── src/
    ├── flake.nix         rust toolchain + prebuilt libcef (fixed-output)
    ├── Cargo.toml        cef-rs + winit
    ├── main.rs           entry — CEF init + window (skeleton)
    └── 2_configs/
        └── keybindings.json   (shared shape with qute's SoT)
```
