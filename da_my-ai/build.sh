#!/usr/bin/env bash
# my-ai universal build engine — 100% data-driven from build.json. Rust workspace:
#   my-ai (CLI) — pure Rust, built for BOTH x86_64 and aarch64 (lean `.#cli` nix
#   shell, no webkit). my-ai-gui (Tauri v2 systray/webview) needs webkit → built
#   only on x86_64 (build.gui_arches) via the `.#default` shell.
# Rust/Tauri compile is heavy → CI (ship-my-ai-app.yml, matrixed per-arch) is the
# normal build path; local `build` is for devs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

command -v jq >/dev/null 2>&1 || { echo "jq required (reads build.json)"; exit 1; }
J() { jq -r "$1" build.json; }
BIN="$(J .app.bin)"; GUI="$(J .app.gui_bin)"; DASH="$(J .app.dash_bin)"
REPO="$(J .build.repo)"; TAG="$(J .build.release_tag)"
STORE="$HOME/$(J .runtime.store_subdir)"
ARCH="$(uname -m)"                                   # x86_64 | aarch64
mapfile -t GUI_ARCHES < <(jq -r '.build.gui_arches[]' build.json)
say() { printf '\033[0;36m[my-ai]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[my-ai] %s\033[0m\n' "$*" >&2; exit 1; }

# Is the Tauri GUI built/shipped for the current arch? (webkit desktop only)
gui_enabled() { local a; for a in "${GUI_ARCHES[@]}"; do [ "$a" = "$ARCH" ] && return 0; done; return 1; }

# Run a command inside a nix devshell (unless already in one). `.#cli` = lean Rust
# toolchain (pure-Rust crates, no webkit); `.#default` = full webkit/tauri toolchain.
# Detect an existing devshell via IN_NIX_SHELL — never `command -v cargo` (CI/dev
# machines ship a system cargo, which would bypass nix). The pkg-config setup hook
# owns PKG_CONFIG_PATH (follows propagatedBuildInputs: gtk3 → pango/cairo/atk/…);
# do NOT override it. -L streams full build logs.
nix_dev() {
  local sh="$1"; shift
  if [ -n "${IN_NIX_SHELL:-}" ]; then "$@"; else nix develop -L ".#$sh" -c "$@"; fi
}

# Ensure src-tauri/icons/*.png exist (tauri build.rs validates these globs even
# under `cargo check`). Render from icon.svg only if `magick` is DIRECTLY on PATH
# — never pull nix just to rasterize an icon. Otherwise ship a valid placeholder
# PNG so validation passes; a real render happens on a dev machine with imagemagick.
icon() {
  mkdir -p src-tauri/icons
  # `tauri::generate_context!` rejects any icon PNG that isn't 8-bit RGBA.
  # ImageMagick's PNG coder auto-picks a colour type from image content —
  # small/flat-looking output (esp. 32x32) can get quantized to a palette
  # (type 3) instead, which built fine locally but panicked the proc macro
  # in CI. `-define png:color-type=6` pins the coder to RGBA regardless of
  # content, so this can't regress silently again.
  if command -v magick >/dev/null 2>&1 && [ -f icon.svg ]; then
    magick -background none icon.svg -resize 256x256 -define png:color-type=6 src-tauri/icons/icon.png    2>/dev/null || true
    magick -background none icon.svg -resize 128x128 -define png:color-type=6 src-tauri/icons/128x128.png 2>/dev/null || true
    magick -background none icon.svg -resize 32x32   -define png:color-type=6 src-tauri/icons/32x32.png   2>/dev/null || true
  fi
  local png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  local f
  for f in icon.png 128x128.png 32x32.png; do
    [ -s "src-tauri/icons/$f" ] || printf '%s' "$png" | base64 -d > "src-tauri/icons/$f"
  done
}

_run_logged() { # <logfile> <cmd...> — tee output, dump tail + exit on failure
  local log="$1"; shift
  "$@" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  [ "$rc" = 0 ] || { say "FAILED (rc=$rc) — tail:"; tail -100 "$log"; exit "$rc"; }
}

cmd_check() {
  say "check core+cli+dash ($ARCH)…"
  _run_logged /tmp/my-ai-cli.log nix_dev cli cargo check -p my-ai-core -p my-ai-cli -p my-ai-dash
  if gui_enabled; then
    say "check gui ($ARCH)…"; icon
    _run_logged /tmp/my-ai-gui.log nix_dev default cargo check -p my-ai-gui
  fi
  say "check ok ($ARCH)"
}

cmd_build() {
  say "build core+cli+dash ($ARCH)…"
  nix_dev cli cargo build --release -p my-ai-cli -p my-ai-dash
  nix_dev cli cargo test -p my-ai-core -p my-ai-cli -p my-ai-dash
  if gui_enabled; then
    say "build gui ($ARCH)…"; icon
    nix_dev default cargo tauri build          # my-ai-gui + .deb bundle
  fi
  say "built $ARCH (gui: $(gui_enabled && echo yes || echo no))"
}

# Stage arch-suffixed release assets into dist-assets/ (CI uploads this dir).
cmd_stage() {
  local d="dist-assets"; rm -rf "$d"; mkdir -p "$d"
  command cp -f "target/release/$BIN"  "$d/$BIN-$ARCH"
  command cp -f "target/release/$DASH" "$d/$DASH-$ARCH"
  if gui_enabled; then
    command cp -f "target/release/$GUI" "$d/$GUI-$ARCH"
    local deb; deb="$(command ls target/release/bundle/deb/*.deb 2>/dev/null | head -1 || true)"
    [ -n "$deb" ] && command cp -f "$deb" "$d/"
  fi
  say "staged for $ARCH: $(command ls "$d" | tr '\n' ' ')"
}

cmd_dev()   { icon; nix_dev default cargo tauri dev; }
cmd_clean() { rm -rf target src-tauri/icons dist-assets; }

# Fetch the CI-built binaries for THIS arch from the rolling GH release.
cmd_fetch() {
  local dir="${1:-$HOME/$(J .runtime.bin_dir)}"; mkdir -p "$dir"
  command -v gh >/dev/null 2>&1 || die "gh CLI required to fetch the CI binaries"
  say "fetching $TAG ($ARCH) from $REPO → $dir"
  local b
  for b in "$BIN"; do
    gh release download "$TAG" -R "$REPO" -p "$b-$ARCH" -O "$dir/$b" --clobber && chmod +x "$dir/$b" \
      || say "($b-$ARCH not in release yet — non-fatal)"
  done
  gh release download "$TAG" -R "$REPO" -p "$DASH-$ARCH" -O "$STORE/$DASH" --clobber && chmod +x "$STORE/$DASH" \
    || say "($DASH-$ARCH not in release yet — non-fatal)"
  if gui_enabled; then
    gh release download "$TAG" -R "$REPO" -p "$GUI-$ARCH" -O "$dir/$GUI" --clobber && chmod +x "$dir/$GUI" \
      || say "($GUI-$ARCH not in release yet — non-fatal)"
  fi
}

# Resolve + cache the webkit runtime lib path for the GUI (my-ai-gui links webkit).
resolve_libpath() {
  local cache="$STORE/runtime-libpath" gcroot="$STORE/runtime-gcroot" sys="$ARCH-linux"
  local libpath=""; [ -s "$cache" ] && libpath="$(command cat "$cache")"
  local first="${libpath%%:*}"
  if [ -z "$libpath" ] || [ ! -e "$first/libwebkit2gtk-4.1.so.0" ]; then
    mkdir -p "$STORE"
    nix build --out-link "$gcroot" "$HERE#devShells.$sys.runtime" >/dev/null 2>&1 || true
    libpath="$(nix eval --raw "$HERE#runtimeLibPath.$sys" 2>/dev/null || true)"
    [ -n "$libpath" ] && printf '%s' "$libpath" > "$cache"
  fi
  printf '%s' "$libpath"
}

# Run a built/fetched binary (default the GUI) with only runtime libs + env.
cmd_run() {
  local b="${1:-$GUI}" bin=""
  if   [ -x "target/release/$b" ]; then bin="target/release/$b"
  elif [ -x "$STORE/$b" ];         then bin="$STORE/$b"
  else cmd_fetch "$STORE"; bin="$STORE/$b"; fi
  [ -x "$bin" ] || die "no binary at $bin (build or fetch first)"
  local k v
  while IFS=$'\t' read -r k v; do export "$k=$v"; done \
    < <(jq -r '.runtime.env | to_entries[] | "\(.key)\t\(.value)"' build.json)
  if [ "$b" = "$GUI" ]; then
    LD_LIBRARY_PATH="$(resolve_libpath):${LD_LIBRARY_PATH:-}" exec "$bin" "${@:2}"
  else
    exec "$bin" "${@:2}"
  fi
}

# install — CLI on PATH; GUI (x86 desktop) gets a self-contained launcher.
cmd_install() {
  local bindir="$HOME/$(J .runtime.bin_dir)"
  mkdir -p "$bindir" "$STORE"
  cmd_fetch "$STORE"
  for b in "$BIN"; do
    [ -x "$STORE/$b" ] && { command cp -f "$STORE/$b" "$bindir/$b"; chmod +x "$bindir/$b"; }
  done
  if gui_enabled && [ -x "$STORE/$GUI" ]; then
    local libpath; libpath="$(resolve_libpath)"
    local envlines; envlines="$(jq -r '.runtime.env | to_entries[] | "export \(.key)=\(.value)"' build.json)"
    {
      echo '#!/usr/bin/env bash'
      echo "# $GUI launcher (generated by build.sh install) — self-contained."
      echo "export LD_LIBRARY_PATH=\"$libpath\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
      echo "$envlines"
      echo "export PATH=\"$bindir:\$PATH\""
      echo "exec \"$STORE/$GUI\" \"\$@\""
    } > "$bindir/$GUI"
    chmod +x "$bindir/$GUI"
    local apps="$HOME/.local/share/applications" icons="$HOME/.local/share/icons/hicolor/scalable/apps"
    mkdir -p "$apps" "$icons"
    command cp -f "$(J .desktop.icon_svg)" "$icons/$GUI.svg" 2>/dev/null || true
    cat > "$apps/$GUI.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$(J .app.product_name)
GenericName=$(J .desktop.generic_name)
Comment=$(J .desktop.comment)
Exec=$bindir/$GUI
Icon=$GUI
Terminal=false
StartupNotify=true
StartupWMClass=$(J .app.wm_class)
Categories=$(J .desktop.categories)
EOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" 2>/dev/null || true
  fi

  # my-ai-usage.service — the daemon that publishes $XDG_RUNTIME_DIR/my-ai-usage.json
  # + .seg, which the status line reads for its 05h-T/05h-S rows. Without this
  # unit, `switch my-ai` drops a working binary but the status line still shows
  # nothing for those rows until a home-manager activation runs (which is the
  # whole reason `switch` exists — see my-konsole-tray.service in
  # da_my-konsole/build.sh for the house pattern this follows).
  #
  # DUPLICATION NOTE: the unit content below is hand-kept in sync with
  # the home-manager module at
  # ba_flakes_desktop/src/app_especific/my-ai/claude-superset.nix
  # (systemd.user.services.my-ai-usage + the my-ai-usage-daemon wrapper it
  # writes). There is no single source both paths read — home-manager activation
  # renders its own unit from Nix, this script renders a matching one from bash.
  # If one changes (interval, MemoryMax, the GUI-then-headless fallback), the
  # other must be updated by hand or they drift.
  local wrapper="$bindir/my-ai-usage-daemon"
  {
    echo '#!/usr/bin/env bash'
    echo "# my-ai-usage-daemon (generated by build.sh install) — mirrors the wrapper"
    echo "# claude-superset.nix writes, so switch-installed and home-manager-installed"
    echo "# machines behave the same."
    echo "# Headless \`my-ai usage --daemon\` is the unit's ExecStart, not the GUI:"
    echo "# it now grows its own ksni systray (cli/src/tray.rs) when a display is"
    echo "# present, so the GUI's webview no longer has to be paid for just to get"
    echo "# a tray icon. my-ai-gui stays a normal user-launched app (desktop file"
    echo "# above) — it was pushing ~134MB against this unit's 128MiB MemoryMax."
    echo 'exec "'"$bindir/$BIN"'" usage --daemon --interval 30'
  } > "$wrapper"
  chmod +x "$wrapper"

  local sysd="$HOME/.config/systemd/user"
  mkdir -p "$sysd"
  cat > "$sysd/my-ai-usage.service" <<EOF
[Unit]
Description=my-ai usage publisher + systray (5h window data for the Claude status line)
ConditionPathExists=$bindir/$BIN
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=$wrapper
# always, not on-failure: a publisher that exits 0 and stays dead leaves the
# status line frozen on stale numbers with no error anywhere — that's what
# happened before this daemon had a tray (251 OOM kills, one clean exit, unit
# stayed down). Restart unconditionally so a stale snapshot is never silent.
Restart=always
RestartSec=30
# No MemoryMax (2026-08-07): a static byte cap kills this unit's own normal
# subprocesses (ld-linux, jq, JITWorker at startup — not a leak) the moment
# they legitimately cross it, regardless of real system pressure. Stays in
# the default slice, governed only by PSI (freeze-guard / systemd-oomd) like
# every other unit. Nice/CPUWeight still keep it low-priority under contention.
Nice=19
CPUWeight=20

[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now my-ai-usage.service 2>/dev/null \
    && say "usage daemon: enabled + started" \
    || say "usage daemon: installed unit, but couldn't start it now (no user session bus?) — will start on next login"

  say "installed $BIN$(gui_enabled && echo ", $GUI" || echo "") → $bindir"
}

case "${1:-build}" in
  check)   cmd_check ;;
  build)   cmd_build ;;
  stage)   cmd_stage ;;
  dev)     cmd_dev ;;
  run)     shift; cmd_run "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  install) cmd_install ;;
  clean)   cmd_clean ;;
  *) die "unknown verb: ${1:-} (check|build|stage|dev|run|fetch|install|clean)" ;;
esac
