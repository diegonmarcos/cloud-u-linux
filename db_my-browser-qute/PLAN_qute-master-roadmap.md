# PLAN — my-browser (qute) MASTER ROADMAP

> **The thesis:** a browser as light as raw qutebrowser but with **every capability
> Chrome/Brave have** — password manager, autofill, ad/tracker/fingerprint blocking,
> dark mode, reader, translate, video tools, containers, sync, workspaces — where
> **each capability is a declarative, data-driven "plugin" you enable/disable at will**,
> so the running footprint is always exactly what you asked for and nothing more.
>
> Companion doc: `PLAN_plugins-vaultwarden.md` (plugin-system + Vaultwarden detail).
> This file is the umbrella roadmap: all tracks, priorities, and the fork boundary.

## Architecture invariants (never violated)

- **JSON SoT → home-module → programs.qutebrowser.** Every feature is data in
  `src/2_configs/*.json`; the Nix module projects it. No imperative config.
- **Three extension surfaces only** (verified against qutebrowser 3.5.1 source):
  `config` (settings, `:config-cycle`, zero footprint off), `userscript`
  (`spawn --userscript` / greasemonkey, runs only when invoked), `daemon`
  (system service, browser-agnostic). Everything below maps to one of these — or,
  explicitly flagged, needs the **fork** (Track L).
- **Minimal by default.** New plugins ship OFF or lazy; profiles bound the set.
- **Ship via GitHub Release + GHCR** (pipeline exists). Desktop consumes the Release.
- **Every track ends with a tester.** A config change isn't done until something proves it.

---

## Track A — Plugin system maturation  (builds on Phase 0, HIGH)
- A1. **Live enable/disable persistence.** Config-plugin toggles are live via
  `:config-cycle` but don't survive a restart unless written back. Add
  `:plugin-set <id> on|off` that writes the state into a gitignored
  `~/.config/qutebrowser/plugin-state.py` sourced by config.py (runtime overrides,
  declarative defaults still win on rebuild). Tester: toggle, restart, state holds.
- A2. **Profiles.** `qute-profiles.json`: `minimal` / `daily` / `dev` / `locked-down`
  plugin sets. `:profile <name>` swaps the enabled set live. Footprint provably bounded.
- A3. **Plugin health in the Plugins tab.** Show each plugin's actual runtime state
  (read live via `:config-dict` / userscript presence), not just the declared default.
- A4. **Greasemonkey manager.** Surface `~/.config/qutebrowser/greasemonkey/` scripts
  as plugins (list, enable/disable via `content.user_scripts`), so third-party
  userscripts are first-class.

## Track B — Vaultwarden: full password manager parity  (HIGH — see companion plan)
- B1. login user/pass/TOTP (have). Card (bw type 3) + identity/address (type 4) autofill.
- B2. **Save login** (`:vault-save`) — Brave's "save password?" via `bw create`.
- B3. **Edit / add** (`:vault-edit`, `:vault-add`) — change URL/user/pass, add entries.
- B4. **Generate password** (`:vault-gen`) — `bw generate` into the focused field.
- B5. Vault status in the Plugins tab (locked/unlocked, item counts, last sync).
- All via `bw` CLI against `vault.diegonmarcos.com`, keyctl session, auto-lock, no fork.

## Track C — Tabs, windows & workspaces  (HIGH)
- C1. Done: permanent bar, pinned tabs (index-safe), open-saved-tabs, session restore.
- C2. **Workspaces.** Named `:session-save`/`:session-load` sets bound to keys +
  a workspace switcher card on the dashboard. "Work / personal / research" tab sets.
- C3. **Tab search & recently-closed** surfaces (`:tab-select`, undo list on dashboard).
- C4. Tab tuning as config plugins: width, title format, favicons, `last_close`,
  `mode_on_change`, close-button, `tabs.new_position`.
- C5. **Tree/stacked tabs** — qutebrowser has `tabs.tree_tabs` (verify version) OR
  a userscript; if neither, flag for Track L. Confirm before building.
- ⚠️ Right-click "Edit URL / Edit Tab Name / Pin" context menu → **Track L (fork)**.
  Command equivalents exist now: `e`/`E` edit URL, `<Ctrl-p>` pin.

## Track D — Privacy & security suite  (HIGH)
- D1. Anti-fingerprint plugin (have canvas; add `webgl`, `content.headers.user_agent`
  rotation, `content.headers.referer` trim, `content.webrtc_ip_handling_policy`).
- D2. **Container / ephemeral tabs** — `:open -p` private window per identity;
  a "temp container" plugin that opens throwaway sessions. Verify isolation depth.
- D3. **Per-site settings plugin** — quick JS/cookies/images/geolocation toggles for
  the current domain (`config.set(..., pattern=<domain>)`), listed on the dashboard.
- D4. **Cookie & data manager** — `:cookies` page/command; clear-on-close allowlist.
- D5. HTTPS-only, DNS-over-HTTPS check, and a security posture card on the dashboard.
- D6. Passkeys (fido2 broker, have) surfaced in the Plugins/Security tab.

## Track E — Content & media tools  (MED)
- E1. **Reader mode** — readability-lxml (already in qute's python env) userscript →
  strip to article, toggle. `,r`.
- E2. **Dark reader** — beyond native darkmode: a userscript/user-stylesheet with a
  per-site allowlist for sites the native mode mishandles.
- E3. **Translate** — selection → translate endpoint (self-hostable), inline result.
- E4. **Video tools** — playback speed ±, picture-in-picture, `yt-dlp` download,
  sponsorblock-style skip (userscript). `,V` menu.
- E5. **Download manager** — a dashboard card over `qute://downloads` + `~/Downloads`.
- E6. **Screenshot / clip** — KDE Spectacle integration (already on the system).

## Track F — Search, navigation & the omnibox  (MED)
- F1. Search-engine pack expansion (qute-search-engines.json) + bang syntax (!g !yt !gh).
- F2. **History & quickmark intelligence** — frecency-ranked completion, the dashboard
  "Last Sessions" already pulls history; add a full history search page.
- F3. **Smart bookmarks** — the cloud/front auto-discovered folders (have) + tags,
  and a "add current page to bookmarks" flow writing back to qute-bookmarks.json.
- F4. Custom `qute://` start-page as the new-tab (the dashboard already is this).

## Track G — Dashboard / new-tab evolution  (MED)
- G1. Widgets: weather, calendar (radicale), mail count (maddy), infra health
  (already have a Health tab) — all from your own self-hosted APIs, opt-in cards.
- G2. Command palette on the dashboard mirroring `:` with fuzzy plugin/bookmark/action search.
- G3. Theming: the dashboard already tracks Breeze Dark; add a light/dark toggle synced
  to `colors.webpage.preferred_color_scheme`.

## Track H — Performance & the minimal-footprint guarantee  (MED)
- H1. **Profiles (Track A2) are the footprint control** — `minimal` disables adblock
  lists reload, userscripts, heavy features; measured RSS delta documented.
- H2. Lazy session restore (`session.lazy_restore` — verified present) default on.
- H3. Process-model & cache tuning as config plugins (`qt.args`, cache sizes).
- H4. A `:footprint` command → dashboard card showing enabled plugins + their cost.

## Track I — Sync & multi-device  (MED)
- I1. Config already syncs via git (the whole repo). Add **bookmark/quickmark sync**
  from the same JSON SoT so termux/other machines share the set.
- I2. Vault (Vaultwarden) already syncs cross-device natively — document the flow.
- I3. History/session sync via a self-hosted endpoint (syncthing already in the stack) — opt-in.

## Track J — Testing & CI hardening  (HIGH — currently thin)
- J1. **Config load test**: CI already builds config.py; add a headless
  `qutebrowser --temp-basedir -C config.py :quit` smoke that fails on any load error
  (catches the exact SyntaxError class we hit this session).
- J2. **Registry lint**: schema-validate qute-plugins.json / qute-*.json (jq + a schema)
  in `build.sh check`.
- J3. **Userscript tests**: each userscript (vault, reader, …) gets a dry-run unit
  (mock `bw`, assert the emitted `:fake-key`/fifo commands).
- J4. **gen-dashboard golden test**: assert token injection is byte-exact (regression
  guard for the awk `&` bug fixed this session).

## Track K — Distribution & release ergonomics  (LOW — pipeline exists)
- K1. Versioning + CHANGELOG from commits; the rolling `qute-standalone-latest` tag
  gains semver tags too.
- K2. In-browser "update available" card (compare bundled rev vs GHCR/Release rev).
- K3. One-command bootstrap for a fresh machine (`build.sh install-standalone`).

## Track L — OPTIONAL native fork  (LOW — explicit opt-in only)
Only if you accept tracking upstream + maintaining a patch series. Everything above is
**no-fork**. These genuinely need Qt-source changes (verified: no API exists):
- L1. Right-click tab context menu (Edit URL / Edit Tab Name / Pin / Duplicate).
- L2. Tab rename (custom titles independent of page `<title>`).
- L3. In-page toolbar buttons / an extension-style action bar.
- L4. A true settings GUI (vs the current `:config-edit` + dashboard reference).
Recommendation: **defer.** Command/userscript/dashboard equivalents cover ~95%; a fork
is a permanent maintenance tax on a project whose whole point is minimalism.
- L5. **Dual tab-strip layout** (opt-in 2026-07-10) — a SECOND `QTabWidget`/`TabBar`
  for pinned tabs, visually separate from the regular-tabs strip, with MyBar (bookmark
  bar removed once bookmarks live as a pinned tab; plugin icons only) as a third row.
  Real surgery: every tab-indexed keybinding/command (`H`/`L`, `tab-focus <N>`,
  `tab-move`, `tab-close`, session save/restore, `tabbed_browser.widget` call sites
  across `mainwindow.py`/`tabbedbrowser.py`/`app.py`) must route by pinned-state across
  TWO widgets instead of one. Default pinned set = `localhost:8000`, `qute-bookmarks.html`,
  Qwant — from `qute-default-window.json`. Needs its own dedicated session: prototype
  the second QTabWidget + minimal routing first, verify tab-index-dependent keybinds
  don't silently break, THEN wire pin/unpin to move a tab between strips.
- L6. **Full network-traffic capture / export** (opt-in 2026-07-10) — "export everything
  the browser saw for this site", including XHR/fetch API response bodies (e.g.
  LinkedIn's server-rendered JSON), not just the rendered DOM (native `page.save()`
  MHTML would miss those). Needs QtWebEngine's remote-debugging port (Chromium DevTools
  Protocol) + a CDP client that subscribes to `Network.responseReceived` /
  `Network.getResponseBody`, a storage format (per-site capture session → directory of
  request/response pairs), and `:capture-start` / `:capture-stop` / `:capture-export`
  commands. New daemon-class component, not a MyBar tweak — own PLAN doc before coding.
Both L5/L6 confirmed in-scope by the operator (not deferred) — sized here so the next
session starts with a real plan instead of re-deriving scope from scratch.

---

## Suggested execution order

1. **A1–A2** (toggle persistence + profiles) — makes the plugin system real & footprint-bounded.
2. **B1–B3** (Vaultwarden cards/identities/save) — the biggest daily-use gap vs Brave.
3. **J1–J2** (config smoke test + registry lint) — stops the recurring "switch broke" class.
4. **C2, D3, E1** (workspaces, per-site settings, reader) — highest UX payoff.
5. Everything else by demand.

Each step: JSON/source change → `build.sh check` → standalone CI → verify config.py →
desktop `switch` → launch & drive. No step is done without its tester (Fire Rule 5).
