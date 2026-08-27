# PLAN — qute plugins manager + full Vaultwarden autofill + Brave-parity toolkit

> Goal: a **minimalist** qutebrowser that still has **all the features** of Chrome/Brave
> (password manager, autofill, dark mode, ad/tracker/fingerprint blocking, reader mode,
> video tools, translate, per-site settings, workspaces) — but every feature is a
> **declarative, data-driven "plugin"** you can **enable/disable easily**, so the
> footprint stays minimal. No bloat running unless you turn it on.

## The hard architectural truth (verified against qutebrowser 3.5.1 source)

qutebrowser has **no WebExtension API and no plugin-manager UI**. It has exactly three
real extension surfaces — every "plugin" we ship is one of these:

1. **Config surface** — `config.py` settings. Runtime-toggleable via `:config-cycle`
   / `:config-dict-add` (both verified present). **Zero footprint when off.** This is
   adblock, dark mode, fingerprint protection, JS on/off, autoplay, per-site settings.
2. **Userscript surface** — `spawn --userscript <name>` + Greasemonkey
   (`content.user_scripts`). **Only runs when invoked or its @match fires.** This is
   Vaultwarden autofill, reader mode, video controls, translate, save-login.
3. **Daemon surface** — external system daemons (already have `da_autofill-rbw-rofi`,
   `da_fido2-vault-broker`). OS-level, browser-agnostic.

**A "plugin" in our system = one entry in `src/2_configs/qute-plugins.json`** declaring
which surface it uses, its enabled state, its config, and its keybinding. The
home-module reads the registry and wires only what's enabled. `:plugins` opens a
generated management page; `:plugin-toggle-<id>` flips it live.

**What genuinely needs a fork (flagged, NOT auto-built):** right-click tab context menu
("Edit URL / Edit Tab Name / Pin"), tab rename, an in-page toolbar-button UI. qutebrowser's
`tabwidget.py` has no context-menu/rename hook — a real Qt-source fork. We give
**command equivalents** instead (Phase 3) and offer the fork as opt-in Phase 5.

---

## Phase 0 — Plugin registry + `:plugins` manager  ← BUILD FIRST (answers "how do I config my plugins")

- `src/2_configs/qute-plugins.json` — the SoT. Each plugin:
  `{id, name, category, surface, enabled, toggle_option?, invert?, userscript?, actions?, keybinding?, description, footprint}`.
- `home-module.nix` reads it and generates, data-driven:
  - `aliases.plugins` → `open <qute-bookmarks.html>#plugins` (the manager page).
  - `aliases."plugins-vaultwarden"` → `open <qute-bookmarks.html>#plugins-vaultwarden`.
  - per config-plugin `aliases."plugin-toggle-<id>"` → `config-cycle <toggle_option> true false`.
  - keybindings from each plugin's `keybinding` (e.g. `,pa` adblock, `,pd` dark, `,pp` plugins page).
  - for enabled config-plugins, apply `settings.<toggle_option>` (registry becomes the
    default-state SoT; the dup keys move out of qute-settings.json — rule 6).
- `gen-dashboard.sh` injects `__PLUGINS_JSON__`; the dashboard template gains a **Plugins
  tab**: one card per plugin — name, category, on/off pill, footprint note, its keybind,
  its toggle command. `#plugins-vaultwarden` deep-links straight to the Vaultwarden card.
- **Tester:** `:plugins` opens the page; `,pa` runtime-toggles `content.blocking.enabled`
  (adblock) with no rebuild; every registry plugin renders a card.

## Phase 1 — Full Vaultwarden autofill (`qute-vault` userscript, extends qute-bitwarden)

Vendor an enhanced userscript into `src/userscripts/qute-vault` (fork of the bundled
`qute-bitwarden`, which only does login user/pass/totp). Backed by `bw` CLI against
`vault.diegonmarcos.com`, keyctl session, auto-lock — same security model, no secrets in config.

- **login**: `user`, `pass`, `user-pass` (Tab), `totp` (2FA) — domain-matched picker.
- **card** (bw type 3): number, cardholder, exp mm/yy, CVV → checkout payment forms.
- **identity** (bw type 4): name, address, city, state, postal, country, phone, email → address forms.
- **save-login** (`:vault-save`): grab current URL + rofi-prompted user/pass → `bw create item` (Brave's "save password?").
- **edit** (`:vault-edit`): pick a domain entry → rofi form → `bw edit` (edit URL/user/pass).
- **add** (`:vault-add`): rofi form (name/url/user/pass) → `bw create`.
- Commands + keybindings: `<Ctrl-Shift-b>` picker, `,vu ,vp ,vt ,vc ,vi ,vs` for the actions.
- **`:plugins-vaultwarden`** opens the Vaultwarden card with all of the above documented + `bw login` status.
- **Tester:** login page → `user-pass` fills; `vault-save` creates an entry; card/identity fill a checkout form.

## Phase 2 — Brave-parity plugin pack (all config/userscript, all toggleable)

Each a registry entry, most OFF-by-default, all runtime-toggleable → minimal footprint:
- **privacy**: adblock (have) + anti-fingerprint (`content.canvas_reading`/`webgl` off), referer trim, DNT, no-3rdparty cookies.
- **dark-mode**: `colors.webpage.darkmode.enabled` + per-site allowlist.
- **reader-mode**: userscript via `readability-lxml` (already in qute's python env — verified in the qute-bitwarden sitedir).
- **video-tools**: userscript — speed ±, PiP, download via `yt-dlp`.
- **translate**: userscript — selection → translate endpoint.
- **per-site**: quick JS/cookies/images toggles for the current domain.
- **greasemonkey manager**: expose `~/.config/qutebrowser/greasemonkey/` in the Plugins page.
- **password-breach / strength**: optional, via bw + HIBP k-anonymity.

## Phase 3 — Tabs, advanced (config-only; context-menu is Phase 5 fork)

- Done: permanent bar (`tabs.show=always`), pinned tabs. Add: tab width, title format,
  favicons, `tabs.last_close`, `tabs.mode_on_change`, close-button behavior — all registry toggles.
- **Workspaces**: named `:session-save`/`:session-load` bound to keys + a workspace switcher on the dashboard.
- Tab search (`:tab-select`), recently-closed list.
- Command equivalents for the wanted context menu: Edit URL = `e`/`E` (have), Pin = `<Ctrl-p>` (have).

## Phase 4 — Distribution & the minimal-footprint guarantee

- Everything flows through `qute-plugins.json` → `build.sh` → standalone bundle + GHCR + GitHub Release (pipeline already exists).
- **Profiles**: `minimal` / `full` plugin sets so footprint is provably bounded and switchable.

## Phase 5 — OPTIONAL native fork (explicit opt-in only)

Only if you accept tracking upstream + maintaining patches: right-click tab context menu
(Edit URL / Edit Tab Name / Pin), tab rename, in-page toolbar buttons. Everything else
above needs **no fork**. Recommend deferring — the command/userscript equivalents cover 95%.

---

### Build order this session: **Phase 0 now** (registry + `:plugins` + `:plugins-vaultwarden`
+ per-plugin toggles + Plugins tab), shipped via the standalone CI pipeline. Phases 1–5 follow.
