#!/bin/sh
# Termux flake rebuild — one-shot: git pull + build.sh switch.
# Run on the device when source has new commits and you need to apply.
#
# Usage:
#   sh ~/git/cloud-mykonsole-dtk/5-infos/rebuild-flake/rebuild-flake.sh
#   curl -fsSL https://raw.githubusercontent.com/diegonmarcos/cloud-mykonsole-dtk/main/5-infos/rebuild-flake/rebuild-flake.sh | sh
set -eu

UNIX_REPO="$HOME/git/cloud-unix"
FLAKE_DIR="$UNIX_REPO/bb_flakes_termux"
BUILD_SH="$FLAKE_DIR/build.sh"

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_BLU='\033[0;36m'; C_RST='\033[0m'
ok()   { printf "${C_GREEN}[OK]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YEL}[WARN]${C_RST} %s\n" "$*"; }
fail() { printf "${C_RED}[FAIL]${C_RST} %s\n" "$*"; exit 1; }
step() { printf "\n${C_BLU}>>>${C_RST} %s\n" "$*"; }

# ── 1. Sync source ────────────────────────────────────────────────────
step "1/3  git pull ~/git/cloud-unix"
[ -d "$UNIX_REPO/.git" ] || fail "$UNIX_REPO is not a git repo"
cd "$UNIX_REPO"
git pull --ff-only 2>&1 | tail -5 || warn "git pull non-zero (network? local changes?)"
HEAD=$(git -C "$UNIX_REPO" log -1 --oneline)
ok "HEAD=$HEAD"

# ── 2. Run build.sh ───────────────────────────────────────────────────
step "2/3  ./build.sh switch (verbose)"
[ -x "$BUILD_SH" ] || fail "$BUILD_SH not executable"
"$BUILD_SH" switch

# ── 3. Status ─────────────────────────────────────────────────────────
step "3/3  Status"
echo "  current generation: $(readlink /nix/var/nix/profiles/per-user/$(whoami)/profile 2>/dev/null || echo '?')"
echo "  proot binary:       $(stat -c '%y' /bin/proot-static 2>/dev/null || echo '?')"
echo "  termux-sshd:        $(readlink -f "$HOME/.local/bin/termux-sshd" 2>/dev/null || echo 'missing')"

printf "\n${C_GREEN}═══════ REBUILD COMPLETE ═══════${C_RST}\n"
echo "  If proot was patched: fully kill the Termux app (Force Stop in Android"
echo "  settings) and reopen — the running proot is mmap'd from the OLD binary."
echo "  Then 'dtk 13' (rescue-sshd) to start sshd."
