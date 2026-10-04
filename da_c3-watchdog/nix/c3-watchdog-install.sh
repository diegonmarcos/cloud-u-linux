#!/usr/bin/env sh
# c3-watchdog-install.sh — the installer for a machine with no nix.
#
# Its counterpart is nix/c3-watchdog-install.nix: one installs by DESCRIBING and
# hands the description to a generation, this one installs by DOING. They are
# named alike because they do the same job in different worlds.
#
# THE ONE THING THIS FILE DOES NOT DO IS DESCRIBE THE SERVICE. The unit beside
# it in this tarball was rendered by nix from watchdog-service.nix, the same
# expression the NixOS and home-manager modules render — so a Debian box and a
# NixOS laptop cannot end up running units that disagree. Every previous
# version of this app had the unit typed out in three places; they disagreed
# about the binary's own name, and a laptop ran a three-week-old daemon through
# four successful deploys with nothing to notice. Placing a file you did not
# write is the point, not a shortcut.
#
# It also never edits a flake.nix. On a machine with nix the repository
# declares the machine, and an installer that rewrites the repository inverts
# that — see --nix, which prints what to add and leaves the adding to you.
set -eu

PREFIX="${PREFIX:-/usr/local}"
BIN="$PREFIX/bin"
UNIT="${UNIT:-/etc/systemd/system}"
CAPS="cap_sys_ptrace,cap_dac_read_search,cap_net_admin+ep"
HERE="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\033[0;36m[c3-watchdog]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[c3-watchdog]\033[0m %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--nix" ]; then
  cat <<'NIXHELP'
This machine has nix. Do not run this script — add the flake to the
configuration that already describes the machine, and switch:

  inputs.c3-watchdog.url = "github:diegonmarcos/cloud-u-linux?dir=da_c3-watchdog";

  outputs = { self, nixpkgs, home-manager, c3-watchdog }: ...   # add to the signature

  modules = [
    c3-watchdog.homeManagerModules.default          # or .nixosModules.default
    { services.my-watchdog.enable = true; }
  ];

Edit the SOURCE flake, never a generated dist/ copy — the next deploy
overwrites that one and your change disappears without an error.
NIXHELP
  exit 0
fi

# A truncated download is the failure this fleet has already had, and it does
# not announce itself: the file is present, executable and short. Verify before
# installing, and fail closed — a size check that can disable itself is how the
# last one got through.
if [ -f "$HERE/SHA256SUMS" ]; then
  say "verifying checksums"
  ( cd "$HERE" && sha256sum -c SHA256SUMS ) >/dev/null 2>&1 || die "checksum mismatch — re-download, do not install this"
else
  die "no SHA256SUMS beside this script — refusing to install unverified binaries"
fi

[ "$(id -u)" -eq 0 ] || die "run as root (it writes $BIN, $UNIT and grants file capabilities)"

say "binaries → $BIN"
install -Dm755 "$HERE/c3-watchdog-d"   "$BIN/c3-watchdog-d"
install -Dm755 "$HERE/c3-watchdog-tui" "$BIN/c3-watchdog-tui"

say "policy → /etc/c3-watchdog"
install -Dm644 "$HERE/watchdog-policy.json" /etc/c3-watchdog/watchdog-policy.json

# A file capability is an xattr on the INODE, so replacing the binary drops it
# — every update silently un-privileges the daemon. That is why the firewall
# page went blank after an update and stayed blank: nft list ruleset needs
# CAP_NET_ADMIN and the new inode had none. Granted on every run, not only the
# first.
if setcap "$CAPS" "$BIN/c3-watchdog-d" 2>/dev/null; then
  say "capabilities granted"
else
  say "NO capabilities — per-process io, PSS and the firewall page will stay blank"
  say "  setcap $CAPS $BIN/c3-watchdog-d"
fi

# The unit nix rendered, placed verbatim. @BIN@ is the only thing this script
# is allowed to decide, because it is the only thing that depends on where the
# files went rather than on what the service is.
say "unit → $UNIT/my-watchdog.service"
sed "s|@BIN@|$BIN|g" "$HERE/my-watchdog.service" > "$UNIT/my-watchdog.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable --now my-watchdog.service
  say "started — c3-watchdog-tui for the panel"
else
  say "no systemd here; run $BIN/c3-watchdog-d --no-tray yourself"
fi
