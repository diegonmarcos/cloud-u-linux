#!/bin/sh
# chroot-into.sh — Generic chroot helper for the Surface Pro 8 multi-boot
# Auto-mounts kernel filesystems + target root + necessary binds, then drops
# into a shell (or just sets up mounts).
#
# Targets: nixos | kali | debian
#
# (kubuntu target retired 2026-05-04: p5 was repurposed from Kubuntu OS to
#  Shared-Lib data partition for Docker storage. To inspect /mnt/shared-lib,
#  just `mount /dev/disk/by-label/Shared-Lib /mnt/shared-lib` directly — no
#  chroot needed for a non-OS data partition.)
#
# Usage:
#   sudo ./chroot-into.sh <target> [--mount-only|--shell|--unmount]
#
# Options:
#   --mount-only   Set up mounts and exit (manual chroot)
#   --shell        Mount + chroot + interactive shell (default)
#   --unmount      Tear down all mounts for the target
#   --help         This message
#
# POSIX-compliant. Run as root or via sudo.

set -eu

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

# Target → device + subvol (where applicable). Override via env if needed.
NIXOS_LUKS_UUID="${NIXOS_LUKS_UUID:-3c75c6db-4d7c-4570-81f1-02d168781aac}"
NIXOS_MAPPER="${NIXOS_MAPPER:-/dev/mapper/pool}"
NIXOS_SUBVOL_ROOT="${NIXOS_SUBVOL_ROOT:-@nixos}"
NIXOS_SUBVOL_HOME="${NIXOS_SUBVOL_HOME:-@home-diego}"

KALI_UUID="${KALI_UUID:-509491e4-d3a7-426d-9b78-4b024b24cc32}"
DEBIAN_LABEL="${DEBIAN_LABEL:-rescue-os-debian}"

CHROOT_BASE="${CHROOT_BASE:-/tmp/chroot-into}"

# ═══════════════════════════════════════════════════════════════════════════════
# COLORS / LOG
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
err()     { printf "${RED}[x]${NC} %s\n" "$1" >&2; exit 1; }
section() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

# ═══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
chroot-into — generic multi-distro chroot helper

Usage:
  sudo $0 <target> [action]

Targets:
  nixos      LUKS pool, subvol=@nixos (auto-unlocks pool if needed)
  kali       /dev/disk/by-uuid/$KALI_UUID
  debian     label=$DEBIAN_LABEL  (rescue-os-debian on p6)

Actions:
  --shell        chroot in (default)
  --mount-only   set up mounts and exit
  --unmount      tear down mounts for the target

Examples:
  sudo $0 nixos
  sudo $0 debian --mount-only
  sudo $0 kali --unmount

Detected host distro: $(detect_host)
EOF
    exit 0
}

detect_host() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        ID=$(. /etc/os-release; echo "$ID")
        echo "$ID"
    else
        echo "unknown"
    fi
}

resolve_target() {
    case "$1" in
        nixos)   echo "luks" ;;
        kali)    echo "/dev/disk/by-uuid/$KALI_UUID" ;;
        debian)  echo "/dev/disk/by-label/$DEBIAN_LABEL" ;;
        *)       err "Unknown target: $1 (use: nixos|kali|debian)" ;;
    esac
}

mp_dir() { echo "$CHROOT_BASE/$1"; }

mounted() { mountpoint -q "$1" 2>/dev/null; }

ensure_pool_unlocked() {
    if [ ! -e "$NIXOS_MAPPER" ]; then
        log "Unlocking LUKS pool (UUID=$NIXOS_LUKS_UUID)..."
        cryptsetup open "/dev/disk/by-uuid/$NIXOS_LUKS_UUID" pool
    else
        log "LUKS pool already unlocked at $NIXOS_MAPPER"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MOUNT / UNMOUNT
# ═══════════════════════════════════════════════════════════════════════════════

setup_mounts() {
    target="$1"
    chroot_dir=$(mp_dir "$target")
    section "Setting up chroot at $chroot_dir for target=$target"

    mkdir -p "$chroot_dir"

    # Resolve and mount root
    if [ "$target" = "nixos" ]; then
        ensure_pool_unlocked
        if ! mounted "$chroot_dir"; then
            mount -t btrfs -o "subvol=$NIXOS_SUBVOL_ROOT" "$NIXOS_MAPPER" "$chroot_dir"
            log "Mounted: $NIXOS_MAPPER (subvol=$NIXOS_SUBVOL_ROOT) → $chroot_dir"
        fi
        # Bind home subvol from pool
        mkdir -p "$chroot_dir/home/diego"
        if ! mounted "$chroot_dir/home/diego"; then
            mount -t btrfs -o "subvol=$NIXOS_SUBVOL_HOME" "$NIXOS_MAPPER" "$chroot_dir/home/diego"
            log "Mounted: $NIXOS_MAPPER (subvol=$NIXOS_SUBVOL_HOME) → $chroot_dir/home/diego"
        fi
        # NixOS expects /nix populated — bind nested @nixos/nix subvol
        mkdir -p "$chroot_dir/nix"
        # Note: /nix lives inside the @nixos subvol already; no extra mount needed unless
        # the user has a separate @nix subvol. Adjust here if so.
    else
        device=$(resolve_target "$target")
        [ ! -e "$device" ] && err "Device for $target not found at $device"
        if ! mounted "$chroot_dir"; then
            mount "$device" "$chroot_dir"
            log "Mounted: $device → $chroot_dir"
        fi
    fi

    # Kernel filesystems
    mkdir -p "$chroot_dir/proc" "$chroot_dir/sys" "$chroot_dir/dev" "$chroot_dir/run"

    if ! mounted "$chroot_dir/proc"; then
        mount -t proc proc "$chroot_dir/proc"
        log "Mounted: proc"
    fi
    if ! mounted "$chroot_dir/sys"; then
        mount --rbind /sys "$chroot_dir/sys"
        mount --make-rslave "$chroot_dir/sys"
        log "Mounted: sys"
    fi
    if ! mounted "$chroot_dir/dev"; then
        mount --rbind /dev "$chroot_dir/dev"
        mount --make-rslave "$chroot_dir/dev"
        log "Mounted: dev"
    fi
    if ! mounted "$chroot_dir/run"; then
        mount -t tmpfs tmpfs "$chroot_dir/run"
        log "Mounted: run (tmpfs)"
    fi

    # DNS
    if [ -f /etc/resolv.conf ] && [ ! -L "$chroot_dir/etc/resolv.conf" ]; then
        cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf" 2>/dev/null || true
    fi

    log "Chroot ready at $chroot_dir"
}

teardown_mounts() {
    target="$1"
    chroot_dir=$(mp_dir "$target")
    section "Unmounting $chroot_dir"

    [ ! -d "$chroot_dir" ] && { warn "$chroot_dir does not exist"; return 0; }

    for mnt in \
        "$chroot_dir/run" \
        "$chroot_dir/dev/pts" \
        "$chroot_dir/dev/shm" \
        "$chroot_dir/dev" \
        "$chroot_dir/sys" \
        "$chroot_dir/proc" \
        "$chroot_dir/home/diego" \
        "$chroot_dir/nix" \
        "$chroot_dir"
    do
        if mounted "$mnt"; then
            umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
            log "Unmounted: $mnt"
        fi
    done

    log "Cleanup complete"
}

enter_shell() {
    target="$1"
    chroot_dir=$(mp_dir "$target")
    section "Entering chroot for $target"
    echo "Type 'exit' to leave."
    echo
    # Pick a shell that exists in the target
    for sh_path in /usr/bin/fish /bin/bash /bin/sh; do
        if [ -x "$chroot_dir$sh_path" ]; then
            chroot "$chroot_dir" "$sh_path" --login 2>/dev/null || chroot "$chroot_dir" "$sh_path"
            return $?
        fi
    done
    err "No shell found in $chroot_dir (/bin/bash, /usr/bin/fish, /bin/sh)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

[ "$(id -u)" -ne 0 ] && err "Run as root (use sudo)"

[ $# -lt 1 ] && usage

TARGET="$1"
ACTION="${2:-shell}"

case "$TARGET" in
    -h|--help|help) usage ;;
esac

# Validate target
case "$TARGET" in
    nixos|kali|debian) ;;
    *) err "Unknown target: $TARGET (use: nixos|kali|debian)" ;;
esac

case "$ACTION" in
    --unmount|-u|unmount)
        teardown_mounts "$TARGET"
        ;;
    --mount-only|-m|mount-only|mount)
        setup_mounts "$TARGET"
        echo
        echo "Chroot ready. Enter manually:"
        echo "  sudo chroot $(mp_dir "$TARGET") /bin/bash --login"
        echo "Tear down with:"
        echo "  sudo $0 $TARGET --unmount"
        ;;
    --shell|-s|shell|"")
        setup_mounts "$TARGET"
        enter_shell "$TARGET"
        echo
        echo "Shell exited. Mounts still active. Tear down with:"
        echo "  sudo $0 $TARGET --unmount"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        err "Unknown action: $ACTION (use: --shell, --mount-only, --unmount)"
        ;;
esac
