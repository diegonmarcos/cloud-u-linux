# agentic-ui

A standalone fork of [goose-desktop](https://github.com/block/goose)'s React
renderer (`ui/desktop/src`), with Electron stripped out entirely. Built as a
plain static Vite app and served locally by my-konsole's Tauri backend
(`src-tauri/src/main.rs`, `tiny_http` on `127.0.0.1:58765`), which floats it in
as a native child webview — the same mechanism the "Web Browser" profile uses
(`WebviewUrl::External`). Pinned as an item under the Agentic profile
(`src/data/profiles/06-agentic/profile.json`), alongside the existing ratatui
dashboard, not replacing it.

## Why this exists

`my-ai-api` (our own deployed service, `cloud/a_solutions/user-ai_my-ai-api`)
already runs upstream goose's own agent server (`goose serve`, ACP protocol)
internally, on `10.0.0.6:3227` — so goose-desktop's own frontend can talk to
it directly. No protocol shim needed, just a build with Electron's IPC layer
replaced by a runtime HTTP fetch.

## Runtime config, not build-time config

Upstream reads the ACP backend URL/secret from Electron main via IPC
(`window.electron.getAcpUrl()` / `getSecretKey()`). This build fetches
`/config.json` at runtime instead (see `src/acp/runtimeConfig.ts`):

```json
{ "goosedUrl": "http://10.0.0.6:3227", "secretKey": "..." }
```

`config.json.example` in this directory documents the shape. The **real**
`config.json` is gitignored — never commit it, it carries the goosed secret.
When served by my-konsole's Tauri backend, `/config.json` isn't a static file
at all — it's synthesized on the fly by the Rust static server, reading
`GOOSE_SERVER__SECRET_KEY` from the environment (same var the `my-ai-api`
container reads from sops). `config.json.example` is only for standalone
`vite dev`/local testing outside of my-konsole.

## What was stripped / stubbed

Electron is gone: no main process, no preload, no IPC bridge. Every
`window.electron.*` / `window.appConfig.*` call site across ~40 component
files is served by a single global shim (`src/electronShim.ts`, installed by
`renderer.tsx` before `App.tsx` renders) rather than editing each call site
individually. The shim:

- Persists the handful of settings the UI actually needs (theme, language,
  etc) to `localStorage`, mirroring what Electron's settings store held.
- No-ops (with a `console.warn`) everything that means real OS/Electron
  integration: native file/save dialogs, dock/tray/menu-bar icons, deep
  links, the auto-updater, opening new OS windows, filesystem access outside
  the browser sandbox. These UI affordances still render — clicking them
  logs a warning and does nothing. Known-not-working, by design:
  - "Check for updates" / update banners
  - Native file/directory picker dialogs (import/export session files)
  - System tray icon, dock icon badge
  - Global keyboard shortcuts (OS-level, outside the webview)
  - Deep link / `goose://` URL handling
  - `powerSaveBlocker` (no effect — not Electron)

The actual agent connection (ACP over WebSocket, chat, tool calls, sessions)
is NOT stubbed — that's the real, rewired path via `runtimeConfig.ts` +
`acpConnection.ts`, talking straight to `goosed`.

## Rebuilding

CI (`ship-my-konsole-app.yml`) runs this automatically on every push to
`main` that touches `da_my-konsole/**`:

```sh
npm ci
npm run build          # → dist/, tarballed as agentic-ui-dist.tar.gz in the release
```

Locally (only if you need to iterate outside CI — the project convention is
"all builds happen in GHA", so prefer pushing and letting CI build):

```sh
npm install
npm run build
```

`build.sh build` (my-konsole's top-level build) stages `dist/` into
`src-tauri/agentic-ui-dist` as a bundled Tauri resource. `build.sh fetch`
downloads the CI-built `agentic-ui-dist.tar.gz` from the rolling
`my-konsole-latest` GitHub release into
`~/.local/share/my-konsole/agentic-ui/dist`, which the running app prefers
over the bundled copy (same user-dir-first pattern as profiles/config).
