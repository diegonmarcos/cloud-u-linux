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
  install)
    # Fetch, then run it as a user service. Separate from `fetch` because
    # fetching a binary and enrolling it in systemd are different decisions,
    # and the second one should be asked for.
    "$0" fetch
    mkdir -p "$HOME/.config/systemd/user"
    unit=my-watchdog.service
    # A headless box has no graphical-session.target to hang off, and a unit
    # that WantedBy a target which never activates simply never starts.
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || unit=my-watchdog-headless.service
    install -m644 "$(dirname "$0")/$unit" "$HOME/.config/systemd/user/my-watchdog.service"
    systemctl --user daemon-reload
    systemctl --user enable --now my-watchdog.service
    say "Installed and started ($unit)."
    ;;

  deploy)
    # Push it to every mesh peer in ~/.ssh/config. The peers are aarch64 and
    # x86_64 both, so the right artifact is chosen per host from uname -m
    # rather than assumed.
    shift || true
    # One host per ADDRESS: the config gives several aliases per machine
    # (a -dropbear twin, a claude_ prefix), and deploying to the same box four
    # times under four names is four copies of the same scp.
    hosts="${*:-$(awk '/^Host /{h=$2}
      /HostName[ =]+10\.0\.0\./{ if (h !~ /dropbear/ && !(seen[$2]++)) print h }' "$HOME/.ssh/config")}"
    for h in $hosts; do
      arch=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$h" 'uname -m' 2>/dev/null) || {
        say "$h: unreachable, skipped"; continue; }
      case "$arch" in
        aarch64|arm64) asset="$BIN-aarch64" ;;
        x86_64)        asset="$BIN-x86_64" ;;
        *) say "$h: no build for $arch, skipped"; continue ;;
      esac
      tmp="$(mktemp)"
      gh release download "$TAG" --repo "$REPO" --pattern "$asset" --output "$tmp" --clobber
      # Same ETXTBSY dance as fetch: write beside it, then rename over.
      ssh -o BatchMode=yes "$h" 'mkdir -p ~/.local/bin' </dev/null
      scp -q "$tmp" "$h:.local/bin/.$BIN.new"
      ssh -o BatchMode=yes "$h" "chmod +x ~/.local/bin/.$BIN.new && mv -f ~/.local/bin/.$BIN.new ~/.local/bin/$BIN" </dev/null
      rm -f "$tmp"
      say "$h ($arch): installed"
    done
    ;;

  check)
    say "Nothing to check locally — this product builds on GHA only."
    ;;
  *)
    echo "usage: build.sh [fetch|install|deploy [host...]|check]" >&2
    exit 2
    ;;
esac
