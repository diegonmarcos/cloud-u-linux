#!/usr/bin/env bash
# my-konsole engine. 100% DATA-DRIVEN: all identity/config comes from build.json;
# no values are hardcoded here. Heavy steps run inside `nix develop` (flake.nix),
# so the host never needs cargo/webkit/node. Rust/Tauri compile is heavy → CI
# (ship-my-konsole-app.yml) is the normal build path; local `build` is for devs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

log()  { printf '\033[0;36m[my-konsole]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[my-konsole] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq required (reads build.json — the single source of truth)"
cfg() { jq -r "$1" build.json; }

# ── All engine data sourced from build.json (never hardcoded) ──────────────
BIN="$(cfg '.app.bin')"
DASH="${BIN}-dash"          # ratatui TUI-dashboards binary (pure Rust, runs on any TTY)
SHELL_CMD="$(cfg '.app.shell')"
RELEASE_TAG="$(cfg '.build.release_tag')"
REPO="$(cfg '.build.repo')"
STORE="$HOME/$(cfg '.runtime.store_subdir')"

# Emit runtime config = src/data/config.json + a derived `app` block the frontend
# uses for the About panel + updater (repo/release/paths). Single source is
# build.json; paths stay ~-relative (portable → reproducible on any machine,
# the shell expands ~ when the updater command runs). $1 = dest file.
emit_config() {
  jq --arg repo "$REPO" \
     --arg repo_url "https://github.com/$REPO" \
     --arg tag "$RELEASE_TAG" \
     --arg bin "$BIN" --arg dash "$DASH" \
     --arg store "~/$(cfg '.runtime.store_subdir')" \
     --arg clone_dir "~/git/$(basename "$REPO")" \
     --arg subdir "$(cfg '.build.subdir')" \
     '. + {app: {repo:$repo, repo_url:$repo_url, release_tag:$tag, bin:$bin, dash:$dash, store:$store, clone_dir:$clone_dir, subdir:$subdir}}' \
     src/data/config.json > "$1"
}

# Vendor xterm.js browser assets → frontend/vendor. Packages + dest names are
# data (.build.vendor / .build.vendor_map), so adding an addon is a JSON edit.
vendor() {
  log "Vendoring xterm assets…"
  mkdir -p frontend/vendor   # git doesn't track the empty dir; recreate on fresh checkout
  local tmp; tmp="$(mktemp -d)"
  local pkgs; mapfile -t pkgs < <(jq -r '.build.vendor | to_entries[] | "\(.key)@\(.value)"' build.json)
  ( cd "$tmp"; npm init -y >/dev/null 2>&1; npm install --no-audit --no-fund --silent "${pkgs[@]}" >/dev/null 2>&1 )
  local src dst
  while IFS=$'\t' read -r src dst; do
    command cp -f "$tmp/node_modules/$src" "frontend/vendor/$dst"
  done < <(jq -r '.build.vendor_map | to_entries[] | "\(.key)\t\(.value)"' build.json)
  rm -rf "$tmp"
  log "Vendored: $(command ls frontend/vendor | tr '\n' ' ')"
  step_bundle_data
}

# Bundle profiles + config → frontend/data/*.json (static JSON, generated —
# NOT committed). The WebView build (Android cloud-ide + plain browser) has no
# Tauri backend, so its frontend worker fetches these instead of calling
# get_profiles/get_config. Same source (src/data/) as stage_resources/sync_data,
# same sorted-by-dirname order the Rust backend globs in.
step_bundle_data() {
  log "Bundling profiles + config → frontend/data/…"
  mkdir -p frontend/data   # git doesn't track the empty dir; recreate on fresh checkout
  jq -s '{profiles: .}' src/data/profiles/*/profile.json > frontend/data/profiles.json
  emit_config frontend/data/config.json 2>/dev/null || echo '{}' > frontend/data/config.json
  log "Bundled → frontend/data/{profiles,config}.json"
}

# Copy data profiles next to the built binary as Tauri resources (bundled).
stage_resources() {
  # Mirror source — rm first so a renamed/removed profile dir leaves no orphan.
  rm -rf src-tauri/profiles; mkdir -p src-tauri/profiles
  command cp -rf src/data/profiles/* src-tauri/profiles/ 2>/dev/null || true
  # config.json (theme/font/keybindings + derived app block) ships too — read at runtime.
  emit_config src-tauri/config.json 2>/dev/null || true
  # agentic-ui/dist (goose-desktop-derived static build) → bundled resource, so
  # a fresh install works even before the first `build.sh fetch`. CI builds it
  # via `npm run build` in agentic-ui/ before calling build.sh build. Always
  # create the dir (even a placeholder) — tauri's resource-glob validation
  # fails `cargo check`/`cargo tauri build` if "agentic-ui-dist/**/*" matches nothing.
  rm -rf src-tauri/agentic-ui-dist; mkdir -p src-tauri/agentic-ui-dist
  if [ -d agentic-ui/dist ]; then
    command cp -rf agentic-ui/dist/. src-tauri/agentic-ui-dist/
  else
    echo '<!doctype html><title>agentic-ui not built</title>run agentic-ui/npm run build' \
      > src-tauri/agentic-ui-dist/index.html
  fi
}

# Sync repo data (profiles + config) → user dir. The app prefers this over the
# bundled copy, so edits apply on the next launch WITHOUT a rebuild.
sync_data() {
  # Mirror source — rm first so a renamed/removed profile dir leaves no orphan.
  rm -rf "$STORE/profiles"; mkdir -p "$STORE/profiles"
  command cp -rf src/data/profiles/* "$STORE/profiles/" 2>/dev/null || true
  emit_config "$STORE/config.json" 2>/dev/null || command cp -f src/data/config.json "$STORE/config.json" 2>/dev/null || true
  # shared/*.json feed the ratatui dashboards (e.g. cloud-targets.json)
  command cp -f src/data/shared/*.json "$STORE/" 2>/dev/null || true
  # loose top-level data files (e.g. model-pricing.json) also feed the dashboards
  command cp -f src/data/*.json "$STORE/" 2>/dev/null || true
  # systrays.json — read directly by main.rs's setup_systrays() at startup
  command cp -f configs/systrays.json "$STORE/systrays.json" 2>/dev/null || true
  # clipboard.json — tunables for the clipboard-manager tray (clipboard.rs).
  # NOT part of systrays.json: that tray is native ksni, not config-driven
  # (see clipboard.rs's module doc). The runtime store (history/pinned/
  # lists) is separate and lives at $STORE/clipboard-store.json, created by
  # the daemon itself at 0600 — never touched by install.
  command cp -f configs/clipboard.json "$STORE/clipboard.json" 2>/dev/null || true
  # protected-slices.json — read directly by watchdog.rs's process-table kill
  # guard (load_protected_slices/proc_protected_slice), re-read on every kill
  # request so an edit here takes effect without restarting the daemon.
  command cp -f configs/protected-slices.json "$STORE/protected-slices.json" 2>/dev/null || true
  # …and the per-tray SVGs it names. rm first: an icon renamed in the manifest
  # must not keep resolving to the old file left behind here.
  rm -rf "$STORE/systray-icons"; mkdir -p "$STORE/systray-icons"
  command cp -f configs/systray-icons/*.svg "$STORE/systray-icons/" 2>/dev/null || true
  # The watchdog panel widget is NOT installed here any more. It used to be
  # cp -rf'd out of this working tree into ~/.local/share/plasma/plasmoids/,
  # which meant the deployed widget was whatever happened to be checked out —
  # not reproducible from any generation, and invisible to the desktop closure
  # build (whose path filter is ba_flakes_desktop/src/**, so QML edits here
  # never rebuilt it). It now lives in the desktop flake and is installed from
  # an immutable store path by home.activation.installWatchdogPlasmoid:
  #   ba_flakes_desktop/src/modules/dotfiles/kde/plasmoids/com.diegonmarcos.watchdog
  # This app still owns everything it actually produces — binary, launcher,
  # .desktop entry, icon — all driven from build.json as before.
  log "Synced profiles + config + shared + systrays → $STORE"
}

icon() {
  mkdir -p src-tauri/icons
  # Render the personalized icon.svg → PNGs (via imagemagick in the dev shell).
  if [ -f icon.svg ] && nix develop -c magick -background none icon.svg \
        -resize 256x256 src-tauri/icons/icon.png 2>/dev/null; then
    nix develop -c magick -background none icon.svg -resize 128x128 src-tauri/icons/128x128.png 2>/dev/null || true
    nix develop -c magick -background none icon.svg -resize 32x32   src-tauri/icons/32x32.png   2>/dev/null || true
    return 0
  fi
  # Fallback: a valid 1x1 PNG so tauri-build's icon validation still passes.
  [ -f src-tauri/icons/icon.png ] && return 0
  printf '%s' \
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' \
    | base64 -d > src-tauri/icons/icon.png
}

# The ratatui dashboards binary — pure Rust (no webkit/tauri), so it runs on
# any TTY. Built as a separate crate under dash/.
build_dash() {
  log "cargo build (dashboards, release)…"
  nix develop -c cargo build --release --manifest-path dash/Cargo.toml
  log "Built dashboards → dash/target/release/$DASH"
}

cmd_build() {
  vendor; stage_resources; icon
  log "cargo tauri build (release)…"
  nix develop -c cargo tauri build
  build_dash
  log "Built. Bundle under src-tauri/target/release/bundle/"
}

cmd_dev()   { vendor; stage_resources; icon; nix develop -c cargo tauri dev; }
# check also stages resources + icon: tauri's build.rs validates the
# tauri.conf.json `resources`/`icon` globs even under `cargo check`.
cmd_check() {
  stage_resources; icon
  nix develop -c cargo check --manifest-path src-tauri/Cargo.toml
  # watchdog.rs publishes the JSON every plasmoid and the dash read; its
  # name/escape logic has unit tests, and untested is how ld-linux shipped.
  nix develop -c cargo test --manifest-path src-tauri/Cargo.toml --bin my-konsole
  nix develop -c cargo check --manifest-path dash/Cargo.toml
  # plain `cargo check` skips test targets — dash's braille/sort tests would
  # never be compiled, let alone run. It's a small crate; run them.
  nix develop -c cargo test --manifest-path dash/Cargo.toml
}
cmd_clean() { rm -rf src-tauri/target src-tauri/profiles src-tauri/config.json frontend/vendor/*.js frontend/vendor/*.css; }

# Fetch the CI-built binary from the rolling GitHub Release into the store dir.
cmd_fetch() {
  mkdir -p "$STORE"
  command -v gh >/dev/null 2>&1 || die "gh CLI required to fetch the CI binary"
  log "Fetching $BIN + $DASH from GH release $RELEASE_TAG ($REPO)…"
  # Download into a temp dir, then atomically mv over the target. A running
  # binary can't be overwritten in place (ETXTBSY: "text file busy"), but a
  # rename swaps the inode — the running process keeps the old one, the next
  # launch picks up the new one.
  local tmp; tmp="$(mktemp -d "$STORE/.fetch.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "$BIN" --dir "$tmp" --clobber \
    || die "release download failed"
  chmod +x "$tmp/$BIN"; mv -f "$tmp/$BIN" "$STORE/$BIN"
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "$DASH" --dir "$tmp" --clobber 2>/dev/null \
    && { chmod +x "$tmp/$DASH"; mv -f "$tmp/$DASH" "$STORE/$DASH"; } || log "(dashboards binary not in release yet — non-fatal)"
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "agentic-ui-dist.tar.gz" --dir "$tmp" --clobber 2>/dev/null \
    && { rm -rf "$STORE/agentic-ui/dist"; mkdir -p "$STORE/agentic-ui/dist"; \
         tar -xzf "$tmp/agentic-ui-dist.tar.gz" -C "$STORE/agentic-ui/dist"; \
         log "Synced agentic-ui dist → $STORE/agentic-ui/dist"; } \
    || log "(agentic-ui-dist not in release yet — non-fatal)"
  sync_data   # profiles/config must match the binary — never fetch a binary with stale data
  # $DASH runs off $PATH (~/.local/bin), not $STORE — keep that copy in sync too,
  # or a stale $HOME/.local/bin/$DASH silently shadows every fresh fetch.
  if [ -x "$STORE/$DASH" ] && [ -d "$HOME/.local/bin" ]; then
    command cp -f "$STORE/$DASH" "$HOME/.local/bin/$DASH"; chmod +x "$HOME/.local/bin/$DASH"
  fi
  log "Fetched → $STORE/$BIN (restart my-konsole to load it)"
}

# Resolve + cache the webkit runtime lib path. `nix eval` realizes the closure
# (slow first time); the cached value makes later reads instant.
resolve_libpath() {
  local cache="$STORE/runtime-libpath" gcroot="$STORE/runtime-gcroot"
  local sys="$(uname -m)-linux"
  # If the cached path's webkit lib is gone (fresh machine / GC), re-resolve.
  local libpath=""
  [ -s "$cache" ] && libpath="$(command cat "$cache")"
  local first="${libpath%%:*}"
  if [ -z "$libpath" ] || [ ! -e "$first/libwebkit2gtk-4.1.so.0" ]; then
    mkdir -p "$STORE"
    # REALIZE the runtime deps (fetch webkit+gtk from cache — NOT a local build)
    # and pin a gcroot so they survive `nix-collect-garbage`. `nix eval` alone
    # returns store paths WITHOUT realizing them → the launcher would point at a
    # non-existent lib dir. This is the fix for that.
    nix build --out-link "$gcroot" "$HERE#devShells.$sys.runtime" >/dev/null 2>&1 || true
    libpath="$(nix eval --raw "$HERE#runtimeLibPath.$sys" 2>/dev/null || true)"
    [ -n "$libpath" ] && printf '%s' "$libpath" > "$cache"
  fi
  printf '%s' "$libpath"
}

# Launch the binary (local build > fetched) using ONLY runtime libs.
cmd_run() {
  sync_data
  local bin="${1:-}"
  if [ -z "$bin" ]; then
    if   [ -x "src-tauri/target/release/$BIN" ]; then bin="src-tauri/target/release/$BIN"
    elif [ -x "$STORE/$BIN" ];                    then bin="$STORE/$BIN"
    else cmd_fetch; bin="$STORE/$BIN"; fi
  fi
  [ -x "$bin" ] || die "no binary at $bin (build or fetch first)"
  # Runtime env is data-driven (.runtime.env in build.json) — e.g. the WEBKIT
  # software-compositing flags that avoid GBM errors on the Surface iGPU.
  local k v
  while IFS=$'\t' read -r k v; do export "$k=$v"; done \
    < <(jq -r '.runtime.env | to_entries[] | "\(.key)\t\(.value)"' build.json)
  LD_LIBRARY_PATH="$(resolve_libpath):${LD_LIBRARY_PATH:-}" MYK_SHELL="${MYK_SHELL:-$SHELL_CMD}" exec "$bin"
}

# install — self-contained desktop integration (launcher + .desktop + icon),
# all fields from build.json. No home-manager activation needed. Idempotent.
cmd_install() {
  sync_data
  local apps="$HOME/.local/share/applications"
  local icons="$HOME/.local/share/icons/hicolor/scalable/apps"
  mkdir -p "$HOME/.local/bin" "$apps" "$icons"

  # 1. Deploy the binary + a SELF-CONTAINED launcher on PATH (no repo/build.sh
  #    dependency at runtime — webkit libs + env baked in, like a wrapped app).
  local binpath="$STORE/$BIN"
  if [ ! -x "$binpath" ]; then
    if [ -x "src-tauri/target/release/$BIN" ]; then command cp -f "src-tauri/target/release/$BIN" "$binpath"; chmod +x "$binpath";
    else cmd_fetch; fi
  fi
  local libpath; libpath="$(resolve_libpath)"
  local envlines; envlines="$(jq -r '.runtime.env | to_entries[] | "export \(.key)=\(.value)"' build.json)"
  local launcher="$HOME/.local/bin/$BIN"
  {
    echo '#!/usr/bin/env bash'
    echo "# $BIN (generated by build.sh install) — self-contained; no repo needed."
    echo "export LD_LIBRARY_PATH=\"$libpath\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
    echo "$envlines"
    echo "export MYK_SHELL=\"\${MYK_SHELL:-$SHELL_CMD}\""
    echo "exec \"$binpath\" \"\$@\""
  } > "$launcher"
  chmod +x "$launcher"

  # 2. personalized icon → hicolor scalable (KDE resolves SVG by name)
  command cp -f "$(cfg '.desktop.icon_svg')" "$icons/$BIN.svg" 2>/dev/null || true

  # 3. .desktop entry (Name/Exec/Icon/WMClass/etc all from build.json)
  cat > "$apps/$BIN.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$(cfg '.app.product_name')
GenericName=$(cfg '.desktop.generic_name')
Comment=$(cfg '.desktop.comment')
Exec=$launcher
Icon=$BIN
Terminal=false
StartupNotify=true
StartupWMClass=$(cfg '.app.wm_class')
Categories=$(cfg '.desktop.categories')
EOF

  # 4. dashboards binary → ~/.local/bin (pure Rust, self-contained, no wrapper)
  # Take whichever is NEWER, never a fixed preference. Preferring the local
  # target/ was silently reverting the box: this repo builds on GHA only, so
  # dash/target/ here is a months-old leftover, and every `install` clobbered
  # the binary `fetch` had just pulled — you got the old UI back. Comparing
  # mtimes is right in both places: CI's fresh build wins there, the fetched
  # release wins here.
  local dashsrc="" local_dash="dash/target/release/$DASH"
  if [ -x "$local_dash" ] && [ -x "$STORE/$DASH" ]; then
    if [ "$local_dash" -nt "$STORE/$DASH" ]; then dashsrc="$local_dash"; else dashsrc="$STORE/$DASH"; fi
  elif [ -x "$local_dash" ]; then dashsrc="$local_dash"
  elif [ -x "$STORE/$DASH" ]; then dashsrc="$STORE/$DASH"; fi
  [ -n "$dashsrc" ] && log "dashboards ← $dashsrc"
  if [ -n "$dashsrc" ]; then command cp -f "$dashsrc" "$HOME/.local/bin/$DASH"; chmod +x "$HOME/.local/bin/$DASH"; fi

  # 4b. `watchdog` — the name people actually type for full watchdog control.
  #     The tray icon is the always-on indicator; this is the whole surface
  #     (PSI, process table, sorting, kill). Stale ~/.local/bin/watchdog-*
  #     scripts from before the Rust daemon are unrelated and unmanaged.
  {
    echo '#!/usr/bin/env bash'
    echo "# watchdog (generated by build.sh install) — full watchdog control."
    echo "exec \"$HOME/.local/bin/$DASH\" monitor \"\$@\""
  } > "$HOME/.local/bin/watchdog"
  chmod +x "$HOME/.local/bin/watchdog"

  # 5b. systray daemon — my-konsole IS the systray now (native Tauri tray-icon
  #     feature, see src-tauri/src/main.rs setup_systrays()). One persistent
  #     `my-konsole --tray-daemon` process hosts every enabled icon in
  #     configs/systrays.json (already synced to $STORE/systrays.json by
  #     sync_data above). Replaces the old per-tray Electron apps, the
  #     bash/yad scripts, and the one-.desktop-per-tray launcher approach —
  #     real StatusNotifierItem icons, one binary, self-installed, no nix.
  if [ -f configs/systrays.json ]; then
    local sysd="$HOME/.config/systemd/user"
    mkdir -p "$sysd"
    cat > "$sysd/my-konsole-tray.service" <<EOF
[Unit]
Description=my-konsole systray daemon (nixos/watchdog/docker/cloud/vault/workflow icons)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=$launcher --tray-daemon
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now my-konsole-tray.service 2>/dev/null \
      && log "systray daemon: enabled + started ($(jq '.trays | map(select(.enable)) | length' configs/systrays.json) icon(s))" \
      || log "systray daemon: installed unit, but couldn't start it now (no user session bus?) — will start on next login"
  fi

  # 6. refresh caches (best-effort — no failure if the tools are absent)
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" 2>/dev/null || true
  command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  log "Installed launcher + desktop entry + icon + dashboards ($DASH)"
}

case "${1:-build}" in
  build)    cmd_build ;;
  dev)      cmd_dev ;;
  check)    cmd_check ;;
  run)      shift; cmd_run "${1:-}" ;;
  fetch)    cmd_fetch ;;
  install)  cmd_install ;;
  data)     sync_data ;;
  clean)    cmd_clean ;;
  vendor)   vendor ;;
  bundle-data) step_bundle_data ;;
  *)        echo "Usage: $0 [build|dev|check|run|fetch|install|data|clean|vendor|bundle-data]" ;;
esac
