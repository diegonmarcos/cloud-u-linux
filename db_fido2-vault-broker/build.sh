#!/usr/bin/env bash
# fido2-vault-broker — build engine
#
# Public unix/ repo holds CODE + TEMPLATES.
# Private vault/fido/ holds REAL CONFIG + SEALED MASTER + SEALED CACHE.
# `build.sh deploy` symlinks vault/fido/ into XDG paths.
# Operator NEVER edits ~/.config/ directly.
#
# Usage:
#   ./build.sh build         # cargo build --release inside nix dev shell
#   ./build.sh test          # cargo test
#   ./build.sh check         # cargo fmt --check + clippy + check
#   ./build.sh fmt           # cargo fmt
#   ./build.sh run           # cargo run inside nix dev shell
#   ./build.sh clean         # rm dist/ + target/
#   ./build.sh nix           # nix build (reproducible flake)
#   ./build.sh init-vault    # scaffold vault/fido/ skeleton from src/templates/
#   ./build.sh seal-master   # prompt for vault password, TPM-seal it into vault/fido/
#   ./build.sh deploy        # create symlinks vault/fido/ → ~/.config + ~/.local/share
#                            # + install udev rule (sudo) + reload udev
#   ./build.sh install       # install binary + user systemd unit
#   ./build.sh enable        # systemctl --user enable + start
#   ./build.sh ship          # build + install + deploy + enable (full pipeline)
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
get_json() { node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(JSON.stringify(v||null))"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { printf '\033[0;31m[%s] ERROR: %s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# Expand ~ and $ENV references in a single path string (declarative — caller
# never inlines path constants).
expand_path() {
  node -e "const p=process.argv[1]; let r=p.replace(/^~/,process.env.HOME); r=r.replace(/\\\$([A-Z_][A-Z0-9_]*)/g,(_,n)=>process.env[n]||''); process.stdout.write(r)" "$1"
}

BINARY_NAME="$(get build.binary_name)"
UNIT_NAME="$(get runtime.user_unit_name)"
UNIT_SRC="$ROOT/$(get paths.systemd_unit)"
[ -z "$BINARY_NAME" ] && die "build.json: build.binary_name missing"

# Cargo features (data-driven from build.json — never hardcoded).
CARGO_FEATURES="$(node -e "const c=require('$CONFIG'); const f=(c.build&&c.build.cargo_features)||[]; process.stdout.write(f.join(','))")"
FEATURES_FLAG=""
[ -n "$CARGO_FEATURES" ] && FEATURES_FLAG="--features $CARGO_FEATURES"

# Vault paths (data-driven from build.json deploy block).
VAULT_ROOT_ENV="$(get deploy.vault_root_env)"
VAULT_ROOT_DEFAULT="$(get deploy.vault_root_default)"
VAULT_SUBDIR="$(get deploy.vault_subdir)"
VAULT_ROOT="$(expand_path "${!VAULT_ROOT_ENV:-$VAULT_ROOT_DEFAULT}")"
VAULT_DIR="$VAULT_ROOT/$VAULT_SUBDIR"

# ── commands ───────────────────────────────────────────────────────────
cmd="${1:-build}"

case "$cmd" in
  build)
    log "cargo build --release ${FEATURES_FLAG:-(default features)} (in nix dev shell)"
    cd "$SRC"
    nix develop --command cargo build --release $FEATURES_FLAG
    mkdir -p "$DIST"
    TARGET_DIR="$(nix develop --command cargo metadata --format-version 1 --no-deps | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.stdout.write(JSON.parse(s).target_directory)})')"
    [ -n "$TARGET_DIR" ] || TARGET_DIR="$SRC/target"
    cp "$TARGET_DIR/release/$BINARY_NAME" "$DIST/$BINARY_NAME"
    log "Built: $DIST/$BINARY_NAME"
    ;;

  test)
    cd "$SRC"
    nix develop --command cargo test $FEATURES_FLAG
    ;;

  check)
    cd "$SRC"
    nix develop --command bash -c "cargo fmt --check && cargo clippy --all-targets $FEATURES_FLAG -- -D warnings && cargo check $FEATURES_FLAG"
    ;;

  fmt)
    cd "$SRC"
    nix develop --command cargo fmt
    ;;

  run)
    cd "$SRC"
    RUST_LOG=debug nix develop --command cargo run
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

  init-vault)
    [ -d "$VAULT_ROOT" ] || die "vault root $VAULT_ROOT does not exist (set $VAULT_ROOT_ENV or clone vault/ to $VAULT_ROOT_DEFAULT)"
    mkdir -p "$VAULT_DIR"
    chmod 0700 "$VAULT_DIR"
    log "Vault dir: $VAULT_DIR (mode 0700)"

    # Templates → vault (idempotent, never overwrites real files).
    n_templates="$(node -e "const c=require('$CONFIG'); process.stdout.write(String((c.deploy&&c.deploy.templates||[]).length))")"
    for i in $(seq 0 $((n_templates - 1))); do
      tpl_src="$ROOT/$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.templates[$i].src)")"
      tpl_dst="$VAULT_DIR/$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.templates[$i].dst_in_vault)")"
      tpl_mode="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.templates[$i].mode)")"
      tpl_overwrite="$(node -e "const c=require('$CONFIG'); process.stdout.write(String(c.deploy.templates[$i].overwrite))")"
      if [ -f "$tpl_dst" ] && [ "$tpl_overwrite" != "true" ]; then
        log "  skip (exists): $tpl_dst"
      else
        install -Dm"$tpl_mode" "$tpl_src" "$tpl_dst"
        log "  install: $tpl_src → $tpl_dst (mode $tpl_mode)"
      fi
    done

    # Per-directory mkdir + chmod from deploy.vault_directories.
    n_dirs="$(node -e "const c=require('$CONFIG'); process.stdout.write(String((c.deploy&&c.deploy.vault_directories||[]).length))")"
    for i in $(seq 0 $((n_dirs - 1))); do
      d_path="$VAULT_DIR/$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.vault_directories[$i].path)")"
      d_mode="$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.vault_directories[$i].mode)")"
      mkdir -p "$d_path"
      chmod "$d_mode" "$d_path"
      log "  dir: $d_path (mode $d_mode)"
    done
    log "vault skeleton ready — edit $VAULT_DIR/config.toml then run: $0 seal-master && $0 deploy"
    ;;

  seal-master)
    [ -f "$DIST/$BINARY_NAME" ] || die "$DIST/$BINARY_NAME not built — run './build.sh build' first"
    [ -d "$VAULT_DIR" ] || die "$VAULT_DIR missing — run './build.sh init-vault' first"
    blob_name="$(get deploy.master_seal.blob_in_vault)"
    [ -n "$blob_name" ] || die "build.json: deploy.master_seal.blob_in_vault missing"
    blob_path="$VAULT_DIR/$blob_name"
    log "Sealing master password into $blob_path (no plaintext on disk)"

    # Two paths:
    #   * Interactive (stdin is a tty)  — prompt + no-echo read.
    #   * Non-interactive (stdin piped) — slurp stdin verbatim, no prompt.
    # Both feed the binary's `seal --in -` so plaintext only ever lives in
    # this process's memory + the binary's Zeroizing buffer.
    if [ -t 0 ]; then
      printf 'master password (no echo): ' >&2
      stty -echo
      IFS= read -r master
      stty echo
      printf '\n' >&2
    else
      log "stdin is a pipe — reading master password non-interactively"
      # `read -r` returns 1 on EOF without newline; tolerate that since
      # operators piping `printf 'pw'` (no trailing \n) is the common path.
      IFS= read -r master || true
    fi
    [ -n "$master" ] || die "empty master password rejected"
    printf '%s' "$master" | "$DIST/$BINARY_NAME" "$(get deploy.master_seal.binary_subcommand)" --in - --out "$blob_path"
    unset master
    chmod 0600 "$blob_path"
    log "  sealed: $blob_path (mode 0600)"
    log "  next: $0 deploy"
    ;;

  deploy)
    [ -d "$VAULT_DIR" ] || die "$VAULT_DIR missing — run './build.sh init-vault' first"

    # Symlinks vault/fido/ → XDG paths (idempotent via `ln -sfn`).
    n_links="$(node -e "const c=require('$CONFIG'); process.stdout.write(String((c.deploy&&c.deploy.symlinks||[]).length))")"
    for i in $(seq 0 $((n_links - 1))); do
      link_src="$VAULT_DIR/$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.symlinks[$i].from_in_vault)")"
      link_dst="$(expand_path "$(node -e "const c=require('$CONFIG'); process.stdout.write(c.deploy.symlinks[$i].to)")")"
      mkdir -p "$(dirname "$link_dst")"
      [ -e "$link_src" ] || [ -L "$link_src" ] || {
        # OK to symlink to a not-yet-existent target (master.tpm-sealed before
        # seal-master, sealed/ before init-vault). Create the placeholder dir
        # if the schema marks it as a directory link.
        is_dir="$(node -e "const c=require('$CONFIG'); process.stdout.write(String(c.deploy.symlinks[$i].is_directory||false))")"
        if [ "$is_dir" = "true" ]; then mkdir -p "$link_src"; chmod 0700 "$link_src"; fi
      }
      ln -sfn "$link_src" "$link_dst"
      log "  link: $link_dst → $link_src"
    done

    # Udev rule → /etc/udev/rules.d/ (sudo). Skipped if rule contents identical.
    udev_src="$VAULT_DIR/$(get deploy.udev_rule.from_in_vault)"
    udev_dst="$(get deploy.udev_rule.to)"
    if [ -f "$udev_src" ]; then
      if [ -f "$udev_dst" ] && cmp -s "$udev_src" "$udev_dst"; then
        log "  udev rule already current: $udev_dst"
      else
        sudo install -Dm0644 "$udev_src" "$udev_dst"
        sudo udevadm control --reload
        sudo udevadm trigger
        log "  udev rule: $udev_src → $udev_dst (reloaded)"
      fi
    else
      log "  skip udev: $udev_src not present (run init-vault to seed it)"
    fi
    log "deploy done"
    ;;

  install)
    [ -f "$DIST/$BINARY_NAME" ] || die "$DIST/$BINARY_NAME not built — run './build.sh build' first"
    install -Dm755 "$DIST/$BINARY_NAME" "$HOME/.local/bin/$BINARY_NAME"
    install -Dm644 "$UNIT_SRC" "$HOME/.config/systemd/user/$UNIT_NAME"
    systemctl --user daemon-reload
    log "Installed binary → ~/.local/bin/, unit → ~/.config/systemd/user/"
    log "  Enable with: ./build.sh enable"
    ;;

  enable)
    systemctl --user enable --now "$UNIT_NAME"
    log "Enabled + started $UNIT_NAME"
    ;;

  ship)
    "$0" build
    "$0" install
    "$0" deploy
    "$0" enable
    log "FULL PIPELINE OK — verify: journalctl --user -u $UNIT_NAME -f"
    ;;

  *)
    die "Unknown command: $cmd"
    ;;
esac
