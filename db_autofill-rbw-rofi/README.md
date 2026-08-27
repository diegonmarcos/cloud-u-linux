# da_autofill-rbw-rofi

System-wide hotkey password and TOTP autofill on Linux, backed by
[`rbw`](https://github.com/doy/rbw) (Bitwarden / Vaultwarden CLI). Replaces
the *autofill* path of the Bitwarden browser extension — but works in **any**
focused window, not just browsers: terminals, ssh prompts, KeePassXC unlock,
native apps, browsers, anything that takes keystrokes.

Pick an entry from a `rofi`/`wofi` picker, then the username/password are
typed straight into the focused field via `wtype` (Wayland) or `xdotool`
(X11). Single-shot, ~10 MiB peak RSS, no resident daemon — the binary is
invoked on a hotkey by `systemd --user`.

Companion: passkey/WebAuthn signing is handled separately by
`~/git/cloud-unix/da_fido2-vault-broker/` (virtual FIDO2 device on /dev/uhid).
Together the two replace both halves of the Bitwarden browser extension.

All runtime behaviour is declarative — the picker, typer, clipboard, action
list, default action, TOTP-clipboard timeout and slow-typing settings live
in `build.json` and are read by the binary on every run.

## Install

```sh
./build.sh build      # cargo build --release inside the project's nix flake
./build.sh install    # places binary at ~/.local/bin and unit at ~/.config/systemd/user
```

## Enable on login

```sh
./build.sh enable     # systemctl --user enable --now da_autofill-rbw-rofi.service
```

The service is `Type=oneshot`; it does not stay resident. "Enabling" here
just makes sure it can be started by your hotkey daemon — the actual
trigger is whatever shortcut you bind below.

## Hotkey recipes

In every case the action you bind is just:

```sh
systemctl --user start da_autofill-rbw-rofi.service
```

### KDE Plasma

System Settings -> Shortcuts -> Custom Shortcuts -> Edit -> New ->
Global Shortcut -> Command/URL.

- Trigger: `Super+P`
- Action: `systemctl --user start da_autofill-rbw-rofi.service`

### Hyprland

```hyprlang
bind = SUPER, P, exec, systemctl --user start da_autofill-rbw-rofi.service
```

### Sway / i3

```text
bindsym $mod+p exec --no-startup-id systemctl --user start da_autofill-rbw-rofi.service
```

### GNOME

```sh
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']" \
  && gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'rbw-rofi' \
  && gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'systemctl --user start da_autofill-rbw-rofi.service' \
  && gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>p'
```

## Configure rbw

Before the first hotkey trigger you need a working `rbw` install pointed at
your Bitwarden / Vaultwarden instance.

```sh
rbw config set base_url <YOUR_VAULTWARDEN_URL>
rbw config set email    <YOUR_EMAIL>
rbw login
rbw unlock
```

The picker just shells out to `rbw list / rbw get / rbw code`; this binary
holds no credentials of its own.

## Behaviour

1. Picker opens with vault entries (`name (username)`).
2. Pick an entry -> Enter.
3. Picker re-opens with the action menu (default first):
   - `user_tab_pass` (default) — types username, Tab, password
   - `user`                    — types username only
   - `pass`                    — types password only
   - `totp`                    — copies TOTP to clipboard, auto-clears after
                                 `runtime.totp_to_clipboard_seconds` (build.json)
4. Press Esc / cancel at either picker -> exit cleanly.

Secrets are fed to `wtype` / `xdotool` via stdin (never argv) so they do
not appear in `/proc/<pid>/cmdline`. The in-memory copy is zeroized after
typing.

## Slow-typing mode

Some sites debounce keystrokes too aggressively for the default zero-delay
typing speed. Set `DA_AUTOFILL_RBW_ROFI_SLOW=1` and re-trigger the hotkey:

```sh
DA_AUTOFILL_RBW_ROFI_SLOW=1 systemctl --user start da_autofill-rbw-rofi.service
```

The delay-ms value is read from `build.json::runtime.slow_typing_delay_ms`.

## Troubleshooting

- **"Vault locked" notification** — run `rbw unlock`.
- **Nothing happens** — check the unit's status:
  `systemctl --user status da_autofill-rbw-rofi.service`
- **Picker not found** — install `rofi` (X11) or `wofi` (Wayland) per your
  distro, or edit `build.json::runtime.picker.{wayland,x11}` to point at
  the picker you actually have.
- **Nothing types** — confirm the right typer is installed for your
  display server (`wtype` for Wayland, `xdotool` for X11). Run with debug
  logging by editing the unit (`systemctl --user edit
  da_autofill-rbw-rofi.service`) and adding
  `Environment=RUST_LOG=debug`. Check the journal:
  `journalctl --user -u da_autofill-rbw-rofi.service -n 100`.
- **`build.json` not found** — by default the binary walks up from the
  current directory and from its own location. Override with
  `DA_AUTOFILL_RBW_ROFI_CONFIG=/abs/path/to/build.json`, or drop a copy
  under `$XDG_CONFIG_HOME/da_autofill-rbw-rofi/build.json`.

## Files

```
da_autofill-rbw-rofi/
|-- build.json            declarative runtime config (single source of truth)
|-- build.sh              build / test / install / enable engine
|-- src/
|   |-- Cargo.toml        crate manifest
|   |-- Cargo.lock        pinned deps
|   |-- flake.nix         reproducible nix dev shell + buildRustPackage
|   |-- systemd/
|   |   `-- da_autofill-rbw-rofi.service   user-level oneshot unit
|   `-- src/
|       |-- main.rs       orchestrator (picker -> vault -> typer)
|       |-- config.rs     build.json loader
|       |-- env.rs        Wayland / X11 detection + argv splitter
|       |-- picker.rs     rofi/wofi/dmenu wrapper
|       |-- typer.rs      wtype / xdotool wrapper (stdin only, zeroize)
|       `-- vault.rs      rbw subprocess wrapper
`-- dist/
    `-- da_autofill-rbw-rofi    release binary (after ./build.sh build)
```
