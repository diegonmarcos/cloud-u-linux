#!/usr/bin/env bash
# c3-morpheus — fetch the GHA-built binary. Never compiles locally: the same
# freeze-guard reason da_watchdog's build.sh states at length.
set -euo pipefail
C='\033[0;36m'; N='\033[0m'
say() { printf "${C}[c3-morpheus]${N} %s\n" "$*"; }

REPO=diegonmarcos/cloud-u-linux
TAG=c3-morpheus-latest
BIN=c3-morpheus
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/c3-morpheus"
LINK="$HOME/.local/bin/$BIN"

arch() {
  case "$(uname -m)" in
    x86_64)          echo x86_64 ;;
    aarch64|arm64)   echo aarch64 ;;
    *) say "unsupported architecture $(uname -m)"; exit 1 ;;
  esac
}

case "${1:-fetch}" in
  fetch)
    mkdir -p "$DEST" "$(dirname "$LINK")"
    asset="$BIN-$(arch)"
    say "fetching $asset from $TAG…"
    # mktemp + mv: writing over a running binary is ETXTBSY, and rename(2) is
    # the only safe way to swap one out from under a live process.
    tmp="$(mktemp "$DEST/.$BIN.XXXXXX")"
    gh release download "$TAG" --repo "$REPO" --pattern "$asset" --output "$tmp" --clobber
    chmod +x "$tmp"
    mv -f "$tmp" "$DEST/$BIN"
    ln -sf "$DEST/$BIN" "$LINK"
    say "installed $LINK"
    # The tools it shells out to. Reported, never assumed: a missing jq must
    # surface as a missing jq and not as an empty workflow list.
    for t in curl jq gh; do
      command -v "$t" >/dev/null 2>&1 || say "WARNING: $t is not on PATH — see \`$BIN doctor\`"
    done
    ;;
  check)
    # What CI runs. Local `cargo build` is deliberately absent from this
    # script: there is no subcommand here that compiles.
    say "compile-verify happens on GHA (ship-c3-morpheus.yml). Nothing is built locally."
    exit 0
    ;;
  *)
    echo "usage: build.sh {fetch|check}" >&2
    exit 1
    ;;
esac
