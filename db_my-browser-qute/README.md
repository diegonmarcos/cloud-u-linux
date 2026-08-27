# da_my-browser

A *config layer* (not a fork) over upstream qutebrowser that ships as a
home-manager module. Reads four JSON files in `src/2_configs/` and projects
them into qutebrowser's declarative settings/search/keybindings/quickmarks
surface. Edit JSON, switch home-manager, browser config rewrites itself.

## Why

The Bitwarden browser extension provides two things:
1. **Password autofill** — replaced by `~/git/cloud-unix/da_autofill-rbw-rofi/`
   (system-wide hotkey → rofi/wofi picker → keystroke synth).
2. **Passkey / WebAuthn signing** — replaced by
   `~/git/cloud-unix/da_fido2-vault-broker/` (virtual FIDO2 device on /dev/uhid).

With both daemons running, the browser doesn't need an extension for either.
This project picks **qutebrowser** as the daily-driver because:
- ~50k Python LoC — small relative to Brave/Firefox
- Vim-style keybindings; tiny UI chrome
- QtWebEngine (Chromium) → FIDO2 over /dev/hidraw works natively
- Already in nixpkgs → ship via home-manager, no fork
- `programs.qutebrowser` home-manager surface lets us declare every
  setting/keybind/search-engine/quickmark as data

We don't fork. We just own the config.

## What's in this repo

```
da_my-browser/
├── build.json                     SoT (paths, integrations, data sources)
├── build.sh                       engine: lint-json / check / print-config / diff
└── src/
    ├── flake.nix                  exposes homeManagerModules.default
    ├── 2_configs/
    │   ├── qute-settings.json     content blocking, JS, cookies, fonts, etc.
    │   ├── qute-search-engines.json   ddg / g / yt / gh / wp / nix / vault / auth / git
    │   ├── qute-keybindings.json  Ctrl-Shift-{P,U,L,O} → autofill daemon hooks
    │   └── qute-bookmarks.json    quickmarks for the diegonmarcos.com stack
    └── nix/
        └── home-module.nix        reads JSON, projects into programs.qutebrowser
```

## Operator path

This is already wired into the live desktop flake. `ba_flakes_desktop`
declares the monorepo as a non-flake input and imports this module from it:

```nix
# ba_flakes_desktop/src/flake.nix
inputs.unix-repo = { url = "github:diegonmarcos/cloud-unix"; flake = false; };
```

```nix
# ba_flakes_desktop/src/modules/browsers/qute.nix
{ inputs, ... }:
{
  imports = [ "${inputs.unix-repo}/da_my-browser/src/nix/home-module.nix" ];
  programs.da_my-browser = {
    enable = true;
    defaultBrowser = false;   # flip to true to own http(s) via xdg.mime
  };
}
```

The `browsers/qute` leaf is listed in the `productivity` profile
(`ba_flakes_desktop/src/modules/leaves.json`), so it ships with the full
preset. Apply:

```bash
~/git/cloud-unix/ba_flakes_desktop/build.sh switch surface-plasma   # apply
qutebrowser                                                   # daily-driver
```

Because the import resolves through the `unix-repo` github input (pinned in
`flake.lock`), edits to `src/2_configs/*.json` only land after you push the
monorepo and bump the pin — `nix flake lock --update-input unix-repo` (or
`build.sh update`), then `switch`. For an uncommitted local test, build with
`--override-input unix-repo path:/home/diego/git/cloud-unix`.

For a standalone home flake (no monorepo), the generic path still works:
`inputs.da_my-browser.url = "path:../../da_my-browser/src"` then import
`da_my-browser.homeManagerModules.default`.

## Editing the config

```bash
$EDITOR ~/git/cloud-unix/da_my-browser/src/2_configs/qute-search-engines.json
~/git/cloud-unix/da_my-browser/build.sh check       # validate JSON + nix eval
~/git/cloud-unix/cb_user_diego_nix/build.sh switch    # apply
# qutebrowser already running picks up new config on next config-source
```

## Daemon integration

| Daemon | Browser interaction |
|---|---|
| `da_fido2-vault-broker` | Passive — qutebrowser/Chromium discovers /dev/hidraw5 (FIDO2 VID `F1D0`) automatically when WebAuthn is invoked. Zero browser config. |
| `da_autofill-rbw-rofi` | Active — keybindings `Ctrl-Shift-{P,U,L,O}` (in `qute-keybindings.json`) fire the daemon directly from a qutebrowser focus context, on top of the global system-wide hotkey. |

## Status

- ✅ Scaffold + JSON SoT
- ✅ home-manager module (reads JSON, projects to `programs.qutebrowser`)
- ✅ Wired into the live desktop flake — `ba_flakes_desktop/src/modules/browsers/qute.nix`
  imports this module via the `unix-repo` flake input and enables it; the
  `browsers/qute` leaf is in the `productivity` profile (`modules/leaves.json`).
  Apply with `ba_flakes_desktop/build.sh switch surface-plasma`.
- ✅ Theme / colors block — Breeze-Dark palette in `qute-settings.json::colors`
  (statusbar + tabs + `webpage.preferred_color_scheme = dark`)
- ✅ Autofill keybindings fire the daemon with a real action selector
  (`pick`/`user`/`pass`/`totp`) via `spawn --detach`
- ⏳ Userscript dir for advanced integrations (e.g. fire `da_fido2-vault-broker` admin commands from the browser) — optional/future

## Why not fork qutebrowser

Upstream qutebrowser is already minimal and the home-manager surface is rich
enough that "what we'd customise in a fork" is reachable through pure config.
Forking would mean tracking upstream + maintaining patches. Not worth it.

If you ever want a *new* browser engine: see Servo (Rust, research-grade) or
Ladybird (C++, pre-alpha). Both are 5+ year projects. This is not that.
