#!/usr/bin/env bash
# my-watchdog — fetch the GHA-built binary. Never compiles locally: the Rust
# build is heavy and the freeze-guard on this laptop exists because of exactly
# that kind of job.
set -euo pipefail
C='\033[0;36m'; N='\033[0m'
say() { printf "${C}[my-watchdog]${N} %s\n" "$*"; }

REPO=diegonmarcos/cloud-unix
TAG=my-watchdog-latest
BIN=my-watchdog
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/my-konsole"
LINK="$HOME/.local/bin/$BIN"

case "${1:-fetch}" in
  fetch)
    mkdir -p "$DEST" "$(dirname "$LINK")"
    say "Fetching $BIN from $TAG…"
    # mktemp + mv: writing over a running binary is ETXTBSY, and rename(2) is
    # the only way to swap one out from under a live process safely.
    tmp="$(mktemp "$DEST/.$BIN.XXXXXX")"
    gh release download "$TAG" --repo "$REPO" --pattern "$BIN" --output "$tmp" --clobber
    chmod +x "$tmp"
    mv -f "$tmp" "$DEST/$BIN"
    ln -sf "$DEST/$BIN" "$LINK"
    say "Fetched → $DEST/$BIN (restart my-watchdog to load it)"
    ;;
  check)
    say "Nothing to check locally — this product builds on GHA only."
    ;;
  *)
    echo "usage: build.sh [fetch|check]" >&2
    exit 2
    ;;
esac
