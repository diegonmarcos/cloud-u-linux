# tray

Trigger: `daemon-start`. Code: `tray.rs` (ksni StatusNotifierItem, mounted into `my-ai-cli`).

Spawned by the usage daemon when `WAYLAND_DISPLAY`/`DISPLAY` is set. It has no standalone run;
`my-ai engine run tray` explains that and exits non-zero.
