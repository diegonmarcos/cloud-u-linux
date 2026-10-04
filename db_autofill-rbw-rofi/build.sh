#!/usr/bin/env bash
# da_autofill-rbw-rofi — build engine
#
# Usage:
#   ./build.sh build      # cargo build --release inside nix dev shell
#   ./build.sh test       # cargo test
#   ./build.sh check      # cargo fmt --check + clippy + cargo check
#   ./build.sh fmt        # cargo fmt
#   ./build.sh run        # run binary with debug log level
#   ./build.sh clean      # rm dist/ + target/
#   ./build.sh install    # install binary + user systemd unit
#   ./build.sh enable     # systemctl --user enable + start
#   ./build.sh nix        # nix build (reproducible flake-based build)
#   (default = build)
#
# All behaviour driven by build.json — no hardcoded paths or names.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
DIST="$ROOT/dist"
LOG="$ROOT/build.log"
CONFIG="$ROOT/build.json"

# ── helpers ────────────────────────────────────────────────────────────
get() { node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { printf '\033[0;31m[%s] ERROR: %s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

BINARY_NAME="$(get build.binary_name)"
UNIT_NAME="$(get runtime.user_unit_name)"
UNIT_SRC="$ROOT/$(get paths.systemd_unit)"
[ -z "$BINARY_NAME" ] && die "build.json: build.binary_name missing"
[ -z "$UNIT_NAME" ]   && die "build.json: runtime.user_unit_name missing"

# nix dev shell wrapper — falls back to bare cargo if nix missing AND user opts out
in_dev() {
  if command -v nix >/dev/null 2>&1; then
    nix develop "$SRC" --command "$@"
  else
    log "WARN: nix not found, running directly: $*"
    "$@"
  fi
}

# ── commands ───────────────────────────────────────────────────────────
cmd="${1:-build}"

case "$cmd" in
  build)
    log "cargo build --release (in nix dev shell)"
    cd "$SRC"
    in_dev cargo build --release
    mkdir -p "$DIST"
    # Resolve target dir from cargo metadata so we honour CARGO_TARGET_DIR
    # overrides (some users / CI / nix shells redirect target/ outside SRC).
    TARGET_DIR="$(in_dev cargo metadata --format-version 1 --no-deps | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.stdout.write(JSON.parse(s).target_directory)})')"
    [ -n "$TARGET_DIR" ] || TARGET_DIR="$SRC/target"
    cp "$TARGET_DIR/release/$BINARY_NAME" "$DIST/$BINARY_NAME"
    log "Built: $DIST/$BINARY_NAME"
    ;;

  test)
    cd "$SRC"
    in_dev cargo test
    ;;

  check)
    cd "$SRC"
    in_dev bash -c 'cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo check'
    ;;

  fmt)
    cd "$SRC"
    in_dev cargo fmt
    ;;

  run)
    cd "$SRC"
    RUST_LOG=debug in_dev cargo run
    ;;

  clean)
    rm -rf "$DIST" "$SRC/target"
    log "Cleaned dist/ + target/"
    ;;

  nix)
    log "nix build (reproducible)"
    cd "$SRC"
    nix build --print-build-logs
    mkdir -p "$DIST"
    cp -L result/bin/"$BINARY_NAME" "$DIST/$BINARY_NAME"
    log "Built via flake: $DIST/$BINARY_NAME"
    ;;

  install)
    [ -f "$DIST/$BINARY_NAME" ] || die "$DIST/$BINARY_NAME not built — run './build.sh build' first"
    install -Dm755 "$DIST/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME"
    install -Dm644 "$UNIT_SRC" "$HOME/.config/systemd/user/$UNIT_NAME"
    systemctl --user daemon-reload
    log "Installed binary → ~/.local/bin/, unit → ~/.config/systemd/user/"
    log "  Bind a hotkey to: systemctl --user start $UNIT_NAME"
    log "  Or auto-enable on login with: ./build.sh enable"
    ;;

  enable)
    systemctl --user enable --now "$UNIT_NAME" || true
    log "Enabled $UNIT_NAME (oneshot, will run on hotkey trigger)"
    ;;

  *)
    die "Unknown command: $cmd"
    ;;
esac
