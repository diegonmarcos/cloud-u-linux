#!/usr/bin/env bash
# my-ai universal build engine — 100% data-driven from build.json. Rust workspace:
#   my-ai (CLI) + my-ai-dash (ratatui TTY) built with cargo; my-ai-gui (Tauri v2
#   systray/webview) built with cargo-tauri (+ .deb). Heavy steps run inside
#   `nix develop` (flake.nix) so the host never needs cargo/webkit. Rust/Tauri
#   compile is heavy → CI (ship-my-ai-app.yml) is the normal build path.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

command -v jq >/dev/null 2>&1 || { echo "jq required (reads build.json)"; exit 1; }
J() { jq -r "$1" build.json; }
BIN="$(J .app.bin)"; DASH="$(J .app.dash_bin)"; GUI="$(J .app.gui_bin)"
REPO="$(J .build.repo)"; TAG="$(J .build.release_tag)"
STORE="$HOME/$(J .runtime.store_subdir)"
mapfile -t ARTIFACTS < <(jq -r '.build.artifacts[]' build.json)
say() { printf '\033[0;36m[my-ai]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[my-ai] %s\033[0m\n' "$*" >&2; exit 1; }

# Run a command with the Rust/webkit toolchain. Detect the nix devshell via
# IN_NIX_SHELL — NOT `command -v cargo`: CI runners (and dev machines) ship a
# system cargo, so a cargo-presence check would bypass nix entirely and miss
# glib/webkit/pkg-config. When not already in a devshell, enter `nix develop`
# and INJECT the pkg-config + lib paths into the command's env via `env VAR=…`
# (`nix develop -c` does not reliably apply the shellHook / mkShell env vars).
_NSYS="$(uname -m)-linux"
in_shell() {
  if [ -n "${IN_NIX_SHELL:-}" ]; then
    "$@"
  else
    local pcp lp
    pcp="$(nix eval --raw ".#pkgConfigPath.$_NSYS" 2>&1)" || die "nix eval pkgConfigPath failed: $pcp"
    lp="$(nix eval --raw ".#runtimeLibPath.$_NSYS" 2>&1)" || die "nix eval runtimeLibPath failed: $lp"
    say "PKG_CONFIG_PATH=$pcp"
    [ -n "$pcp" ] || die "resolved PKG_CONFIG_PATH is empty (.#pkgConfigPath.$_NSYS)"
    nix develop -c env PKG_CONFIG_PATH="$pcp" LD_LIBRARY_PATH="$lp" "$@"
  fi
}

# Render icon.svg → src-tauri/icons PNGs (tauri build.rs validates these globs even
# under `cargo check`). Fallback: a valid 1×1 PNG so validation still passes.
icon() {
  mkdir -p src-tauri/icons
  if [ -f icon.svg ] && in_shell magick -background none icon.svg -resize 256x256 src-tauri/icons/icon.png 2>/dev/null; then
    in_shell magick -background none icon.svg -resize 128x128 src-tauri/icons/128x128.png 2>/dev/null || true
    in_shell magick -background none icon.svg -resize 32x32   src-tauri/icons/32x32.png   2>/dev/null || true
    return 0
  fi
  [ -f src-tauri/icons/icon.png ] && return 0
  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' | base64 -d > src-tauri/icons/icon.png
  command cp -f src-tauri/icons/icon.png src-tauri/icons/128x128.png
  command cp -f src-tauri/icons/icon.png src-tauri/icons/32x32.png
}

cmd_check() {
  icon
  in_shell cargo check --workspace
}

cmd_build() {
  icon
  in_shell cargo build --release -p my-ai-cli -p my-ai-dash
  in_shell cargo test -p my-ai-core -p my-ai-cli
  in_shell cargo tauri build          # my-ai-gui + .deb bundle
  say "built: ${ARTIFACTS[*]} (+ .deb)"
}

cmd_dev()   { icon; in_shell cargo tauri dev; }
cmd_clean() { rm -rf target src-tauri/icons; }

# Fetch the CI-built binaries from the rolling GH release into a dir (default bin_dir).
cmd_fetch() {
  local dir="${1:-$HOME/$(J .runtime.bin_dir)}"; mkdir -p "$dir"
  command -v gh >/dev/null 2>&1 || die "gh CLI required to fetch the CI binaries"
  say "fetching $TAG from $REPO → $dir"
  for b in "${ARTIFACTS[@]}"; do
    gh release download "$TAG" -R "$REPO" -p "$b" -O "$dir/$b" --clobber && chmod +x "$dir/$b" \
      || say "($b not in release yet — non-fatal)"
  done
}

# Resolve + cache the webkit runtime lib path for the GUI (my-ai-gui links webkit).
resolve_libpath() {
  local cache="$STORE/runtime-libpath" gcroot="$STORE/runtime-gcroot"
  local sys; sys="$(uname -m)-linux"
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
  local b="${1:-$GUI}"
  local bin=""
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

# install — self-contained desktop integration for the GUI + CLI/dash on PATH.
cmd_install() {
  local bindir="$HOME/$(J .runtime.bin_dir)"
  mkdir -p "$bindir" "$STORE"
  cmd_fetch "$STORE"
  # CLI + dash: plain copies on PATH (no webkit).
  for b in "$BIN" "$DASH"; do
    [ -x "$STORE/$b" ] && { command cp -f "$STORE/$b" "$bindir/$b"; chmod +x "$bindir/$b"; }
  done
  # GUI: self-contained launcher (webkit libpath + env baked in).
  if [ -x "$STORE/$GUI" ]; then
    local libpath; libpath="$(resolve_libpath)"
    local envlines; envlines="$(jq -r '.runtime.env | to_entries[] | "export \(.key)=\(.value)"' build.json)"
    {
      echo '#!/usr/bin/env bash'
      echo "# $GUI launcher (generated by build.sh install) — self-contained."
      echo "export LD_LIBRARY_PATH=\"$libpath\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
      echo "$envlines"
      echo "export PATH=\"$bindir:\$PATH\""   # so the GUI finds my-ai / my-ai-dash
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
  say "installed $BIN, $DASH, $GUI → $bindir"
}

case "${1:-build}" in
  check)   cmd_check ;;
  build)   cmd_build ;;
  dev)     cmd_dev ;;
  run)     shift; cmd_run "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  install) cmd_install ;;
  clean)   cmd_clean ;;
  *) die "unknown verb: ${1:-} (check|build|dev|run|fetch|install|clean)" ;;
esac
