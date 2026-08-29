#!/usr/bin/env bash
# my-browser-rust-chromium — build engine.
#
# MVP strategy: build the real upstream cef-rs `cefsimple` example INSIDE its own
# workspace (where its workspace-deps resolve and `export-cef-dir` fetches the
# matching CEF). That gives a proven-good Rust + real-Chromium (BoringSSL) binary
# — the clean-fingerprint MVP — without standalone dependency surgery. We fork /
# customize (start URL, chrome bar, keybinds) on top of this baseline next.
#
# Data-driven: cef-rs repo + ref live in build.json (cef_rs.repo / cef_rs.ref).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$HERE/dist"; WORK="$HERE/.build"
NAME="my-browser-rust-chromium"; TAG="${NAME}-latest"; TARBALL="${NAME}-linux-x86_64.tar.gz"

REPO="$(jq -r '.cef_rs.repo' "$HERE/build.json")"
REF="$(jq -r '.cef_rs.ref'  "$HERE/build.json")"
EXAMPLE_DIR="$(jq -r '.cef_rs.example_dir' "$HERE/build.json")"
EXAMPLE_PKG="$(jq -r '.cef_rs.example_pkg' "$HERE/build.json")"
CEF_DIR="$WORK/cef"; SRC="$WORK/cef-rs"

_fetch() {   # clone cef-rs @ ref + export the matching CEF into $CEF_DIR
  rm -rf "$SRC"; mkdir -p "$WORK"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC" 2>/dev/null || git clone --depth 1 "$REPO" "$SRC"
  ( cd "$SRC" && cargo run -p export-cef-dir -- --force "$CEF_DIR" )
}
_overlay() {   # our fork lives as full-file overrides in src/overlay/, layered over
               # the cloned cefsimple before building. Robust (no patch-context drift).
  [ -d "$HERE/src/overlay" ] && command cp -rf "$HERE/src/overlay/." "$SRC/examples/$EXAMPLE_DIR/" && echo "overlay applied"
  return 0
}
_build() { _overlay; export CEF_PATH="$CEF_DIR" LD_LIBRARY_PATH="$CEF_DIR:${LD_LIBRARY_PATH:-}"
  ( cd "$SRC" && cargo build -p "$EXAMPLE_PKG" --release ) ; }

cmd="${1:-help}"
case "$cmd" in
  fetch)   _fetch ;;
  build)   [ -d "$SRC" ] || _fetch; _build ;;
  run)     "$0" build; CEF_PATH="$CEF_DIR" LD_LIBRARY_PATH="$CEF_DIR" "$SRC/target/release/$EXAMPLE_PKG" "${2:-}" ;;
  clean)   rm -rf "$WORK" "$DIST" ;;

  release) "$0" build
    mkdir -p "$DIST/bundle"
    cp "$SRC/target/release/$EXAMPLE_PKG" "$DIST/bundle/$NAME"
    cp -r "$CEF_DIR"/. "$DIST/bundle/" 2>/dev/null || true   # libcef.so + resources for a portable run
    # baked homepage (copied from qute's dashboard → 2_configs/, committed)
    cp "$HERE/2_configs/my-browser-chromium-homepage.html" "$DIST/bundle/" 2>/dev/null || true
    # launcher: sets CEF paths + opens the baked homepage (src/overlay parses --url=)
    cat > "$DIST/bundle/my-browser" <<'LAUNCH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
export CEF_PATH="$HERE" LD_LIBRARY_PATH="$HERE"
# Upstream's osr example hardcoded wgpu Backends::VULKAN and this bundle ships
# no Vulkan ICD, so the loader found no adapter and the Rust side panicked with
# NoAdapter before a window appeared -- CEF itself was fine.
# src/overlay now asks for VULKAN|GL and honours WGPU_BACKEND, so GL is a real
# fallback and this is no longer load-bearing. Kept as belt-and-braces: point
# the loader at the host's ICDs so Vulkan still wins where a driver exists.
# ponytail: delete this block if it ever gets in the way -- GL covers it.
if [ -z "${VK_ICD_FILENAMES:-}" ] && [ -z "${VK_DRIVER_FILES:-}" ]; then
  for _d in /run/opengl-driver/share/vulkan/icd.d /usr/share/vulkan/icd.d; do
    [ -d "$_d" ] || continue
    _icd="$(ls "$_d"/*.json 2>/dev/null | tr '\n' ':' | sed 's/:$//')"
    [ -n "$_icd" ] && export VK_ICD_FILENAMES="$_icd" && break
  done
fi
exec "$HERE/my-browser-rust-chromium" --url="file://$HERE/my-browser-chromium-homepage.html" "$@"
LAUNCH
    chmod +x "$DIST/bundle/my-browser"
    tar -C "$DIST/bundle" -czf "$DIST/$TARBALL" .
    echo "staged $DIST/$TARBALL" ;;

  gh-release)
    gh release view "$TAG" >/dev/null 2>&1 \
      || gh release create "$TAG" --title "$NAME (rolling)" --notes "Rust + real-Chromium (CEF) MVP — upstream cefsimple baseline"
    gh release upload "$TAG" "$DIST/$TARBALL" --clobber ;;

  ghcr-push)   # oras rejects absolute paths → push from inside $DIST with a relative name
    ( cd "$DIST" && oras push "ghcr.io/diegonmarcos/${NAME}:latest" "${TARBALL}:application/gzip" ) ;;

  install)   # user-level install: bundle + icon + .desktop. No sudo, no system paths.
    PREFIX="${PREFIX:-$HOME/.local/share/$NAME}"
    APPS="$HOME/.local/share/applications"
    ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"
    mkdir -p "$PREFIX" "$APPS" "$ICONS"
    tb="$DIST/$TARBALL"
    if [ ! -f "$tb" ]; then   # no local stage (local builds are not how this ships) -> take the rolling release
      tmp="$(mktemp -d)"; gh release download "$TAG" -D "$tmp" --clobber; tb="$tmp/$TARBALL"
    fi
    tar -xzf "$tb" -C "$PREFIX"
    chmod +x "$PREFIX/my-browser" "$PREFIX/$NAME"
    cp "$HERE/2_configs/$NAME.svg" "$ICONS/$NAME.svg"
    # awk, not sed: a substituted path containing & would be eaten by sed's replacement syntax
    awk -v exec_path="$PREFIX/my-browser" '{ gsub(/@EXEC@/, exec_path); print }' \
      "$HERE/2_configs/$NAME.desktop" > "$APPS/$NAME.desktop"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
    command -v gtk-update-icon-cache  >/dev/null && gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    echo "installed -> $PREFIX"; echo "desktop entry -> $APPS/$NAME.desktop" ;;

  uninstall) # exact inverse of install, so trying this out is reversible
    PREFIX="${PREFIX:-$HOME/.local/share/$NAME}"
    rm -rf "$PREFIX"
    rm -f "$HOME/.local/share/applications/$NAME.desktop"
    rm -f "$HOME/.local/share/icons/hicolor/scalable/apps/$NAME.svg"
    echo "removed $PREFIX + desktop entry + icon" ;;

  ship)    "$0" release && "$0" gh-release && "$0" ghcr-push ;;
  help|*)  echo "usage: build.sh {fetch|build|run [URL]|release|gh-release|ghcr-push|ship|install|uninstall|clean}" ;;
esac
