# my-konsole-engine on Termux

Runs the `my-konsole-engine` ws-PTY server (statically-linked, `aarch64-unknown-linux-musl`)
on-device in Termux, so the my-konsole WebView app can connect to
`ws://127.0.0.1:7333` and get a real PTY/shell.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/diegonmarcos/cloud-unix/main/da_my-konsole/termux/install.sh | bash
```

This fetches `my-konsole-engine-aarch64` from the rolling `my-konsole-latest`
GitHub release, installs it to `$PREFIX/bin/my-konsole-engine`, and writes a
Termux:Boot autostart script at `~/.termux/boot/my-konsole-engine`. Re-run any
time to update to the latest build.

## Termux:Boot (autostart on device boot)

The boot script only runs if the separate **Termux:Boot** app (F-Droid add-on,
not on Play Store) is installed AND opened at least once — Android won't grant
boot-receiver permissions otherwise. After installing Termux:Boot, open it
once, then reboot (or `am start` it) to confirm `my-konsole-engine` comes up.

Without Termux:Boot, start the engine manually:

```sh
my-konsole-engine &
```

## Keeping it alive

Android's doze/app-standby can suspend Termux's background process. If the
engine gets killed while the app is backgrounded, run:

```sh
termux-wake-lock
```

(needs `termux-api` installed: `pkg install termux-api`). This holds a
partial wake lock so the engine survives doze between WebView sessions.

## Manual verify

```sh
my-konsole-engine &
curl -sv http://127.0.0.1:7333 2>&1 | head -5   # expect a 101/upgrade-ish response, not connection-refused
```

The engine binds `127.0.0.1:7333` by default (`MYK_ENGINE_ADDR` overrides).
