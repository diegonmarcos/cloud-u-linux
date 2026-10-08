#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ linux-store bootstrap — a fresh Linux userland → fully declarative $HOME ║
# ║                                                                          ║
# ║ Usage: sh bootstrap.sh [--backup] [--no-switch]                          ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# What the flakes' first-boot did for nix-on-droid / home-manager, for a box
# with no nix: the one script to run on a new phone (proot Debian) or desktop.
#
#   1. tools     apt-installs what the engine and the configs need (termux);
#                on desktop it only reports what is missing
#   2. checkouts the git base (~/git, or the CloudDrive mount on the phone):
#                clones cloud-me_configs + cloud-u-linux when absent, and on a
#                FUSE mount sets core.createObject=rename so git can write
#   3. render    deb-user-configs/build.sh build  (src/ → dist/)
#   4. switch    linux-store switch --backup       (the flake's build.sh switch)
#   5. shell     nothing to do — the switched fish/bash config already sources
#                ~/.linux-store/env.{fish,sh}; open a new shell
#
# Idempotent: every step checks before it acts, so re-running is the repair
# path too. Secrets are NOT part of bootstrap: the `secret` layer needs your
# age key (SOPS_AGE_KEY_FILE) and is declared, not bootstrapped.
set -eu

ME=bootstrap
say() { printf '%s: %s\n' "$ME" "$*"; }
die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/linux-store"
USER_ID="${LINUX_STORE_USER:-diego-admin}"
BACKUP=""; NOSWITCH=0
for a in "$@"; do
    case "$a" in
        --backup) BACKUP=--backup ;;
        --no-switch) NOSWITCH=1 ;;
        *) die "unknown flag $a (bootstrap.sh [--backup] [--no-switch])" ;;
    esac
done

[ "$(uname -s)" = Linux ] || die "Linux only"
[ -f "$ENGINE" ] || die "engine not beside me at $ENGINE"

# ── 1. tools ────────────────────────────────────────────────────────────────
# jq sha256sum flock find mv: the engine refuses to start without them.
# fish vim git curl: what the declaration's host entries and dotfiles expect.
PROFILE="$(LINUX_STORE_PROFILE="${LINUX_STORE_PROFILE:-}" sh "$ENGINE" profile)"
say "profile: $PROFILE"
need=""
for t in jq sha256sum flock git curl fish vim less; do
    command -v "$t" >/dev/null 2>&1 || need="$need $t"
done
if [ -n "$need" ]; then
    pkgs="$(printf '%s' "$need" | sed 's/sha256sum/coreutils/; s/flock/util-linux/')"
    if [ "$PROFILE" = termux ] && command -v apt-get >/dev/null 2>&1; then
        say "installing:$pkgs"
        # a fresh proot ships no package lists: "Unable to locate package" is
        # the symptom, update is the cure
        [ -n "$(ls -A /var/lib/apt/lists 2>/dev/null | grep -v -e lock -e partial -e auxfiles)" ] \
            || DEBIAN_FRONTEND=noninteractive apt-get update -q
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q $pkgs
    else
        die "missing:$need — install them with your package manager and re-run"
    fi
else
    say "tools: all present"
fi

# ── 2. checkouts ────────────────────────────────────────────────────────────
# ONE place for every repo, on every machine — no ~/git fallback.
GB="${GIT_BASE:-$HOME/cloud-drive-shared-store/git}"
[ -d "$GB" ] || { mkdir -p "$GB"; say "created $GB"; }
say "git base: $GB"

for r in cloud-me_configs cloud-u-linux; do
    if [ -d "$GB/$r/.git" ]; then
        continue
    fi
    say "cloning $r"
    if ! git clone -q "https://github.com/diegonmarcos/$r.git" "$GB/$r" 2>/dev/null; then
        [ "$r" = cloud-me_configs ] && die "could not clone $r (private): run 'gh auth login' first, or copy the checkout to $GB/$r"
        die "could not clone $r"
    fi
done

# A FUSE mount (the phone's CloudDrive) cannot hard-link, which git's object
# writer does by default: proot turns the failure into a dangling temp object.
case "$GB" in
    /storage/*|*/cloud-drive-shared-store/*)
        for d in "$GB"/*/.git; do
            [ -d "$d" ] || continue
            [ "$(git -C "${d%/.git}" config core.createObject 2>/dev/null)" = rename ] && continue
            git -C "${d%/.git}" config core.createObject rename && say "git: core.createObject=rename in ${d%/.git}"
        done
        ;;
esac

# ── 3. render ───────────────────────────────────────────────────────────────
UP="$(jq -r --arg u "$USER_ID" '.configs_users[]? | select(.id == $u) | .path // empty' "$GB/cloud-me_configs/configs.json")"
[ -n "$UP" ] || die "$GB/cloud-me_configs/configs.json declares no configs-user '$USER_ID'"
DUC="$GB/cloud-me_configs/$UP/deb-user-configs"
[ -f "$DUC/linux-store.json" ] || die "no declaration at $DUC/linux-store.json"
if [ -f "$DUC/build.sh" ]; then
    say "render: $DUC/build.sh build"
    sh "$DUC/build.sh" build
fi

# ── 4. switch ───────────────────────────────────────────────────────────────
if [ "$NOSWITCH" = 1 ]; then
    say "built; --no-switch given, run: sh $ENGINE switch $BACKUP"
    exit 0
fi
say "switch: linux-store switch $BACKUP"
# shellcheck disable=SC2086
GIT_BASE="$GB" sh "$ENGINE" switch $BACKUP

# ── 5. shell ────────────────────────────────────────────────────────────────
say "done — open a new shell (exec fish). linux-store is on PATH from ~/.linux-store/current/bin."
GIT_BASE="$GB" sh "$ENGINE" status
