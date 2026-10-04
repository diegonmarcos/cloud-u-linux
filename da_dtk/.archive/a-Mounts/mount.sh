#!/bin/sh
# FUSE Mount Manager - Unified mount manager for VMs, Drives, and Phones
# Author: Diego Nepomuceno Marcos
# Version: 1.3

set -e

# Config file is relative to script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/mount.json"

# ==============================================================================
# COLORS (defined early for dependency messages)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Unicode symbols
SYM_CHECK="✓"
SYM_CROSS="✗"
SYM_DOT="●"
SYM_CIRCLE="○"
SYM_ARROW="→"
SYM_WARN="⚠"

# ==============================================================================
# DISTRO DETECTION
# ==============================================================================

detect_distro() {
    if [ -f /etc/NIXOS ] || [ -d /nix/store ]; then
        echo "nixos"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/fedora-release ]; then
        echo "fedora"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"

# ==============================================================================
# DEPENDENCY DEFINITIONS
# ==============================================================================

# Format: "command|description|arch_pkg|debian_pkg|fedora_pkg|nix_pkg|required"
DEPS_CORE="
jq|JSON processor|jq|jq|jq|jq|yes
rclone|Cloud storage mounter|rclone|rclone|rclone|rclone|yes
fusermount|FUSE unmount utility|fuse2|fuse|fuse|fuse|yes
"

DEPS_PHONE="
kdeconnect-cli|KDE Connect CLI|kdeconnect|kdeconnect|kdeconnect|kdeconnect|no
qdbus|Qt D-Bus tool|qt5-tools|qttools5-dev-tools|qt5-qttools|qt5.qttools|no
"

DEPS_OCI="
oci|Oracle Cloud CLI|oci-cli(AUR)|python3-oci-cli|oci-cli|oci-cli|no
"

# ==============================================================================
# DEPENDENCY FUNCTIONS
# ==============================================================================

get_pkg_manager_cmd() {
    case "$DISTRO" in
        nixos)   echo "nix-env -iA nixpkgs" ;;
        arch)    echo "sudo pacman -S --noconfirm" ;;
        debian)  echo "sudo apt-get install -y" ;;
        fedora)  echo "sudo dnf install -y" ;;
        alpine)  echo "sudo apk add" ;;
        *)       echo "" ;;
    esac
}

get_pkg_name() {
    dep_line="$1"
    case "$DISTRO" in
        arch)    echo "$dep_line" | cut -d'|' -f3 ;;
        debian)  echo "$dep_line" | cut -d'|' -f4 ;;
        fedora)  echo "$dep_line" | cut -d'|' -f5 ;;
        nixos)   echo "$dep_line" | cut -d'|' -f6 ;;
        *)       echo "$dep_line" | cut -d'|' -f3 ;;
    esac
}

check_dep() {
    cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

install_dep() {
    dep_line="$1"
    cmd=$(echo "$dep_line" | cut -d'|' -f1)
    pkg=$(get_pkg_name "$dep_line")
    pkg_cmd=$(get_pkg_manager_cmd)

    if [ -z "$pkg_cmd" ]; then
        printf "${RED}${SYM_CROSS}${NC} Unknown distro. Install manually: %s\n" "$pkg"
        return 1
    fi

    # NixOS special handling
    if [ "$DISTRO" = "nixos" ]; then
        printf "${YELLOW}${SYM_WARN}${NC} NixOS detected. Recommended approaches:\n"
        printf "  ${DIM}1. Add to configuration.nix:${NC}\n"
        printf "     ${CYAN}environment.systemPackages = [ pkgs.%s ];${NC}\n" "$pkg"
        printf "  ${DIM}2. Temporary install:${NC}\n"
        printf "     ${CYAN}nix-shell -p %s${NC}\n" "$pkg"
        printf "  ${DIM}3. User profile (not recommended):${NC}\n"
        printf "     ${CYAN}nix-env -iA nixpkgs.%s${NC}\n" "$pkg"
        printf "\nInstall to user profile now? [y/N] "
        read -r answer
        case "$answer" in
            [Yy]*)
                nix-env -iA "nixpkgs.$pkg"
                return $?
                ;;
            *)
                printf "${YELLOW}Skipped.${NC} Add to configuration.nix for persistent install.\n"
                return 1
                ;;
        esac
    fi

    # Check for AUR packages on Arch
    if [ "$DISTRO" = "arch" ] && echo "$pkg" | grep -q "(AUR)"; then
        pkg=$(echo "$pkg" | sed 's/(AUR)//')
        if command -v yay >/dev/null 2>&1; then
            printf "${CYAN}Installing %s from AUR...${NC}\n" "$pkg"
            yay -S --noconfirm "$pkg"
            return $?
        elif command -v paru >/dev/null 2>&1; then
            printf "${CYAN}Installing %s from AUR...${NC}\n" "$pkg"
            paru -S --noconfirm "$pkg"
            return $?
        else
            printf "${RED}${SYM_CROSS}${NC} AUR helper (yay/paru) required for: %s\n" "$pkg"
            printf "  Install yay: ${CYAN}sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si${NC}\n"
            return 1
        fi
    fi

    printf "${CYAN}Installing %s...${NC}\n" "$pkg"
    # shellcheck disable=SC2086
    $pkg_cmd $pkg
    return $?
}

check_all_deps() {
    missing_core=""
    missing_phone=""
    missing_oci=""

    # Check core deps
    echo "$DEPS_CORE" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd=$(echo "$line" | cut -d'|' -f1)
        if ! check_dep "$cmd"; then
            echo "$cmd"
        fi
    done
}

show_deps_status() {
    printf "\n${CYAN}${BOLD}╔════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║           Dependencies Status                  ║${NC}\n"
    printf "${CYAN}${BOLD}╚════════════════════════════════════════════════╝${NC}\n\n"

    printf "${DIM}Detected distro:${NC} ${YELLOW}%s${NC}\n\n" "$DISTRO"

    # Core dependencies
    printf "${GREEN}${BOLD}▸ Core (Required)${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    echo "$DEPS_CORE" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd=$(echo "$line" | cut -d'|' -f1)
        desc=$(echo "$line" | cut -d'|' -f2)
        pkg=$(get_pkg_name "$line")
        if check_dep "$cmd"; then
            printf "  ${GREEN}${SYM_CHECK}${NC} %-18s ${DIM}%s${NC}\n" "$cmd" "$desc"
        else
            printf "  ${RED}${SYM_CROSS}${NC} %-18s ${DIM}%s${NC} ${RED}[%s]${NC}\n" "$cmd" "$desc" "$pkg"
        fi
    done

    # Phone dependencies
    printf "\n${BLUE}${BOLD}▸ Phone Mount (Optional)${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    echo "$DEPS_PHONE" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd=$(echo "$line" | cut -d'|' -f1)
        desc=$(echo "$line" | cut -d'|' -f2)
        pkg=$(get_pkg_name "$line")
        if check_dep "$cmd"; then
            printf "  ${GREEN}${SYM_CHECK}${NC} %-18s ${DIM}%s${NC}\n" "$cmd" "$desc"
        else
            printf "  ${DIM}${SYM_CIRCLE}${NC} %-18s ${DIM}%s${NC} ${YELLOW}[%s]${NC}\n" "$cmd" "$desc" "$pkg"
        fi
    done

    # OCI dependencies
    printf "\n${MAGENTA}${BOLD}▸ OCI Flex Control (Optional)${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    echo "$DEPS_OCI" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd=$(echo "$line" | cut -d'|' -f1)
        desc=$(echo "$line" | cut -d'|' -f2)
        pkg=$(get_pkg_name "$line")
        if check_dep "$cmd"; then
            printf "  ${GREEN}${SYM_CHECK}${NC} %-18s ${DIM}%s${NC}\n" "$cmd" "$desc"
        else
            printf "  ${DIM}${SYM_CIRCLE}${NC} %-18s ${DIM}%s${NC} ${YELLOW}[%s]${NC}\n" "$cmd" "$desc" "$pkg"
        fi
    done

    # NixOS notice
    if [ "$DISTRO" = "nixos" ]; then
        printf "\n${YELLOW}${BOLD}NixOS Note:${NC}\n"
        printf "${DIM}────────────────────────────────────────────────${NC}\n"
        printf "  For persistent installs, add packages to:\n"
        printf "  ${CYAN}/etc/nixos/configuration.nix${NC}\n"
        printf "  Then run: ${CYAN}sudo nixos-rebuild switch${NC}\n"
    fi

    printf "\n"
}

deps_menu() {
    printf "\n${CYAN}${BOLD}╔════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║           Dependencies Manager                 ║${NC}\n"
    printf "${CYAN}${BOLD}╚════════════════════════════════════════════════╝${NC}\n\n"

    printf "${DIM}Distro:${NC} ${YELLOW}%s${NC}    " "$DISTRO"
    pkg_cmd=$(get_pkg_manager_cmd)
    if [ -n "$pkg_cmd" ]; then
        printf "${DIM}Pkg manager:${NC} ${GREEN}%s${NC}\n\n" "$(echo "$pkg_cmd" | cut -d' ' -f1-2)"
    else
        printf "${RED}Unknown package manager${NC}\n\n"
    fi

    printf "${BOLD}Actions:${NC}\n"
    printf "  ${GREEN}1${NC}  Show dependency status\n"
    printf "  ${GREEN}2${NC}  Install ALL missing (core + optional)\n"
    printf "  ${GREEN}3${NC}  Install core only (jq, rclone, fuse)\n"
    printf "  ${GREEN}4${NC}  Install phone support (kdeconnect)\n"
    printf "  ${GREEN}5${NC}  Install OCI CLI\n"
    printf "  ${DIM}0${NC}  Back\n"
    printf "\n${BOLD}Choice:${NC} "
    read -r choice

    case "$choice" in
        1) show_deps_status ;;
        2) install_all_deps ;;
        3) install_core_deps ;;
        4) install_phone_deps ;;
        5) install_oci_deps ;;
        0) return ;;
        *) printf "${RED}Invalid choice${NC}\n" ;;
    esac
}

# Collect missing packages from a dep list
get_missing_pkgs() {
    deps="$1"
    missing=""
    echo "$deps" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd=$(echo "$line" | cut -d'|' -f1)
        if ! check_dep "$cmd"; then
            pkg=$(get_pkg_name "$line")
            echo "$pkg"
        fi
    done
}

# NixOS batch installer
nixos_install_batch() {
    pkgs="$1"
    category="$2"

    if [ -z "$pkgs" ]; then
        printf "${GREEN}${SYM_CHECK}${NC} All %s dependencies installed!\n" "$category"
        return 0
    fi

    # Convert newlines to spaces
    pkg_list=$(echo "$pkgs" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ //;s/ $//')

    printf "\n${YELLOW}${BOLD}NixOS - Missing %s packages:${NC} %s\n\n" "$category" "$pkg_list"
    printf "${BOLD}How to install:${NC}\n"
    printf "  ${GREEN}1${NC}  Open nix-shell with packages ${DIM}(temporary, recommended for testing)${NC}\n"
    printf "  ${GREEN}2${NC}  Copy configuration.nix snippet ${DIM}(persistent, recommended)${NC}\n"
    printf "  ${GREEN}3${NC}  Install to user profile ${DIM}(nix-env, not recommended)${NC}\n"
    printf "  ${DIM}0${NC}  Skip\n"
    printf "\n${BOLD}Choice:${NC} "
    read -r choice

    case "$choice" in
        1)
            printf "\n${CYAN}${BOLD}Run this command:${NC}\n\n"
            printf "  ${GREEN}nix-shell -p %s --run '%s'${NC}\n\n" "$pkg_list" "$0"
            printf "${DIM}Or for interactive shell:${NC}\n"
            printf "  ${GREEN}nix-shell -p %s${NC}\n" "$pkg_list"
            printf "  ${DIM}Then run:${NC} ${GREEN}./mount.sh${NC} ${DIM}(not 'sh mount.sh')${NC}\n\n"
            printf "Open interactive nix-shell now? [Y/n] "
            read -r open_shell
            case "$open_shell" in
                [Nn]*) printf "${YELLOW}Skipped.${NC}\n" ;;
                *)
                    printf "\n${CYAN}Opening nix-shell...${NC}\n"
                    printf "${DIM}Run ${GREEN}./mount.sh${NC}${DIM} inside the shell, then 'exit' when done${NC}\n\n"
                    # shellcheck disable=SC2086
                    nix-shell -p $pkg_list
                    printf "\n${GREEN}${SYM_CHECK}${NC} Exited nix-shell\n"
                    ;;
            esac
            ;;
        2)
            printf "\n${CYAN}Add this to your configuration.nix:${NC}\n\n"
            printf "${GREEN}environment.systemPackages = with pkgs; [${NC}\n"
            for pkg in $pkg_list; do
                printf "  ${GREEN}%s${NC}\n" "$pkg"
            done
            printf "${GREEN}];${NC}\n\n"
            printf "${DIM}Then run: ${CYAN}sudo nixos-rebuild switch${NC}\n"
            printf "\n${YELLOW}Copied to clipboard?${NC} "
            if command -v wl-copy >/dev/null 2>&1; then
                snippet="environment.systemPackages = with pkgs; [\n"
                for pkg in $pkg_list; do
                    snippet="$snippet  $pkg\n"
                done
                snippet="$snippet];"
                printf "%b" "$snippet" | wl-copy
                printf "${GREEN}Yes (wl-copy)${NC}\n"
            elif command -v xclip >/dev/null 2>&1; then
                snippet="environment.systemPackages = with pkgs; [\n"
                for pkg in $pkg_list; do
                    snippet="$snippet  $pkg\n"
                done
                snippet="$snippet];"
                printf "%b" "$snippet" | xclip -selection clipboard
                printf "${GREEN}Yes (xclip)${NC}\n"
            else
                printf "${DIM}No clipboard tool found${NC}\n"
            fi
            ;;
        3)
            printf "\n${CYAN}Installing to user profile...${NC}\n"
            for pkg in $pkg_list; do
                printf "  ${CYAN}Installing %s...${NC}\n" "$pkg"
                nix-env -iA "nixpkgs.$pkg" || true
            done
            printf "${GREEN}${SYM_CHECK}${NC} Done!\n"
            ;;
        0|*)
            printf "${YELLOW}Skipped.${NC}\n"
            ;;
    esac
}

# Generic installer (for non-NixOS)
install_deps_generic() {
    deps="$1"
    category="$2"

    printf "\n${CYAN}${BOLD}Installing %s dependencies...${NC}\n\n" "$category"

    echo "$deps" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd=$(echo "$line" | cut -d'|' -f1)
        if ! check_dep "$cmd"; then
            install_dep "$line" || true
        else
            printf "${GREEN}${SYM_CHECK}${NC} %s already installed\n" "$cmd"
        fi
    done
}

install_core_deps() {
    if [ "$DISTRO" = "nixos" ]; then
        missing=$(get_missing_pkgs "$DEPS_CORE")
        nixos_install_batch "$missing" "core"
    else
        install_deps_generic "$DEPS_CORE" "core"
    fi
}

install_phone_deps() {
    if [ "$DISTRO" = "nixos" ]; then
        missing=$(get_missing_pkgs "$DEPS_PHONE")
        nixos_install_batch "$missing" "phone"
    else
        install_deps_generic "$DEPS_PHONE" "phone"
    fi
}

install_oci_deps() {
    if [ "$DISTRO" = "nixos" ]; then
        missing=$(get_missing_pkgs "$DEPS_OCI")
        nixos_install_batch "$missing" "OCI"
    else
        install_deps_generic "$DEPS_OCI" "OCI"
    fi
}

install_all_deps() {
    if [ "$DISTRO" = "nixos" ]; then
        # Collect all missing
        missing_core=$(get_missing_pkgs "$DEPS_CORE")
        missing_phone=$(get_missing_pkgs "$DEPS_PHONE")
        missing_oci=$(get_missing_pkgs "$DEPS_OCI")
        all_missing=$(printf "%s\n%s\n%s" "$missing_core" "$missing_phone" "$missing_oci" | grep -v '^$' | sort -u)
        nixos_install_batch "$all_missing" "all"
    else
        install_deps_generic "$DEPS_CORE" "core"
        install_deps_generic "$DEPS_PHONE" "phone"
        install_deps_generic "$DEPS_OCI" "OCI"
        printf "\n${GREEN}${SYM_CHECK}${NC} Done!\n"
    fi
}

# ==============================================================================
# JQ CHECK (after colors are defined)
# ==============================================================================

# Commands that work without jq
case "${1:-}" in
    deps)
        show_deps_status
        exit 0
        ;;
    deps-install)
        install_core_deps
        exit 0
        ;;
    deps-phone)
        install_phone_deps
        exit 0
        ;;
    deps-oci)
        install_oci_deps
        exit 0
        ;;
    deps-all)
        install_all_deps
        exit 0
        ;;
    -h|--help|help)
        # Minimal help without jq
        if ! command -v jq >/dev/null 2>&1; then
            printf "\n${CYAN}${BOLD}FUSE Mount Manager v1.3${NC}\n\n"
            printf "${YELLOW}${SYM_WARN} jq not installed${NC} - showing minimal help\n\n"
            printf "${BOLD}Dependency commands (work without jq):${NC}\n"
            printf "  ${BLUE}deps${NC}           Show dependency status\n"
            printf "  ${BLUE}deps-install${NC}   Install core deps (jq, rclone, fuse)\n"
            printf "  ${BLUE}deps-phone${NC}     Install phone deps (kdeconnect)\n"
            printf "  ${BLUE}deps-oci${NC}       Install OCI CLI\n"
            printf "  ${BLUE}deps-all${NC}       Install all dependencies\n"
            printf "\nRun ${CYAN}%s deps-install${NC} first, then ${CYAN}%s --help${NC} for full help.\n" "$0" "$0"
            exit 0
        fi
        ;;
esac

# Check jq for other commands
if ! command -v jq >/dev/null 2>&1; then
    # Special message if inside a nix-shell (shouldn't happen but helps debug)
    if [ -n "$IN_NIX_SHELL" ]; then
        printf "${RED}${SYM_CROSS}${NC} jq not found even though you're in a nix-shell.\n"
        printf "  This can happen if you ran ${DIM}sh mount.sh${NC} instead of ${CYAN}./mount.sh${NC}\n"
        printf "  Try: ${CYAN}chmod +x mount.sh && ./mount.sh${NC}\n"
        exit 1
    fi
    printf "${RED}${SYM_CROSS}${NC} jq is required for this command.\n"
    printf "  Run: ${CYAN}%s deps${NC} to check dependencies\n" "$0"
    printf "  Run: ${CYAN}%s deps-install${NC} to install core deps\n" "$0"
    exit 1
fi

# Load settings from JSON (with fallbacks)
# Note: _settings is inside an array element, so we need to search for it
get_setting() {
    key="$1"
    default="$2"
    val=$(jq -r ".[] | select(has(\"_settings\")) | ._settings.$key // empty" "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        echo "$val"
    else
        echo "$default"
    fi
}

FUSE_DIR="$(get_setting "mount_dir" "/home/diego/mnt_mnt")"
RCLONE_OPTS="$(get_setting "rclone_opts" "--vfs-cache-mode writes")"
LOG_FILE_NAME="$(get_setting "log_file" ".mount.log")"
LOG_FILE="$FUSE_DIR/$LOG_FILE_NAME"

# ==============================================================================
# LOGGING
# ==============================================================================

init_log() {
    # Create directory if it doesn't exist
    if [ ! -d "$FUSE_DIR" ]; then
        mkdir -p "$FUSE_DIR"
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
    fi
    # Rotate log if > 1MB
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
    fi
}

log_debug() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_error() {
    printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

init_log

# ==============================================================================
# JSON CONFIG HELPERS
# ==============================================================================

# Get phone config from JSON
get_phone_config() {
    key="$1"
    jq -r ".[\"_phone\"].$key // empty" "$CONFIG_FILE" 2>/dev/null
}

# Get OCI Flex config from JSON (flex-1 by default for wake/sleep)
get_oci_flex_config() {
    key="$1"
    jq -r ".[\"_oci_flex_1\"].$key // empty" "$CONFIG_FILE" 2>/dev/null
}

# List enabled mounts by type
list_mounts() {
    mount_type="$1"
    jq -r ".[] | select(.type == \"$mount_type\" and .enabled == true) | .name" "$CONFIG_FILE" 2>/dev/null
}

# Get mount remote name
get_mount_remote() {
    name="$1"
    jq -r ".[] | select(.name == \"$name\") | .remote" "$CONFIG_FILE" 2>/dev/null
}

# Get all mounts (for status display)
list_all_mounts() {
    jq -r '.[] | select(has("name") and has("type")) | "\(.name)|\(.type)|\(.enabled)"' "$CONFIG_FILE" 2>/dev/null
}

# Update a setting in JSON
update_setting() {
    key="$1"
    value="$2"
    tmp_file=$(mktemp)
    # Find the _settings object and update the key
    jq --arg k "$key" --arg v "$value" '
        map(if has("_settings") then ._settings[$k] = $v else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
}

# ==============================================================================
# HELPERS
# ==============================================================================

print_header() {
    printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"
    printf "%s\n" "$(echo "$1" | sed 's/./-/g')"
}

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; }

is_mounted() {
    mountpoint -q "$1" 2>/dev/null
}

# ==============================================================================
# RCLONE MOUNTS (VMs & Drives)
# ==============================================================================

check_rclone_remote() {
    remote=$1
    rclone listremotes 2>/dev/null | grep -q "^${remote}:$"
}

# Create a new rclone remote interactively
create_rclone_remote() {
    remote=$1
    remote_type=$2  # "drive" for Google Drive, "sftp" for SSH

    printf "\n${CYAN}${BOLD}Creating rclone remote: %s${NC}\n" "$remote"
    log_debug "Creating rclone remote: $remote (type: $remote_type)"

    case "$remote_type" in
        drive)
            printf "${YELLOW}This will open a browser for Google OAuth.${NC}\n"
            printf "Press Enter to continue or Ctrl+C to cancel..."
            read -r _

            # Use rclone config create with interactive OAuth
            rclone config create "$remote" drive \
                scope=drive \
                --config="$HOME/.config/rclone/rclone.conf"

            if check_rclone_remote "$remote"; then
                log "Remote '$remote' created successfully!"
                log_debug "Remote $remote created successfully"
                return 0
            else
                error "Failed to create remote '$remote'"
                log_error "Failed to create remote $remote"
                return 1
            fi
            ;;
        sftp)
            printf "Enter SSH host: "
            read -r ssh_host
            printf "Enter SSH user: "
            read -r ssh_user
            printf "Enter SSH key path (or leave empty for password): "
            read -r ssh_key

            if [ -n "$ssh_key" ]; then
                rclone config create "$remote" sftp \
                    host="$ssh_host" \
                    user="$ssh_user" \
                    key_file="$ssh_key"
            else
                rclone config create "$remote" sftp \
                    host="$ssh_host" \
                    user="$ssh_user"
            fi

            if check_rclone_remote "$remote"; then
                log "Remote '$remote' created successfully!"
                return 0
            else
                error "Failed to create remote '$remote'"
                return 1
            fi
            ;;
        *)
            error "Unknown remote type: $remote_type"
            return 1
            ;;
    esac
}

# Prompt to create missing remote
prompt_create_remote() {
    remote=$1

    # Determine type based on remote name
    case "$remote" in
        Gdrive_*) remote_type="drive" ;;
        OCI_*|GCP_*) remote_type="sftp" ;;
        *) remote_type="unknown" ;;
    esac

    printf "\n${YELLOW}Remote '%s' is not configured.${NC}\n" "$remote"
    printf "Would you like to create it now? [y/N] "
    read -r answer

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            create_rclone_remote "$remote" "$remote_type"
            return $?
            ;;
        *)
            warn "Skipping remote creation"
            return 1
            ;;
    esac
}

mount_rclone_path() {
    remote=$1
    remote_path=$2
    mountpoint=$3

    log_debug "Attempting mount: ${remote}:${remote_path} -> $mountpoint"

    if is_mounted "$mountpoint"; then
        warn "Already mounted: $mountpoint"
        log_debug "Skip: $mountpoint already mounted"
        return 0
    fi

    # Check if rclone remote exists, offer to create if missing
    if ! check_rclone_remote "$remote"; then
        log_error "Remote '$remote' not found"
        if prompt_create_remote "$remote"; then
            log_debug "Remote $remote created, continuing with mount"
        else
            return 1
        fi
    fi

    mkdir -p "$mountpoint"

    # Capture rclone errors to log
    mount_log=$(mktemp)
    # shellcheck disable=SC2086
    nohup rclone mount "${remote}:${remote_path}" "$mountpoint" $RCLONE_OPTS >"$mount_log" 2>&1 &
    mount_pid=$!

    tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 0.5
        if is_mounted "$mountpoint"; then
            log "Mounted ${remote}:${remote_path} -> $mountpoint"
            log_debug "Success: ${remote}:${remote_path} -> $mountpoint (pid=$mount_pid)"
            rm -f "$mount_log"
            return 0
        fi
        # Check if process died
        if ! kill -0 "$mount_pid" 2>/dev/null; then
            break
        fi
        tries=$((tries + 1))
    done

    # Mount failed - capture error
    if [ -f "$mount_log" ] && [ -s "$mount_log" ]; then
        err_msg=$(cat "$mount_log")
        log_error "Mount failed: ${remote}:${remote_path} - $err_msg"
    else
        log_error "Mount failed: ${remote}:${remote_path} - timeout or unknown error"
    fi
    rm -f "$mount_log"

    error "Failed: ${remote}:${remote_path}"
    return 1
}

mount_vm() {
    name=$1
    remote=$2

    log "Mounting $name..."
    mount_rclone_path "$remote" "/" "$FUSE_DIR/$name/sys" || true
    mount_rclone_path "$remote" "/home" "$FUSE_DIR/$name/home" || true
    mount_rclone_path "$remote" "/var/lib/docker/volumes" "$FUSE_DIR/$name/docker" || true
    mount_rclone_path "$remote" "/mnt" "$FUSE_DIR/$name/mnt" || true
}

unmount_vm() {
    name=$1
    for subdir in sys home docker mnt; do
        if is_mounted "$FUSE_DIR/$name/$subdir"; then
            fusermount -uz "$FUSE_DIR/$name/$subdir" 2>/dev/null
            log "Unmounted $name/$subdir"
        fi
    done
}

mount_drive() {
    name=$1
    remote=$2

    log "Mounting $name..."
    mount_rclone_path "$remote" "/" "$FUSE_DIR/$name" || true
}

unmount_drive() {
    name=$1
    if is_mounted "$FUSE_DIR/$name"; then
        fusermount -uz "$FUSE_DIR/$name" 2>/dev/null
        log "Unmounted $name"
    fi
}

# ==============================================================================
# PHONE MOUNT (KDE Connect)
# ==============================================================================

phone_is_reachable() {
    device_id=$(get_phone_config "device_id")
    [ -z "$device_id" ] && return 1
    kdeconnect-cli -a --id-only 2>/dev/null | grep -q "$device_id"
}

phone_is_mounted() {
    device_id=$(get_phone_config "device_id")
    [ -z "$device_id" ] && return 1
    qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
        org.kde.kdeconnect.device.sftp.isMounted 2>/dev/null | grep -q true
}

mount_phone() {
    device_id=$(get_phone_config "device_id")
    phone_name=$(get_phone_config "name")
    sftp_base=$(get_phone_config "sftp_base")

    if [ -z "$device_id" ]; then
        error "Phone not configured in mount.json"
        return 1
    fi

    if ! phone_is_reachable; then
        error "Phone not reachable. Check:"
        printf "  - Phone is on same network\n"
        printf "  - KDE Connect app is running\n"
        return 1
    fi

    log "Mounting phone via KDE Connect..."
    qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
        org.kde.kdeconnect.device.sftp.mount 2>/dev/null
    sleep 1

    if ! phone_is_mounted; then
        error "Failed to mount phone SFTP"
        qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
            org.kde.kdeconnect.device.sftp.getMountError 2>/dev/null
        return 1
    fi

    rm -f "$FUSE_DIR/$phone_name" 2>/dev/null
    ln -sf "$sftp_base" "$FUSE_DIR/$phone_name"
    log "Mounted: $FUSE_DIR/$phone_name"
}

unmount_phone() {
    device_id=$(get_phone_config "device_id")
    phone_name=$(get_phone_config "name")

    if phone_is_mounted; then
        qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
            org.kde.kdeconnect.device.sftp.unmount 2>/dev/null
        log "Unmounted phone"
    fi
    rm -f "$FUSE_DIR/$phone_name" 2>/dev/null
}

# ==============================================================================
# OCI FLEX CONTROL
# ==============================================================================

flex_status() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Checking OCI Flex status..."
    state=$(SUPPRESS_LABEL_WARNING=True oci compute instance get \
        --instance-id "$instance_id" \
        --region "$region" \
        --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null)
    if [ -n "$state" ]; then
        case "$state" in
            RUNNING) printf "  ${GREEN}●${NC} OCI_Flex_1: %s\n" "$state" ;;
            STOPPED) printf "  ${RED}○${NC} OCI_Flex_1: %s\n" "$state" ;;
            *)       printf "  ${YELLOW}◐${NC} OCI_Flex_1: %s\n" "$state" ;;
        esac
    else
        error "Failed to get OCI Flex status"
    fi
}

flex_start() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Starting OCI Flex..."
    SUPPRESS_LABEL_WARNING=True oci compute instance action \
        --instance-id "$instance_id" \
        --region "$region" \
        --action START >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Start command sent. Waiting for VM..."
        sleep 5
        flex_status
    else
        error "Failed to start OCI Flex"
    fi
}

flex_stop() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Stopping OCI Flex..."
    unmount_vm "OCI_Flex_1"
    SUPPRESS_LABEL_WARNING=True oci compute instance action \
        --instance-id "$instance_id" \
        --region "$region" \
        --action STOP >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Stop command sent"
        flex_status
    else
        error "Failed to stop OCI Flex"
    fi
}

flex_reset() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Force resetting OCI Flex..."
    unmount_vm "OCI_Flex_1"
    SUPPRESS_LABEL_WARNING=True oci compute instance action \
        --instance-id "$instance_id" \
        --region "$region" \
        --action RESET >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Reset command sent. VM will reboot..."
        flex_status
    else
        error "Failed to reset OCI Flex"
    fi
}

# ==============================================================================
# BATCH OPERATIONS
# ==============================================================================

mount_all_vms() {
    print_header "Mounting VMs"
    list_mounts "vm" | while read -r name; do
        remote=$(get_mount_remote "$name")
        mount_vm "$name" "$remote"
    done
}

unmount_all_vms() {
    print_header "Unmounting VMs"
    list_mounts "vm" | while read -r name; do
        unmount_vm "$name"
    done
}

mount_all_drives() {
    print_header "Mounting Drives"
    list_mounts "drive" | while read -r name; do
        remote=$(get_mount_remote "$name")
        mount_drive "$name" "$remote"
    done
}

unmount_all_drives() {
    print_header "Unmounting Drives"
    list_mounts "drive" | while read -r name; do
        unmount_drive "$name"
    done
}

mount_all() {
    mount_all_drives
    mount_all_vms
    printf "\n"
    show_status
}

unmount_all() {
    print_header "Unmounting All"

    if is_mounted "$FUSE_DIR/Containers"; then
        fusermount -uz "$FUSE_DIR/Containers" 2>/dev/null
        log "Unmounted Containers"
    fi

    unmount_all_vms
    unmount_all_drives
    unmount_phone

    log "Done"
}

# ==============================================================================
# STATUS
# ==============================================================================

show_status() {
    printf "\n${CYAN}${BOLD}╔════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║            FUSE Mount Status                   ║${NC}\n"
    printf "${CYAN}${BOLD}╚════════════════════════════════════════════════╝${NC}\n\n"

    # VMs (from JSON config)
    printf "${BLUE}${BOLD}Virtual Machines${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    list_all_mounts | grep "|vm|" | while IFS='|' read -r name type enabled; do
        # Check if remote exists
        if ! check_rclone_remote "$name" 2>/dev/null; then
            printf "  ${DIM}${SYM_CROSS} %-14s${NC} ${RED}(rclone not configured)${NC}\n" "$name"
            continue
        fi
        [ "$enabled" != "true" ] && printf "  ${DIM}(disabled)${NC} "
        printf "  ${YELLOW}${BOLD}%s${NC}\n" "$name"
        for subdir in sys home docker mnt; do
            path="$FUSE_DIR/$name/$subdir"
            if [ -d "$path" ]; then
                if is_mounted "$path"; then
                    printf "    ${GREEN}${SYM_CHECK}${NC} %-8s ${DIM}%s${NC}\n" "$subdir" "$path"
                else
                    printf "    ${DIM}${SYM_CIRCLE}${NC} %-8s\n" "$subdir"
                fi
            else
                printf "    ${DIM}${SYM_CIRCLE}${NC} %-8s ${DIM}(dir missing)${NC}\n" "$subdir"
            fi
        done
    done

    # Drives (from JSON config)
    printf "\n${BLUE}${BOLD}Cloud Drives${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    list_all_mounts | grep "|drive|" | while IFS='|' read -r name type enabled; do
        if ! check_rclone_remote "$name" 2>/dev/null; then
            printf "  ${RED}${SYM_CROSS}${NC} %-14s ${RED}(rclone not configured)${NC}\n" "$name"
            printf "    ${DIM}Tip: run 'rclone config' to add this remote${NC}\n"
        elif is_mounted "$FUSE_DIR/$name"; then
            printf "  ${GREEN}${SYM_CHECK}${NC} %-14s ${DIM}%s${NC}\n" "$name" "$FUSE_DIR/$name"
        else
            printf "  ${DIM}${SYM_CIRCLE}${NC} %-14s ${DIM}(not mounted)${NC}\n" "$name"
        fi
    done

    # Phone (from JSON config)
    phone_name=$(get_phone_config "name")
    sftp_base=$(get_phone_config "sftp_base")
    printf "\n${BLUE}${BOLD}Phone (KDE Connect)${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    if [ -n "$phone_name" ]; then
        if phone_is_reachable 2>/dev/null; then
            if phone_is_mounted 2>/dev/null; then
                printf "  ${GREEN}${SYM_DOT}${NC} %-14s ${GREEN}connected${NC}\n" "$phone_name"
                printf "    ${DIM}${SYM_ARROW} %s${NC}\n" "$sftp_base"
            else
                printf "  ${YELLOW}${SYM_CIRCLE}${NC} %-14s ${YELLOW}reachable${NC} (not mounted)\n" "$phone_name"
            fi
        else
            printf "  ${DIM}${SYM_CIRCLE}${NC} %-14s ${DIM}offline${NC}\n" "$phone_name"
        fi
    else
        printf "  ${DIM}${SYM_CIRCLE}${NC} (not configured in mount.json)\n"
    fi

    # Containers
    printf "\n${BLUE}${BOLD}Container Symlinks${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    count=$(find "$FUSE_DIR/Containers/" -maxdepth 1 -type l 2>/dev/null | wc -l)
    printf "  ${GREEN}${SYM_CHECK}${NC} %s symlinks in %s\n" "$count" "$FUSE_DIR/Containers/"

    # Log info
    printf "\n${BLUE}${BOLD}Debug Log${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
        log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        last_error=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || true)
        last_error=${last_error:-0}
        printf "  ${DIM}Path:${NC}   %s\n" "$LOG_FILE"
        printf "  ${DIM}Lines:${NC}  %s  ${DIM}Size:${NC} %s  " "$log_lines" "$log_size"
        if [ "$last_error" != "0" ] && [ -n "$last_error" ]; then
            printf "${RED}Errors: %s${NC}\n" "$last_error"
        else
            printf "${GREEN}No errors${NC}\n"
        fi
    else
        printf "  ${DIM}(No log file yet)${NC}\n"
    fi
    printf "\n"
}

# ==============================================================================
# TUI MENU
# ==============================================================================

compact_status() {
    # VMs - one line each
    printf "  ${BLUE}VMs:${NC}     "
    for vm in OCI_micro_0 OCI_micro_1 OCI_Flex_1 GCP_micro_1; do
        # Count mounted subdirs
        mounted=0
        total=0
        for subdir in sys home docker mnt; do
            path="$FUSE_DIR/$vm/$subdir"
            if [ -d "$path" ]; then
                total=$((total + 1))
                if is_mounted "$path"; then
                    mounted=$((mounted + 1))
                fi
            fi
        done
        # Short VM name
        case "$vm" in
            OCI_micro_0) short="m0" ;;
            OCI_micro_1) short="m1" ;;
            OCI_Flex_1)  short="f1" ;;
            GCP_micro_1) short="gcp" ;;
        esac
        if [ "$mounted" -eq "$total" ] && [ "$total" -gt 0 ]; then
            printf "${GREEN}${SYM_CHECK}%s${NC} " "$short"
        elif [ "$mounted" -gt 0 ]; then
            printf "${YELLOW}${SYM_WARN}%s${NC}(%d/%d) " "$short" "$mounted" "$total"
        else
            printf "${DIM}${SYM_CIRCLE}%s${NC} " "$short"
        fi
    done
    printf "\n"

    # Drives - one line
    printf "  ${BLUE}Drives:${NC}  "
    for drive in Gdrive_dnm Gdrive_me; do
        case "$drive" in
            Gdrive_dnm) short="dnm" ;;
            Gdrive_me)  short="me" ;;
        esac
        if [ -d "$FUSE_DIR/$drive" ] && is_mounted "$FUSE_DIR/$drive"; then
            printf "${GREEN}${SYM_CHECK}%s${NC} " "$short"
        elif ! check_rclone_remote "$drive" 2>/dev/null; then
            printf "${RED}${SYM_CROSS}%s${NC}${DIM}(no cfg)${NC} " "$short"
        else
            printf "${DIM}${SYM_CIRCLE}%s${NC} " "$short"
        fi
    done
    printf "\n"

    # Phone & Containers - one line
    printf "  ${BLUE}Phone:${NC}   "
    if phone_is_reachable 2>/dev/null && phone_is_mounted 2>/dev/null; then
        printf "${GREEN}${SYM_DOT}${NC} mounted"
    elif phone_is_reachable 2>/dev/null; then
        printf "${YELLOW}${SYM_CIRCLE}${NC} reachable"
    else
        printf "${DIM}${SYM_CIRCLE}${NC} offline"
    fi

    count=$(find "$FUSE_DIR/Containers/" -maxdepth 1 -type l 2>/dev/null | wc -l)
    printf "   ${BLUE}Cntrs:${NC} ${GREEN}%s${NC}\n" "$count"
}

show_menu() {
    clear
    printf "${CYAN}${BOLD}"
    printf "╔══════════════════════════════════════════════╗\n"
    printf "║         FUSE Mount Manager v1.3              ║\n"
    printf "╚══════════════════════════════════════════════╝${NC}\n\n"

    # Status bar
    printf "${DIM}─────────────────── Status ───────────────────${NC}\n"
    compact_status
    printf "${DIM}%s${NC}\n" "$FUSE_DIR"
    printf "${DIM}───────────────────────────────────────────────${NC}\n\n"

    # Mount section
    printf "${GREEN}${BOLD}▸ Mount${NC}\n"
    printf "  ${GREEN}1${NC}  Mount all (VMs + Drives)    ${GREEN}5${NC}  Mount single VM\n"
    printf "  ${GREEN}2${NC}  Mount all VMs               ${GREEN}6${NC}  Mount single Drive\n"
    printf "  ${GREEN}3${NC}  Mount all Drives            ${GREEN}p${NC}  Mount Phone\n"
    printf "\n"

    # Unmount section
    printf "${RED}${BOLD}▸ Unmount${NC}\n"
    printf "  ${RED}7${NC}  Unmount all                  ${RED}10${NC} Unmount single VM\n"
    printf "  ${RED}8${NC}  Unmount all VMs              ${RED}11${NC} Unmount single Drive\n"
    printf "  ${RED}9${NC}  Unmount all Drives           ${RED}u${NC}  Unmount Phone\n"
    printf "\n"

    # OCI Flex section
    printf "${MAGENTA}${BOLD}▸ OCI Flex (Wake-on-Demand)${NC}\n"
    printf "  ${MAGENTA}f${NC}  Status    ${MAGENTA}F${NC}  Start    ${MAGENTA}x${NC}  Stop    ${MAGENTA}X${NC}  Reset\n"
    printf "\n"

    # Utils section
    printf "${CYAN}${BOLD}▸ Utils${NC}\n"
    printf "  ${CYAN}s${NC}  Full status    ${CYAN}l${NC}  View log      ${CYAN}c${NC}  Clear log\n"
    printf "  ${CYAN}r${NC}  Rclone config  ${YELLOW}e${NC}  Settings      ${BLUE}d${NC}  Dependencies\n"
    printf "                                          ${CYAN}q${NC}  Quit\n"
    printf "\n"

    printf "${BOLD}Choice:${NC} "
}

select_vm() {
    action=$1
    printf "\n${BOLD}Select VM:${NC}\n"
    printf "  1) OCI_micro_0\n"
    printf "  2) OCI_micro_1\n"
    printf "  3) OCI_Flex_1\n"
    printf "  4) GCP_micro_1\n"
    printf "  0) Cancel\n"
    printf "Choice: "
    read -r choice
    case "$choice" in
        1) $action "OCI_micro_0" "OCI_micro_0" ;;
        2) $action "OCI_micro_1" "OCI_micro_1" ;;
        3) $action "OCI_Flex_1" "OCI_Flex_1" ;;
        4) $action "GCP_micro_1" "GCP_micro_1" ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

select_drive() {
    action=$1
    printf "\n${BOLD}Select Drive:${NC}\n"
    printf "  1) Gdrive_dnm  ${DIM}(diegonmarcos1@gmail.com)${NC}\n"
    printf "  2) Gdrive_me   ${DIM}(me@diegonmarcos.com)${NC}\n"
    printf "  0) Cancel\n"
    printf "Choice: "
    read -r choice
    case "$choice" in
        1) $action "Gdrive_dnm" "Gdrive_dnm" ;;
        2) $action "Gdrive_me" "Gdrive_me" ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

configure_remote_menu() {
    printf "\n${BOLD}Configure rclone remote:${NC}\n"
    printf "${DIM}Current remotes: $(rclone listremotes | tr '\n' ' ')${NC}\n\n"

    # Show which are missing
    printf "  ${BLUE}Drives:${NC}\n"
    for drive in Gdrive_dnm Gdrive_me; do
        if check_rclone_remote "$drive"; then
            printf "    ${GREEN}${SYM_CHECK}${NC} %s (configured)\n" "$drive"
        else
            printf "    ${RED}${SYM_CROSS}${NC} %s (missing)\n" "$drive"
        fi
    done

    printf "\n  ${BLUE}VMs (SFTP):${NC}\n"
    for vm in OCI_micro_0 OCI_micro_1 OCI_Flex_1 GCP_micro_1; do
        if check_rclone_remote "$vm"; then
            printf "    ${GREEN}${SYM_CHECK}${NC} %s (configured)\n" "$vm"
        else
            printf "    ${RED}${SYM_CROSS}${NC} %s (missing)\n" "$vm"
        fi
    done

    printf "\n${BOLD}Select remote to configure:${NC}\n"
    printf "  1) Gdrive_dnm ${DIM}(diegonmarcos1@)${NC}    5) OCI_micro_0\n"
    printf "  2) Gdrive_me  ${DIM}(me@diegonmarcos)${NC}   6) OCI_micro_1\n"
    printf "  3) (custom)      7) OCI_Flex_1\n"
    printf "  4) Run rclone    8) GCP_micro_1\n"
    printf "     config TUI    0) Cancel\n"
    printf "Choice: "
    read -r choice

    case "$choice" in
        1) create_rclone_remote "Gdrive_dnm" "drive" ;;
        2) create_rclone_remote "Gdrive_me" "drive" ;;
        3)
            printf "Enter remote name: "
            read -r name
            printf "Type (drive/sftp): "
            read -r rtype
            create_rclone_remote "$name" "$rtype"
            ;;
        4) rclone config ;;
        5) create_rclone_remote "OCI_micro_0" "sftp" ;;
        6) create_rclone_remote "OCI_micro_1" "sftp" ;;
        7) create_rclone_remote "OCI_Flex_1" "sftp" ;;
        8) create_rclone_remote "GCP_micro_1" "sftp" ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

view_log() {
    printf "\n${CYAN}${BOLD}=== Mount Log (last 30 lines) ===${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -30 "$LOG_FILE" | while IFS= read -r line; do
            case "$line" in
                *ERROR*) printf "${RED}%s${NC}\n" "$line" ;;
                *)       printf "${DIM}%s${NC}\n" "$line" ;;
            esac
        done
    else
        printf "${DIM}(No log file yet)${NC}\n"
    fi
    printf "\n${DIM}Log path: %s${NC}\n" "$LOG_FILE"
}

clear_log() {
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
        log "Log cleared"
        printf "Log cleared.\n"
    fi
}

settings_menu() {
    printf "\n${CYAN}${BOLD}╔════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║              Settings                      ║${NC}\n"
    printf "${CYAN}${BOLD}╚════════════════════════════════════════════╝${NC}\n\n"

    printf "${BLUE}${BOLD}Current Settings${NC}\n"
    printf "${DIM}────────────────────────────────────────────${NC}\n"
    printf "  ${YELLOW}1${NC}  Mount directory:  ${GREEN}%s${NC}\n" "$FUSE_DIR"
    printf "  ${YELLOW}2${NC}  Rclone options:   ${GREEN}%s${NC}\n" "$RCLONE_OPTS"
    printf "  ${YELLOW}3${NC}  Log file:         ${GREEN}%s${NC}\n" "$LOG_FILE_NAME"
    printf "\n"
    printf "  ${DIM}e${NC}  Edit config JSON  ${DIM}(%s)${NC}\n" "$CONFIG_FILE"
    printf "  ${DIM}0${NC}  Back\n"
    printf "\n${BOLD}Choice:${NC} "
    read -r choice

    case "$choice" in
        1)
            printf "\n${BOLD}Current mount directory:${NC} %s\n" "$FUSE_DIR"
            printf "${BOLD}New mount directory:${NC} "
            read -r new_dir
            if [ -n "$new_dir" ]; then
                # Expand ~ if present
                new_dir=$(eval echo "$new_dir")
                if [ ! -d "$new_dir" ]; then
                    printf "Directory doesn't exist. Create it? [y/N] "
                    read -r create
                    case "$create" in
                        [Yy]*) mkdir -p "$new_dir" ;;
                        *) warn "Aborted"; return ;;
                    esac
                fi
                update_setting "mount_dir" "$new_dir"
                log "Mount directory changed to: $new_dir"
                printf "${GREEN}${SYM_CHECK}${NC} Mount directory updated to: %s\n" "$new_dir"
                printf "${YELLOW}${SYM_WARN}${NC} Restart the script to apply changes.\n"
            fi
            ;;
        2)
            printf "\n${BOLD}Current rclone options:${NC} %s\n" "$RCLONE_OPTS"
            printf "${DIM}Common options:${NC}\n"
            printf "  ${DIM}--vfs-cache-mode off${NC}      No caching (default rclone)\n"
            printf "  ${DIM}--vfs-cache-mode minimal${NC}  Cache only open files\n"
            printf "  ${DIM}--vfs-cache-mode writes${NC}   Cache writes (recommended)\n"
            printf "  ${DIM}--vfs-cache-mode full${NC}     Full caching\n"
            printf "\n${BOLD}New rclone options:${NC} "
            read -r new_opts
            if [ -n "$new_opts" ]; then
                update_setting "rclone_opts" "$new_opts"
                log "Rclone options changed to: $new_opts"
                printf "${GREEN}${SYM_CHECK}${NC} Rclone options updated.\n"
                printf "${YELLOW}${SYM_WARN}${NC} Restart the script to apply changes.\n"
            fi
            ;;
        3)
            printf "\n${BOLD}Current log file:${NC} %s\n" "$LOG_FILE_NAME"
            printf "${BOLD}New log file name:${NC} "
            read -r new_log
            if [ -n "$new_log" ]; then
                update_setting "log_file" "$new_log"
                log "Log file changed to: $new_log"
                printf "${GREEN}${SYM_CHECK}${NC} Log file updated.\n"
                printf "${YELLOW}${SYM_WARN}${NC} Restart the script to apply changes.\n"
            fi
            ;;
        e|E)
            if command -v "${EDITOR:-nano}" >/dev/null 2>&1; then
                "${EDITOR:-nano}" "$CONFIG_FILE"
            else
                printf "${RED}No editor found. Set \$EDITOR or install nano.${NC}\n"
            fi
            ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

show_settings() {
    printf "\n${CYAN}${BOLD}Settings${NC} ${DIM}(from %s)${NC}\n" "$CONFIG_FILE"
    printf "${DIM}────────────────────────────────────────────${NC}\n"
    printf "  ${BLUE}mount_dir:${NC}    %s\n" "$FUSE_DIR"
    printf "  ${BLUE}rclone_opts:${NC}  %s\n" "$RCLONE_OPTS"
    printf "  ${BLUE}log_file:${NC}     %s\n" "$LOG_FILE"
    printf "\n"
}

run_tui() {
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            # Mount
            1) mount_all ;;
            2) mount_all_vms; show_status ;;
            3) mount_all_drives; show_status ;;
            p|P|4) mount_phone ;;
            5) select_vm mount_vm; show_status ;;
            6) select_drive mount_drive; show_status ;;
            # Unmount
            7) unmount_all ;;
            8) unmount_all_vms; show_status ;;
            9) unmount_all_drives; show_status ;;
            u|U) unmount_phone ;;
            10) select_vm unmount_vm; show_status ;;
            11) select_drive unmount_drive; show_status ;;
            # OCI Flex
            f) flex_status ;;
            F) flex_start ;;
            x) flex_stop ;;
            X) flex_reset ;;
            # Utils
            s|S) show_status ;;
            l|L) view_log ;;
            c|C) clear_log ;;
            r|R) configure_remote_menu ;;
            e|E) settings_menu ;;
            d|D) deps_menu ;;
            q|Q) printf "${GREEN}Bye!${NC}\n"; exit 0 ;;
            *) error "Invalid choice: $choice" ;;
        esac
        printf "\n${DIM}Press Enter to continue...${NC}"
        read -r _
    done
}

# ==============================================================================
# HELP
# ==============================================================================

show_help() {
    printf "\n"
    printf "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║           FUSE Mount Manager v1.3                                ║${NC}\n"
    printf "${CYAN}${BOLD}║     Unified mount manager for VMs, Drives, and Phones           ║${NC}\n"
    printf "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"

    printf "${YELLOW}${BOLD}USAGE${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${GREEN}mount.sh${NC} ${DIM}[COMMAND] [OPTIONS]${NC}\n"
    printf "    ${GREEN}mount.sh${NC}                      ${DIM}# Launch interactive TUI${NC}\n"
    printf "\n"

    printf "${GREEN}${BOLD}▸ MOUNT COMMANDS${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${GREEN}mount${NC}              Mount all ${DIM}(VMs + Drives)${NC}\n"
    printf "    ${GREEN}mount-vms${NC}          Mount all VMs\n"
    printf "    ${GREEN}mount-drives${NC}       Mount all Drives\n"
    printf "    ${GREEN}mount-phone${NC}        Mount phone via KDE Connect\n"
    printf "    ${GREEN}mount-vm${NC} ${CYAN}NAME${NC}      Mount specific VM\n"
    printf "                       ${DIM}Names: OCI_micro_0, OCI_micro_1, OCI_Flex_1, GCP_micro_1${NC}\n"
    printf "\n"

    printf "${RED}${BOLD}▸ UNMOUNT COMMANDS${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${RED}unmount${NC}            Unmount everything\n"
    printf "    ${RED}unmount-vms${NC}        Unmount all VMs\n"
    printf "    ${RED}unmount-drives${NC}     Unmount all Drives\n"
    printf "    ${RED}unmount-phone${NC}      Unmount phone\n"
    printf "    ${RED}unmount-vm${NC} ${CYAN}NAME${NC}    Unmount specific VM\n"
    printf "\n"

    printf "${MAGENTA}${BOLD}▸ OCI FLEX (Wake-on-Demand)${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${MAGENTA}flex-start${NC}         Start OCI Flex VM\n"
    printf "    ${MAGENTA}flex-stop${NC}          Stop OCI Flex VM\n"
    printf "    ${MAGENTA}flex-reset${NC}         Force reset OCI Flex VM\n"
    printf "    ${MAGENTA}flex-status${NC}        Show OCI Flex VM status\n"
    printf "\n"

    printf "${BLUE}${BOLD}▸ UTILITIES${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${BLUE}status${NC}, ${BLUE}s${NC}          Show mount status\n"
    printf "    ${BLUE}log${NC}                View debug log ${DIM}(last 50 lines)${NC}\n"
    printf "    ${BLUE}log-clear${NC}          Clear debug log\n"
    printf "    ${BLUE}-h${NC}, ${BLUE}--help${NC}        Show this help\n"
    printf "\n"

    printf "${YELLOW}${BOLD}▸ CONFIGURATION${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${YELLOW}config${NC}             Show current settings\n"
    printf "    ${YELLOW}config-edit${NC}        Interactive settings menu\n"
    printf "    ${YELLOW}config-set${NC} ${CYAN}K V${NC}    Set config key ${DIM}(mount_dir, rclone_opts, log_file)${NC}\n"
    printf "\n"

    printf "${BLUE}${BOLD}▸ DEPENDENCIES${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${BLUE}deps${NC}               Show dependency status ${DIM}(works without jq)${NC}\n"
    printf "    ${BLUE}deps-install${NC}       Install core dependencies\n"
    printf "    ${BLUE}deps-phone${NC}         Install phone mount deps ${DIM}(kdeconnect)${NC}\n"
    printf "    ${BLUE}deps-oci${NC}           Install OCI CLI\n"
    printf "    ${BLUE}deps-all${NC}           Install ALL dependencies\n"
    printf "\n"

    printf "${CYAN}${BOLD}EXAMPLES${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${DIM}\$${NC} ${GREEN}mount.sh${NC}                      ${DIM}# Launch TUI${NC}\n"
    printf "    ${DIM}\$${NC} ${GREEN}mount.sh${NC} deps                 ${DIM}# Check dependencies${NC}\n"
    printf "    ${DIM}\$${NC} ${GREEN}mount.sh${NC} deps-install         ${DIM}# Install core deps${NC}\n"
    printf "    ${DIM}\$${NC} ${GREEN}mount.sh${NC} mount                ${DIM}# Mount all${NC}\n"
    printf "    ${DIM}\$${NC} ${GREEN}mount.sh${NC} mount-vm OCI_Flex_1  ${DIM}# Mount specific VM${NC}\n"
    printf "    ${DIM}\$${NC} ${GREEN}mount.sh${NC} flex-start           ${DIM}# Wake up OCI Flex${NC}\n"
    printf "\n"

    printf "${CYAN}${BOLD}MOUNT STRUCTURE${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${CYAN}~/mnt_mnt/${NC}\n"
    printf "    ${DIM}├──${NC} ${DIM}.mount.log${NC}        ${DIM}# Debug log (hidden)${NC}\n"
    printf "    ${DIM}├──${NC} ${YELLOW}OCI_micro_0/${NC}     ${DIM}# Oracle VM 1 (Mail)${NC}\n"
    printf "    ${DIM}│   ├──${NC} sys/          ${DIM}# Root filesystem${NC}\n"
    printf "    ${DIM}│   ├──${NC} home/         ${DIM}# Home directories${NC}\n"
    printf "    ${DIM}│   ├──${NC} docker/       ${DIM}# Docker volumes${NC}\n"
    printf "    ${DIM}│   └──${NC} mnt/          ${DIM}# Mount points${NC}\n"
    printf "    ${DIM}├──${NC} ${YELLOW}OCI_micro_1/${NC}     ${DIM}# Oracle VM 2 (Analytics)${NC}\n"
    printf "    ${DIM}├──${NC} ${MAGENTA}OCI_Flex_1/${NC}      ${DIM}# Oracle Flex (Photos) - wake-on-demand${NC}\n"
    printf "    ${DIM}├──${NC} ${YELLOW}GCP_micro_1/${NC}     ${DIM}# Google Cloud (Proxy)${NC}\n"
    printf "    ${DIM}├──${NC} ${GREEN}Gdrive_dnm/${NC}      ${DIM}# Google Drive (dnm account)${NC}\n"
    printf "    ${DIM}├──${NC} ${GREEN}Gdrive_me/${NC}       ${DIM}# Google Drive (me account)${NC}\n"
    printf "    ${DIM}├──${NC} ${BLUE}samsung_gS21/${NC}    ${DIM}# Phone (KDE Connect)${NC}\n"
    printf "    ${DIM}└──${NC} ${CYAN}Containers/${NC}      ${DIM}# Symlinks to all docker volumes${NC}\n"
    printf "\n"

    printf "${YELLOW}${BOLD}REQUIREMENTS${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${SYM_DOT} ${GREEN}rclone${NC}           ${DIM}configured with remotes (rclone config)${NC}\n"
    printf "    ${SYM_DOT} ${GREEN}fusermount${NC}       ${DIM}FUSE utilities${NC}\n"
    printf "    ${SYM_DOT} ${GREEN}oci${NC}              ${DIM}OCI CLI (for flex control)${NC}\n"
    printf "    ${SYM_DOT} ${GREEN}kdeconnect-cli${NC}   ${DIM}KDE Connect + qdbus (for phone)${NC}\n"
    printf "\n"

    printf "${RED}${BOLD}TROUBLESHOOTING${NC}\n"
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
    printf "    ${SYM_WARN} Mount fails?        ${DIM}Check the log:${NC} ${CYAN}mount.sh log${NC}\n"
    printf "    ${SYM_WARN} Missing remote?     ${DIM}Add it with:${NC}   ${CYAN}rclone config${NC}\n"
    printf "\n"
}

# ==============================================================================
# MAIN
# ==============================================================================

case "${1:-}" in
    "")
        run_tui
        ;;
    mount)
        mount_all
        ;;
    mount-vms)
        mount_all_vms
        show_status
        ;;
    mount-drives)
        mount_all_drives
        show_status
        ;;
    mount-phone)
        mount_phone
        ;;
    mount-vm)
        if [ -z "${2:-}" ]; then
            error "Usage: $0 mount-vm NAME"
            exit 1
        fi
        mount_vm "$2" "$2"
        ;;
    unmount|umount)
        unmount_all
        ;;
    unmount-vms|umount-vms)
        unmount_all_vms
        show_status
        ;;
    unmount-drives|umount-drives)
        unmount_all_drives
        show_status
        ;;
    unmount-phone|umount-phone)
        unmount_phone
        ;;
    unmount-vm|umount-vm)
        if [ -z "${2:-}" ]; then
            error "Usage: $0 unmount-vm NAME"
            exit 1
        fi
        unmount_vm "$2"
        ;;
    status|s)
        show_status
        ;;
    log)
        view_log
        ;;
    log-clear)
        clear_log
        ;;
    flex-start)
        flex_start
        ;;
    flex-stop)
        flex_stop
        ;;
    flex-reset)
        flex_reset
        ;;
    flex-status)
        flex_status
        ;;
    config|settings)
        show_settings
        ;;
    config-edit)
        settings_menu
        ;;
    config-set)
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            error "Usage: $0 config-set KEY VALUE"
            printf "  Keys: mount_dir, rclone_opts, log_file\n"
            exit 1
        fi
        update_setting "$2" "$3"
        log "Setting $2 changed to: $3"
        printf "${GREEN}${SYM_CHECK}${NC} %s = %s\n" "$2" "$3"
        ;;
    deps-phone)
        install_phone_deps
        ;;
    deps-oci)
        install_oci_deps
        ;;
    deps-all)
        install_all_deps
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        error "Unknown command: $1"
        printf "Run '$0 help' for usage\n"
        exit 1
        ;;
esac
