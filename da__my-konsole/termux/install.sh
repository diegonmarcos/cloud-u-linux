#!/usr/bin/env bash
# my-konsole-engine — Termux installer. Fetches the static aarch64-musl engine
# binary from the rolling GH release, installs it to $PREFIX/bin, and wires a
# Termux:Boot autostart script so it's up before the WebView app connects.
# Idempotent: safe to re-run (re-fetches + overwrites).
set -euo pipefail

# ── data (only vars here — never hardcode below) ───────────────────────────
REPO="diegonmarcos/cloud-unix"
RELEASE_TAG="my-konsole-latest"
ASSET_NAME="my-konsole-engine-aarch64"
BIN_NAME="my-konsole-engine"

log() { printf '[my-konsole-engine] %s\n' "$*"; }
die() { printf '[my-konsole-engine] ERROR: %s\n' "$*" >&2; exit 1; }

: "${PREFIX:?PREFIX not set — run this inside Termux}"
mkdir -p "$PREFIX/bin"
dest="$PREFIX/bin/$BIN_NAME"

log "Fetching $ASSET_NAME from $REPO@$RELEASE_TAG…"
if command -v gh >/dev/null 2>&1; then
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "$ASSET_NAME" \
    --dir "$(dirname "$dest")" --clobber \
    && mv -f "$(dirname "$dest")/$ASSET_NAME" "$dest"
else
  command -v curl >/dev/null 2>&1 || die "need curl or gh"
  url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"
  curl -fL -o "$dest" "$url" || die "download failed: $url"
fi
chmod +x "$dest"
log "Installed → $dest"

# ── Termux:Boot autostart ───────────────────────────────────────────────────
boot_dir="$HOME/.termux/boot"
mkdir -p "$boot_dir"
cat > "$boot_dir/$BIN_NAME" <<EOF
#!$PREFIX/bin/sh
# Autostart my-konsole-engine on boot (via Termux:Boot). Binds 127.0.0.1:7333
# by default (MYK_ENGINE_ADDR unset) — the on-device WebView connects there.
# Also (re)starts the httpd/eruda/md-json asset server the WebView renders
# local markdown/JSON through — boot is the only trigger that fires without
# an interactive shell (the fish auto-start hook only fires on shell open).
command -v my-webserver >/dev/null 2>&1 && my-webserver start >/dev/null 2>&1
exec "$dest"
EOF
chmod +x "$boot_dir/$BIN_NAME"
log "Boot script → $boot_dir/$BIN_NAME"

log "Done. See README.md for the Termux:Boot app requirement + wake-lock note."
