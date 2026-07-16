#!/usr/bin/env bash
# my-ai universal build engine — data-driven from build.json. Rust CLI + TTY dash (+ Tauri GUI Phase 4).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
J() { jq -r "$1" build.json; }
REPO="$(J .build.repo)"; TAG="$(J .build.release_tag)"
mapfile -t BINS < <(jq -r '.build.artifacts[]' build.json)
say() { printf '\033[0;36m[my-ai]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[my-ai] %s\033[0m\n' "$*" >&2; exit 1; }

in_shell() { if command -v cargo >/dev/null 2>&1; then "$@"; else nix develop -c "$@"; fi; }

cmd_check()  { in_shell cargo fmt --check || true; in_shell cargo clippy --all-targets -- -D warnings || true; }
cmd_build()  { in_shell cargo build --release --workspace; in_shell cargo test --workspace; say "built: ${BINS[*]}"; }
cmd_run()    { local b="${1:-my-ai-dash}"; [ -x "target/release/$b" ] || cmd_build; "target/release/$b" "${@:2}"; }
cmd_clean()  { rm -rf target; }

cmd_fetch() {
  local dir="${1:-$HOME/$(J .runtime.bin_dir)}"; mkdir -p "$dir"
  say "fetching $TAG from $REPO -> $dir"
  for b in "${BINS[@]}"; do gh release download "$TAG" -R "$REPO" -p "$b" -O "$dir/$b" --clobber && chmod +x "$dir/$b"; done
}
cmd_install() { cmd_fetch "$HOME/$(J .runtime.bin_dir)"; say "installed to $HOME/$(J .runtime.bin_dir)"; }

case "${1:-build}" in
  check) cmd_check ;;
  build) cmd_build ;;
  run)   shift; cmd_run "$@" ;;
  fetch) shift; cmd_fetch "$@" ;;
  install) cmd_install ;;
  clean) cmd_clean ;;
  *) die "unknown verb: ${1:-} (check|build|run|fetch|install|clean)" ;;
esac
