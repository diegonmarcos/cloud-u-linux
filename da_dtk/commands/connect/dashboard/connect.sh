#!/bin/sh
# NOTE: Uses 'local' and bash arrays in select_and_mount_vm — needs bash/dash/ash.
# Key reading is POSIX (stty+dd).
# connect.sh - Cloud Connect: Unified Dashboard
# Combines: Git Manager + FUSE Mounts + Rclone Sync + Servers + Webservers
# Author: Diego Nepomuceno Marcos
# Version: 2.0
#
# Usage:
#   ./connect.sh              # Launch dashboard
#   ./connect.sh <command>    # CLI mode
#   ./connect.sh --help       # Show help

set -eu

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
CC_CACHE_DIR="$SCRIPT_DIR/.cache/connect"

# Static modules (hand-maintained, committed to git)
CC_MODULES_STATIC=(
    "$SCRIPT_DIR/connect-settings.json"
    "$SCRIPT_DIR/connect-mesh.json"
    "$SCRIPT_DIR/connect-git.json"
    "$SCRIPT_DIR/connect-fuse-drives.json"
    "$SCRIPT_DIR/connect-sync.json"
    "$SCRIPT_DIR/connect-data-servers.json"
    "$SCRIPT_DIR/connect-web-servers.json"
    "$SCRIPT_DIR/connect-hm-flakes.json"
)
# Dynamic modules (auto-generated at startup into .cache/, override statics)
CC_MODULES_DYNAMIC=(
    "$CC_CACHE_DIR/env.json"
    "$CC_CACHE_DIR/mesh.json"
    "$CC_CACHE_DIR/hm-flakes.json"
)
# Merged list used by load_config() — statics first, dynamics override
CC_MODULES=("${CC_MODULES_STATIC[@]}" "${CC_MODULES_DYNAMIC[@]}")
CONFIG_JSON=""  # populated by load_config()
CC_DATA=""       # populated by collect_all() — single-source JSON for all views

# Query the collected live-state JSON (single-source for all views)
_d() { jq "$@" <<< "$CC_DATA" 2>/dev/null; }

# JSON-escape a string value (handles quotes, backslashes, newlines)
_json_str() { printf '%s' "$1" | jq -Rs .; }

# Safe jq-from-file: _jqf <filter> <file> <fallback>
# Returns fallback if file missing, empty, or jq produces no output
_jqf() { local r; r=$(jq -c "$1" "$2" 2>/dev/null) && [ -n "$r" ] && printf '%s' "$r" || printf '%s' "$3"; }

# Environment detection — set by cc_probe_env(), used by load_config() for path overrides
CC_ENV_PROFILE=""   # android-arm | desktop-x86 | desktop-arm
CC_ENV_SYSTEM=""    # Android ARM | Desktop x86 | Desktop ARM
CC_ENV_OS=""        # Nix-on-Android | NixOS | Linux
CC_ENV_ARCH=""      # aarch64 | x86_64 | armv7l

# Sync state files
SYNC_JOBS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rclone_manager/sync_jobs.json"
SYNC_RULES_FILE=""  # set from config
SYNC_LOG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rclone_manager/logs"

# =============================================================================
# 256-COLOR SCHEME
# =============================================================================

if [ -t 1 ]; then
    RST="\033[0m"
    BLD="\033[1m"
    DIM="\033[2m"
    # Section accent colors (256-color)
    C_HEAD="\033[38;5;255m"     # header: bright white
    C_HM="\033[38;5;183m"       # A) HOME-MANAGER: lavender
    C_MESH="\033[38;5;44m"      # B) MESH: teal
    C_GIT="\033[38;5;77m"       # C) GIT: green
    C_DRIVE="\033[38;5;220m"    # C) FUSE DRIVES: gold
    C_SYNC="\033[38;5;177m"     # E) SYNC: magenta
    C_SRVR="\033[38;5;69m"      # F) DATA SERVERS: blue
    C_WEB="\033[38;5;208m"      # G) WEBSERVER: orange
    C_SVC="\033[38;5;114m"      # H) SERVICES: mint green
    C_SEC="\033[38;5;203m"      # I) SECURITY: alert red
    # Status colors
    C_OK="\033[38;5;77m"        # green
    C_WARN="\033[38;5;220m"     # yellow
    C_ERR="\033[38;5;196m"      # red
    C_INFO="\033[38;5;75m"      # cyan
    C_DIM="\033[38;5;240m"      # gray
    C_ALERT="\033[38;5;203m"    # alert red
    # Gauge gradient
    C_G1="\033[38;5;34m"        # 0-25%
    C_G2="\033[38;5;76m"        # 25-50%
    C_G3="\033[38;5;220m"       # 50-75%
    C_G4="\033[38;5;196m"       # 75-100%
    # Sparkline
    C_SP="\033[38;5;44m"
    # Background for header
    BG_HEAD="\033[48;5;235m"
else
    RST='' BLD='' DIM=''
    C_HEAD='' C_MESH='' C_GIT='' C_DRIVE='' C_SYNC='' C_SRVR='' C_SVC='' C_WEB='' C_HM=''
    C_OK='' C_WARN='' C_ERR='' C_INFO='' C_DIM='' C_ALERT='' C_SEC=''
    C_G1='' C_G2='' C_G3='' C_G4='' C_SP='' BG_HEAD=''
fi

# =============================================================================
# SYMBOLS
# =============================================================================

S_RUN="◉"
S_STOP="○"
S_OK="✓"
S_FAIL="✗"
S_WARN="⚠"
S_DOT="●"
S_PLAY="▶"
S_ARR="→"
S_ARBI="↔"
S_ARRL="←"

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

cc_probe_env() {
    local arch os_id is_termux=false

    # Architecture
    arch=$(uname -m 2>/dev/null || echo "unknown")
    CC_ENV_ARCH="$arch"

    # Termux detection
    if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
        is_termux=true
    fi

    # OS detection
    if $is_termux; then
        CC_ENV_OS="Nix-on-Android"
    elif [ -f "/etc/os-release" ]; then
        os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-linux}")
        case "$os_id" in
            nixos) CC_ENV_OS="NixOS" ;;
            *)     CC_ENV_OS="Linux" ;;
        esac
    else
        CC_ENV_OS="Linux"
    fi

    # Map to profile
    if $is_termux; then
        CC_ENV_PROFILE="android-arm"
        CC_ENV_SYSTEM="Android ARM"
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        CC_ENV_PROFILE="desktop-arm"
        CC_ENV_SYSTEM="Desktop ARM"
    else
        CC_ENV_PROFILE="desktop-x86"
        CC_ENV_SYSTEM="Desktop x86"
    fi

    # Write to cache
    mkdir -p "$CC_CACHE_DIR"
    jq -n \
        --arg profile "$CC_ENV_PROFILE" \
        --arg system  "$CC_ENV_SYSTEM" \
        --arg os      "$CC_ENV_OS" \
        --arg arch    "$CC_ENV_ARCH" \
        '{"env": {"profile": $profile, "system": $system, "os": $os, "arch": $arch}}' \
        > "$CC_CACHE_DIR/env.json"
}

# Fetch cloud-topology.json + cloud-configs.json from GitHub (cached)
CLOUD_RAW_BASE="https://raw.githubusercontent.com/diegonmarcos/cloud-infra/main"
CLOUD_TOPOLOGY=""
CLOUD_CONFIGS=""

_fetch_cloud_json() {
    local cache_topo="$CC_CACHE_DIR/cloud-topology.json"
    local cache_conf="$CC_CACHE_DIR/cloud-configs.json"
    local max_age=300  # 5 min cache

    # Use cache if fresh
    if [ -f "$cache_topo" ] && [ -f "$cache_conf" ]; then
        local age=$(( $(date +%s) - $(date -r "$cache_topo" +%s 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$max_age" ]; then
            CLOUD_TOPOLOGY=$(cat "$cache_topo")
            CLOUD_CONFIGS=$(cat "$cache_conf")
            return 0
        fi
    fi

    # Fetch in parallel
    curl -sf --max-time 5 "$CLOUD_RAW_BASE/cloud-topology.json" > "$cache_topo.tmp" &
    local pid1=$!
    curl -sf --max-time 5 "$CLOUD_RAW_BASE/cloud-configs.json" > "$cache_conf.tmp" &
    local pid2=$!
    wait "$pid1" "$pid2" || true

    # Validate and commit
    if jq empty "$cache_topo.tmp" 2>/dev/null && jq empty "$cache_conf.tmp" 2>/dev/null; then
        mv "$cache_topo.tmp" "$cache_topo"
        mv "$cache_conf.tmp" "$cache_conf"
        CLOUD_TOPOLOGY=$(cat "$cache_topo")
        CLOUD_CONFIGS=$(cat "$cache_conf")
    else
        rm -f "$cache_topo.tmp" "$cache_conf.tmp"
        # Fall back to stale cache
        [ -f "$cache_topo" ] && CLOUD_TOPOLOGY=$(cat "$cache_topo")
        [ -f "$cache_conf" ] && CLOUD_CONFIGS=$(cat "$cache_conf")
    fi
}

# Build mesh.json from cloud-topology.json (fetched from GitHub)
cc_build_mesh() {
    _fetch_cloud_json

    [ -z "$CLOUD_TOPOLOGY" ] && return  # no data available

    # Read static mesh for phone + vm_subdirs defaults
    local static_mesh
    static_mesh=$(jq '.mesh // {}' "$SCRIPT_DIR/connect-mesh.json" 2>/dev/null || echo '{}')
    local default_subdirs
    default_subdirs=$(echo "$static_mesh" | jq '[{"name":"sys","remote_path":"/"},{"name":"home","remote_path":"/home"},{"name":"docker","remote_path":"/var/lib/docker/volumes"},{"name":"mnt","remote_path":"/mnt"}]')

    # Transform topology vms{} object → mesh.vms[] array
    jq -n \
        --argjson cfg "$CLOUD_TOPOLOGY" \
        --argjson static "$static_mesh" \
        --argjson subdirs "$default_subdirs" \
        '{
            "mesh": {
                "vms": [
                    $cfg.vms | to_entries[] |
                    {
                        "id":         .key,
                        "name":       .value.ssh_alias,
                        "alias":      .value.ssh_alias,
                        "wg_ip":      .value.wg_ip,
                        "public_ip":  .value.ip,
                        "description":.value.description,
                        "specs":      (.value.specs // null),
                        "vm_subdirs": $subdirs,
                        "services":   (.key as $vmid | $cfg.services | to_entries | map(select(.value.vm == $vmid)) | map(.key))
                    }
                ],
                "phone": ($static.phone // {}),
                "storage": ($cfg.storage // []),
                "vpss":    ($cfg.vpss // {}),
                "firewalls": ($cfg.firewalls // [])
            },
            "service_details": ($cfg.services | to_entries | map({
                key: .key,
                value: {
                    "domain": .value.domain,
                    "port": (.value.ports[0] // "—"),
                    "availability": (if .value.wake then "wake-on-demand" else "24/7" end),
                    "category": .value.category
                }
            }) | from_entries)
        }' > "$CC_CACHE_DIR/mesh.json"
}

# Build hm-flakes.json by scanning ~/git/cloud-unix/ flake directories
cc_build_hm() {
    local git_root
    git_root=$(jq -r --arg p "$CC_ENV_PROFILE" '
        if .profiles[$p].git_workdir then .profiles[$p].git_workdir
        else .settings.git_workdir end' \
        "$SCRIPT_DIR/connect-settings.json" 2>/dev/null)
    git_root="${git_root/#\~/$HOME}"

    local unix_dir="$git_root/unix"
    [ ! -d "$unix_dir" ] && return  # unix repo not cloned

    # Read static hm-flakes for descriptions and enabled flags
    local static_hm
    static_hm=$(jq '.home_manager_flakes // []' "$SCRIPT_DIR/connect-hm-flakes.json" 2>/dev/null || echo '[]')

    jq -n \
        --arg unix_dir "$unix_dir" \
        --argjson static "$static_hm" \
        '{
            "home_manager_flakes": [
                {"name":"nixos-surface", "type":"nixos",        "path": ($unix_dir + "/aa_nixos-surface_host"), "enabled":true},
                {"name":"desktop",       "type":"home-manager", "path": ($unix_dir + "/ba_flakes_desktop"),     "enabled":true},
                {"name":"termux",        "type":"home-manager", "path": ($unix_dir + "/bb_flakes_termux"),      "enabled":true}
            ] | map(
                . as $entry |
                . + (($static[] | select(.name == $entry.name) | {description, enabled}) // {})
            )
        }' > "$CC_CACHE_DIR/hm-flakes.json"
}

# =============================================================================
# LOAD CONFIG
# =============================================================================

# Query the merged in-memory config
_jq() { jq "$@" <<< "$CONFIG_JSON" 2>/dev/null; }

# Re-merge all modules into CONFIG_JSON (call after any write-back)
_reload_config_json() {
    local existing=()
    local mfile
    for mfile in "${CC_MODULES[@]}"; do
        [ -f "$mfile" ] && existing+=("$mfile")
    done
    CONFIG_JSON=$(jq -s 'reduce .[] as $m ({}; . * $m)' "${existing[@]}" 2>/dev/null)
}

# Write a jq filter to the module that owns .settings.$key, then reload
_module_for_settings_key() {
    local key="$1"
    local mfile
    for mfile in "${CC_MODULES[@]}"; do
        [ -f "$mfile" ] || continue
        if jq -e --arg k "$key" 'has("settings") and (.settings | has($k))' "$mfile" >/dev/null 2>&1; then
            echo "$mfile"; return
        fi
    done
    echo "$SCRIPT_DIR/connect-settings.json"
}

# Write a jq mutation to a specific module file, then reload CONFIG_JSON
_jq_write() {
    local mfile="$1"; shift
    local tmp="$CC_CACHE_DIR/.jqw.$$"
    jq "$@" "$mfile" > "$tmp" && mv "$tmp" "$mfile"
    _reload_config_json
}

load_config() {
    if ! command -v jq >/dev/null 2>&1; then
        printf "${C_ERR}jq is required${RST}\n" >&2
        exit 1
    fi

    local existing=()
    local mfile
    for mfile in "${CC_MODULES_STATIC[@]}"; do
        if [ ! -f "$mfile" ]; then
            printf "${C_WARN}Module not found: %s${RST}\n" "$(basename "$mfile")" >&2
        else
            existing+=("$mfile")
        fi
    done
    for mfile in "${CC_MODULES_DYNAMIC[@]}"; do
        [ -f "$mfile" ] && existing+=("$mfile")
    done

    if [ "${#existing[@]}" -eq 0 ]; then
        printf "${C_ERR}No config modules found in: %s${RST}\n" "$SCRIPT_DIR" >&2
        exit 1
    fi

    CONFIG_JSON=$(jq -s 'reduce .[] as $m ({}; . * $m)' "${existing[@]}" 2>/dev/null)
    if [ -z "$CONFIG_JSON" ] || [ "$CONFIG_JSON" = "null" ]; then
        printf "${C_ERR}Failed to merge config modules${RST}\n" >&2
        exit 1
    fi

    GIT_WORKDIR=$(_jq -r '.settings.git_workdir')
    MOUNT_DIR=$(_jq -r '.settings.mount_dir')
    SYNC_DIR=$(_jq -r '.settings.sync_dir')
    RCLONE_OPTS=$(_jq -r '.settings.rclone_opts')
    RCLONE_SYNC_OPTS=$(_jq -r '.settings.rclone_sync_opts')
    MERGE_STRATEGY=$(_jq -r '.settings.merge_strategy')
    LOG_FILE_NAME=$(_jq -r '.settings.log_file')
    LOG_FILE="$MOUNT_DIR/$LOG_FILE_NAME"

    # Profile-based path overrides (applied after base settings)
    if [ -n "$CC_ENV_PROFILE" ]; then
        local p_git p_mount p_sync p_log
        p_git=$(_jq -r --arg p "$CC_ENV_PROFILE" '.profiles[$p].git_workdir // empty')
        p_mount=$(_jq -r --arg p "$CC_ENV_PROFILE" '.profiles[$p].mount_dir // empty')
        p_sync=$(_jq -r --arg p "$CC_ENV_PROFILE" '.profiles[$p].sync_dir // empty')
        p_log=$(_jq -r --arg p "$CC_ENV_PROFILE" '.profiles[$p].log_file // empty')
        # Expand tilde
        [ -n "$p_git" ]   && GIT_WORKDIR="${p_git/#\~/$HOME}"
        [ -n "$p_mount" ] && MOUNT_DIR="${p_mount/#\~/$HOME}"
        [ -n "$p_sync" ]  && SYNC_DIR="${p_sync/#\~/$HOME}"
        [ -n "$p_log" ]   && LOG_FILE_NAME="$p_log"
        LOG_FILE="$MOUNT_DIR/$LOG_FILE_NAME"
    fi

    SYNC_RULES_FILE="$SYNC_DIR/sync.json"

    # Ensure dirs
    mkdir -p "$MOUNT_DIR" "$SYNC_DIR" "$SYNC_LOG_DIR" "$(dirname "$SYNC_JOBS_FILE")"
    [ ! -f "$SYNC_JOBS_FILE" ] && echo "[]" > "$SYNC_JOBS_FILE"
    [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

    # Rotate log if > 1MB
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
    fi
}

log_msg() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }
log_err() { printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }

# =============================================================================
# GAUGE BAR RENDERING
# =============================================================================

# Smooth gauge: gauge_bar <current> <max> <width> <label>
# Uses Unicode fractional blocks: ▏▎▍▌▋▊▉█
gauge_bar() {
    local cur=$1 max=$2 width=${3:-16} label=${4:-""}
    local blocks="▏▎▍▌▋▊▉█"
    local pct=0
    [ "$max" -gt 0 ] 2>/dev/null && pct=$(( cur * 100 / max ))
    [ "$pct" -gt 100 ] && pct=100

    # Pick color by percentage
    local gc="$C_G1"
    [ "$pct" -ge 25 ] && gc="$C_G2"
    [ "$pct" -ge 50 ] && gc="$C_G3"
    [ "$pct" -ge 75 ] && gc="$C_G4"

    local filled_8ths=$(( pct * width * 8 / 100 ))
    local full=$(( filled_8ths / 8 ))
    local frac=$(( filled_8ths % 8 ))
    local empty=$(( width - full - (frac > 0 ? 1 : 0) ))

    local bar=""
    local i=0
    while [ "$i" -lt "$full" ]; do bar="${bar}█"; i=$((i+1)); done
    if [ "$frac" -gt 0 ]; then
        # Extract fractional character (UTF-8 multibyte)
        local fc
        fc=$(printf '%s' "$blocks" | awk -v n="$frac" 'BEGIN{FS=""}{print $n}')
        bar="${bar}${fc}"
    fi
    i=0
    while [ "$i" -lt "$empty" ]; do bar="${bar}░"; i=$((i+1)); done

    if [ -n "$label" ]; then
        printf "%b%s%b %3d%% %s" "$gc" "$bar" "$RST" "$pct" "$label"
    else
        printf "%b%s%b %3d%%" "$gc" "$bar" "$RST" "$pct"
    fi
}

# =============================================================================
# SPARKLINE
# =============================================================================

# sparkline <space-separated-values> (0-8 scale)
sparkline() {
    local chars="▁▂▃▄▅▆▇█"
    local vals="$1"
    local max=1
    for v in $vals; do [ "$v" -gt "$max" ] 2>/dev/null && max=$v; done
    local out=""
    for v in $vals; do
        local idx=1
        [ "$max" -gt 0 ] 2>/dev/null && idx=$(( v * 7 / max + 1 ))
        [ "$idx" -gt 8 ] && idx=8
        [ "$idx" -lt 1 ] && idx=1
        local c
        c=$(printf '%s' "$chars" | awk -v n="$idx" 'BEGIN{FS=""}{print $n}')
        out="${out}${c}"
    done
    printf "%b%s%b" "$C_SP" "$out" "$RST"
}

# =============================================================================
# UTILITY: is_mounted, rclone_remote_exists
# =============================================================================

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

rclone_remote_exists() {
    rclone listremotes 2>/dev/null | grep -q "^${1}:$"
}

# =============================================================================
# A) MESH - Data Collection
# =============================================================================

# Get vm_subdir names for a VM by JSON index (newline-separated)
_vm_subdirs() { _jq -r ".mesh.vms[$1].vm_subdirs[].name"; }
# Get vm_subdir names for a VM by VM name
_vm_subdirs_by_name() { _jq -r --arg n "$1" '.mesh.vms[] | select(.name==$n) | .vm_subdirs[].name'; }
# Get remote_path for a named subdir of a VM (by index)
_vm_subdir_remote_path() { _jq -r --arg s "$2" ".mesh.vms[$1].vm_subdirs[] | select(.name==\$s) | .remote_path"; }

# Get VM reachability via TCP/nc — fast SYN/ACK only, no SSH handshake overhead.
# Both desktop and android use nc; SSH full handshake is unnecessary for a ping check.
#
# Future Implementation RoadMap Backlog:
#   wireguard-go (netstack/userspace mode) — run WG tunnel natively inside Termux without root.
#   Would use gVisor netstack (no TUN device needed), expose SOCKS5 on localhost,
#   removing dependency on Android WG app per-app VPN inclusion.
#   Ref: https://github.com/WireGuard/wireguard-go (netstack branch)
vm_is_reachable() {
    local host=${1:?} port=${2:-22}
    nc -z -w2 "$host" "$port" 2>/dev/null
}

# Get phone status via KDE Connect
phone_status() {
    local dev_id
    dev_id=$(_jq -r '.mesh.phone.device_id')
    [ -z "$dev_id" ] || [ "$dev_id" = "null" ] && echo "unconfigured" && return

    if ! command -v kdeconnect-cli >/dev/null 2>&1; then
        echo "no-kdeconnect"
        return
    fi

    if kdeconnect-cli -a --id-only 2>/dev/null | grep -q "$dev_id"; then
        if command -v qdbus >/dev/null 2>&1; then
            local mounted
            mounted=$(qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$dev_id/sftp" \
                org.kde.kdeconnect.device.sftp.isMounted 2>/dev/null || echo "false")
            [ "$mounted" = "true" ] && echo "mounted" || echo "reachable"
        else
            echo "reachable"
        fi
    else
        echo "offline"
    fi
}

phone_battery() {
    local dev_id
    dev_id=$(_jq -r '.mesh.phone.device_id')
    [ -z "$dev_id" ] || [ "$dev_id" = "null" ] && echo "?" && return
    if command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$dev_id/battery" \
            org.kde.kdeconnect.device.battery.charge 2>/dev/null || echo "?"
    else
        echo "?"
    fi
}

# =============================================================================
# SINGLE-SOURCE DATA COLLECTION — collect_all()
# All views (full, compact, resume, logs, gauges, alerts) read from CC_DATA.
# No render function does its own I/O — collect_all() does ALL system calls.
# =============================================================================

# Collect all git data for ONE repo — runs in background subshell.
# Outputs a single JSON object to stdout. No global side-effects.
# Optimized: batches git calls to minimize subprocess spawns.
_git_collect_repo() {
    local repo_name=$1 dir=$2

    if ! [ -d "$dir/.git" ]; then
        printf '{"name":"%s","cloned":false}' "$repo_name"
        return
    fi

    cd "$dir" 2>/dev/null || { printf '{"name":"%s","cloned":false}' "$repo_name"; return; }

    local now; now=$(date +%s)

    # ── Batch 1: git status (heaviest single call) ──
    local dirty; dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    # ── Batch 2: branch info + ahead/behind + tracking (one for-each-ref) ──
    local branch tracking pull push
    branch=$(git branch --show-current 2>/dev/null || echo "?")
    local lr; lr=$(git rev-list --left-right --count HEAD...@{u} 2>/dev/null)
    if [ -n "$lr" ]; then
        push=$(echo "$lr" | awk '{print $1}')
        pull=$(echo "$lr" | awk '{print $2}')
        tracking=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "none")
    else
        pull="?"; push="?"; tracking="none"
    fi

    # ── Batch 3: last commit (ts + msg in one call) + branches + tags + stash + url ──
    local ts_c msg url branches tags stash submods
    local log1; log1=$(git log -1 --format='%ct|%s' 2>/dev/null || echo "0|")
    ts_c=${log1%%|*}
    msg=$(echo "${log1#*|}" | head -c20)
    url=$(git remote get-url origin 2>/dev/null || echo "none")
    branches=$(git branch --list 2>/dev/null | wc -l | tr -d ' ')
    tags=$(git tag -l 2>/dev/null | wc -l | tr -d ' ')
    stash=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
    submods=$([ -f .gitmodules ] && echo yes || echo no)

    # ── Size: pack file size (instant, no directory walk) ──
    local size="?"
    if [ -d .git/objects/pack ]; then
        local pack_bytes=0
        for pf in .git/objects/pack/*.pack; do
            [ -f "$pf" ] || continue
            local ps; ps=$(stat -c %s "$pf" 2>/dev/null || stat -f %z "$pf" 2>/dev/null || echo 0)
            pack_bytes=$((pack_bytes + ps))
        done
        size="$((pack_bytes / 1048576))M"
    fi

    # ── Auth from URL (pure string, no subprocess) ──
    local auth
    case "$url" in
        git@*|ssh://*) auth="SSH" ;;
        https://*|http://*) auth="HTTP" ;;
        "") auth="—" ;;
        *) auth="?" ;;
    esac

    # ── Commit age (pure arithmetic) ──
    local diff=$((now - ts_c)) age
    if [ "$diff" -lt 3600 ]; then age="$((diff/60))m"
    elif [ "$diff" -lt 86400 ]; then age="$((diff/3600))h"
    else age="$((diff/86400))d"; fi

    # ── Fetch age (stat + arithmetic) ──
    local fetch_age="never"
    if [ -f .git/FETCH_HEAD ]; then
        local fts fdiff
        fts=$(stat -c %Y .git/FETCH_HEAD 2>/dev/null || stat -f %m .git/FETCH_HEAD 2>/dev/null || echo 0)
        fdiff=$((now - fts))
        if [ "$fdiff" -lt 60 ]; then fetch_age="${fdiff}s"
        elif [ "$fdiff" -lt 3600 ]; then fetch_age="$((fdiff/60))m"
        elif [ "$fdiff" -lt 86400 ]; then fetch_age="$((fdiff/3600))h"
        else fetch_age="$((fdiff/86400))d"; fi
    fi

    # ── Activity: ONE git log → bucket with awk (replaces 8 separate git log calls) ──
    local activity; activity=$(git log --format=%ct --since="8 weeks ago" 2>/dev/null | awk -v now="$now" '
        BEGIN { for(i=0;i<8;i++) b[i]=0 }
        { week=int((now-$1)/604800); if(week>=0 && week<8) b[week]++ }
        END { for(i=7;i>=0;i--) printf " %d", b[i] }
    ')

    # ── CI status via gh (parallel — no sequential penalty) ──
    local ci="-"
    if command -v gh >/dev/null 2>&1 && [ -n "$url" ] && [ "$url" != "none" ]; then
        local repo_slug conclusion
        repo_slug=$(echo "$url" | sed 's/.*github.com[:/]\([^/]*\/[^.]*\).*/\1/')
        conclusion=$(gh run list --repo "$repo_slug" --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || echo "")
        case "$conclusion" in
            success)   ci="$S_OK" ;;
            failure)   ci="$S_FAIL" ;;
            cancelled) ci="$S_STOP" ;;
            "")        ci="-" ;;
            *)         ci="?" ;;
        esac
    fi

    # ── One jq call: ALL escaping + JSON assembly ──
    printf '%s' "$msg" | jq -Rc \
        --arg name "$repo_name" --arg branch "$branch" \
        --argjson dirty "$dirty" --argjson stash "$stash" \
        --arg pull "$pull" --arg push "$push" --arg ci "$ci" \
        --arg age "$age" --arg size "$size" --arg auth "$auth" \
        --argjson branches "$branches" --arg url "$url" \
        --arg tracking "$tracking" --arg fetch_age "$fetch_age" \
        --argjson tags "$tags" --arg submods "$submods" \
        --arg activity "$activity" \
        '{name:$name,cloned:true,branch:$branch,dirty:$dirty,stash:$stash,
          pull:$pull,push:$push,ci:$ci,age:$age,size:$size,commit_msg:.,
          auth:$auth,branches:$branches,remote_url:$url,tracking:$tracking,
          last_fetch:$fetch_age,tags:$tags,submods:$submods,activity:$activity}'
}

collect_all() {
    # Temporarily disable set -e — probing functions legitimately return non-zero
    local _old_opts; _old_opts=$(set +o); set +e
    local ts; ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # Perf timer helper (ms precision)
    local _perf_t0; _perf_t0=$(date +%s%N 2>/dev/null || echo 0)
    _perf() {
        local now; now=$(date +%s%N 2>/dev/null || echo 0)
        local ms=$(( (now - _perf_t0) / 1000000 ))
        printf >&2 "  [perf] %-20s %5dms\n" "$1" "$ms"
        _perf_t0=$now
    }

    # ═══ PARALLEL SECTION — fire all heavy work as background jobs ═══
    local _par="$CC_CACHE_DIR/.par.$$"
    mkdir -p "$_par"

    # ── MESH VMs (parallel nc to wg_ip) ──
    (
        local _vm_tsv _nc_tmpdir vm_count=0 mesh_vms="[" _gauge_mesh_up=0
        _vm_tsv=$(jq -r '.mesh.vms[] | [.name, .alias, .wg_ip, .public_ip] | @tsv' <<< "$CONFIG_JSON" 2>/dev/null)
        _nc_tmpdir="$CC_CACHE_DIR/.nc.$$"
        mkdir -p "$_nc_tmpdir"
        while IFS=$'\t' read -r _n _a _w _p; do
            [ -z "$_w" ] && continue
            ( nc -z -w2 "$_w" 22 2>/dev/null && echo "online" || echo "offline" ) > "$_nc_tmpdir/$_a" &
        done <<< "$_vm_tsv"
        wait || true
        while IFS=$'\t' read -r name alias_name wg_ip pub_ip; do
            [ -z "$name" ] && continue
            local state="offline"
            [ -f "$_nc_tmpdir/$alias_name" ] && state=$(cat "$_nc_tmpdir/$alias_name")
            local mounted=0 sub_json="[" sfirst=true
            for sub in $(jq -r ".mesh.vms[$vm_count].vm_subdirs[]?.name" <<< "$CONFIG_JSON" 2>/dev/null); do
                local sm=false
                is_mounted "$MOUNT_DIR/$name/$sub" && { sm=true; mounted=$((mounted+1)); }
                [ "$sfirst" = "true" ] && sfirst=false || sub_json="$sub_json,"
                sub_json="$sub_json{\"name\":\"$sub\",\"mounted\":$sm}"
            done
            sub_json="$sub_json]"
            # Extract specs from mesh.json (static terraform data)
            local specs_json
            specs_json=$(jq -c ".mesh.vms[$vm_count].specs // null" <<< "$CONFIG_JSON" 2>/dev/null || echo "null")
            [ "$mounted" -gt 0 ] && _gauge_mesh_up=$((_gauge_mesh_up+1))
            [ "$vm_count" -gt 0 ] && mesh_vms="$mesh_vms,"
            mesh_vms="$mesh_vms{\"name\":\"$name\",\"alias\":\"$alias_name\",\"wg_ip\":\"$wg_ip\",\"public_ip\":\"$pub_ip\",\"state\":\"$state\",\"uptime_secs\":0,\"cpu_pct\":\"?\",\"ram_pct\":\"?\",\"specs\":$specs_json,\"mounts_up\":$mounted,\"subdirs\":$sub_json}"
            vm_count=$((vm_count+1))
        done <<< "$_vm_tsv"
        mesh_vms="$mesh_vms]"
        rm -rf "$_nc_tmpdir"
        printf '%s' "$mesh_vms" > "$_par/mesh_vms.json"
        printf '%s' "$vm_count" > "$_par/mesh_vm_count"
        printf '%s' "$_gauge_mesh_up" > "$_par/mesh_gauge_up"
    ) &

    # ── GIT REPOS ──
    local _git_tmpdir="$CC_CACHE_DIR/.git.$$"
    mkdir -p "$_git_tmpdir"
    (
        local repos; repos=$(jq -r '(.git.public_repos // {} | keys[]) , (.git.private_repos // {} | keys[])' <<< "$CONFIG_JSON" 2>/dev/null)
        local _git_pids="" _git_i=0
        while IFS= read -r repo_name; do
            [ -z "$repo_name" ] && continue
            local dir="$GIT_WORKDIR/$repo_name"
            if [ -d "$dir/.git" ]; then
                _git_collect_repo "$repo_name" "$dir" > "$_git_tmpdir/$(printf '%03d' $_git_i).json" 2>/dev/null &
                _git_pids="$_git_pids $!"
            else
                printf '{"name":"%s","cloned":false}' "$repo_name" > "$_git_tmpdir/$(printf '%03d' $_git_i).json"
            fi
            _git_i=$((_git_i+1))
        done <<< "$repos"
        for _pid in $_git_pids; do wait "$_pid" 2>/dev/null; done
        touch "$_git_tmpdir/.done"
    ) &

    # ── SYNC ──
    (
        local sync_remotes_json="[]"
        if command -v rclone >/dev/null 2>&1; then
            local remotes_raw; remotes_raw=$(rclone listremotes 2>/dev/null | sed 's/:$//')
            [ -n "$remotes_raw" ] && sync_remotes_json=$(echo "$remotes_raw" | jq -Rs 'split("\n") | map(select(length > 0))')
        fi
        local sync_rules_json; sync_rules_json=$(sync_list_rules 2>/dev/null || echo "[]")
        local sync_running_json; sync_running_json=$(sync_get_running_jobs 2>/dev/null || echo "[]")
        printf '%s' "$sync_remotes_json" > "$_par/sync_remotes.json"
        printf '%s' "$sync_rules_json" > "$_par/sync_rules.json"
        printf '%s' "$sync_running_json" > "$_par/sync_running.json"
    ) &

    # ── DATA SERVERS ──
    (
        local _srv_tsv; _srv_tsv=$(jq -r '.data_servers[]? | [.name, .type, (.port|tostring), .root, (.auth // "none"), (.tls // false | tostring), (.mode // "local")] | @tsv' <<< "$CONFIG_JSON" 2>/dev/null)
        local servers_json="[" si=0
        while IFS=$'\t' read -r sname stype sport sroot sauth stls smode; do
            [ -z "$sname" ] && continue
            sroot=$(_srv_expand_path "$sroot")
            local short_root="${sroot/#$HOME/\~}"
            [ ${#short_root} -gt 20 ] && short_root="...${short_root: -17}"
            local pid="" bind_addr="—" clients="—" uptime_str="—" running=false
            pid=$(_srv_detect_pid "$stype" "$sport")
            if [ -n "$pid" ]; then
                running=true; bind_addr=$(_srv_detect_bind "$sport")
                clients=$(_srv_client_count "$sport"); uptime_str=$(_srv_uptime "$pid")
            else
                [ "$smode" = "lan" ] && bind_addr="0.0.0.0:$sport" || bind_addr="127.0.0.1:$sport"
            fi
            local pid_val="null"; [ -n "$pid" ] && pid_val="$pid"
            [ "$si" -gt 0 ] && servers_json="$servers_json,"
            servers_json="$servers_json{\"name\":\"$sname\",\"type\":\"$stype\",\"port\":$sport,\"root\":\"$short_root\",\"auth\":\"$sauth\",\"tls\":$stls,\"mode\":\"$smode\",\"running\":$running,\"pid\":$pid_val,\"bind\":\"$bind_addr\",\"clients\":\"$clients\",\"uptime\":\"$uptime_str\"}"
            si=$((si+1))
        done <<< "$_srv_tsv"
        servers_json="$servers_json]"
        local unison_json; unison_json=$(jq '[.unison_profiles[]? | {name, profile, enabled: (.enabled // false)}]' <<< "$CONFIG_JSON" 2>/dev/null)
        printf '%s' "$servers_json" > "$_par/servers.json"
        printf '%s' "$unison_json" > "$_par/unison.json"
    ) &

    # ── WEBSERVERS ──
    (
        local webservers_json="[" wfirst=true seen_pids=""
        while IFS= read -r pidfile; do
            [ -z "$pidfile" ] && continue
            local wport wserver wpid=""
            wport=$(jq -r '.port // "?"' "$pidfile" 2>/dev/null)
            wserver=$(jq -r '.server // "?"' "$pidfile" 2>/dev/null)
            while IFS= read -r p; do
                [ -n "$p" ] && kill -0 "$p" 2>/dev/null && wpid="$p" && break
            done < <(jq -r '.pids | to_entries[] | .value | tostring' "$pidfile" 2>/dev/null)
            [ -z "$wpid" ] && continue
            seen_pids="$seen_pids $wpid"
            local wproj; wproj=$(dirname "$pidfile")
            wproj="${wproj#$GIT_WORKDIR/}"; wproj="${wproj#$HOME/}"
            local wfw="$wserver"
            case "$wserver" in vite) wfw="Vite";; sveltekit) wfw="SvelteKit";; next) wfw="Next.js";; esac
            local wup; wup=$(ps -o etimes= -p "$wpid" 2>/dev/null | tr -d ' ' || echo 0)
            local wrt="Node"; echo "$wserver" | grep -qi "python\|flask\|uvicorn" && wrt="Python"
            local wname; wname=$(basename "$(dirname "$pidfile")")
            [ "$wfirst" = "true" ] && wfirst=false || webservers_json="$webservers_json,"
            webservers_json="$webservers_json{\"name\":\"$wname\",\"port\":\"$wport\",\"runtime\":\"$wrt\",\"framework\":\"$wfw\",\"project\":\"${wproj:0:26}\",\"pid\":\"$wpid\",\"uptime_secs\":$wup}"
        done < <(find "$GIT_WORKDIR" -maxdepth 4 -name ".build.pid" 2>/dev/null | sort)
        # pgrep scan
        _ws_detect2() {
            local wpid="$1" wrt="$2"
            echo "$seen_pids" | grep -qw "$wpid" && return
            local wport wcmd wcwd wproj wfw
            wport=$(_get_pid_port "$wpid")
            wcmd=$(ps -o args= -p "$wpid" 2>/dev/null | head -c60 || echo "")
            wcwd=$(readlink -f "/proc/$wpid/cwd" 2>/dev/null || echo "")
            wproj="${wcwd#$GIT_WORKDIR/}"; wproj="${wproj#$HOME/}"; wproj="${wproj:0:26}"
            wfw="$wrt"
            echo "$wcmd" | grep -qi "vite" && wfw="Vite"
            echo "$wcmd" | grep -qi "svelte" && wfw="SvelteKit"
            echo "$wcmd" | grep -qi "next" && wfw="Next.js"
            echo "$wcmd" | grep -qi "flask" && wfw="Flask"
            echo "$wcmd" | grep -qi "uvicorn\|fastapi" && wfw="FastAPI"
            local wup; wup=$(ps -o etimes= -p "$wpid" 2>/dev/null | tr -d ' ' || echo 0)
            [ "$wfirst" = "true" ] && wfirst=false || webservers_json="$webservers_json,"
            webservers_json="$webservers_json{\"name\":\"$wrt\",\"port\":\"$wport\",\"runtime\":\"$wrt\",\"framework\":\"$wfw\",\"project\":\"$wproj\",\"pid\":\"$wpid\",\"uptime_secs\":$wup}"
        }
        while IFS= read -r wpid; do [ -n "$wpid" ] && _ws_detect2 "$wpid" "Node"; done \
            < <(pgrep -f "node.*dev\|node.*serve\|vite\|next.*dev\|live-server" 2>/dev/null || true)
        while IFS= read -r wpid; do [ -n "$wpid" ] && _ws_detect2 "$wpid" "Python"; done \
            < <(pgrep -f "python.*-m http\|uvicorn\|flask run\|gunicorn" 2>/dev/null || true)
        webservers_json="$webservers_json]"
        printf '%s' "$webservers_json" > "$_par/webservers.dat"
    ) &

    # ── HOME-MANAGER ──
    (
        local _hm_tsv; _hm_tsv=$(jq -r '.home_manager_flakes[]? | [.name, .type, .path, (.enabled|tostring)] | @tsv' <<< "$CONFIG_JSON" 2>/dev/null)
        local hm_json="[" hi=0
        while IFS=$'\t' read -r hname htype hpath henabled; do
            [ -z "$hname" ] && continue
            hpath="${hpath/#\~/$HOME}"
            local hdirty=0 hgit_label="?" hgen="—"
            if [ "$henabled" != "false" ] && [ -d "$hpath" ]; then
                if [ "$htype" = "home-manager" ]; then
                    local prof_dir="/nix/var/nix/profiles/per-user/${USER:-$(id -un)}"
                    local gen=""
                    gen=$(ls "$prof_dir" 2>/dev/null | grep -oP '^home-manager-\K\d+(?=-link)' | sort -n | tail -1)
                    [ -z "$gen" ] && gen=$(ls "$prof_dir" 2>/dev/null | grep -oP '^profile-\K\d+(?=-link)' | sort -n | tail -1)
                    [ -n "$gen" ] && hgen="gen $gen"
                elif [ "$htype" = "nixos" ]; then
                    local gen=""
                    gen=$(ls /nix/var/nix/profiles/ 2>/dev/null | grep -oP '^system-\K\d+(?=-link)' | sort -n | tail -1)
                    [ -n "$gen" ] && hgen="gen $gen"
                fi
                if [ -f "$hpath/.git/HEAD" ]; then
                    local local_ref remote_ref
                    local_ref=$(git -C "$hpath" rev-parse HEAD 2>/dev/null)
                    remote_ref=$(git -C "$hpath" rev-parse @{u} 2>/dev/null)
                    if [ -n "$local_ref" ] && [ -n "$remote_ref" ]; then
                        [ "$local_ref" = "$remote_ref" ] && hgit_label="synced" || hgit_label="diverged"
                    fi
                fi
            fi
            [ "$hi" -gt 0 ] && hm_json="$hm_json,"
            hm_json="$hm_json{\"name\":\"$hname\",\"type\":\"$htype\",\"path\":\"${hpath/$HOME/\~}\",\"enabled\":$henabled,\"dirty\":$hdirty,\"git_label\":\"$hgit_label\",\"generation\":\"$hgen\"}"
            hi=$((hi+1))
        done <<< "$_hm_tsv"
        hm_json="$hm_json]"
        printf '%s' "$hm_json" > "$_par/hm.dat"
    ) &

    # ── Foreground: LOCAL PC + PHONE + DRIVES + SERVICES (fast, no I/O) ──
    local lh_hostname lh_os lh_kernel lh_up_secs lh_cpu lh_ram_used lh_ram_total lh_disk_used lh_disk_total
    lh_hostname="${HM_PROFILE:-$(hostname 2>/dev/null || echo 'unknown')}"
    lh_os=$(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null | head -c16 || echo "Linux")
    lh_kernel=$(uname -r | head -c17)
    lh_up_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    lh_cpu=$(top -bn1 2>/dev/null | grep 'Cpu' | awk '{printf "%d%%", 100-$8}' || echo "?")
    lh_ram_used=$(free -g 2>/dev/null | awk '/Mem:/{print $3}' || echo 0)
    lh_ram_total=$(free -g 2>/dev/null | awk '/Mem:/{print $2}' || echo 1)
    lh_disk_used=$(df -BG /home 2>/dev/null | awk 'NR==2{gsub("G","",$3); print $3}' || echo 0)
    lh_disk_total=$(df -BG /home 2>/dev/null | awk 'NR==2{gsub("G","",$2); print $2}' || echo 1)
    local local_json="{\"hostname\":\"$lh_hostname\",\"os\":\"$lh_os\",\"kernel\":\"$lh_kernel\",\"uptime_secs\":$lh_up_secs,\"cpu\":\"$lh_cpu\",\"ram_used_g\":$lh_ram_used,\"ram_total_g\":$lh_ram_total,\"disk_used\":$lh_disk_used,\"disk_total\":$lh_disk_total}"

    local phone_name phone_model phone_storage_gb phone_stat phone_bat
    local _phone_tsv
    _phone_tsv=$(_jq -r '[(.mesh.phone.name // "none"), (.mesh.phone.model // "Unknown"), (.mesh.phone.storage_gb // "?")] | @tsv')
    phone_name=$(echo "$_phone_tsv" | cut -f1)
    phone_model=$(echo "$_phone_tsv" | cut -f2)
    phone_storage_gb=$(echo "$_phone_tsv" | cut -f3)
    phone_stat="none"; phone_bat="?"
    if [ "$phone_name" != "none" ] && [ "$phone_name" != "null" ]; then
        phone_stat=$(phone_status)
        phone_bat=$(phone_battery)
    fi
    local phone_json
    phone_json=$(jq -nc --arg n "$phone_name" --arg m "$phone_model" --arg s "$phone_storage_gb" --arg st "$phone_stat" --arg b "$phone_bat" \
        '{name:$n, model:$m, storage_gb:$s, status:$st, battery:$b}')

    # Drives (foreground — checks local mounts)
    local _drv_tsv
    _drv_tsv=$(_jq -r '.fuse_drives[]? | [.name, (.account // ""), .remote] | @tsv')
    local drive_count=0 drives_json="[" _gd_up=0
    while IFS=$'\t' read -r dname dacct dremote; do
        [ -z "$dname" ] && continue
        local dmounted=false dused=0 dtotal=0
        local mount_path="$MOUNT_DIR/$dname"
        if is_mounted "$mount_path"; then
            dmounted=true; _gd_up=$((_gd_up+1))
            local usage; usage=$(rclone about "${dremote}:" --json 2>/dev/null || echo "{}")
            local used_b total_b
            used_b=$(echo "$usage" | jq -r '.used // 0' 2>/dev/null || echo 0)
            total_b=$(echo "$usage" | jq -r '.total // 0' 2>/dev/null || echo 0)
            dused=$((used_b / 1073741824)); dtotal=$((total_b / 1073741824))
            [ "$dtotal" -eq 0 ] && dtotal=15
        fi
        [ "$drive_count" -gt 0 ] && drives_json="$drives_json,"
        drives_json="$drives_json{\"name\":\"$dname\",\"account\":\"$dacct\",\"remote\":\"$dremote\",\"mounted\":$dmounted,\"used_g\":$dused,\"total_g\":$dtotal,\"mount_path\":\"$mount_path\"}"
        drive_count=$((drive_count+1))
    done <<< "$_drv_tsv"
    drives_json="$drives_json]"
    local symlinks_json="["
    if [ -d "$MOUNT_DIR" ]; then
        local slfirst=true
        while IFS= read -r link; do
            [ -z "$link" ] && continue
            local lname; lname=$(basename "$link")
            local ltarget; ltarget=$(readlink -f "$link" 2>/dev/null || echo "?")
            [ "$slfirst" = "true" ] && slfirst=false || symlinks_json="$symlinks_json,"
            symlinks_json="$symlinks_json{\"name\":\"$lname\",\"target\":\"$ltarget\"}"
        done < <(find "$MOUNT_DIR" -maxdepth 1 -type l 2>/dev/null)
    fi
    symlinks_json="$symlinks_json]"

    # Services (pure jq, fast)
    local services_json
    services_json=$(_jq '[
        .mesh.vms[] as $vm |
        $vm.services[] as $svc |
        {
            name: $svc,
            vm: $vm.alias,
            domain: ((.service_details[$svc].domain) // "—"),
            port: ((.service_details[$svc].port) // "—"),
            availability: ((.service_details[$svc].availability) // "24/7")
        }
    ]')
    _perf "FOREGROUND_done"

    # ═══ WAIT FOR ALL PARALLEL JOBS ═══
    wait || true
    _perf "ALL_parallel_done"

    # ── Read parallel results ──
    local mesh_vms vm_count _gauge_mesh_up
    mesh_vms=$(cat "$_par/mesh_vms.json" 2>/dev/null || echo "[]")
    vm_count=$(cat "$_par/mesh_vm_count" 2>/dev/null || echo 0)
    _gauge_mesh_up=$(cat "$_par/mesh_gauge_up" 2>/dev/null || echo 0)

    local sync_remotes_json sync_rules_json sync_running_json
    sync_remotes_json=$(cat "$_par/sync_remotes.json" 2>/dev/null || echo "[]")
    sync_rules_json=$(cat "$_par/sync_rules.json" 2>/dev/null || echo "[]")
    sync_running_json=$(cat "$_par/sync_running.json" 2>/dev/null || echo "[]")

    local servers_json unison_json
    servers_json=$(cat "$_par/servers.json" 2>/dev/null || echo "[]")
    unison_json=$(cat "$_par/unison.json" 2>/dev/null || echo "[]")

    local webservers_json
    webservers_json=$(cat "$_par/webservers.dat" 2>/dev/null || echo "[]")

    local hm_json
    hm_json=$(cat "$_par/hm.dat" 2>/dev/null || echo "[]")

    # Git assembly
    local git_json="[" gfirst=true
    for _gf in "$_git_tmpdir"/*.json; do
        [ -f "$_gf" ] || continue
        local _frag; _frag=$(cat "$_gf")
        [ -z "$_frag" ] && continue
        [ "$gfirst" = "true" ] && gfirst=false || git_json="$git_json,"
        git_json="$git_json$_frag"
    done
    git_json="$git_json]"
    rm -rf "$_git_tmpdir" "$_par"

    local _jqtmp="$CC_CACHE_DIR/.jqtmp.$$"
    cat > "$_jqtmp" << 'JQEOF'
def safesum: if length==0 then 0 else add end;
{
    total: length,
    cloned: [.[] | select(.cloned==true)] | length,
    clean: [.[] | select(.cloned==true and .dirty==0)] | length,
    dirty: [.[] | select(.cloned==true and .dirty>0)] | length,
    pull: [.[] | select(.cloned==true and (.pull|tostring) != "?" and (.pull|tonumber)>0) | .pull|tonumber] | safesum,
    push: [.[] | select(.cloned==true and (.push|tostring) != "?" and (.push|tonumber)>0) | .push|tonumber] | safesum,
    ssh: [.[] | select(.auth=="SSH")] | length,
    http: [.[] | select(.auth=="HTTP")] | length
}
JQEOF
    local git_totals; git_totals=$(printf '%s' "$git_json" | jq -cf "$_jqtmp")
    rm -f "$_jqtmp"
    local _gt_clean; _gt_clean=$(echo "$git_totals" | jq -r '.clean')
    local _gt_cloned; _gt_cloned=$(echo "$git_totals" | jq -r '.cloned')
    local _gt_dirty; _gt_dirty=$(echo "$git_totals" | jq -r '.dirty')
    local not_cloned_str; not_cloned_str=$(printf '%s' "$git_json" | jq -r '[.[] | select(.cloned==false) | .name] | join(" ")')
    local not_cloned_esc; not_cloned_esc=$(_json_str "$not_cloned_str")
    _perf "ASSEMBLE_results"

    # ═══ GAUGES ═══
    local _gd_vm_up=$_gauge_mesh_up
    local _gd_total=$((_gd_up + _gd_vm_up))
    local _gd_max=$((drive_count + vm_count))
    # Sync gauge: enabled rules that ran < 24h
    local _gs_enabled; _gs_enabled=$(echo "$sync_rules_json" | jq '[.[] | select(.enabled == true)] | length')
    local _gs_recent=0
    if [ "$_gs_enabled" -gt 0 ]; then
        local now_epoch; now_epoch=$(date +%s)
        while IFS= read -r lr; do
            [ "$lr" = "null" ] || [ "$lr" = "never" ] || [ -z "$lr" ] && continue
            local lr_epoch; lr_epoch=$(date -d "$lr" +%s 2>/dev/null || echo 0)
            [ $(( now_epoch - lr_epoch )) -lt 86400 ] && _gs_recent=$((_gs_recent+1))
        done < <(echo "$sync_rules_json" | jq -r '.[] | select(.enabled == true) | .last_run // "never"')
    fi
    local _hm_max; _hm_max=$(echo "$hm_json" | jq 'length' 2>/dev/null || echo 0)
    local _hm_cur; _hm_cur=$(echo "$hm_json" | jq '[.[] | select(.enabled == true)] | length' 2>/dev/null || echo 0)
    local gauges_json="{\"hm_cur\":$_hm_cur,\"hm_max\":$_hm_max,\"mesh_cur\":$_gauge_mesh_up,\"mesh_max\":$vm_count,\"git_cur\":$_gt_clean,\"git_max\":$_gt_cloned,\"drive_cur\":$_gd_total,\"drive_max\":$_gd_max,\"sync_cur\":$_gs_recent,\"sync_max\":$_gs_enabled}"

    # ═══ ALERTS ═══
    local _al_vm_down=$((vm_count - _gauge_mesh_up))
    local _al_drive_down=$((drive_count - _gd_up))
    local _al_sync_run; _al_sync_run=$(echo "$sync_running_json" | jq 'length')
    local alerts_json="{\"vm_down\":$_al_vm_down,\"dirty_repos\":$_gt_dirty,\"drives_down\":$_al_drive_down,\"sync_running\":$_al_sync_run}"

    # ═══ LOG ═══
    local log_json="{}"
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        local log_size log_lines log_errs log_warns last_lines
        log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        log_errs=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo 0)
        log_warns=$(grep -c "WARN" "$LOG_FILE" 2>/dev/null || echo 0)
        last_lines=$(tail -20 "$LOG_FILE" 2>/dev/null | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
        log_json="{\"size\":\"$log_size\",\"lines\":$log_lines,\"errors\":$log_errs,\"warnings\":$log_warns,\"tail\":$last_lines}"
    fi
    _perf "GAUGES+ALERTS+LOG"

    # ═══ ASSEMBLE CC_DATA ═══
    CC_DATA=$(cat <<EOJSON
{
  "timestamp": "$ts",
  "env_profile": "$CC_ENV_PROFILE",
  "mesh": {"vms": $mesh_vms, "local": $local_json, "phone": $phone_json, "storage": $(jq -c '.mesh.storage // []' <<< "$CONFIG_JSON"), "vpss": $(jq -c '.mesh.vpss // {}' <<< "$CONFIG_JSON"), "firewalls": $(jq -c '.mesh.firewalls // []' <<< "$CONFIG_JSON")},
  "security": {"os_firewalls": $(_jqf '.os_firewalls // []' "$CC_CACHE_DIR/cloud-topology.json" '[]'), "os_firewall_global": $(_jqf '.os_firewall_global // {}' "$CC_CACHE_DIR/cloud-topology.json" '{}'), "wireguard": $(_jqf '.wireguard // {}' "$CC_CACHE_DIR/cloud-topology.json" '{}'), "caddy_routes": $(_jqf '.infra.caddy.routes // []' "$CC_CACHE_DIR/cloud-configs.json" '[]')},
  "git": {"repos": $git_json, "totals": $git_totals, "not_cloned": $not_cloned_esc},
  "drives": {"cloud": $drives_json, "symlinks": $symlinks_json},
  "sync": {"remotes": $sync_remotes_json, "rules": $sync_rules_json, "running_jobs": $sync_running_json},
  "servers": {"data_servers": $servers_json, "unison": $unison_json},
  "services": $services_json,
  "webservers": $webservers_json,
  "home_manager": $hm_json,
  "gauges": $gauges_json,
  "alerts": $alerts_json,
  "log": $log_json
}
EOJSON
)
    _perf "ASSEMBLE"
    # Restore original shell options (re-enable set -e if it was on)
    eval "$_old_opts"
}

# =============================================================================
# A) MESH - Rendering
# =============================================================================

render_mesh() {
    [ -z "$CC_DATA" ] && collect_all
    local vm_count; vm_count=$(_d '.mesh.vms | length')

    # VPS Providers
    local vps_keys; vps_keys=$(_d -r '.mesh.vpss | keys[]' 2>/dev/null)
    if [ -n "$vps_keys" ]; then
        printf "  ${BLD}%-12s %-20s %-14s %-12s${RST}\n" \
            "VPS" "Provider" "Tier" "Terraform"
        printf "  ${C_DIM}"
        local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
        printf "${RST}\n"
        for vk in $vps_keys; do
            local prov tier has_tf
            prov=$(_d -r ".mesh.vpss[\"$vk\"].provider // \"$vk\"")
            tier=$(_d -r ".mesh.vpss[\"$vk\"].tier // \"—\"")
            has_tf=$(_d -r ".mesh.vpss[\"$vk\"].has_terraform // false")
            local tf_str
            if [ "$has_tf" = "true" ]; then tf_str="${C_OK}✓${RST}"; else tf_str="${C_DIM}—${RST}"; fi
            printf "  %-12s %-20s %-14s %b\n" "$vk" "$prov" "$tier" "$tf_str"
        done
        printf "\n"
    fi

    # VM Table header
    local i=0
    printf "  ${BLD}%-17s %-7s %-12s %-18s %5s %11s %11s %11s %10s${RST}\n" \
        "VM" "State" "WG IP" "Public IP" "Up" "CPU" "RAM" "Disk" "GPU"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    # VM rows — pure formatting, all data from CC_DATA
    i=0
    while [ "$i" -lt "$vm_count" ]; do
        local name wg_ip pub_ip vm_state up_secs cpu_pct ram_pct
        name=$(_d -r ".mesh.vms[$i].name")
        wg_ip=$(_d -r ".mesh.vms[$i].wg_ip")
        pub_ip=$(_d -r ".mesh.vms[$i].public_ip")
        vm_state=$(_d -r ".mesh.vms[$i].state")
        up_secs=$(_d -r ".mesh.vms[$i].uptime_secs")
        cpu_pct=$(_d -r ".mesh.vms[$i].cpu_pct")
        ram_pct=$(_d -r ".mesh.vms[$i].ram_pct")

        # Specs from terraform (static)
        local spec_cpu spec_ram spec_disk spec_gpu spec_gpu_vram
        spec_cpu=$(_d -r ".mesh.vms[$i].specs.cpu // 0")
        spec_ram=$(_d -r ".mesh.vms[$i].specs.ram_gb // 0")
        spec_disk=$(_d -r ".mesh.vms[$i].specs.disk_gb // 0")
        spec_gpu=$(_d -r ".mesh.vms[$i].specs.gpu // null")
        spec_gpu_vram=$(_d -r ".mesh.vms[$i].specs.gpu_vram // null")

        local state state_sym state_color up_str cpu_str ram_str disk_str
        if [ "$vm_state" = "online" ]; then
            state="RUN"; state_sym="$S_RUN"; state_color="$C_OK"
            if [ "$up_secs" -gt 86400 ] 2>/dev/null; then
                up_str="$((up_secs / 86400))d"
            elif [ "$up_secs" -gt 3600 ] 2>/dev/null; then
                up_str="$((up_secs / 3600))h"
            elif [ "$up_secs" -gt 0 ] 2>/dev/null; then
                up_str="$((up_secs / 60))m"
            else
                up_str="?"
            fi
            cpu_str="${cpu_pct}%/${spec_cpu}c"; ram_str="${ram_pct}%/${spec_ram}G"
        else
            state="STOP"; state_sym="$S_STOP"; state_color="$C_DIM"
            up_str="—"; cpu_str="—/${spec_cpu}c"; ram_str="—/${spec_ram}G"
        fi

        if [ "$spec_disk" -gt 0 ] 2>/dev/null; then
            disk_str="${spec_disk}G"
        else
            disk_str="—"
        fi

        local gpu_str="—"
        if [ "$spec_gpu" != "null" ] && [ -n "$spec_gpu" ]; then
            # Short label: "T4/16G", "A100/40G", etc.
            local gpu_short; gpu_short=$(echo "$spec_gpu" | sed 's/NVIDIA //')
            if [ "$spec_gpu_vram" != "null" ] && [ -n "$spec_gpu_vram" ]; then
                gpu_str="${gpu_short}/${spec_gpu_vram}"
            else
                gpu_str="$gpu_short"
            fi
        fi

        printf "  %-17s %b%s %-4s%b %-12s %-18s %5s %11s %11s %11s %10s\n" \
            "$name" "$state_color" "$state_sym" "$state" "$RST" \
            "$wg_ip" "$pub_ip" "$up_str" "$cpu_str" "$ram_str" "$disk_str" "$gpu_str"
        i=$((i+1))
    done

    # Object Storage
    local storage_count; storage_count=$(_d '.mesh.storage | length' 2>/dev/null || echo 0)
    if [ "$storage_count" -gt 0 ] 2>/dev/null; then
        printf "\n  ${BLD}%-12s %-30s %-12s${RST}\n" \
            "Storage" "Bucket" "Tier"
        printf "  ${C_DIM}"
        w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
        printf "${RST}\n"
        local si=0
        while [ "$si" -lt "$storage_count" ]; do
            local s_prov s_name s_tier
            s_prov=$(_d -r ".mesh.storage[$si].provider")
            s_name=$(_d -r ".mesh.storage[$si].name")
            s_tier=$(_d -r ".mesh.storage[$si].tier")
            printf "  %-12s %-30s %-12s\n" "$s_prov" "$s_name" "$s_tier"
            si=$((si+1))
        done
    fi

    # LOCAL PC
    printf "\n  ${BLD}%-17s %-16s %-17s %5s %4s %-12s  Disk${RST}\n" \
        "LOCAL" "OS" "Kernel" "Up" "CPU" "RAM"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local hostname_str os_str kernel_str up_local cpu_local ram_used_g ram_total_g disk_used disk_total
    hostname_str=$(_d -r '.mesh.local.hostname')
    os_str=$(_d -r '.mesh.local.os')
    kernel_str=$(_d -r '.mesh.local.kernel')
    local up_secs_local; up_secs_local=$(_d -r '.mesh.local.uptime_secs')
    if [ "$up_secs_local" -gt 86400 ] 2>/dev/null; then
        up_local="$((up_secs_local / 86400))d"
    elif [ "$up_secs_local" -gt 3600 ] 2>/dev/null; then
        up_local="$((up_secs_local / 3600))h"
    else
        up_local="$((up_secs_local / 60))m"
    fi
    cpu_local=$(_d -r '.mesh.local.cpu')
    ram_used_g=$(_d -r '.mesh.local.ram_used_g')
    ram_total_g=$(_d -r '.mesh.local.ram_total_g')
    disk_used=$(_d -r '.mesh.local.disk_used')
    disk_total=$(_d -r '.mesh.local.disk_total')

    printf "  %-17s %-16s %-17s %5s %4s %dG/%dG  " \
        "$hostname_str" "$os_str" "$kernel_str" "$up_local" "$cpu_local" \
        "$ram_used_g" "$ram_total_g"
    gauge_bar "$disk_used" "$disk_total" 18 "${disk_used}G/${disk_total}G"
    printf "\n"

    # PHONE
    local phone_name phone_stat phone_bat
    phone_name=$(_d -r '.mesh.phone.name')
    if [ "$phone_name" != "none" ] && [ "$phone_name" != "null" ]; then
        printf "\n  ${BLD}%-17s %-16s %-10s %-14s Connection${RST}\n" \
            "PHONE" "Device" "Battery" "Storage"
        printf "  ${C_DIM}"
        w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
        printf "${RST}\n"

        phone_stat=$(_d -r '.mesh.phone.status')
        phone_bat=$(_d -r '.mesh.phone.battery')
        local bat_str="?"
        if [ "$phone_bat" != "?" ] && [ "$phone_bat" -gt 0 ] 2>/dev/null; then
            bat_str=$(gauge_bar "$phone_bat" 100 8 "${phone_bat}%")
        fi

        local conn_str
        case "$phone_stat" in
            mounted)    conn_str="${C_OK}${S_RUN} KDE Connect${RST}" ;;
            reachable)  conn_str="${C_WARN}${S_STOP} reachable${RST}" ;;
            offline)    conn_str="${C_DIM}${S_STOP} offline${RST}" ;;
            *)          conn_str="${C_DIM}${S_STOP} $phone_stat${RST}" ;;
        esac

        local phone_model phone_storage_gb
        phone_model=$(_d -r '.mesh.phone.model')
        phone_storage_gb=$(_d -r '.mesh.phone.storage_gb')
        printf "  %-17s %-16s %-10b %-14s %b\n" \
            "$phone_name" "$phone_model" "$bat_str" "?/${phone_storage_gb} GB" "$conn_str"
    fi
}

# =============================================================================
# B) GIT - Data Collection & Rendering
# =============================================================================

git_check_cloned()     { [ -d "$1/.git" ]; }
git_dirty_count()      { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }
git_stash_count()      { git -C "$1" stash list 2>/dev/null | wc -l | tr -d ' '; }
git_unpulled()         { git -C "$1" rev-parse @{u} >/dev/null 2>&1 && git -C "$1" log ..@{u} --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "?"; }
git_unpushed()         { git -C "$1" rev-parse @{u} >/dev/null 2>&1 && git -C "$1" log @{u}.. --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "?"; }
git_branch()           { git -C "$1" branch --show-current 2>/dev/null || echo "?"; }
git_branch_count()     { git -C "$1" branch --list 2>/dev/null | wc -l | tr -d ' '; }
git_tag_count()        { git -C "$1" tag -l 2>/dev/null | wc -l | tr -d ' '; }
git_remote_url()       { git -C "$1" remote get-url origin 2>/dev/null || echo "none"; }
git_auth_type()        {
    local url; url=$(git -C "$1" remote get-url origin 2>/dev/null || echo "")
    case "$url" in
        git@*|ssh://*)   echo "SSH" ;;
        https://*|http://*) echo "HTTP" ;;
        "")              echo "—" ;;
        *)               echo "?" ;;
    esac
}
git_remote_name()      { git -C "$1" remote 2>/dev/null | head -1 || echo "none"; }
git_tracking_branch()  { git -C "$1" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "none"; }
git_has_submodules()   { [ -f "$1/.gitmodules" ] && echo "yes" || echo "no"; }
git_hook_count()       { ls "$1/.git/hooks/"* 2>/dev/null | grep -cv '\.sample$' || echo 0; }
git_last_fetch_age()   {
    local fetch_head="$1/.git/FETCH_HEAD"
    [ ! -f "$fetch_head" ] && echo "never" && return
    local ts; ts=$(stat -c %Y "$fetch_head" 2>/dev/null || stat -f %m "$fetch_head" 2>/dev/null || echo 0)
    local now; now=$(date +%s)
    local diff=$(( now - ts ))
    if [ "$diff" -lt 60 ]; then echo "${diff}s"
    elif [ "$diff" -lt 3600 ]; then echo "$(( diff / 60 ))m"
    elif [ "$diff" -lt 86400 ]; then echo "$(( diff / 3600 ))h"
    else echo "$(( diff / 86400 ))d"
    fi
}
git_last_commit_msg()  { git -C "$1" log -1 --pretty=format:'%s' 2>/dev/null | head -c20; }

git_last_commit_age() {
    local ts
    ts=$(git -C "$1" log -1 --pretty=format:'%ct' 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local diff=$(( now - ts ))
    if [ "$diff" -lt 3600 ]; then
        echo "$(( diff / 60 ))m"
    elif [ "$diff" -lt 86400 ]; then
        echo "$(( diff / 3600 ))h"
    else
        echo "$(( diff / 86400 ))d"
    fi
}

git_ci_status() {
    local dir=$1
    [ ! -d "$dir/.git" ] && echo "-" && return
    command -v gh >/dev/null 2>&1 || { echo "?"; return; }
    local url
    url=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
    [ -z "$url" ] && echo "?" && return
    local repo
    repo=$(echo "$url" | sed 's/.*github.com[:/]\([^/]*\/[^.]*\).*/\1/')
    local conclusion
    conclusion=$(gh run list --repo "$repo" --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || echo "")
    case "$conclusion" in
        success)   echo "$S_OK" ;;
        failure)   echo "$S_FAIL" ;;
        cancelled) echo "$S_STOP" ;;
        "")        echo "-" ;;
        *)         echo "?" ;;
    esac
}

git_repo_size() {
    local dir=$1
    du -sm "$dir/.git" 2>/dev/null | awk '{printf "%dM", $1}' || echo "?"
}

git_activity_sparkline() {
    local dir=$1
    # Commits per week for last 8 weeks
    local vals=""
    local w=7
    while [ "$w" -ge 0 ]; do
        local since="$((w+1)) weeks ago"
        local until="$w weeks ago"
        local cnt
        cnt=$(git -C "$dir" log --oneline --since="$since" --until="$until" 2>/dev/null | wc -l | tr -d ' ')
        vals="$vals $cnt"
        w=$((w-1))
    done
    sparkline "$vals"
}

render_git() {
    [ -z "$CC_DATA" ] && collect_all
    # Row 1: main info — Row 2: remote URL + extra details (indented)
    # Cols: Repo=20 Branch=10 Auth=5 Local=13 Remote=13 CI=3 Stsh=3 Br=3 Age=4 Size=5 Spark=9 Commit=rest
    printf "  ${BLD}%-20s %-10s %-5s %-13s %-13s %-3s %-3s %-3s %-4s %-5s %-9s %s${RST}\n" \
        "Repo" "Branch" "Auth" "Local" "Remote" "CI" "Sth" "Br" "Age" "Size" "Activity" "Last Commit"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local repo_count; repo_count=$(_d '.git.repos | length')
    local idx=0
    while [ "$idx" -lt "$repo_count" ]; do
        local repo_name cloned
        repo_name=$(_d -r ".git.repos[$idx].name")
        cloned=$(_d -r ".git.repos[$idx].cloned")

        if [ "$cloned" != "true" ]; then
            idx=$((idx+1)); continue
        fi

        local branch dirty stash pull push ci age size commit_msg
        local auth branches remote_url tracking last_fetch tags submods activity
        branch=$(_d -r ".git.repos[$idx].branch")
        dirty=$(_d -r ".git.repos[$idx].dirty")
        stash=$(_d -r ".git.repos[$idx].stash")
        pull=$(_d -r ".git.repos[$idx].pull")
        push=$(_d -r ".git.repos[$idx].push")
        ci=$(_d -r ".git.repos[$idx].ci")
        age=$(_d -r ".git.repos[$idx].age")
        size=$(_d -r ".git.repos[$idx].size")
        commit_msg=$(_d -r ".git.repos[$idx].commit_msg")
        auth=$(_d -r ".git.repos[$idx].auth")
        branches=$(_d -r ".git.repos[$idx].branches")
        remote_url=$(_d -r ".git.repos[$idx].remote_url")
        tracking=$(_d -r ".git.repos[$idx].tracking")
        last_fetch=$(_d -r ".git.repos[$idx].last_fetch")
        tags=$(_d -r ".git.repos[$idx].tags")
        submods=$(_d -r ".git.repos[$idx].submods")
        activity=$(_d -r ".git.repos[$idx].activity")

        # AUTH — pad then color
        local auth_color
        case "$auth" in
            SSH)  auth_color="$C_OK" ;;
            HTTP) auth_color="$C_WARN" ;;
            *)    auth_color="$C_DIM" ;;
        esac
        local auth_padded; auth_padded=$(printf "%-5s" "$auth")
        local auth_f="${auth_color}${auth_padded}${RST}"

        # LOCAL STATUS — pad then color
        local local_plain local_color
        if [ "$dirty" -gt 0 ] 2>/dev/null; then
            local_plain="Dirty [$dirty]"; local_color="$C_WARN"
        elif [ "$push" = "?" ]; then
            local_plain="No Remote"; local_color="$C_ERR"
        elif [ "$push" -gt 0 ] 2>/dev/null; then
            local_plain="$push Unpushed"; local_color="$C_WARN"
        else
            local_plain="OK"; local_color="$C_OK"
        fi
        local local_padded; local_padded=$(printf "%-13s" "$local_plain")
        local local_f="${local_color}${local_padded}${RST}"

        # REMOTE STATUS — pad then color
        local remote_plain remote_color
        if [ "$pull" = "?" ]; then
            remote_plain="Not Checked"; remote_color="$C_DIM"
        elif [ "$pull" -gt 0 ] 2>/dev/null; then
            remote_plain="$pull To Pull"; remote_color="$C_INFO"
        else
            remote_plain="Up to Date"; remote_color="$C_OK"
        fi
        local remote_padded; remote_padded=$(printf "%-13s" "$remote_plain")
        local remote_f="${remote_color}${remote_padded}${RST}"

        # Stash — pad then color
        local stash_plain stash_color
        if [ "$stash" -gt 0 ] 2>/dev/null; then
            stash_plain="$stash"; stash_color="$C_WARN"
        else
            stash_plain="·"; stash_color="$C_DIM"
        fi
        local stash_padded; stash_padded=$(printf "%-3s" "$stash_plain")
        local stash_f="${stash_color}${stash_padded}${RST}"

        # Branches — pad then color
        local br_padded; br_padded=$(printf "%-3s" "$branches")
        local br_f
        [ "$branches" -gt 1 ] 2>/dev/null && br_f="${C_INFO}${br_padded}${RST}" || br_f="${C_DIM}${br_padded}${RST}"

        # CI — pad then color
        local ci_plain ci_color
        case "$ci" in
            "$S_OK")   ci_plain="${S_OK}"; ci_color="$C_OK" ;;
            "$S_FAIL") ci_plain="${S_FAIL}"; ci_color="$C_ERR" ;;
            "-")       ci_plain="—"; ci_color="$C_DIM" ;;
            *)         ci_plain="?"; ci_color="$C_DIM" ;;
        esac
        local ci_padded; ci_padded=$(printf "%-3s" "$ci_plain")
        local ci_f="${ci_color}${ci_padded}${RST}"

        # Activity sparkline (from pre-collected weekly counts)
        local spark; spark=$(sparkline "$activity")

        # Row 1: main info
        printf "  %-20s %-10s %b%b%b%b%b%b%-4s %-5s %b  %s\n" \
            "$repo_name" "$branch" \
            "$auth_f" "$local_f" "$remote_f" "$ci_f" "$stash_f" "$br_f" \
            "$age" "$size" "$spark" "$commit_msg"

        # Row 2: remote URL + tracking + last fetch + tags + submodules
        local url_short; url_short=$(echo "$remote_url" | sed 's|git@github.com:|gh:|;s|https://github.com/|gh:|;s|\.git$||')
        local extra=""
        [ "$tags" -gt 0 ] 2>/dev/null && extra="${extra} ${C_DIM}tags:${RST}${C_INFO}${tags}${RST}"
        [ "$submods" = "yes" ] && extra="${extra} ${C_WARN}submodules${RST}"
        printf "  ${C_DIM}%-20s %s  track:%-20s fetch:%s%b${RST}\n" \
            "" "$url_short" "$tracking" "$last_fetch" "$extra"
        idx=$((idx+1))
    done

    # Summary totals from pre-computed data
    local total_repos cloned dirty_total pull_total push_total ssh_total http_total
    total_repos=$(_d -r '.git.totals.total')
    cloned=$(_d -r '.git.totals.cloned')
    dirty_total=$(_d -r '.git.totals.dirty')
    pull_total=$(_d -r '.git.totals.pull')
    push_total=$(_d -r '.git.totals.push')
    ssh_total=$(_d -r '.git.totals.ssh')
    http_total=$(_d -r '.git.totals.http')

    printf "\n  ${C_DIM}Total: %s repos | %s cloned | " "$total_repos" "$cloned"
    printf "auth: ${RST}${C_OK}%s SSH${RST}${C_DIM} / ${RST}${C_WARN}%s HTTP${RST}${C_DIM} | " "$ssh_total" "$http_total"
    [ "$dirty_total" -gt 0 ] && printf "${C_WARN}%s dirty${RST}${C_DIM}" "$dirty_total" || printf "0 dirty"
    printf " | "
    [ "$pull_total" -gt 0 ] && printf "${C_INFO}%s to pull${RST}${C_DIM}" "$pull_total" || printf "0 to pull"
    printf " | "
    [ "$push_total" -gt 0 ] && printf "${C_WARN}%s to push${RST}" "$push_total" || printf "0 to push"
    printf "${RST}\n"

    # Not cloned line
    local not_cloned; not_cloned=$(_d -r '.git.not_cloned')
    if [ -n "$not_cloned" ] && [ "$not_cloned" != "" ] && [ "$not_cloned" != " " ]; then
        printf "  ${C_DIM}NOT CLONED %s${RST}\n" "$(echo "$not_cloned" | sed 's/ / · /g')"
    fi
}

# =============================================================================
# B) GIT - Actions
# =============================================================================

git_get_repos() { _jq -r '(.git.public_repos // {} | keys[]) , (.git.private_repos // {} | keys[])'; }
git_get_url() {
    local name=$1
    local url
    url=$(_jq -r ".git.public_repos.\"$name\" // .git.private_repos.\"$name\" // empty")
    echo "$url"
}

_git_auto_fix_errors() {
    local dir="$1" output="$2"
    # Filename too long: auto-enable longpaths
    if echo "$output" | grep -qi "filename too long\|file name too long"; then
        printf "    ${C_WARN}Auto-fix: enabling core.longpaths${RST}\n"
        git -C "$dir" config core.longpaths true
    fi
    # Symlink errors: auto-disable symlinks
    if echo "$output" | grep -qi "unable to create symlink\|symlink.*not supported"; then
        printf "    ${C_WARN}Auto-fix: disabling core.symlinks${RST}\n"
        git -C "$dir" config core.symlinks false
    fi
    # Failed merge: abort
    if [ -f "$dir/.git/MERGE_HEAD" ]; then
        printf "    ${C_WARN}Auto-fix: aborting failed merge${RST}\n"
        git -C "$dir" merge --abort 2>/dev/null || true
    fi
}

git_cmd_sync() {
    printf "\n${BLD}=== Syncing All Repos ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        if [ ! -d "$dir/.git" ]; then
            printf "${C_INFO}${S_ARR}${RST} Cloning %s...\n" "$name"
            local url; url=$(git_get_url "$name")
            [ -n "$url" ] && git clone "$url" "$dir" 2>&1 || printf "${C_ERR}Clone failed${RST}\n"
            continue
        fi
        printf "${C_INFO}${S_ARR}${RST} Syncing ${BLD}%s${RST}...\n" "$name"
        # Auto-commit before pull
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            git -C "$dir" add -A && git -C "$dir" commit -q -m "sync: auto-commit" 2>/dev/null || true
        fi
        git -C "$dir" fetch -q 2>/dev/null || true
        local pull_out
        pull_out=$(git -C "$dir" pull --no-rebase --strategy-option="$MERGE_STRATEGY" -q 2>&1) || {
            printf "    ${C_ERR}Pull error${RST}\n"
            _git_auto_fix_errors "$dir" "$pull_out"
        }
        git -C "$dir" push -q 2>&1 || true
        printf "${C_OK}${S_OK}${RST} Done\n"
    done <<< "$(git_get_repos)"
}

git_cmd_pull() {
    printf "\n${BLD}=== Pulling All Repos ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}${S_ARR}${RST} Pulling %s..." "$name"
        # Auto-commit before pull (like gcl.sh) instead of just stashing
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            printf " ${C_WARN}[auto-commit]${RST}"
            git -C "$dir" add -A && git -C "$dir" commit -q -m "auto-commit before pull" 2>/dev/null || true
        fi
        local pull_out
        pull_out=$(git -C "$dir" pull --no-rebase --strategy-option="$MERGE_STRATEGY" -q 2>&1)
        if [ $? -eq 0 ]; then
            printf " ${C_OK}${S_OK}${RST}\n"
        else
            printf " ${C_ERR}${S_FAIL}${RST}\n"
            _git_auto_fix_errors "$dir" "$pull_out"
        fi
    done <<< "$(git_get_repos)"
}

git_cmd_commit() {
    printf "\n${BLD}=== Committing All Repos ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            printf "${C_INFO}${S_ARR}${RST} Committing %s..." "$name"
            git -C "$dir" add -A && git -C "$dir" commit -m "auto-commit" 2>/dev/null && \
                printf " ${C_OK}${S_OK}${RST}\n" || printf " ${C_WARN}nothing${RST}\n"
        fi
    done <<< "$(git_get_repos)"
}

git_cmd_push() {
    printf "\n${BLD}=== Pushing All Repos ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}${S_ARR}${RST} Pushing %s..." "$name"
        git -C "$dir" push -q 2>&1 && printf " ${C_OK}${S_OK}${RST}\n" || printf " ${C_ERR}${S_FAIL}${RST}\n"
    done <<< "$(git_get_repos)"
}

git_cmd_fetch() {
    printf "\n${BLD}=== Fetching All Repos (parallel) ===${RST}\n\n"
    local pids="" names=""
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}${S_ARR}${RST} Fetching %s...\n" "$name"
        git -C "$dir" fetch -q 2>/dev/null &
        pids="$pids $!"
        names="$names $name"
    done <<< "$(git_get_repos)"

    # Wait for all fetches and report results
    local i=1
    for pid in $pids; do
        local rname
        rname=$(echo "$names" | cut -d' ' -f$((i+1)))
        if wait "$pid" 2>/dev/null; then
            printf "  ${C_OK}${S_OK}${RST} %s\n" "$rname"
        else
            printf "  ${C_ERR}${S_FAIL}${RST} %s\n" "$rname"
        fi
        i=$((i+1))
    done
    printf "\n${C_OK}${S_OK}${RST} All fetches complete\n"
}

git_cmd_fetch_status() {
    printf "\n${BLD}=== Fetch + Status ===${RST}\n\n"
    # Parallel fetch
    local pids=""
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        git -C "$dir" fetch -q 2>/dev/null &
        pids="$pids $!"
    done <<< "$(git_get_repos)"

    printf "${C_INFO}Fetching %d repos...${RST}" "$(echo "$pids" | wc -w)"
    for pid in $pids; do wait "$pid" 2>/dev/null; done
    printf " ${C_OK}done${RST}\n\n"

    # Render with accurate pull counts
    render_git
}

git_cmd_untracked() {
    printf "\n${BLD}=== Untracked Files ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local files
        files=$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)
        if [ -n "$files" ]; then
            printf "${C_INFO}%s:${RST}\n" "$name"
            echo "$files" | while read -r f; do printf "  ${C_WARN}+ %s${RST}\n" "$f"; done
            echo ""
        fi
    done <<< "$(git_get_repos)"
}

git_cmd_unstaged() {
    printf "\n${BLD}=== Unstaged Changes ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local files
        files=$(git -C "$dir" diff --name-only 2>/dev/null)
        if [ -n "$files" ]; then
            printf "${C_INFO}%s:${RST}\n" "$name"
            echo "$files" | while read -r f; do printf "  ${C_WARN}M %s${RST}\n" "$f"; done
            echo ""
        fi
    done <<< "$(git_get_repos)"
}

git_cmd_ignored() {
    printf "\n${BLD}=== Ignored Files ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local cnt
        cnt=$(git -C "$dir" ls-files --others --ignored --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        [ "$cnt" -gt 0 ] && printf "${C_INFO}%s:${RST} ${C_DIM}%s files${RST}\n" "$name" "$cnt"
    done <<< "$(git_get_repos)"
}

git_cmd_clone_menu() {
    local repos uncloned_arr=()
    repos=$(git_get_repos)
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        [ ! -d "$GIT_WORKDIR/$name/.git" ] && uncloned_arr+=("$name")
    done <<< "$repos"

    if [ "${#uncloned_arr[@]}" -eq 0 ]; then
        printf "${C_OK}All repos cloned.${RST}\n"
        return
    fi

    # Selection state: 0=deselected, 1=selected
    local count=${#uncloned_arr[@]}
    local selected=()
    local i
    for (( i=0; i<count; i++ )); do selected+=("0"); done

    while true; do
        printf "\n${BLD}━━━ Clone Menu (toggle with number, Enter to clone) ━━━${RST}\n\n"
        for (( i=0; i<count; i++ )); do
            local marker="[ ]"
            [ "${selected[$i]}" = "1" ] && marker="${C_OK}[x]${RST}"
            printf "  %b %s${RST}  %s\n" "$marker" "${C_INFO}$((i+1))${RST})" "${uncloned_arr[$i]}"
        done

        printf "\n  ${C_INFO}a${RST}) Select all  ${C_INFO}n${RST}) Select none  ${C_DIM}0${RST}) Cancel  ${C_OK}Enter${RST}) Clone selected\n"
        printf "${BLD}Choice:${RST} "
        read -r choice

        case "$choice" in
            0) return ;;
            a|A) for (( i=0; i<count; i++ )); do selected[$i]="1"; done ;;
            n|N) for (( i=0; i<count; i++ )); do selected[$i]="0"; done ;;
            "")
                # Clone all selected
                local any=false
                for (( i=0; i<count; i++ )); do
                    if [ "${selected[$i]}" = "1" ]; then
                        any=true
                        local url; url=$(git_get_url "${uncloned_arr[$i]}")
                        printf "${C_INFO}${S_ARR}${RST} Cloning %s...\n" "${uncloned_arr[$i]}"
                        git clone "$url" "$GIT_WORKDIR/${uncloned_arr[$i]}" 2>&1 || true
                    fi
                done
                [ "$any" = "false" ] && printf "${C_WARN}Nothing selected${RST}\n"
                return
                ;;
            *)
                # Toggle number
                if echo "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
                    local idx=$((choice-1))
                    if [ "${selected[$idx]}" = "0" ]; then
                        selected[$idx]="1"
                    else
                        selected[$idx]="0"
                    fi
                else
                    printf "${C_ERR}Invalid choice${RST}\n"
                fi
                ;;
        esac
    done
}

git_cmd_dirty() {
    printf "\n${BLD}=== Repos Needing Attention ===${RST}\n\n"
    printf "  ${BLD}%-17s %-9s %5s %4s %4s  Issue${RST}\n" "Repo" "Branch" "Dirty" "Pull" "Push"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 80 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local found=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue

        local dirty pull push issues=""
        dirty=$(git_dirty_count "$dir")
        pull=$(git_unpulled "$dir")
        push=$(git_unpushed "$dir")

        [ "$dirty" -gt 0 ] 2>/dev/null && issues="${issues}${C_WARN}dirty${RST} "
        [ "$pull" != "?" ] && [ "$pull" -gt 0 ] 2>/dev/null && issues="${issues}${C_INFO}behind${RST} "
        [ "$push" != "?" ] && [ "$push" -gt 0 ] 2>/dev/null && issues="${issues}${C_WARN}ahead${RST} "

        [ -z "$issues" ] && continue

        found=1
        local branch; branch=$(git_branch "$dir")
        printf "  %-17s %-9s %5s %4s %4s  %b\n" \
            "$name" "$branch" "$dirty" "$pull" "$push" "$issues"
    done <<< "$(git_get_repos)"

    [ "$found" -eq 0 ] && printf "  ${C_OK}${S_OK} All repos clean${RST}\n"
}

git_toggle_merge() {
    if [ "$MERGE_STRATEGY" = "theirs" ]; then
        MERGE_STRATEGY="ours"
        printf "${C_OK}${S_OK}${RST} Merge strategy: ${C_WARN}Local wins${RST}\n"
    else
        MERGE_STRATEGY="theirs"
        printf "${C_OK}${S_OK}${RST} Merge strategy: ${C_INFO}Server wins${RST}\n"
    fi
    _jq_write "$SCRIPT_DIR/connect-sync.json" \
        --arg v "$MERGE_STRATEGY" '.settings.merge_strategy = $v'
}

git_cmd_remotes() {
    printf "\n${BLD}=== Git Remotes (all repos) ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}%s:${RST}\n" "$name"
        git -C "$dir" remote -v 2>/dev/null | while read -r line; do
            printf "  ${C_DIM}%s${RST}\n" "$line"
        done
        echo ""
    done <<< "$(git_get_repos)"
}

git_cmd_branches() {
    printf "\n${BLD}=== Git Branches (all repos) ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local current; current=$(git_branch "$dir")
        local count; count=$(git_branch_count "$dir")
        printf "${C_INFO}%s${RST} (${C_DIM}%s branches, current: ${RST}${C_OK}%s${RST}${C_DIM})${RST}\n" "$name" "$count" "$current"
        git -C "$dir" branch -a 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q '^\*'; then
                printf "  ${C_OK}%s${RST}\n" "$line"
            else
                printf "  ${C_DIM}%s${RST}\n" "$line"
            fi
        done
        echo ""
    done <<< "$(git_get_repos)"
}

git_cmd_tags() {
    printf "\n${BLD}=== Git Tags (all repos) ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local count; count=$(git_tag_count "$dir")
        [ "$count" -eq 0 ] && continue
        printf "${C_INFO}%s${RST} (${C_DIM}%s tags${RST})\n" "$name" "$count"
        git -C "$dir" tag -l 2>/dev/null | while read -r tag; do
            printf "  ${C_WARN}%s${RST}\n" "$tag"
        done
        echo ""
    done <<< "$(git_get_repos)"
}

git_cmd_log() {
    printf "\n${BLD}=== Git Log (last 10 commits per repo) ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}%s:${RST}\n" "$name"
        git -C "$dir" log --oneline --graph --decorate -10 2>/dev/null | while read -r line; do
            printf "  ${C_DIM}%s${RST}\n" "$line"
        done
        echo ""
    done <<< "$(git_get_repos)"
}

git_cmd_stash_list() {
    printf "\n${BLD}=== Git Stashes (all repos) ===${RST}\n\n"
    local found=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local count; count=$(git_stash_count "$dir")
        [ "$count" -eq 0 ] && continue
        found=1
        printf "${C_INFO}%s${RST} (${C_WARN}%s stashes${RST})\n" "$name" "$count"
        git -C "$dir" stash list 2>/dev/null | while read -r line; do
            printf "  ${C_DIM}%s${RST}\n" "$line"
        done
        echo ""
    done <<< "$(git_get_repos)"
    [ "$found" -eq 0 ] && printf "  ${C_OK}${S_OK} No stashes${RST}\n"
}

git_cmd_diff() {
    printf "\n${BLD}=== Git Diff (unstaged changes) ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        local dirty; dirty=$(git_dirty_count "$dir")
        [ "$dirty" -eq 0 ] && continue
        printf "${C_INFO}%s:${RST}\n" "$name"
        git -C "$dir" diff --stat 2>/dev/null
        echo ""
    done <<< "$(git_get_repos)"
}

git_cmd_gc() {
    printf "\n${BLD}=== Git Garbage Collection (all repos) ===${RST}\n\n"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}${S_ARR}${RST} Running gc on %s...\n" "$name"
        git -C "$dir" gc --auto 2>&1 | while read -r line; do
            printf "  ${C_DIM}%s${RST}\n" "$line"
        done
    done <<< "$(git_get_repos)"
    printf "\n${C_OK}${S_OK}${RST} Done\n"
}

git_cmd_prune() {
    printf "\n${BLD}=== Git Prune (remove unreachable objects) ===${RST}\n\n"
    printf "${C_WARN}This will run 'git remote prune origin' + 'git prune' on all repos.${RST}\n"
    printf "Continue? [y/N] "
    read -r confirm
    case "$confirm" in
        [Yy]*) ;;
        *) printf "${C_DIM}Cancelled${RST}\n"; return ;;
    esac
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local dir="$GIT_WORKDIR/$name"
        [ ! -d "$dir/.git" ] && continue
        printf "${C_INFO}${S_ARR}${RST} Pruning %s...\n" "$name"
        git -C "$dir" remote prune origin 2>&1 | while read -r line; do
            printf "  ${C_DIM}%s${RST}\n" "$line"
        done
        git -C "$dir" prune 2>&1 | while read -r line; do
            printf "  ${C_DIM}%s${RST}\n" "$line"
        done
    done <<< "$(git_get_repos)"
    printf "\n${C_OK}${S_OK}${RST} Done\n"
}

# =============================================================================
# C) FUSE DRIVES - Rendering & Actions
# =============================================================================

render_drives() {
    [ -z "$CC_DATA" ] && collect_all
    # Cloud Drives
    printf "  ${BLD}%-17s %-27s %-7s %-16s %-8s Mount${RST}\n" \
        "FUSE DRIVES" "Account" "State" "Usage" "Quota"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local drive_count; drive_count=$(_d '.drives.cloud | length')
    local d=0
    while [ "$d" -lt "$drive_count" ]; do
        local dname dacct dmounted dused dtotal mount_path
        dname=$(_d -r ".drives.cloud[$d].name")
        dacct=$(_d -r ".drives.cloud[$d].account")
        dmounted=$(_d -r ".drives.cloud[$d].mounted")
        dused=$(_d -r ".drives.cloud[$d].used_g")
        dtotal=$(_d -r ".drives.cloud[$d].total_g")
        mount_path=$(_d -r ".drives.cloud[$d].mount_path")

        if [ "$dmounted" = "true" ]; then
            local dstate="${C_OK}${S_DOT} ON${RST}"
            printf "  %-17s %-27s %b  " "$dname" "$dacct" "$dstate"
            gauge_bar "$dused" "$dtotal" 12 "${dused}G/${dtotal}G"
            printf "    %s\n" "$mount_path"
        else
            local dstate="${C_DIM}${S_STOP} OFF${RST}"
            printf "  %-17s %-27s %b  ${C_DIM}—${RST}\n" "$dname" "$dacct" "$dstate"
        fi
        d=$((d+1))
    done

    # VM FUSE Mounts — use mesh VM subdir data from CC_DATA
    printf "\n  ${BLD}%-17s %-16s %-28s %-4s  Mount Base${RST}\n" \
        "VM FUSE MOUNTS" "Remote" "Subdirs" "Bar"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local vm_count; vm_count=$(_d '.mesh.vms | length')
    local v=0
    while [ "$v" -lt "$vm_count" ]; do
        local vname valias vremote
        vname=$(_d -r ".mesh.vms[$v].name")
        valias=$(_d -r ".mesh.vms[$v].alias")
        vremote="sftp://$valias"

        local sub_count; sub_count=$(_d ".mesh.vms[$v].subdirs | length")
        local mounted_count=0 total_subs=0 subdir_str=""
        local si=0
        while [ "$si" -lt "$sub_count" ]; do
            local sub sm
            sub=$(_d -r ".mesh.vms[$v].subdirs[$si].name")
            sm=$(_d -r ".mesh.vms[$v].subdirs[$si].mounted")
            total_subs=$((total_subs + 1))
            if [ "$sm" = "true" ]; then
                mounted_count=$((mounted_count + 1))
                subdir_str="${subdir_str}${C_OK}${sub}${S_DOT}${RST} "
            else
                subdir_str="${subdir_str}${C_DIM}${sub}${S_STOP}${RST} "
            fi
            si=$((si+1))
        done

        # Mount bar
        local bar_str="" b=0
        while [ "$b" -lt "$total_subs" ]; do
            if [ "$b" -lt "$mounted_count" ]; then
                bar_str="${bar_str}${C_OK}█${RST}"
            else
                bar_str="${bar_str}${C_DIM}░${RST}"
            fi
            b=$((b+1))
        done

        local mount_base=""
        [ "$mounted_count" -gt 0 ] && mount_base="$MOUNT_DIR/$vname/"

        printf "  %-17s %-16s %b  %b  %s\n" \
            "$vname" "$vremote" "$subdir_str" "$bar_str" "$mount_base"
        v=$((v+1))
    done

    # Container symlinks
    local symlink_count; symlink_count=$(_d '.drives.symlinks | length')
    if [ "$symlink_count" -gt 0 ]; then
        printf "\n  ${C_DIM}Container symlinks: %d${RST}" "$symlink_count"
        local si=0
        while [ "$si" -lt "$symlink_count" ]; do
            printf " ${C_DIM}[%s]${RST}" "$(_d -r ".drives.symlinks[$si].name")"
            si=$((si+1))
        done
        printf "\n"
    fi
}

# Drive mount/unmount actions
mount_rclone_path() {
    local remote=$1 remote_path=$2 mountpoint=$3
    is_mounted "$mountpoint" && { printf "${C_WARN}Already mounted: %s${RST}\n" "$mountpoint"; return 0; }
    if ! rclone_remote_exists "$remote"; then
        printf "${C_ERR}Remote '%s' not configured${RST}\n" "$remote"
        return 1
    fi
    mkdir -p "$mountpoint"
    # shellcheck disable=SC2086
    nohup rclone mount "${remote}:${remote_path}" "$mountpoint" $RCLONE_OPTS >/dev/null 2>&1 &
    local tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 0.5
        is_mounted "$mountpoint" && { printf "${C_OK}[+]${RST} Mounted %s\n" "$mountpoint"; log_msg "Mounted $mountpoint"; return 0; }
        tries=$((tries+1))
    done
    printf "${C_ERR}[-] Failed: %s${RST}\n" "$mountpoint"
    log_err "Mount failed: $mountpoint"
    return 1
}

mount_vm() {
    local name=$1 remote=$2
    printf "${C_INFO}[+]${RST} Mounting %s...\n" "$name"
    local vidx; vidx=$(_jq --arg n "$name" '.mesh.vms | to_entries[] | select(.value.name == $n) | .key')
    local scount; scount=$(_jq ".mesh.vms[$vidx].vm_subdirs | length")
    local si=0
    while [ "$si" -lt "$scount" ]; do
        local sname srpath
        sname=$(_jq -r ".mesh.vms[$vidx].vm_subdirs[$si].name")
        srpath=$(_jq -r ".mesh.vms[$vidx].vm_subdirs[$si].remote_path")
        mount_rclone_path "$remote" "$srpath" "$MOUNT_DIR/$name/$sname" || true
        si=$((si+1))
    done
}

unmount_vm() {
    local name=$1
    while IFS= read -r sub; do
        [ -z "$sub" ] && continue
        if is_mounted "$MOUNT_DIR/$name/$sub"; then
            fusermount -uz "$MOUNT_DIR/$name/$sub" 2>/dev/null
            printf "${C_OK}[+]${RST} Unmounted %s/%s\n" "$name" "$sub"
        fi
    done < <(_vm_subdirs_by_name "$name")
}

mount_drive() {
    local name=$1 remote=$2
    mount_rclone_path "$remote" "/" "$MOUNT_DIR/$name" || true
}

unmount_drive() {
    local name=$1
    if is_mounted "$MOUNT_DIR/$name"; then
        fusermount -uz "$MOUNT_DIR/$name" 2>/dev/null
        printf "${C_OK}[+]${RST} Unmounted %s\n" "$name"
    fi
}

mount_phone() {
    local dev_id phone_name sftp_base
    dev_id=$(_jq -r '.mesh.phone.device_id')
    phone_name=$(_jq -r '.mesh.phone.name')
    sftp_base=$(_jq -r '.mesh.phone.sftp_base')
    [ -z "$dev_id" ] || [ "$dev_id" = "null" ] && { printf "${C_ERR}Phone not configured${RST}\n"; return 1; }
    command -v kdeconnect-cli >/dev/null 2>&1 || { printf "${C_ERR}kdeconnect-cli not found${RST}\n"; return 1; }
    command -v qdbus >/dev/null 2>&1 || { printf "${C_ERR}qdbus not found${RST}\n"; return 1; }
    printf "${C_INFO}[+]${RST} Mounting phone...\n"
    qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$dev_id/sftp" \
        org.kde.kdeconnect.device.sftp.mount 2>/dev/null
    sleep 1
    rm -f "$MOUNT_DIR/$phone_name" 2>/dev/null
    ln -sf "$sftp_base" "$MOUNT_DIR/$phone_name"
    printf "${C_OK}[+]${RST} Mounted: %s/%s\n" "$MOUNT_DIR" "$phone_name"
}

unmount_phone() {
    local dev_id phone_name
    dev_id=$(_jq -r '.mesh.phone.device_id')
    phone_name=$(_jq -r '.mesh.phone.name')
    if command -v qdbus >/dev/null 2>&1 && [ -n "$dev_id" ] && [ "$dev_id" != "null" ]; then
        qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$dev_id/sftp" \
            org.kde.kdeconnect.device.sftp.unmount 2>/dev/null || true
    fi
    rm -f "$MOUNT_DIR/$phone_name" 2>/dev/null
    printf "${C_OK}[+]${RST} Phone unmounted\n"
}

# Numbered mount/unmount helpers
select_and_mount_vm() {
    printf "\n${BLD}Select VM to mount:${RST}\n"
    local vm_count; vm_count=$(_jq '.mesh.vms | length')
    local i=0
    while [ "$i" -lt "$vm_count" ]; do
        local name; name=$(_jq -r ".mesh.vms[$i].name")
        printf "  ${C_INFO}%d${RST}) %s\n" "$((i+1))" "$name"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return
    local idx=$((ch-1))
    local name; name=$(_jq -r ".mesh.vms[$idx].name // empty")
    local remote; remote=$(_jq -r ".mesh.vms[$idx].remote // empty")
    [ -n "$name" ] && mount_vm "$name" "$remote"
}

select_and_unmount_vm() {
    printf "\n${BLD}Select VM to unmount:${RST}\n"
    local vm_count; vm_count=$(_jq '.mesh.vms | length')
    local i=0
    while [ "$i" -lt "$vm_count" ]; do
        local name; name=$(_jq -r ".mesh.vms[$i].name")
        printf "  ${C_INFO}%d${RST}) %s\n" "$((i+1))" "$name"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return
    local idx=$((ch-1))
    local name; name=$(_jq -r ".mesh.vms[$idx].name // empty")
    [ -n "$name" ] && unmount_vm "$name"
}

select_and_mount_drive() {
    printf "\n${BLD}Select Drive to mount:${RST}\n"
    local d_count; d_count=$(_jq '.fuse_drives | length')
    local i=0
    while [ "$i" -lt "$d_count" ]; do
        local name; name=$(_jq -r ".fuse_drives[$i].name")
        printf "  ${C_INFO}%d${RST}) %s\n" "$((i+1))" "$name"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return
    local idx=$((ch-1))
    local name; name=$(_jq -r ".fuse_drives[$idx].name // empty")
    local remote; remote=$(_jq -r ".fuse_drives[$idx].remote // empty")
    [ -n "$name" ] && mount_drive "$name" "$remote"
}

select_and_unmount_drive() {
    printf "\n${BLD}Select Drive to unmount:${RST}\n"
    local d_count; d_count=$(_jq '.fuse_drives | length')
    local i=0
    while [ "$i" -lt "$d_count" ]; do
        local name; name=$(_jq -r ".fuse_drives[$i].name")
        printf "  ${C_INFO}%d${RST}) %s\n" "$((i+1))" "$name"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return
    local idx=$((ch-1))
    local name; name=$(_jq -r ".fuse_drives[$idx].name // empty")
    [ -n "$name" ] && unmount_drive "$name"
}

# =============================================================================
# C) FUSE DRIVES - OCI Flex Control
# =============================================================================

flex_action() {
    local action=$1  # start|stop|reset|status
    local flex_idx=$2  # vm index in config

    local instance_id region name
    instance_id=$(_jq -r ".mesh.vms[$flex_idx].oci_flex.instance_id // empty")
    region=$(_jq -r ".mesh.vms[$flex_idx].oci_flex.region // empty")
    name=$(_jq -r ".mesh.vms[$flex_idx].name")

    if [ -z "$instance_id" ]; then
        printf "${C_ERR}No OCI flex config for %s${RST}\n" "$name"
        return 1
    fi

    if ! command -v oci >/dev/null 2>&1; then
        printf "${C_ERR}oci CLI not found${RST}\n"
        return 1
    fi

    case "$action" in
        status)
            printf "${C_INFO}[i]${RST} Checking %s...\n" "$name"
            local state
            state=$(SUPPRESS_LABEL_WARNING=True oci compute instance get \
                --instance-id "$instance_id" --region "$region" \
                --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
            case "$state" in
                RUNNING) printf "  ${C_OK}${S_RUN}${RST} %s: %s\n" "$name" "$state" ;;
                STOPPED) printf "  ${C_ERR}${S_STOP}${RST} %s: %s\n" "$name" "$state" ;;
                *)       printf "  ${C_WARN}?${RST} %s: %s\n" "$name" "$state" ;;
            esac
            ;;
        start)
            printf "${C_INFO}[+]${RST} Starting %s...\n" "$name"
            SUPPRESS_LABEL_WARNING=True oci compute instance action \
                --instance-id "$instance_id" --region "$region" --action START >/dev/null 2>&1 && \
                printf "${C_OK}${S_OK}${RST} Start command sent\n" || \
                printf "${C_ERR}${S_FAIL}${RST} Failed\n"
            ;;
        stop)
            printf "${C_INFO}[-]${RST} Stopping %s...\n" "$name"
            unmount_vm "$name"
            SUPPRESS_LABEL_WARNING=True oci compute instance action \
                --instance-id "$instance_id" --region "$region" --action STOP >/dev/null 2>&1 && \
                printf "${C_OK}${S_OK}${RST} Stop command sent\n" || \
                printf "${C_ERR}${S_FAIL}${RST} Failed\n"
            ;;
        reset)
            printf "${C_WARN}[!]${RST} Resetting %s...\n" "$name"
            unmount_vm "$name"
            SUPPRESS_LABEL_WARNING=True oci compute instance action \
                --instance-id "$instance_id" --region "$region" --action RESET >/dev/null 2>&1 && \
                printf "${C_OK}${S_OK}${RST} Reset command sent\n" || \
                printf "${C_ERR}${S_FAIL}${RST} Failed\n"
            ;;
    esac
}

# Find flex VM indices
get_flex_indices() {
    local vm_count; vm_count=$(_jq '.mesh.vms | length')
    local i=0
    while [ "$i" -lt "$vm_count" ]; do
        local has_flex; has_flex=$(_jq ".mesh.vms[$i].oci_flex // null")
        [ "$has_flex" != "null" ] && echo "$i"
        i=$((i+1))
    done
}

flex_select_and_action() {
    local action=$1
    local indices; indices=$(get_flex_indices)
    if [ -z "$indices" ]; then
        printf "${C_WARN}No OCI Flex VMs configured${RST}\n"
        return
    fi

    local count; count=$(echo "$indices" | wc -l)
    if [ "$count" -eq 1 ]; then
        flex_action "$action" "$indices"
    else
        printf "\n${BLD}Select Flex VM:${RST}\n"
        local n=1
        for idx in $indices; do
            local name; name=$(_jq -r ".mesh.vms[$idx].name")
            printf "  ${C_INFO}%d${RST}) %s\n" "$n" "$name"
            n=$((n+1))
        done
        printf "${BLD}Choice:${RST} "
        read -r ch
        local target; target=$(echo "$indices" | sed -n "${ch}p")
        [ -n "$target" ] && flex_action "$action" "$target"
    fi
}

# =============================================================================
# D) SYNC - Data Collection & Rendering
# =============================================================================

sync_list_rules() {
    [ ! -f "$SYNC_RULES_FILE" ] && echo "[]" && return
    jq '[.[] | select(has("name") and (.name | startswith("_") | not))]' "$SYNC_RULES_FILE" 2>/dev/null || echo "[]"
}

# --- Sync helpers ---

sync_save_rules() {
    local rules="$1"
    # Preserve schema/comment entries
    local schema="[]"
    if [ -f "$SYNC_RULES_FILE" ]; then
        schema=$(jq '[.[] | select(has("_comment") or has("_schema"))]' "$SYNC_RULES_FILE" 2>/dev/null || echo "[]")
    fi
    echo "$schema $rules" | jq -s 'add' > "$SYNC_RULES_FILE"
}

sync_get_rule() {
    local name="$1"
    sync_list_rules | jq -r ".[] | select(.name == \"$name\")"
}

generate_job_id() {
    echo "job_$(date '+%Y%m%d_%H%M%S')_$$"
}

sync_list_jobs() {
    if [ ! -s "$SYNC_JOBS_FILE" ] || [ "$(cat "$SYNC_JOBS_FILE")" = "[]" ]; then
        echo "[]"
        return
    fi
    cat "$SYNC_JOBS_FILE"
}

# --- Group 3: Job Tracking ---

sync_add_job() {
    local job_id="$1" name="$2" source="$3" dest="$4" sync_type="$5" pid="$6" log_file="$7"
    local now; now=$(date -Iseconds)
    local new_job
    new_job=$(printf '{"job_id":"%s","name":"%s","source":"%s","dest":"%s","sync_type":"%s","status":"running","started":"%s","ended":null,"pid":%s,"log_file":"%s"}' \
        "$job_id" "$name" "$source" "$dest" "$sync_type" "$now" "$pid" "$log_file")
    local jobs; jobs=$(sync_list_jobs)
    jobs=$(echo "$jobs" | jq '. | if length > 19 then .[-19:] else . end')
    echo "$jobs" | jq ". + [$new_job]" > "$SYNC_JOBS_FILE"
}

sync_update_job() {
    local job_id="$1" status="$2"
    local now; now=$(date -Iseconds)
    local jobs; jobs=$(sync_list_jobs)
    echo "$jobs" | jq \
        "(.[] | select(.job_id == \"$job_id\") | .status) = \"$status\" |
         (.[] | select(.job_id == \"$job_id\") | .ended) = \"$now\"" > "$SYNC_JOBS_FILE"
}

sync_clear_completed() {
    local jobs; jobs=$(sync_list_jobs)
    local running; running=$(echo "$jobs" | jq '[.[] | select(.status == "running")]')
    local removed=$(( $(echo "$jobs" | jq 'length') - $(echo "$running" | jq 'length') ))
    echo "$running" > "$SYNC_JOBS_FILE"
    printf "${C_OK}${S_OK}${RST} Cleared %d completed jobs\n" "$removed"
}

sync_update_last_run() {
    local name="$1"
    local now; now=$(date -Iseconds)
    local rules; rules=$(sync_list_rules)
    local updated; updated=$(echo "$rules" | jq "(.[] | select(.name == \"$name\") | .last_run) = \"$now\"")
    sync_save_rules "$updated"
}

# --- Group 1: Sync Engine ---

sync_one_way() {
    local source="$1" dest="$2" dry_run="${3:-false}" delete="${4:-true}"

    local cmd="rclone"
    if [ "$delete" = "true" ]; then
        cmd="$cmd sync"
    else
        cmd="$cmd copy"
    fi

    cmd="$cmd '$source' '$dest' $RCLONE_SYNC_OPTS --verbose --progress"
    [ "$dry_run" = "true" ] && cmd="$cmd --dry-run"

    printf "\n${C_INFO}${BLD}Sync: %s ${S_ARR} %s${RST}\n" "$source" "$dest"
    [ "$dry_run" = "true" ] && printf "${C_WARN}DRY RUN - No changes will be made${RST}\n"

    log_msg "Running: $cmd"
    if eval $cmd; then
        log_msg "Sync completed: $source -> $dest"
        return 0
    else
        log_err "Sync failed: $source -> $dest"
        return 1
    fi
}

sync_bisync() {
    local path1="$1" path2="$2" dry_run="${3:-false}" resync="${4:-false}" conflict_resolve="${5:-newer}"

    local bisync_cache="$HOME/.cache/rclone/bisync"
    [ ! -d "$bisync_cache" ] && resync="true"

    local cmd="rclone bisync '$path1' '$path2' $RCLONE_SYNC_OPTS --verbose"
    [ "$resync" = "true" ] && cmd="$cmd --resync"
    [ "$dry_run" = "true" ] && cmd="$cmd --dry-run"
    [ "$conflict_resolve" = "path1" ] || [ "$conflict_resolve" = "path2" ] && cmd="$cmd --conflict-resolve $conflict_resolve"

    printf "\n${C_INFO}${BLD}Bisync: %s ${S_ARBI} %s${RST}\n" "$path1" "$path2"
    [ "$resync" = "true" ] && printf "${C_WARN}Using --resync (first time or forced)${RST}\n"
    [ "$dry_run" = "true" ] && printf "${C_WARN}DRY RUN - No changes will be made${RST}\n"

    log_msg "Running: $cmd"
    if eval $cmd; then
        log_msg "Bisync completed: $path1 <-> $path2"
        return 0
    else
        log_err "Bisync failed: $path1 <-> $path2"
        return 1
    fi
}

sync_run_rule() {
    local name="$1" dry_run="${2:-false}"

    local rule; rule=$(sync_get_rule "$name")
    if [ -z "$rule" ]; then
        printf "${C_ERR}Rule '%s' not found${RST}\n" "$name"
        return 1
    fi

    local local_path remote sync_type conflict_resolve delete_extra
    local_path=$(echo "$rule" | jq -r '.local_path')
    remote=$(echo "$rule" | jq -r '.remote')
    sync_type=$(echo "$rule" | jq -r '.sync_type')
    conflict_resolve=$(echo "$rule" | jq -r '.conflict_resolve')
    delete_extra=$(echo "$rule" | jq -r '.delete_extra')

    printf "\n${BLD}=== Running rule: %s ===${RST}\n" "$name"
    printf "  Type: %s  Source: %s  Dest: %s\n" "$sync_type" "$local_path" "$remote"

    mkdir -p "$local_path" 2>/dev/null || true

    local success=false
    case "$sync_type" in
        bisync)
            sync_bisync "$remote" "$local_path" "$dry_run" "false" "$conflict_resolve" && success=true ;;
        sync_to_remote)
            sync_one_way "$local_path" "$remote" "$dry_run" "$delete_extra" && success=true ;;
        sync_to_local)
            sync_one_way "$remote" "$local_path" "$dry_run" "$delete_extra" && success=true ;;
        local_to_local|local_bisync)
            mkdir -p "$remote" 2>/dev/null || true
            if [ "$sync_type" = "local_bisync" ]; then
                sync_bisync "$local_path" "$remote" "$dry_run" "false" "$conflict_resolve" && success=true
            else
                sync_one_way "$local_path" "$remote" "$dry_run" "$delete_extra" && success=true
            fi ;;
    esac

    if [ "$success" = "true" ] && [ "$dry_run" = "false" ]; then
        sync_update_last_run "$name"
    fi

    [ "$success" = "true" ] && return 0 || return 1
}

sync_run_rule_background() {
    local name="$1" resync="${2:-false}"

    local rule; rule=$(sync_get_rule "$name")
    if [ -z "$rule" ]; then
        printf "${C_ERR}Rule '%s' not found${RST}\n" "$name"
        return 1
    fi

    local local_path remote sync_type conflict_resolve delete_extra
    local_path=$(echo "$rule" | jq -r '.local_path')
    remote=$(echo "$rule" | jq -r '.remote')
    sync_type=$(echo "$rule" | jq -r '.sync_type')
    conflict_resolve=$(echo "$rule" | jq -r '.conflict_resolve')
    delete_extra=$(echo "$rule" | jq -r '.delete_extra')

    mkdir -p "$local_path" 2>/dev/null || true
    { [ "$sync_type" = "local_to_local" ] || [ "$sync_type" = "local_bisync" ]; } && mkdir -p "$remote" 2>/dev/null || true

    local job_id; job_id=$(generate_job_id)
    local job_log="$SYNC_LOG_DIR/${job_id}.log"

    local source dest
    case "$sync_type" in
        bisync)         source="$remote"; dest="$local_path" ;;
        sync_to_remote) source="$local_path"; dest="$remote" ;;
        sync_to_local)  source="$remote"; dest="$local_path" ;;
        *)              source="$local_path"; dest="$remote" ;;
    esac

    local cmd
    case "$sync_type" in
        bisync|local_bisync)
            cmd="rclone bisync '$source' '$dest' $RCLONE_SYNC_OPTS -v --stats 3s --stats-log-level NOTICE"
            [ "$resync" = "true" ] && cmd="$cmd --resync"
            { [ "$conflict_resolve" = "path1" ] || [ "$conflict_resolve" = "path2" ]; } && cmd="$cmd --conflict-resolve $conflict_resolve"
            ;;
        *)
            if [ "$delete_extra" = "true" ]; then
                cmd="rclone sync '$source' '$dest' $RCLONE_SYNC_OPTS -v --stats 3s --stats-log-level NOTICE"
            else
                cmd="rclone copy '$source' '$dest' $RCLONE_SYNC_OPTS -v --stats 3s --stats-log-level NOTICE"
            fi ;;
    esac

    log_msg "Starting background job: $cmd"
    eval "$cmd" > "$job_log" 2>&1 &
    local pid=$!

    sync_add_job "$job_id" "$name" "$source" "$dest" "$sync_type" "$pid" "$job_log"

    log_msg "Started background sync: $name (PID: $pid)"
    printf "${C_OK}${S_OK}${RST} Started: %s (PID: %s, Job: %s)\n" "$name" "$pid" "$job_id"
    printf "  Log: %s\n" "$job_log"
}

sync_get_running_jobs() {
    [ ! -f "$SYNC_JOBS_FILE" ] && echo "[]" && return
    local jobs; jobs=$(cat "$SYNC_JOBS_FILE")
    local result="[]"
    while IFS= read -r job; do
        [ -z "$job" ] && continue
        local status pid
        status=$(echo "$job" | jq -r '.status')
        pid=$(echo "$job" | jq -r '.pid')
        if [ "$status" = "running" ] && kill -0 "$pid" 2>/dev/null; then
            result=$(echo "$result" | jq ". + [$job]")
        fi
    done < <(echo "$jobs" | jq -c '.[]' 2>/dev/null)
    echo "$result"
}

_sync_job_progress() {
    local log_file="$1"
    if [ ! -f "$log_file" ]; then
        echo "Starting..."
        return
    fi
    local percent transferred speed eta errors result=""
    percent=$(grep -oP '\d+%' "$log_file" 2>/dev/null | tail -1)
    transferred=$(grep -oP 'Transferred:\s+\K[^,]+' "$log_file" 2>/dev/null | tail -1)
    speed=$(grep -oP '\d+\.?\d*\s*[KMG]?i?B/s' "$log_file" 2>/dev/null | tail -1)
    eta=$(grep -oP 'ETA\s+\K\S+' "$log_file" 2>/dev/null | tail -1)
    errors=$(grep -c "ERROR" "$log_file" 2>/dev/null || echo 0)
    [ -n "$percent" ] && result="$percent"
    [ -n "$transferred" ] && result="$result | $transferred"
    [ -n "$speed" ] && result="$result | $speed"
    [ -n "$eta" ] && [ "$eta" != "-" ] && result="$result | ETA: $eta"
    [ "$errors" -gt 0 ] && result="$result | Err:$errors"
    if [ -n "$result" ]; then
        echo "$result"
    else
        local lines; lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
        echo "Processing... ($lines log lines)"
    fi
}

sync_get_completed_jobs() {
    [ ! -f "$SYNC_JOBS_FILE" ] && echo "[]" && return
    local jobs; jobs=$(cat "$SYNC_JOBS_FILE")
    echo "$jobs" | jq -c '[.[] | select(.status != "running")] | .[-5:]' 2>/dev/null || echo "[]"
}

sync_run_rule_interactive() {
    local rules; rules=$(sync_list_rules)
    local count; count=$(echo "$rules" | jq 'length')
    [ "$count" -eq 0 ] && { printf "${C_DIM}No rules configured${RST}\n"; return; }

    printf "\n${BLD}Select rule to run:${RST}\n"
    local i=0
    echo "$rules" | jq -c '.[]' | while IFS= read -r r; do
        local nm; nm=$(echo "$r" | jq -r '.name')
        local en; en=$(echo "$r" | jq -r '.enabled')
        local icon="${C_OK}${S_DOT}${RST}"
        [ "$en" != "true" ] && icon="${C_DIM}${S_STOP}${RST}"
        printf "  %b %d) %s\n" "$icon" "$i" "$nm"
        i=$((i+1))
    done

    printf "${BLD}Rule # (or name):${RST} "
    read -r sel
    [ -z "$sel" ] && return

    local name=""
    if echo "$sel" | grep -qE '^[0-9]+$'; then
        name=$(echo "$rules" | jq -r ".[$sel].name // empty")
    else
        name="$sel"
    fi
    [ -z "$name" ] && { printf "${C_ERR}Invalid selection${RST}\n"; return; }

    printf "Run mode: ${C_INFO}1${RST}) Background  ${C_INFO}2${RST}) Foreground  ${C_INFO}3${RST}) Dry run  [1]: "
    read -r mode
    mode="${mode:-1}"
    case "$mode" in
        1) sync_run_rule_background "$name" ;;
        2) sync_run_rule "$name" "false" ;;
        3) sync_run_rule "$name" "true" ;;
    esac
}

sync_run_rule_cli() {
    local name="$1"
    [ -z "$name" ] && { printf "${C_ERR}Usage: connect.sh sync-run-rule NAME [--dry-run] [--background]${RST}\n"; return 1; }
    shift
    local dry_run="false" background="false"
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run="true" ;;
            --background|-bg) background="true" ;;
        esac
        shift
    done
    if [ "$background" = "true" ]; then
        sync_run_rule_background "$name"
    else
        sync_run_rule "$name" "$dry_run"
    fi
}

sync_list_cli() {
    local rules; rules=$(sync_list_rules)
    local count; count=$(echo "$rules" | jq 'length')
    [ "$count" -eq 0 ] && { printf "${C_DIM}No rules configured${RST}\n"; return; }

    printf "\n${BLD}━━━ Sync Rules ━━━${RST}\n\n"
    local i=1
    echo "$rules" | jq -c '.[]' | while IFS= read -r rule; do
        local name sync_type enabled local_path remote last_run
        name=$(echo "$rule" | jq -r '.name')
        sync_type=$(echo "$rule" | jq -r '.sync_type')
        enabled=$(echo "$rule" | jq -r '.enabled')
        local_path=$(echo "$rule" | jq -r '.local_path')
        remote=$(echo "$rule" | jq -r '.remote')
        last_run=$(echo "$rule" | jq -r '.last_run // "never"')
        [ "$last_run" != "never" ] && [ "$last_run" != "null" ] && last_run="${last_run:0:16}"
        [ "$last_run" = "null" ] && last_run="never"

        local icon status_icon
        case "$sync_type" in
            bisync|local_bisync) icon="$S_ARBI" ;;
            sync_to_remote|local_to_local) icon="$S_ARR" ;;
            sync_to_local) icon="$S_ARRL" ;;
            *) icon="?" ;;
        esac

        if [ "$enabled" = "true" ]; then
            status_icon="${C_OK}${S_DOT}${RST}"
        else
            status_icon="${C_DIM}${S_STOP}${RST}"
        fi

        printf "%2d. %b %s\n" "$i" "$status_icon" "$name"
        printf "    ${C_DIM}%s %s %s${RST}\n" "$local_path" "$icon" "$remote"
        printf "    ${C_DIM}Type: %s | Last: %s${RST}\n\n" "$sync_type" "$last_run"
        i=$((i+1))
    done
}

render_sync() {
    [ -z "$CC_DATA" ] && collect_all
    # Configured Remotes
    printf "  ${BLD}%-17s %-30s State${RST}\n" "REMOTES" "Name"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local remote_count; remote_count=$(_d '.sync.remotes | length')
    if [ "$remote_count" -gt 0 ]; then
        local ri=0
        while [ "$ri" -lt "$remote_count" ]; do
            printf "  ${C_OK}${S_DOT}${RST}  %-30s ${C_OK}configured${RST}\n" "$(_d -r ".sync.remotes[$ri]")"
            ri=$((ri+1))
        done
    else
        printf "  ${C_DIM}No remotes configured${RST}\n"
    fi
    printf "\n"

    # Rules table with count summary — read from CC_DATA
    local rules; rules=$(_d '.sync.rules')
    local rule_count; rule_count=$(echo "$rules" | jq 'length')
    local enabled_cnt; enabled_cnt=$(echo "$rules" | jq '[.[] | select(.enabled == true)] | length')
    local disabled_cnt=$((rule_count - enabled_cnt))

    printf "  ${BLD}%-17s %-4s %-7s %-30s %-26s %-9s Last Run${RST}" \
        "RULES" "Type" "Enabled" "Remote Path" "Local Path" "Conflicts"
    printf "  ${C_DIM}(%s total, ${RST}${C_OK}%s on${RST}${C_DIM}, %s off)${RST}\n" \
        "$rule_count" "$enabled_cnt" "$disabled_cnt"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    if [ "$rule_count" -gt 0 ]; then
        echo "$rules" | jq -c '.[]' | while IFS= read -r rule; do
            local name sync_type enabled remote local_path conflict last_run
            name=$(echo "$rule" | jq -r '.name')
            sync_type=$(echo "$rule" | jq -r '.sync_type')
            enabled=$(echo "$rule" | jq -r '.enabled')
            remote=$(echo "$rule" | jq -r '.remote')
            local_path=$(echo "$rule" | jq -r '.local_path')
            conflict=$(echo "$rule" | jq -r '.conflict_resolve // "newer"')
            last_run=$(echo "$rule" | jq -r '.last_run // "never"')
            [ "$last_run" != "never" ] && [ "$last_run" != "null" ] && last_run="${last_run:0:16}"
            [ "$last_run" = "null" ] && last_run="never"

            local icon en_str
            case "$sync_type" in
                bisync|local_bisync) icon="$S_ARBI" ;;
                sync_to_remote|local_to_local) icon="$S_ARR" ;;
                sync_to_local) icon="$S_ARRL" ;;
                *) icon="?" ;;
            esac

            if [ "$enabled" = "true" ]; then
                en_str="${C_OK}ON${RST}"
            else
                en_str="${C_DIM}OFF${RST}"
            fi

            local r_short="${remote:0:30}"
            local l_short
            l_short=$(echo "$local_path" | sed "s|$HOME|~|")
            l_short="${l_short:0:26}"

            printf "  %-17s  %s   %b%5s  %-30s %-26s %-9s %s\n" \
                "$name" "$icon" "$en_str" "" "$r_short" "$l_short" "$conflict" "$last_run"
        done
    else
        printf "  ${C_DIM}No sync rules configured${RST}\n"
    fi

    # Active jobs — read from CC_DATA
    local running; running=$(_d '.sync.running_jobs')
    local run_count; run_count=$(echo "$running" | jq 'length')

    if [ "$run_count" -gt 0 ]; then
        printf "\n  ${BLD}%-17s %-8s %-11s %-17s Progress${RST}\n" \
            "ACTIVE JOBS" "PID" "Elapsed" "Rule"
        printf "  ${C_DIM}"
        w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
        printf "${RST}\n"

        echo "$running" | jq -c '.[]' | while IFS= read -r job; do
            local jname jpid jstarted jlog
            jname=$(echo "$job" | jq -r '.name')
            jpid=$(echo "$job" | jq -r '.pid')
            jstarted=$(echo "$job" | jq -r '.started')
            jlog=$(echo "$job" | jq -r '.log_file')

            local start_epoch now_epoch elapsed mins secs
            start_epoch=$(date -d "$jstarted" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            elapsed=$((now_epoch - start_epoch))
            mins=$((elapsed / 60))
            secs=$((elapsed % 60))

            local pct_str
            pct_str=$(_sync_job_progress "$jlog")

            printf "  ${C_OK}${S_PLAY}${RST} running        %-8s %02d:%02d:%02d   %-17s %s\n" \
                "$jpid" "$((elapsed/3600))" "$mins" "$secs" "$jname" "$pct_str"
        done
    fi

    # Completed/failed jobs (last 5) — still from disk (not in CC_DATA)
    local completed; completed=$(sync_get_completed_jobs)
    local comp_count; comp_count=$(echo "$completed" | jq 'length')
    if [ "$comp_count" -gt 0 ]; then
        printf "\n  ${C_DIM}Recent:${RST}\n"
        echo "$completed" | jq -c '.[]' | while IFS= read -r job; do
            local jname jstatus jended
            jname=$(echo "$job" | jq -r '.name')
            jstatus=$(echo "$job" | jq -r '.status')
            jended=$(echo "$job" | jq -r '.ended // ""')
            [ -n "$jended" ] && jended="${jended:0:16}"
            case "$jstatus" in
                completed) printf "  ${C_OK}${S_OK}${RST} %s ${C_DIM}(%s)${RST}\n" "$jname" "$jended" ;;
                failed)    printf "  ${C_ERR}${S_FAIL}${RST} %s ${C_DIM}(%s)${RST}\n" "$jname" "$jended" ;;
                cancelled) printf "  ${C_WARN}${S_WARN}${RST} %s ${C_DIM}(%s)${RST}\n" "$jname" "$jended" ;;
            esac
        done
    fi
}

sync_run_all() {
    local rules; rules=$(sync_list_rules)
    local enabled; enabled=$(echo "$rules" | jq -c '.[] | select(.enabled == true)')

    if [ -z "$enabled" ]; then
        printf "${C_DIM}No enabled sync rules${RST}\n"
        return
    fi

    printf "\n${BLD}=== Running All Enabled Sync Rules ===${RST}\n\n"

    printf "Run mode: ${C_INFO}1${RST}) Background  ${C_INFO}2${RST}) Foreground  ${C_INFO}3${RST}) Dry run  [1]: "
    read -r mode
    mode="${mode:-1}"

    echo "$enabled" | while IFS= read -r rule; do
        local name; name=$(echo "$rule" | jq -r '.name')
        case "$mode" in
            1) sync_run_rule_background "$name" ;;
            2) sync_run_rule "$name" "false" ;;
            3) sync_run_rule "$name" "true" ;;
        esac
    done
}

sync_edit_rules() {
    if [ -f "$SYNC_RULES_FILE" ]; then
        "${EDITOR:-vim}" "$SYNC_RULES_FILE"
    else
        printf "${C_WARN}No rules file: %s${RST}\n" "$SYNC_RULES_FILE"
    fi
}

sync_show_jobs() {
    local running; running=$(sync_get_running_jobs)
    local count; count=$(echo "$running" | jq 'length')
    if [ "$count" -eq 0 ]; then
        printf "${C_DIM}No running jobs${RST}\n"
        return
    fi
    echo "$running" | jq -c '.[]' | while IFS= read -r job; do
        local name pid; name=$(echo "$job" | jq -r '.name'); pid=$(echo "$job" | jq -r '.pid')
        printf "  ${C_OK}${S_PLAY}${RST} %s (PID: %s)\n" "$name" "$pid"
    done
}

sync_cancel_job() {
    local running; running=$(sync_get_running_jobs)
    local count; count=$(echo "$running" | jq 'length')
    [ "$count" -eq 0 ] && { printf "${C_DIM}No running jobs${RST}\n"; return; }
    sync_show_jobs
    printf "${BLD}Enter PID to cancel:${RST} "
    read -r pid
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        printf "${C_OK}${S_OK}${RST} Cancelled PID %s\n" "$pid"
    else
        printf "${C_ERR}PID not found or not running${RST}\n"
    fi
}

sync_kill_all() {
    local running; running=$(sync_get_running_jobs)
    echo "$running" | jq -r '.[].pid' | while read -r pid; do
        kill -TERM "$pid" 2>/dev/null && printf "${C_OK}${S_OK}${RST} Killed %s\n" "$pid"
    done
}

# =============================================================================
# D) SYNC - Rule Management (Group 2)
# =============================================================================

sync_add_rule() {
    local name="$1" local_path="$2" remote="$3" sync_type="$4"
    local conflict_resolve="${5:-newer}" delete_extra="${6:-true}"

    if [ -n "$(sync_get_rule "$name")" ]; then
        printf "${C_ERR}Rule '%s' already exists${RST}\n" "$name"
        return 1
    fi

    local now; now=$(date -Iseconds)
    local new_rule
    new_rule=$(printf '{"name":"%s","local_path":"%s","remote":"%s","sync_type":"%s","conflict_resolve":"%s","delete_extra":%s,"enabled":true,"last_run":null,"created":"%s"}' \
        "$name" "$local_path" "$remote" "$sync_type" "$conflict_resolve" "$delete_extra" "$now")

    local rules; rules=$(sync_list_rules)
    local updated; updated=$(echo "$rules" | jq ". + [$new_rule]")
    sync_save_rules "$updated"
    printf "${C_OK}${S_OK}${RST} Rule '%s' added\n" "$name"
    log_msg "Added sync rule: $name"
}

sync_delete_rule() {
    local rules; rules=$(sync_list_rules)
    local count; count=$(echo "$rules" | jq 'length')
    [ "$count" -eq 0 ] && { printf "${C_DIM}No rules to delete${RST}\n"; return; }

    printf "\n${BLD}Select rule to delete:${RST}\n"
    local i=0
    while [ "$i" -lt "$count" ]; do
        local name; name=$(echo "$rules" | jq -r ".[$i].name")
        printf "  ${C_INFO}%d${RST}) %s\n" "$((i+1))" "$name"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return

    local idx=$((ch-1))
    local name; name=$(echo "$rules" | jq -r ".[$idx].name // empty")
    [ -z "$name" ] && { printf "${C_ERR}Invalid choice${RST}\n"; return; }

    printf "${C_WARN}Delete rule '%s'? [y/N]:${RST} " "$name"
    read -r confirm
    case "$confirm" in
        [Yy]*)
            local updated; updated=$(echo "$rules" | jq "del(.[] | select(.name == \"$name\"))")
            sync_save_rules "$updated"
            printf "${C_OK}${S_OK}${RST} Deleted rule '%s'\n" "$name"
            log_msg "Deleted sync rule: $name"
            ;;
        *) printf "${C_DIM}Cancelled${RST}\n" ;;
    esac
}

sync_toggle_rule() {
    local rules; rules=$(sync_list_rules)
    local count; count=$(echo "$rules" | jq 'length')
    [ "$count" -eq 0 ] && { printf "${C_DIM}No rules to toggle${RST}\n"; return; }

    printf "\n${BLD}Select rule to toggle:${RST}\n"
    local i=0
    while [ "$i" -lt "$count" ]; do
        local name enabled
        name=$(echo "$rules" | jq -r ".[$i].name")
        enabled=$(echo "$rules" | jq -r ".[$i].enabled")
        local state_str
        [ "$enabled" = "true" ] && state_str="${C_OK}ON${RST}" || state_str="${C_DIM}OFF${RST}"
        printf "  ${C_INFO}%d${RST}) %-20s %b\n" "$((i+1))" "$name" "$state_str"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return

    local idx=$((ch-1))
    local name; name=$(echo "$rules" | jq -r ".[$idx].name // empty")
    [ -z "$name" ] && { printf "${C_ERR}Invalid choice${RST}\n"; return; }

    local current; current=$(echo "$rules" | jq -r ".[$idx].enabled")
    local new_state="true"
    [ "$current" = "true" ] && new_state="false"

    local updated; updated=$(echo "$rules" | jq "(.[] | select(.name == \"$name\") | .enabled) = $new_state")
    sync_save_rules "$updated"
    if [ "$new_state" = "true" ]; then
        printf "${C_OK}${S_OK}${RST} Enabled '%s'\n" "$name"
    else
        printf "${C_WARN}${S_STOP}${RST} Disabled '%s'\n" "$name"
    fi
}

_sync_select_remote_menu() {
    local remotes; remotes=$(rclone listremotes 2>/dev/null | sed 's/:$//')
    if [ -z "$remotes" ]; then
        printf "${C_ERR}No rclone remotes configured. Run 'rclone config' first.${RST}\n"
        return 1
    fi

    printf "\n${BLD}Select Remote:${RST}\n"
    local i=1
    echo "$remotes" | while IFS= read -r r; do
        printf "  ${C_INFO}%d${RST}) %s\n" "$i" "$r"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return 1
    echo "$remotes" | sed -n "${ch}p"
}

_sync_select_type_menu() {
    local include_local="${1:-false}"

    printf "\n${BLD}Select Sync Type:${RST}\n"
    printf "  ${C_INFO}1${RST}) Bisync (%s) - Two-way sync\n" "$S_ARBI"
    printf "  ${C_INFO}2${RST}) Sync to Remote (%s) - Local overwrites remote\n" "$S_ARR"
    printf "  ${C_INFO}3${RST}) Sync to Local (%s) - Remote overwrites local\n" "$S_ARRL"
    [ "$include_local" = "true" ] && printf "  ${C_INFO}4${RST}) Local to Local - Sync between local folders\n"
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice [1]:${RST} "
    read -r ch
    ch="${ch:-1}"

    case "$ch" in
        1) echo "bisync" ;;
        2) echo "sync_to_remote" ;;
        3) echo "sync_to_local" ;;
        4) [ "$include_local" = "true" ] && echo "local_to_local" || return 1 ;;
        0) return 1 ;;
        *) return 1 ;;
    esac
}

sync_add_rule_wizard() {
    printf "\n${BLD}━━━ Add New Sync Rule ━━━${RST}\n\n"

    printf "${BLD}Rule name:${RST} "
    read -r name
    [ -z "$name" ] && { printf "${C_ERR}Name is required${RST}\n"; return 1; }

    if [ -n "$(sync_get_rule "$name")" ]; then
        printf "${C_ERR}Rule '%s' already exists${RST}\n" "$name"
        return 1
    fi

    printf "\n${BLD}Rule type:${RST}\n"
    printf "  ${C_INFO}1${RST}) Remote sync (local ${S_ARBI} cloud)\n"
    printf "  ${C_INFO}2${RST}) Local sync (local ${S_ARBI} local)\n"
    printf "${BLD}Choice [1]:${RST} "
    read -r rule_type
    rule_type="${rule_type:-1}"

    local local_path remote sync_type conflict_resolve delete_extra

    if [ "$rule_type" = "2" ]; then
        printf "\n${BLD}Source folder path:${RST} "
        read -r local_path
        [ -z "$local_path" ] && { printf "${C_ERR}Source path required${RST}\n"; return 1; }

        printf "${BLD}Destination folder path:${RST} "
        read -r remote
        [ -z "$remote" ] && { printf "${C_ERR}Destination path required${RST}\n"; return 1; }

        printf "\n${BLD}Sync direction:${RST}\n"
        printf "  ${C_INFO}1${RST}) One-way (source ${S_ARR} dest, with deletions)\n"
        printf "  ${C_INFO}2${RST}) One-way copy (no deletions)\n"
        printf "  ${C_INFO}3${RST}) Bisync (${S_ARBI} two-way)\n"
        printf "${BLD}Choice [1]:${RST} "
        read -r dir_choice
        dir_choice="${dir_choice:-1}"

        case "$dir_choice" in
            1) sync_type="local_to_local"; delete_extra="true" ;;
            2) sync_type="local_to_local"; delete_extra="false" ;;
            3) sync_type="local_bisync"; delete_extra="true" ;;
            *) sync_type="local_to_local"; delete_extra="true" ;;
        esac

        conflict_resolve="newer"
        if [ "$sync_type" = "local_bisync" ]; then
            printf "\n${BLD}Conflict resolution:${RST}\n"
            printf "  ${C_INFO}1${RST}) newer (default)\n"
            printf "  ${C_INFO}2${RST}) larger\n"
            printf "  ${C_INFO}3${RST}) path1 (source wins)\n"
            printf "  ${C_INFO}4${RST}) path2 (dest wins)\n"
            printf "${BLD}Choice [1]:${RST} "
            read -r cr_choice
            case "$cr_choice" in
                2) conflict_resolve="larger" ;;
                3) conflict_resolve="path1" ;;
                4) conflict_resolve="path2" ;;
                *) conflict_resolve="newer" ;;
            esac
        fi
    else
        local remote_name; remote_name=$(_sync_select_remote_menu)
        [ -z "$remote_name" ] && return 1

        printf "\n${BLD}Remote path (empty for root):${RST} "
        read -r remote_path
        remote="${remote_name}:${remote_path}"

        printf "${BLD}Local path [%s]:${RST} " "$HOME/Documents/Gdrive_Syncs"
        read -r local_path
        local_path="${local_path:-$HOME/Documents/Gdrive_Syncs}"

        sync_type=$(_sync_select_type_menu)
        [ -z "$sync_type" ] && return 1

        delete_extra="true"
        conflict_resolve="newer"

        if [ "$sync_type" = "bisync" ]; then
            printf "\n${BLD}Conflict resolution:${RST}\n"
            printf "  ${C_INFO}1${RST}) newer (default)\n"
            printf "  ${C_INFO}2${RST}) larger\n"
            printf "  ${C_INFO}3${RST}) path1 (remote wins)\n"
            printf "  ${C_INFO}4${RST}) path2 (local wins)\n"
            printf "${BLD}Choice [1]:${RST} "
            read -r cr_choice
            case "$cr_choice" in
                2) conflict_resolve="larger" ;;
                3) conflict_resolve="path1" ;;
                4) conflict_resolve="path2" ;;
                *) conflict_resolve="newer" ;;
            esac
        fi
    fi

    sync_add_rule "$name" "$local_path" "$remote" "$sync_type" "$conflict_resolve" "$delete_extra"
}

sync_quick_menu() {
    printf "\n${BLD}━━━ Quick Sync ━━━${RST}\n\n"

    local sync_type; sync_type=$(_sync_select_type_menu "true")
    [ -z "$sync_type" ] && return 1

    local source dest

    if [ "$sync_type" = "local_to_local" ]; then
        printf "\n${BLD}Source folder:${RST} "
        read -r source
        [ -z "$source" ] && { printf "${C_ERR}Source required${RST}\n"; return 1; }

        printf "${BLD}Destination folder:${RST} "
        read -r dest
        [ -z "$dest" ] && { printf "${C_ERR}Destination required${RST}\n"; return 1; }
    else
        local remote_name; remote_name=$(_sync_select_remote_menu)
        [ -z "$remote_name" ] && return 1

        printf "\n${BLD}Remote path (empty for root):${RST} "
        read -r remote_path
        local remote="${remote_name}:${remote_path}"

        printf "${BLD}Local path [%s]:${RST} " "$HOME/Documents/Gdrive_Syncs"
        read -r local_path
        local_path="${local_path:-$HOME/Documents/Gdrive_Syncs}"

        case "$sync_type" in
            bisync)         source="$remote"; dest="$local_path" ;;
            sync_to_remote) source="$local_path"; dest="$remote" ;;
            sync_to_local)  source="$remote"; dest="$local_path" ;;
        esac
    fi

    printf "\n${BLD}Run mode:${RST}\n"
    printf "  ${C_INFO}1${RST}) Background (returns to menu)\n"
    printf "  ${C_INFO}2${RST}) Foreground (wait for completion)\n"
    printf "  ${C_INFO}3${RST}) Dry run (preview only)\n"
    printf "${BLD}Choice [1]:${RST} "
    read -r mode
    mode="${mode:-1}"

    case "$mode" in
        1)
            local job_id; job_id=$(generate_job_id)
            local job_log="$SYNC_LOG_DIR/${job_id}.log"
            local cmd
            case "$sync_type" in
                bisync|local_bisync) cmd="rclone bisync '$source' '$dest' $RCLONE_SYNC_OPTS -v --stats 3s" ;;
                *) cmd="rclone sync '$source' '$dest' $RCLONE_SYNC_OPTS -v --stats 3s" ;;
            esac
            eval "$cmd" > "$job_log" 2>&1 &
            local pid=$!
            sync_add_job "$job_id" "Quick Sync" "$source" "$dest" "$sync_type" "$pid" "$job_log"
            printf "${C_OK}${S_OK}${RST} Started background sync (PID: %s, Job: %s)\n" "$pid" "$job_id"
            ;;
        2)
            case "$sync_type" in
                bisync|local_bisync) sync_bisync "$source" "$dest" "false" ;;
                *) sync_one_way "$source" "$dest" "false" ;;
            esac
            ;;
        3)
            case "$sync_type" in
                bisync|local_bisync) sync_bisync "$source" "$dest" "true" ;;
                *) sync_one_way "$source" "$dest" "true" ;;
            esac
            ;;
    esac
}

# =============================================================================
# D) SYNC - Ad-hoc CLI & Extra Commands
# =============================================================================

# Ad-hoc one-way sync from CLI: connect.sh sync-to SRC DEST [--dry-run] [--background]
sync_adhoc() {
    local source="$1" dest="$2"
    [ -z "$source" ] || [ -z "$dest" ] && {
        printf "${C_ERR}Usage: connect.sh sync-to SOURCE DEST [--dry-run] [--background]${RST}\n"
        return 1
    }
    shift 2
    local dry_run="false" background="false"
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run="true" ;;
            --background|-bg) background="true" ;;
        esac
        shift
    done

    if [ "$background" = "true" ]; then
        local job_id; job_id=$(generate_job_id)
        local job_log="$SYNC_LOG_DIR/${job_id}.log"
        local cmd="rclone sync '$source' '$dest' $RCLONE_SYNC_OPTS -v --stats 3s --stats-log-level NOTICE"
        [ "$dry_run" = "true" ] && cmd="$cmd --dry-run"
        log_msg "Running adhoc sync: $cmd"
        eval "$cmd" > "$job_log" 2>&1 &
        local pid=$!
        sync_add_job "$job_id" "adhoc-sync" "$source" "$dest" "sync" "$pid" "$job_log"
        printf "${C_OK}${S_OK}${RST} Started adhoc sync (PID: %s, Job: %s)\n" "$pid" "$job_id"
        printf "  Log: %s\n" "$job_log"
    else
        sync_one_way "$source" "$dest" "$dry_run" "true"
    fi
}

# Ad-hoc bisync from CLI: connect.sh bisync-to P1 P2 [--dry-run] [--resync] [--background]
bisync_adhoc() {
    local p1="$1" p2="$2"
    [ -z "$p1" ] || [ -z "$p2" ] && {
        printf "${C_ERR}Usage: connect.sh bisync-to PATH1 PATH2 [--dry-run] [--resync] [--background]${RST}\n"
        return 1
    }
    shift 2
    local dry_run="false" resync="false" background="false"
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run="true" ;;
            --resync) resync="true" ;;
            --background|-bg) background="true" ;;
        esac
        shift
    done

    if [ "$background" = "true" ]; then
        local job_id; job_id=$(generate_job_id)
        local job_log="$SYNC_LOG_DIR/${job_id}.log"
        local cmd="rclone bisync '$p1' '$p2' $RCLONE_SYNC_OPTS -v --stats 3s --stats-log-level NOTICE"
        [ "$resync" = "true" ] && cmd="$cmd --resync"
        [ "$dry_run" = "true" ] && cmd="$cmd --dry-run"
        log_msg "Running adhoc bisync: $cmd"
        eval "$cmd" > "$job_log" 2>&1 &
        local pid=$!
        sync_add_job "$job_id" "adhoc-bisync" "$p1" "$p2" "bisync" "$pid" "$job_log"
        printf "${C_OK}${S_OK}${RST} Started adhoc bisync (PID: %s, Job: %s)\n" "$pid" "$job_id"
        printf "  Log: %s\n" "$job_log"
    else
        sync_bisync "$p1" "$p2" "$dry_run" "$resync"
    fi
}

# Run all enabled in background (non-interactive, no prompt)
sync_run_all_bg() {
    local rules; rules=$(sync_list_rules)
    local enabled; enabled=$(echo "$rules" | jq -c '.[] | select(.enabled == true)')

    if [ -z "$enabled" ]; then
        printf "${C_DIM}No enabled sync rules${RST}\n"
        return
    fi

    printf "\n${BLD}=== Running All Enabled Rules (Background) ===${RST}\n\n"
    local success=0 failed=0
    echo "$enabled" | while IFS= read -r rule; do
        local name; name=$(echo "$rule" | jq -r '.name')
        sync_run_rule_background "$name" && success=$((success+1)) || failed=$((failed+1))
    done
    printf "\n${C_OK}${S_OK}${RST} All rules launched in background\n"
}

# Cancel by job ID (non-interactive CLI)
sync_cancel_by_id() {
    local job_id="$1"
    [ -z "$job_id" ] && { printf "${C_ERR}Usage: connect.sh sync-cancel-id JOB_ID${RST}\n"; return 1; }
    local jobs; jobs=$(cat "$SYNC_JOBS_FILE" 2>/dev/null || echo "[]")
    local pid; pid=$(echo "$jobs" | jq -r ".[] | select(.job_id == \"$job_id\") | .pid")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        sync_update_job "$job_id" "cancelled"
        printf "${C_OK}${S_OK}${RST} Cancelled job %s (PID: %s)\n" "$job_id" "$pid"
    else
        printf "${C_ERR}Job not found or not running: %s${RST}\n" "$job_id"
    fi
}

# Full sync status display (remotes + rules + jobs + log)
sync_full_status() {
    printf "\n${BLD}━━━ Sync Status ━━━${RST}\n\n"

    # Configured Remotes
    printf "  ${C_INFO}${BLD}Configured Remotes${RST}\n"
    printf "  ${C_DIM}────────────────────────────────────────────────${RST}\n"
    if command -v rclone >/dev/null 2>&1; then
        local remotes; remotes=$(rclone listremotes 2>/dev/null | sed 's/:$//')
        if [ -n "$remotes" ]; then
            echo "$remotes" | while read -r r; do
                printf "  ${C_OK}${S_DOT}${RST} %s\n" "$r"
            done
        else
            printf "  ${C_DIM}No remotes configured${RST}\n"
        fi
    else
        printf "  ${C_DIM}rclone not installed${RST}\n"
    fi

    # Rules summary
    local rules; rules=$(sync_list_rules)
    local total; total=$(echo "$rules" | jq 'length')
    local enabled; enabled=$(echo "$rules" | jq '[.[] | select(.enabled == true)] | length')
    local disabled; disabled=$((total - enabled))
    printf "\n  ${C_SYNC}${BLD}Sync Rules${RST}\n"
    printf "  ${C_DIM}────────────────────────────────────────────────${RST}\n"
    printf "  Total: %s | ${C_OK}Enabled: %s${RST} | ${C_DIM}Disabled: %s${RST}\n\n" "$total" "$enabled" "$disabled"

    # Render full sync table
    render_sync

    # Jobs summary
    local running; running=$(sync_get_running_jobs)
    local run_count; run_count=$(echo "$running" | jq 'length')
    printf "\n  ${C_SYNC}${BLD}Background Jobs${RST}: "
    if [ "$run_count" -gt 0 ]; then
        printf "${C_OK}%s running${RST}\n" "$run_count"
    else
        printf "${C_DIM}none${RST}\n"
    fi

    printf "\n"
    view_log
}

# Restore symlinks (from gcl.sh)
restore_symlinks() {
    local script="$SCRIPT_DIR/restore-spec-symlinks.sh"
    if [ ! -f "$script" ]; then
        printf "${C_WARN}No restore-spec-symlinks.sh found in %s${RST}\n" "$SCRIPT_DIR"
        printf "${C_DIM}This script restores 0.spec symlinks in the git workdir${RST}\n"
        return 1
    fi
    printf "${BLD}=== Restoring Spec Symlinks ===${RST}\n\n"
    bash "$script" "$GIT_WORKDIR"
}

# Config-set CLI: connect.sh config-set KEY VALUE
config_set() {
    local key="$1" value="$2"
    if [ -z "$key" ] || [ -z "$value" ]; then
        printf "${C_ERR}Usage: connect.sh config-set KEY VALUE${RST}\n\n"
        printf "${BLD}Available keys:${RST}\n"
        printf "  git_workdir       Git working directory\n"
        printf "  mount_dir         Mount base directory\n"
        printf "  sync_dir          Sync rules directory\n"
        printf "  rclone_opts       Rclone mount options\n"
        printf "  rclone_sync_opts  Rclone sync options\n"
        printf "  log_file          Log file name\n"
        printf "  merge_strategy    Git merge strategy (ours/theirs)\n\n"
        printf "${BLD}Current values:${RST}\n"
        printf "  git_workdir       = %s\n" "$GIT_WORKDIR"
        printf "  mount_dir         = %s\n" "$MOUNT_DIR"
        printf "  sync_dir          = %s\n" "$SYNC_DIR"
        printf "  rclone_opts       = %s\n" "$RCLONE_OPTS"
        printf "  rclone_sync_opts  = %s\n" "$RCLONE_SYNC_OPTS"
        printf "  log_file          = %s\n" "$LOG_FILE_NAME"
        printf "  merge_strategy    = %s\n" "$MERGE_STRATEGY"
        return 1
    fi
    case "$key" in
        git_workdir|mount_dir|sync_dir|rclone_opts|rclone_sync_opts|log_file|merge_strategy)
            update_setting "$key" "$value"
            printf "${C_OK}${S_OK}${RST} %s = %s\n" "$key" "$value"
            ;;
        *)
            printf "${C_ERR}Unknown setting: %s${RST}\n" "$key"
            printf "${C_DIM}Valid keys: git_workdir, mount_dir, sync_dir, rclone_opts, rclone_sync_opts, log_file, merge_strategy${RST}\n"
            return 1
            ;;
    esac
}

# =============================================================================
# CONFIG & SYSTEM MANAGEMENT (Group 4)
# =============================================================================

update_setting() {
    local key="$1" value="$2"
    local mfile; mfile=$(_module_for_settings_key "$key")
    _jq_write "$mfile" --arg k "$key" --arg v "$value" '.settings[$k] = $v'
    log_msg "Setting updated: $key = $value (module: $(basename "$mfile"))"
}

settings_menu() {
    printf "\n${BLD}━━━ Settings ━━━${RST}\n\n"
    printf "  ${C_INFO}1${RST}  Git workdir:     ${C_OK}%s${RST}\n" "$GIT_WORKDIR"
    printf "  ${C_INFO}2${RST}  Mount directory:  ${C_OK}%s${RST}\n" "$MOUNT_DIR"
    printf "  ${C_INFO}3${RST}  Sync directory:   ${C_OK}%s${RST}\n" "$SYNC_DIR"
    printf "  ${C_INFO}4${RST}  Rclone mount opts:${C_OK}%s${RST}\n" "$RCLONE_OPTS"
    printf "  ${C_INFO}5${RST}  Rclone sync opts: ${C_OK}%s${RST}\n" "$RCLONE_SYNC_OPTS"
    printf "  ${C_INFO}6${RST}  Log file:         ${C_OK}%s${RST}\n" "$LOG_FILE_NAME"
    printf "  ${C_INFO}7${RST}  Merge strategy:   ${C_OK}%s${RST}\n" "$MERGE_STRATEGY"
    printf "\n"
    printf "  ${C_DIM}e${RST}  Edit config module\n"
    printf "  ${C_DIM}0${RST}  Back\n"
    printf "\n${BLD}Choice:${RST} "
    read -r choice

    case "$choice" in
        1) edit_workdir ;;
        2)
            printf "\n${BLD}New mount directory:${RST} "
            read -r new_dir
            if [ -n "$new_dir" ]; then
                new_dir=$(eval echo "$new_dir")
                [ ! -d "$new_dir" ] && { printf "Create? [y/N] "; read -r c; case "$c" in [Yy]*) mkdir -p "$new_dir" ;; *) return ;; esac; }
                update_setting "mount_dir" "$new_dir"
                printf "${C_OK}${S_OK}${RST} Mount directory updated. Restart to apply.\n"
            fi ;;
        3)
            printf "\n${BLD}New sync directory:${RST} "
            read -r new_dir
            if [ -n "$new_dir" ]; then
                new_dir=$(eval echo "$new_dir")
                [ ! -d "$new_dir" ] && mkdir -p "$new_dir"
                update_setting "sync_dir" "$new_dir"
                printf "${C_OK}${S_OK}${RST} Sync directory updated. Restart to apply.\n"
            fi ;;
        4)
            printf "\n${BLD}Current:${RST} %s\n" "$RCLONE_OPTS"
            printf "${C_DIM}Common: --vfs-cache-mode off|minimal|writes|full${RST}\n"
            printf "${BLD}New rclone mount options:${RST} "
            read -r new_opts
            [ -n "$new_opts" ] && { update_setting "rclone_opts" "$new_opts"; printf "${C_OK}${S_OK}${RST} Updated. Restart to apply.\n"; }
            ;;
        5)
            printf "\n${BLD}Current:${RST} %s\n" "$RCLONE_SYNC_OPTS"
            printf "${BLD}New rclone sync options:${RST} "
            read -r new_opts
            [ -n "$new_opts" ] && { update_setting "rclone_sync_opts" "$new_opts"; printf "${C_OK}${S_OK}${RST} Updated. Restart to apply.\n"; }
            ;;
        6)
            printf "\n${BLD}New log file name:${RST} "
            read -r new_log
            [ -n "$new_log" ] && { update_setting "log_file" "$new_log"; printf "${C_OK}${S_OK}${RST} Updated. Restart to apply.\n"; }
            ;;
        7) git_toggle_merge ;;
        e|E) edit_config ;;
        0) return ;;
        *) printf "${C_ERR}Invalid choice${RST}\n" ;;
    esac
}

create_rclone_remote() {
    local remote="$1" remote_type="$2"

    printf "\n${BLD}Creating rclone remote: %s${RST}\n" "$remote"

    case "$remote_type" in
        drive)
            printf "${C_WARN}This will open a browser for Google OAuth.${RST}\n"
            printf "Press Enter to continue or Ctrl+C to cancel..."
            read -r _
            rclone config create "$remote" drive scope=drive
            if rclone_remote_exists "$remote"; then
                printf "${C_OK}${S_OK}${RST} Remote '%s' created\n" "$remote"
                log_msg "Remote created: $remote"
                return 0
            else
                printf "${C_ERR}${S_FAIL}${RST} Failed to create '%s'\n" "$remote"
                return 1
            fi ;;
        sftp)
            printf "${BLD}SSH host:${RST} "
            read -r ssh_host
            printf "${BLD}SSH user:${RST} "
            read -r ssh_user
            printf "${BLD}SSH key path (empty for password):${RST} "
            read -r ssh_key
            if [ -n "$ssh_key" ]; then
                rclone config create "$remote" sftp host="$ssh_host" user="$ssh_user" key_file="$ssh_key"
            else
                rclone config create "$remote" sftp host="$ssh_host" user="$ssh_user"
            fi
            if rclone_remote_exists "$remote"; then
                printf "${C_OK}${S_OK}${RST} Remote '%s' created\n" "$remote"
                log_msg "Remote created: $remote"
                return 0
            else
                printf "${C_ERR}${S_FAIL}${RST} Failed to create '%s'\n" "$remote"
                return 1
            fi ;;
        *)
            printf "${C_ERR}Unknown remote type: %s${RST}\n" "$remote_type"
            return 1 ;;
    esac
}

prompt_create_remote() {
    local remote="$1"
    local remote_type
    case "$remote" in
        Gdrive_*) remote_type="drive" ;;
        OCI_*|GCP_*) remote_type="sftp" ;;
        *) remote_type="sftp" ;;
    esac

    printf "\n${C_WARN}Remote '%s' is not configured.${RST}\n" "$remote"
    printf "Create it now? [y/N] "
    read -r answer
    case "$answer" in
        [Yy]*) create_rclone_remote "$remote" "$remote_type"; return $? ;;
        *) printf "${C_DIM}Skipped${RST}\n"; return 1 ;;
    esac
}

configure_remote_menu() {
    printf "\n${BLD}━━━ Configure Rclone Remotes ━━━${RST}\n\n"
    printf "${C_DIM}Current remotes: %s${RST}\n\n" "$(rclone listremotes 2>/dev/null | tr '\n' ' ')"

    # Show drives status
    printf "  ${C_DRIVE}Drives:${RST}\n"
    local drive_count; drive_count=$(_jq '.fuse_drives | length')
    local d=0
    while [ "$d" -lt "$drive_count" ]; do
        local dremote; dremote=$(_jq -r ".fuse_drives[$d].remote")
        if rclone_remote_exists "$dremote"; then
            printf "    ${C_OK}${S_OK}${RST} %s (configured)\n" "$dremote"
        else
            printf "    ${C_ERR}${S_FAIL}${RST} %s (missing)\n" "$dremote"
        fi
        d=$((d+1))
    done

    # Show VMs status
    printf "\n  ${C_MESH}VMs (SFTP):${RST}\n"
    local vm_count; vm_count=$(_jq '.mesh.vms | length')
    local v=0
    while [ "$v" -lt "$vm_count" ]; do
        local vremote; vremote=$(_jq -r ".mesh.vms[$v].remote")
        if rclone_remote_exists "$vremote"; then
            printf "    ${C_OK}${S_OK}${RST} %s (configured)\n" "$vremote"
        else
            printf "    ${C_ERR}${S_FAIL}${RST} %s (missing)\n" "$vremote"
        fi
        v=$((v+1))
    done

    printf "\n${BLD}Options:${RST}\n"
    # Build dynamic menu from config
    local idx=1
    local menu_items=""

    d=0
    while [ "$d" -lt "$drive_count" ]; do
        local dn; dn=$(_jq -r ".fuse_drives[$d].remote")
        printf "  ${C_INFO}%d${RST}) %s ${C_DIM}(drive)${RST}\n" "$idx" "$dn"
        menu_items="${menu_items}${idx}:drive:${dn}\n"
        idx=$((idx+1))
        d=$((d+1))
    done
    v=0
    while [ "$v" -lt "$vm_count" ]; do
        local vn; vn=$(_jq -r ".mesh.vms[$v].remote")
        printf "  ${C_INFO}%d${RST}) %s ${C_DIM}(sftp)${RST}\n" "$idx" "$vn"
        menu_items="${menu_items}${idx}:sftp:${vn}\n"
        idx=$((idx+1))
        v=$((v+1))
    done
    printf "  ${C_INFO}c${RST}) Custom remote\n"
    printf "  ${C_INFO}t${RST}) Run rclone config TUI\n"
    printf "  ${C_DIM}0${RST}) Cancel\n"
    printf "${BLD}Choice:${RST} "
    read -r ch

    case "$ch" in
        0) return ;;
        c|C)
            printf "${BLD}Remote name:${RST} "
            read -r rname
            printf "${BLD}Type (drive/sftp):${RST} "
            read -r rtype
            create_rclone_remote "$rname" "$rtype" ;;
        t|T) rclone config ;;
        *)
            local entry; entry=$(printf '%b' "$menu_items" | grep "^${ch}:")
            if [ -n "$entry" ]; then
                local rtype rname
                rtype=$(echo "$entry" | cut -d: -f2)
                rname=$(echo "$entry" | cut -d: -f3)
                create_rclone_remote "$rname" "$rtype"
            else
                printf "${C_ERR}Invalid choice${RST}\n"
            fi ;;
    esac
}

_detect_distro() {
    if [ -f /etc/os-release ]; then
        local id; id=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        echo "$id"
    else
        echo "unknown"
    fi
}

_get_pkg_cmd() {
    local distro; distro=$(_detect_distro)
    case "$distro" in
        nixos)          echo "nix-env -iA nixpkgs." ;;
        arch|manjaro)   echo "sudo pacman -S --noconfirm " ;;
        debian|ubuntu|pop) echo "sudo apt install -y " ;;
        fedora)         echo "sudo dnf install -y " ;;
        alpine)         echo "sudo apk add " ;;
        *)              echo "" ;;
    esac
}

_dep_version() {
    local dep="$1"
    case "$dep" in
        git)              git --version 2>/dev/null | awk '{print $3}' ;;
        jq)               jq --version 2>/dev/null | sed 's/^jq-//' ;;
        rclone)           rclone version 2>/dev/null | head -1 | awk '{print $2}' ;;
        fusermount)       fusermount --version 2>/dev/null | awk '{print $NF}' ;;
        gh)               gh --version 2>/dev/null | head -1 | awk '{print $3}' ;;
        oci)              oci --version 2>/dev/null | awk '{print $3}' ;;
        gcloud)           gcloud --version 2>/dev/null | head -1 | awk '{print $NF}' ;;
        kdeconnect-cli)   kdeconnect-cli --version 2>/dev/null | awk '{print $NF}' ;;
        qdbus)            echo "system" ;;
        *)                echo "?" ;;
    esac
}

_dep_pkg_name() {
    local dep="$1" distro="$2"
    # Distro-specific package name mapping
    case "$dep" in
        fusermount)
            case "$distro" in
                nixos)          echo "fuse3" ;;
                arch|manjaro)   echo "fuse3" ;;
                debian|ubuntu|pop) echo "fuse3" ;;
                fedora)         echo "fuse3" ;;
                *)              echo "fuse3" ;;
            esac ;;
        kdeconnect-cli)
            case "$distro" in
                nixos)          echo "kdeconnect" ;;
                arch|manjaro)   echo "kdeconnect" ;;
                debian|ubuntu|pop) echo "kdeconnect" ;;
                *)              echo "kdeconnect" ;;
            esac ;;
        qdbus)
            case "$distro" in
                nixos)          echo "qt5.qttools" ;;
                arch|manjaro)   echo "qt5-tools" ;;
                debian|ubuntu|pop) echo "qttools5-dev-tools" ;;
                *)              echo "qdbus" ;;
            esac ;;
        gh)
            case "$distro" in
                nixos)          echo "gh" ;;
                debian|ubuntu|pop) echo "gh" ;;
                *)              echo "gh" ;;
            esac ;;
        *)  echo "$dep" ;;
    esac
}

deps_menu() {
    printf "\n${BLD}━━━ Dependencies ━━━${RST}\n\n"

    local distro; distro=$(_detect_distro)
    printf "  ${C_DIM}Distro:${RST} ${C_INFO}%s${RST}\n\n" "$distro"

    # Categorized deps
    local categories="Core Phone Cloud"
    local deps_core="git jq rclone fusermount ssh ping clear tput"
    local deps_phone="kdeconnect-cli qdbus"
    local deps_cloud="oci gh gcloud docker"

    local missing_required=0 missing_optional=0

    for cat in $categories; do
        local deps_var="deps_$(echo "$cat" | tr '[:upper:]' '[:lower:]')"
        local deps_list="${!deps_var}"
        local cat_color="$C_INFO"
        local is_required="false"

        case "$cat" in
            Core)  cat_color="$C_OK"; is_required="true" ;;
            Phone) cat_color="$C_WARN" ;;
            Cloud) cat_color="$C_INFO" ;;
        esac

        printf "  %b${BLD}%s${RST}" "$cat_color" "$cat"
        [ "$is_required" = "true" ] && printf " ${C_DIM}(required)${RST}" || printf " ${C_DIM}(optional)${RST}"
        printf "\n"

        for dep in $deps_list; do
            if command -v "$dep" >/dev/null 2>&1; then
                local ver; ver=$(_dep_version "$dep")
                printf "    ${C_OK}${S_OK}${RST} %-20s ${C_DIM}%s${RST}\n" "$dep" "$ver"
            else
                local pkg; pkg=$(_dep_pkg_name "$dep" "$distro")
                if [ "$is_required" = "true" ]; then
                    printf "    ${C_ERR}${S_FAIL}${RST} %-20s ${C_DIM}(missing → %s)${RST}\n" "$dep" "$pkg"
                    missing_required=$((missing_required + 1))
                else
                    printf "    ${C_WARN}${S_STOP}${RST} %-20s ${C_DIM}(not installed → %s)${RST}\n" "$dep" "$pkg"
                    missing_optional=$((missing_optional + 1))
                fi
            fi
        done
        printf "\n"
    done

    printf "${BLD}Actions:${RST}\n"
    printf "  ${C_INFO}1${RST}) Install missing required deps"
    [ "$missing_required" -gt 0 ] && printf " ${C_WARN}(%d missing)${RST}" "$missing_required"
    printf "\n"
    printf "  ${C_INFO}2${RST}) Install all missing deps"
    local total_missing=$((missing_required + missing_optional))
    [ "$total_missing" -gt 0 ] && printf " ${C_WARN}(%d missing)${RST}" "$total_missing"
    printf "\n"
    printf "  ${C_DIM}0${RST}) Back\n"
    printf "${BLD}Choice:${RST} "
    read -r ch

    case "$ch" in
        1) install_deps_category "core" ;;
        2) install_deps_category "core"; install_deps_category "phone"; install_deps_category "cloud" ;;
        0) return ;;
        *) printf "${C_ERR}Invalid choice${RST}\n" ;;
    esac
}

install_dep() {
    local dep="$1"
    local distro; distro=$(_detect_distro)

    if command -v "$dep" >/dev/null 2>&1; then
        printf "${C_DIM}%s already installed${RST}\n" "$dep"
        return 0
    fi

    # Resolve distro-specific package name
    local pkg; pkg=$(_dep_pkg_name "$dep" "$distro")

    if [ "$distro" = "nixos" ]; then
        printf "${C_WARN}NixOS detected. Options:${RST}\n"
        local snippet="environment.systemPackages = [ pkgs.$pkg ];"
        printf "  ${C_INFO}1${RST}) Add to flake/configuration.nix: ${C_INFO}%s${RST}\n" "$snippet"
        printf "  ${C_INFO}2${RST}) Temporary shell: ${C_INFO}nix-shell -p %s${RST}\n" "$pkg"
        printf "  ${C_INFO}3${RST}) Install to user profile (nix-env, not recommended)\n"
        printf "  ${C_DIM}0${RST}) Skip\n"
        printf "${BLD}Choice [0]:${RST} "
        read -r answer
        case "$answer" in
            1)
                # Copy snippet to clipboard if possible
                if command -v wl-copy >/dev/null 2>&1; then
                    printf '%s' "$snippet" | wl-copy 2>/dev/null
                    printf "${C_OK}${S_OK}${RST} Copied to clipboard: %s\n" "$snippet"
                elif command -v xclip >/dev/null 2>&1; then
                    printf '%s' "$snippet" | xclip -selection clipboard 2>/dev/null
                    printf "${C_OK}${S_OK}${RST} Copied to clipboard: %s\n" "$snippet"
                else
                    printf "${C_INFO}Add this to configuration.nix:${RST} %s\n" "$snippet"
                fi
                return 0 ;;
            2) printf "${C_INFO}Run:${RST} nix-shell -p %s\n" "$pkg"; return 0 ;;
            3) nix-env -iA "nixpkgs.$pkg"; return $? ;;
            *) printf "${C_DIM}Skipped${RST}\n"; return 1 ;;
        esac
    fi

    # Arch: try AUR helpers if pacman fails
    if [ "$distro" = "arch" ] || [ "$distro" = "manjaro" ]; then
        if ! pacman -Si "$pkg" >/dev/null 2>&1; then
            local aur_helper=""
            command -v yay >/dev/null 2>&1 && aur_helper="yay"
            command -v paru >/dev/null 2>&1 && aur_helper="paru"
            if [ -n "$aur_helper" ]; then
                printf "${C_INFO}Installing %s from AUR via %s...${RST}\n" "$pkg" "$aur_helper"
                "$aur_helper" -S --noconfirm "$pkg"
                return $?
            else
                printf "${C_WARN}%s not in official repos. Install yay/paru for AUR.${RST}\n" "$pkg"
                return 1
            fi
        fi
    fi

    local pkg_cmd; pkg_cmd=$(_get_pkg_cmd)
    if [ -z "$pkg_cmd" ]; then
        printf "${C_ERR}Unknown distro. Install manually: %s${RST}\n" "$pkg"
        return 1
    fi

    printf "${C_INFO}Installing %s (package: %s)...${RST}\n" "$dep" "$pkg"
    # shellcheck disable=SC2086
    ${pkg_cmd}${pkg}
    return $?
}

install_deps_category() {
    local category="$1"
    local deps_list=""
    case "$category" in
        core)  deps_list="git jq rclone fusermount" ;;
        phone) deps_list="kdeconnect-cli qdbus" ;;
        cloud) deps_list="oci gh gcloud" ;;
        *)     printf "${C_ERR}Unknown category: %s${RST}\n" "$category"; return 1 ;;
    esac

    local distro; distro=$(_detect_distro)

    # NixOS batch mode: collect all missing and present as batch
    if [ "$distro" = "nixos" ]; then
        local missing_pkgs=""
        for dep in $deps_list; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                local pkg; pkg=$(_dep_pkg_name "$dep" "$distro")
                missing_pkgs="${missing_pkgs}${missing_pkgs:+ }${pkg}"
            fi
        done
        if [ -z "$missing_pkgs" ]; then
            printf "${C_OK}${S_OK}${RST} All %s deps installed\n" "$category"
            return 0
        fi
        printf "\n${C_WARN}NixOS — Missing %s packages:${RST} %s\n\n" "$category" "$missing_pkgs"
        printf "${BLD}How to install:${RST}\n"
        printf "  ${C_INFO}1${RST}) Open nix-shell with packages ${C_DIM}(temporary)${RST}\n"
        printf "  ${C_INFO}2${RST}) Copy configuration.nix snippet ${C_DIM}(persistent, recommended)${RST}\n"
        printf "  ${C_INFO}3${RST}) Install to user profile ${C_DIM}(nix-env, not recommended)${RST}\n"
        printf "  ${C_DIM}0${RST}) Skip\n"
        printf "${BLD}Choice [0]:${RST} "
        read -r ch
        case "$ch" in
            1)
                printf "\n${C_INFO}Run:${RST} nix-shell -p %s\n" "$missing_pkgs"
                printf "${C_DIM}Or:${RST}  nix-shell -p %s --run '%s'\n" "$missing_pkgs" "$0"
                printf "\nOpen nix-shell now? [y/N] "
                read -r yn
                case "$yn" in
                    [Yy]*) nix-shell -p $missing_pkgs ;;
                    *) printf "${C_DIM}Skipped${RST}\n" ;;
                esac ;;
            2)
                local snippet="environment.systemPackages = with pkgs; ["
                for pkg in $missing_pkgs; do snippet="$snippet $pkg"; done
                snippet="$snippet ];"
                printf "\n${C_INFO}Add to configuration.nix:${RST}\n  %s\n" "$snippet"
                if command -v wl-copy >/dev/null 2>&1; then
                    printf '%s' "$snippet" | wl-copy 2>/dev/null
                    printf "${C_OK}${S_OK}${RST} Copied to clipboard (wl-copy)\n"
                elif command -v xclip >/dev/null 2>&1; then
                    printf '%s' "$snippet" | xclip -selection clipboard 2>/dev/null
                    printf "${C_OK}${S_OK}${RST} Copied to clipboard (xclip)\n"
                fi ;;
            3)
                for pkg in $missing_pkgs; do
                    printf "${C_INFO}Installing %s...${RST}\n" "$pkg"
                    nix-env -iA "nixpkgs.$pkg" || true
                done ;;
            *) printf "${C_DIM}Skipped${RST}\n" ;;
        esac
        return 0
    fi

    # Non-NixOS: install one by one
    local missing=0
    for dep in $deps_list; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            install_dep "$dep"
            missing=$((missing+1))
        fi
    done
    [ "$missing" -eq 0 ] && printf "${C_OK}${S_OK}${RST} All %s deps installed\n" "$category"
}

install_all_deps() {
    local scope="${1:-required}"
    local deps

    if [ "$scope" = "all" ]; then
        deps=$(_jq -r '(.dependencies.required[], .dependencies.optional[])')
    else
        deps=$(_jq -r '.dependencies.required[]')
    fi

    local missing=0
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if ! command -v "$dep" >/dev/null 2>&1; then
            install_dep "$dep"
            missing=$((missing+1))
        fi
    done <<< "$deps"

    [ "$missing" -eq 0 ] && printf "${C_OK}${S_OK}${RST} All dependencies installed\n"
}

clear_log() {
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
        printf "${C_OK}${S_OK}${RST} Log cleared\n"
        log_msg "Log cleared"
    else
        printf "${C_DIM}No log file${RST}\n"
    fi
}

view_log() {
    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        printf "${C_DIM}Log is empty${RST}\n"
        return
    fi

    # Log info header
    local fsize line_count err_count warn_count
    fsize=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
    line_count=$(wc -l < "$LOG_FILE" 2>/dev/null)
    err_count=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo 0)
    warn_count=$(grep -c "WARN" "$LOG_FILE" 2>/dev/null || echo 0)

    printf "\n${BLD}━━━ Log (%s) ━━━${RST}\n" "$LOG_FILE"
    printf "  ${C_DIM}Size: %s | Lines: %s | Errors: ${RST}" "$fsize" "$line_count"
    [ "$err_count" -gt 0 ] && printf "${C_ERR}%s${RST}" "$err_count" || printf "${C_OK}%s${RST}" "$err_count"
    printf " ${C_DIM}| Warnings: ${RST}"
    [ "$warn_count" -gt 0 ] && printf "${C_WARN}%s${RST}" "$warn_count" || printf "${C_OK}%s${RST}" "$warn_count"
    printf "\n\n"

    tail -30 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -q "ERROR"; then
            printf "  ${C_ERR}%s${RST}\n" "$line"
        elif echo "$line" | grep -q "WARN"; then
            printf "  ${C_WARN}%s${RST}\n" "$line"
        else
            printf "  ${C_DIM}%s${RST}\n" "$line"
        fi
    done
}

edit_workdir() {
    local local_dir; local_dir=$(pwd)

    printf "\n${BLD}=== Edit Git Working Directory ===${RST}\n\n"
    printf "  Current:  ${C_INFO}%s${RST}\n" "$GIT_WORKDIR"
    printf "  Local:    ${C_DIM}%s${RST}\n\n" "$local_dir"

    printf "  ${C_INFO}1${RST}) Use current directory (%s)\n" "$local_dir"
    printf "  ${C_INFO}2${RST}) Enter custom path\n"
    printf "  ${C_DIM}0${RST}) Cancel\n"
    printf "\n${BLD}Choice [1]:${RST} "
    read -r choice
    choice="${choice:-1}"

    local new_path
    case "$choice" in
        1) new_path="$local_dir" ;;
        2)
            printf "\n${BLD}Enter path:${RST} "
            read -r new_path
            [ -z "$new_path" ] && { printf "${C_DIM}Cancelled${RST}\n"; return; }
            new_path=$(echo "$new_path" | sed "s|^~|$HOME|")
            ;;
        0) return ;;
        *) printf "${C_ERR}Invalid choice${RST}\n"; return ;;
    esac

    if [ ! -d "$new_path" ]; then
        printf "${C_WARN}Directory does not exist: %s${RST}\n" "$new_path"
        printf "Create it? [y/N] "
        read -r create
        case "$create" in
            [Yy]*) mkdir -p "$new_path" || { printf "${C_ERR}Failed to create directory${RST}\n"; return; } ;;
            *) printf "${C_DIM}Cancelled${RST}\n"; return ;;
        esac
    fi

    update_setting "git_workdir" "$new_path"
    GIT_WORKDIR="$new_path"
    printf "${C_OK}${S_OK}${RST} Git workdir updated to: %s\n" "$new_path"
}

edit_config() {
    printf "\n${BLD}Select config module to edit:${RST}\n"
    local i=1 mfile
    for mfile in "${CC_MODULES[@]}"; do
        printf "  ${C_INFO}%d${RST}) %s\n" "$i" "$(basename "$mfile")"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return
    local idx=$((ch-1))
    local target="${CC_MODULES[$idx]}"
    [ -z "$target" ] && { printf "${C_ERR}Invalid choice${RST}\n"; return; }
    "${EDITOR:-vim}" "$target"
    _reload_config_json
    printf "${C_OK}${S_OK}${RST} Reloaded.\n"
}

# =============================================================================
# E) DATA SERVERS - Rclone serve / Node HTTP / Unison
# =============================================================================

# ── Resolve tilde/vars in path strings ──
_srv_expand_path() { echo "$1" | sed "s|\\\$HOME|$HOME|;s|~|$HOME|"; }

# ── Sops credential loading (lazy, cached for session) ──
_SRV_SOPS_USER="" _SRV_SOPS_PASS="" _SRV_SOPS_LOADED="false"
_srv_load_sops() {
    [ "$_SRV_SOPS_LOADED" = "true" ] && return 0
    if ! command -v sops >/dev/null 2>&1; then
        printf "  ${C_WARN}sops not found — cannot load secrets${RST}\n" >&2; return 1
    fi
    local age_key="" secrets_file=""
    local i=0 cnt
    cnt=$(_jq '.server_settings.age_key_paths | length')
    while [ "$i" -lt "$cnt" ]; do
        local p; p=$(_srv_expand_path "$(_jq -r ".server_settings.age_key_paths[$i]")")
        [ -f "$p" ] && { age_key="$p"; break; }
        i=$((i+1))
    done
    [ -z "$age_key" ] && { printf "  ${C_WARN}age key not found${RST}\n" >&2; return 1; }
    i=0; cnt=$(_jq '.server_settings.secrets_paths | length')
    while [ "$i" -lt "$cnt" ]; do
        local p; p=$(_srv_expand_path "$(_jq -r ".server_settings.secrets_paths[$i]")")
        [ -f "$p" ] && { secrets_file="$p"; break; }
        i=$((i+1))
    done
    [ -z "$secrets_file" ] && { printf "  ${C_WARN}secrets.yaml not found${RST}\n" >&2; return 1; }
    local decrypted
    decrypted=$(SOPS_AGE_KEY_FILE="$age_key" sops -d --output-type dotenv "$secrets_file" 2>/dev/null) || return 1
    _SRV_SOPS_USER=$(echo "$decrypted" | grep '^SYNC_USER=' | head -1 | sed "s/^SYNC_USER=//;s/^['\"]//;s/['\"]$//")
    _SRV_SOPS_PASS=$(echo "$decrypted" | grep '^SYNC_PASS=' | head -1 | sed "s/^SYNC_PASS=//;s/^['\"]//;s/['\"]$//")
    [ -z "$_SRV_SOPS_USER" ] && _SRV_SOPS_USER="termux"
    _SRV_SOPS_LOADED="true"
}

# ── TLS cert management ──
_srv_ensure_certs() {
    local cert_dir; cert_dir=$(_srv_expand_path "$(_jq -r '.server_settings.cert_dir')")
    if [ ! -f "$cert_dir/cert.pem" ] || [ ! -f "$cert_dir/key.pem" ]; then
        if ! command -v openssl >/dev/null 2>&1; then
            printf "  ${C_WARN}openssl not found — cannot generate certs${RST}\n" >&2; return 1
        fi
        mkdir -p "$cert_dir"
        openssl req -x509 -newkey rsa:2048 -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
            -days 365 -nodes -subj "/CN=connect-local" 2>/dev/null
        printf "  ${C_OK}Generated SSL certificate in %s${RST}\n" "$cert_dir"
    fi
    echo "$cert_dir"
}

# ── Find the HTTP static server script ──
_srv_find_http_server() {
    local i=0 cnt
    cnt=$(_jq '.server_settings.http_server_paths | length')
    while [ "$i" -lt "$cnt" ]; do
        local p; p=$(_srv_expand_path "$(_jq -r ".server_settings.http_server_paths[$i]")")
        [ -f "$p" ] && { echo "$p"; return 0; }
        i=$((i+1))
    done
    return 1
}

# ── Log dir for server output ──
_srv_log_dir() {
    local d; d=$(_srv_expand_path "$(_jq -r '.server_settings.log_dir')")
    mkdir -p "$d"; echo "$d"
}

# ── System-based PID detection: query ss + pgrep, never trust PID files ──
# Returns: PID or empty string
_srv_detect_pid() {
    local stype="$1" sport="$2"
    local pid=""
    # 1) Try ss to find PID listening on that port
    if command -v ss >/dev/null 2>&1; then
        pid=$(ss -tlnp 2>/dev/null | grep ":${sport} " | grep -oP 'pid=\K[0-9]+' | head -1)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
        pid=""
    fi
    # 2) Fallback: pgrep by process pattern
    case "$stype" in
        webdav|sftp) pid=$(pgrep -f "rclone serve $stype.*:${sport}\b" 2>/dev/null | head -1) ;;
        http)        pid=$(pgrep -f "node.*web-server-md-eruda.*${sport}" 2>/dev/null | head -1) ;;
    esac
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
    # 3) Broader pgrep fallback (any rclone serve on that port)
    pid=$(pgrep -f "rclone serve.*${sport}" 2>/dev/null | head -1)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
    return 1
}

# ── Get bind address from live process (via ss) ──
_srv_detect_bind() {
    local sport="$1"
    if command -v ss >/dev/null 2>&1; then
        local addr; addr=$(ss -tlnp 2>/dev/null | grep ":${sport} " | awk '{print $4}' | head -1)
        [ -n "$addr" ] && { echo "$addr"; return; }
    fi
    echo "?:$sport"
}

# ── Count established connections on a port ──
_srv_client_count() {
    local sport="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tnp 2>/dev/null | grep ":${sport} " | grep -c "ESTAB" || echo 0
    else
        echo "?"
    fi
}

# ── Get process uptime ──
_srv_uptime() {
    local pid="$1"
    local secs; secs=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$secs" ] && { echo "?"; return; }
    if [ "$secs" -lt 60 ] 2>/dev/null; then echo "${secs}s"
    elif [ "$secs" -lt 3600 ] 2>/dev/null; then echo "$((secs / 60))m"
    else echo "$((secs / 3600))h$((secs % 3600 / 60))m"; fi
}

# ── Render server table ──
render_servers() {
    [ -z "$CC_DATA" ] && collect_all
    printf "  ${BLD}%-15s %-7s %-6s %-18s %-20s %-6s %-7s %-4s %-5s${RST}\n" \
        "DATA SERVERS" "Type" "Port" "Bind" "Root" "Auth" "State" "Conn" "Up"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local srv_count; srv_count=$(_d '.servers.data_servers | length')
    local s=0
    while [ "$s" -lt "$srv_count" ]; do
        local sname stype sport sroot sauth stls smode running bind_addr clients uptime_str
        sname=$(_d -r ".servers.data_servers[$s].name")
        stype=$(_d -r ".servers.data_servers[$s].type")
        sport=$(_d -r ".servers.data_servers[$s].port")
        sroot=$(_d -r ".servers.data_servers[$s].root")
        sauth=$(_d -r ".servers.data_servers[$s].auth")
        stls=$(_d -r ".servers.data_servers[$s].tls")
        smode=$(_d -r ".servers.data_servers[$s].mode")
        running=$(_d -r ".servers.data_servers[$s].running")
        bind_addr=$(_d -r ".servers.data_servers[$s].bind")
        clients=$(_d -r ".servers.data_servers[$s].clients")
        uptime_str=$(_d -r ".servers.data_servers[$s].uptime")

        local type_label="$stype"
        [ "$stls" = "true" ] && type_label="${stype}+tls"

        if [ "$running" = "true" ]; then
            printf "  %-15s %-7s %-6s %-18s %-20s %-6s ${C_OK}${S_RUN} RUN${RST}  %-4s %-5s\n" \
                "$sname" "$type_label" "$sport" "$bind_addr" "$sroot" "$sauth" "$clients" "$uptime_str"
        else
            printf "  %-15s %-7s %-6s %-18s %-20s %-6s ${C_DIM}${S_STOP} STOP${RST} %-4s %-5s\n" \
                "$sname" "$type_label" "$sport" "$bind_addr" "$sroot" "$sauth" "—" "—"
        fi
        s=$((s+1))
    done

    # Unison profiles
    local uni_count; uni_count=$(_d '.servers.unison | length')
    if [ "$uni_count" -gt 0 ]; then
        printf "  ${C_DIM}"
        local w2=0; while [ "$w2" -lt 99 ]; do printf "─"; w2=$((w2+1)); done
        printf "${RST}\n"
        local u=0
        while [ "$u" -lt "$uni_count" ]; do
            local uname uprofile uenabled
            uname=$(_d -r ".servers.unison[$u].name")
            uprofile=$(_d -r ".servers.unison[$u].profile")
            uenabled=$(_d -r ".servers.unison[$u].enabled")
            local state_str
            [ "$uenabled" = "true" ] && state_str="${C_OK}enabled${RST}" || state_str="${C_DIM}disabled${RST}"
            printf "  %-15s %-7s %-6s %-18s %-20s %-6s %b\n" \
                "$uname" "unison" "—" "bidirectional" "$uprofile" "—" "$state_str"
            u=$((u+1))
        done
    fi

    if [ "$srv_count" -eq 0 ] && [ "$uni_count" -eq 0 ]; then
        printf "  ${C_DIM}No servers configured${RST}\n"
    fi
}

# ── Build rclone/http command for a server entry ──
_srv_build_cmd() {
    local idx="$1"
    local stype sport sroot sauth stls smode
    stype=$(_jq -r ".data_servers[$idx].type")
    sport=$(_jq -r ".data_servers[$idx].port")
    sroot=$(_srv_expand_path "$(_jq -r ".data_servers[$idx].root")")
    sauth=$(_jq -r ".data_servers[$idx].auth // \"none\"")
    stls=$(_jq -r ".data_servers[$idx].tls // false")
    smode=$(_jq -r ".data_servers[$idx].mode // \"local\"")

    local bind_addr
    [ "$smode" = "lan" ] && bind_addr="0.0.0.0:$sport" || bind_addr="127.0.0.1:$sport"

    if [ "$stype" = "http" ]; then
        # Node.js HTTP server with Eruda + Markdown rendering
        # Loopback-only when mode=local (server has app-level firewall rejecting non-127.0.0.1)
        local http_server; http_server=$(_srv_find_http_server)
        if [ -z "$http_server" ]; then
            printf "  ${C_ERR}web-server-md-eruda.mjs not found${RST}\n" >&2; return 1
        fi
        echo "node '$http_server' '$sport' '$sroot' '$bind_addr'"
        return 0
    fi

    # rclone serve (webdav/sftp)
    local cmd="rclone serve $stype '$sroot' --addr '$bind_addr' --vfs-cache-mode full --no-modtime"

    # Auth
    case "$sauth" in
        sops)
            _srv_load_sops || return 1
            # Only add auth for LAN mode on webdav; always for sftp
            if [ "$stype" = "sftp" ] || [ "$smode" = "lan" ]; then
                cmd="$cmd --user '$_SRV_SOPS_USER' --pass '$_SRV_SOPS_PASS'"
            fi
            ;;
        basic)
            printf "  ${C_INFO}Enter credentials for %s:${RST}\n" "$(_jq -r ".data_servers[$idx].name")"
            printf "  User: "; read -r _u
            printf "  Pass: "; read -r _p
            cmd="$cmd --user '$_u' --pass '$_p'"
            ;;
        # none: no auth flags
    esac

    # TLS
    if [ "$stls" = "true" ]; then
        local cert_dir; cert_dir=$(_srv_ensure_certs) || return 1
        cmd="$cmd --cert '$cert_dir/cert.pem' --key '$cert_dir/key.pem'"
    fi

    echo "$cmd"
}

# ── Interactive server picker (returns index or -1) ──
_srv_pick() {
    local label="$1" filter="${2:-all}"  # filter: all | running | stopped
    local srv_count; srv_count=$(_jq '.data_servers | length')
    [ "$srv_count" -eq 0 ] && { printf "${C_WARN}No servers configured${RST}\n"; return 1; }

    printf "\n${BLD}%s:${RST}\n" "$label"
    local s=0 shown=0
    local -a idx_map=()
    while [ "$s" -lt "$srv_count" ]; do
        local sname sport stype
        sname=$(_jq -r ".data_servers[$s].name")
        sport=$(_jq -r ".data_servers[$s].port")
        stype=$(_jq -r ".data_servers[$s].type")
        local pid; pid=$(_srv_detect_pid "$stype" "$sport")
        local show="false"
        case "$filter" in
            all)     show="true" ;;
            running) [ -n "$pid" ] && show="true" ;;
            stopped) [ -z "$pid" ] && show="true" ;;
        esac
        if [ "$show" = "true" ]; then
            shown=$((shown+1))
            idx_map+=("$s")
            local status_hint=""
            [ -n "$pid" ] && status_hint=" ${C_OK}(running)${RST}" || status_hint=" ${C_DIM}(stopped)${RST}"
            printf "  ${C_INFO}%d${RST}) %s :%s %s%b\n" "$shown" "$sname" "$sport" "$stype" "$status_hint"
        fi
        s=$((s+1))
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${C_DIM}No matching servers${RST}\n"; return 1
    fi

    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return 1
    local pick=$((ch-1))
    [ "$pick" -lt 0 ] || [ "$pick" -ge "$shown" ] && { printf "${C_WARN}Invalid choice${RST}\n"; return 1; }
    _SRV_PICKED_IDX="${idx_map[$pick]}"
    return 0
}

_SRV_PICKED_IDX=""

server_start() {
    if ! _srv_pick "Select server to start" "stopped"; then return; fi
    local idx="$_SRV_PICKED_IDX"
    local sname sport stype
    sname=$(_jq -r ".data_servers[$idx].name")
    sport=$(_jq -r ".data_servers[$idx].port")
    stype=$(_jq -r ".data_servers[$idx].type")

    # Already running?
    local pid; pid=$(_srv_detect_pid "$stype" "$sport")
    if [ -n "$pid" ]; then
        printf "  ${C_WARN}%s already running (PID: %s)${RST}\n" "$sname" "$pid"; return
    fi

    local cmd; cmd=$(_srv_build_cmd "$idx") || return
    local log_dir; log_dir=$(_srv_log_dir)

    printf "  ${C_INFO}[+]${RST} Starting %s: %s\n" "$sname" "$cmd"
    eval "nohup $cmd > '$log_dir/$sname.log' 2>&1 &"
    sleep 1

    pid=$(_srv_detect_pid "$stype" "$sport")
    if [ -n "$pid" ]; then
        local bind; bind=$(_srv_detect_bind "$sport")
        local proto_prefix=""
        case "$stype" in
            webdav) [ "$(_jq -r ".data_servers[$idx].tls")" = "true" ] && proto_prefix="https://" || proto_prefix="http://" ;;
            sftp)   proto_prefix="sftp://" ;;
            http)   proto_prefix="http://" ;;
        esac
        printf "  ${C_OK}${S_OK}${RST} %s started — ${C_INFO}%s%s${RST} (PID: %s)\n" "$sname" "$proto_prefix" "$bind" "$pid"
        log_msg "server-start: $sname on :$sport (PID: $pid)"
    else
        printf "  ${C_ERR}Failed to start %s — check %s/%s.log${RST}\n" "$sname" "$log_dir" "$sname"
        log_err "server-start failed: $sname on :$sport"
    fi
}

server_stop() {
    if ! _srv_pick "Select server to stop" "running"; then return; fi
    local idx="$_SRV_PICKED_IDX"
    local sname sport stype
    sname=$(_jq -r ".data_servers[$idx].name")
    sport=$(_jq -r ".data_servers[$idx].port")
    stype=$(_jq -r ".data_servers[$idx].type")

    local pid; pid=$(_srv_detect_pid "$stype" "$sport")
    if [ -z "$pid" ]; then
        printf "  ${C_WARN}%s not running${RST}\n" "$sname"; return
    fi

    kill "$pid" 2>/dev/null
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    printf "  ${C_OK}${S_OK}${RST} Stopped %s (was PID: %s)\n" "$sname" "$pid"
    log_msg "server-stop: $sname (PID: $pid)"
}

server_restart() {
    if ! _srv_pick "Select server to restart" "running"; then return; fi
    local idx="$_SRV_PICKED_IDX"
    local sname sport stype
    sname=$(_jq -r ".data_servers[$idx].name")
    sport=$(_jq -r ".data_servers[$idx].port")
    stype=$(_jq -r ".data_servers[$idx].type")

    local pid; pid=$(_srv_detect_pid "$stype" "$sport")
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null; sleep 0.5
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        printf "  ${C_WARN}Stopped %s${RST}\n" "$sname"
    fi

    local cmd; cmd=$(_srv_build_cmd "$idx") || return
    local log_dir; log_dir=$(_srv_log_dir)
    eval "nohup $cmd > '$log_dir/$sname.log' 2>&1 &"
    sleep 1

    pid=$(_srv_detect_pid "$stype" "$sport")
    if [ -n "$pid" ]; then
        printf "  ${C_OK}${S_OK}${RST} Restarted %s (PID: %s)\n" "$sname" "$pid"
        log_msg "server-restart: $sname on :$sport (PID: $pid)"
    else
        printf "  ${C_ERR}Failed to restart %s${RST}\n" "$sname"
    fi
}

server_mode() {
    if ! _srv_pick "Select server to change mode" "all"; then return; fi
    local idx="$_SRV_PICKED_IDX"
    local sname smode
    sname=$(_jq -r ".data_servers[$idx].name")
    smode=$(_jq -r ".data_servers[$idx].mode // \"local\"")

    local new_mode
    [ "$smode" = "lan" ] && new_mode="local" || new_mode="lan"
    printf "  ${C_INFO}Switching %s: %s → %s${RST}\n" "$sname" "$smode" "$new_mode"

    # Update JSON config on disk
    local config_file="$SCRIPT_DIR/connect-data-servers.json"
    local tmp; tmp=$(jq --arg name "$sname" --arg mode "$new_mode" \
        '(.data_servers[] | select(.name == $name)).mode = $mode' "$config_file")
    echo "$tmp" > "$config_file"

    # Reload config
    load_config

    # Restart if running
    local sport stype
    sport=$(_jq -r ".data_servers[$idx].port")
    stype=$(_jq -r ".data_servers[$idx].type")
    local pid; pid=$(_srv_detect_pid "$stype" "$sport")
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null; sleep 0.5
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        local cmd; cmd=$(_srv_build_cmd "$idx") || return
        local log_dir; log_dir=$(_srv_log_dir)
        eval "nohup $cmd > '$log_dir/$sname.log' 2>&1 &"
        sleep 1
        pid=$(_srv_detect_pid "$stype" "$sport")
        [ -n "$pid" ] && printf "  ${C_OK}${S_OK}${RST} Restarted on %s mode (PID: %s)\n" "$new_mode" "$pid"
    else
        printf "  ${C_OK}${S_OK}${RST} Mode set to %s (server not running)\n" "$new_mode"
    fi
}

server_status() {
    render_servers
}

# ── Unison bisync ──
server_bisync() {
    local uni_count; uni_count=$(_jq '.unison_profiles | length // 0')
    [ "$uni_count" -eq 0 ] && { printf "  ${C_WARN}No Unison profiles configured${RST}\n"; return; }

    if ! command -v unison >/dev/null 2>&1; then
        printf "  ${C_ERR}unison not found — install via nix${RST}\n"; return 1
    fi

    if [ "$uni_count" -eq 1 ]; then
        local profile; profile=$(_jq -r '.unison_profiles[0].profile')
        printf "  ${C_INFO}Running Unison profile: %s${RST}\n" "$profile"
        unison "$profile"
        return
    fi

    printf "\n${BLD}Select Unison profile:${RST}\n"
    local u=0
    while [ "$u" -lt "$uni_count" ]; do
        local uname; uname=$(_jq -r ".unison_profiles[$u].name")
        printf "  ${C_INFO}%d${RST}) %s\n" "$((u+1))" "$uname"
        u=$((u+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return

    local pick=$((ch-1))
    local profile; profile=$(_jq -r ".unison_profiles[$pick].profile")
    printf "  ${C_INFO}Running Unison profile: %s${RST}\n" "$profile"
    unison "$profile"
}

# =============================================================================
# F) SERVICES - Cloud services grouped by VM
# =============================================================================

render_services() {
    [ -z "$CC_DATA" ] && collect_all
    printf "  ${BLD}%-22s %-15s %-30s %-10s %-6s${RST}\n" \
        "SERVICE" "VM" "DOMAIN" "PORT" "STATE"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local total; total=$(_d '.services | length')
    _d '.services | sort_by(.name)[]' | jq -r '[.name, .vm, .domain, .port] | @tsv' | \
    while IFS=$'\t' read -r sname svm sdomain sport; do
        printf "  %-22s %-15s %-30s %-10s %-6s\n" "$sname" "$svm" "$sdomain" "$sport" "?"
    done

    if [ "$total" -eq 0 ]; then printf "  ${C_DIM}No services configured${RST}\n"; fi
}

# =============================================================================
# I) SECURITY - Firewall rules, port bindings, networks
# =============================================================================

render_security() {
    [ -z "$CC_DATA" ] && collect_all

    local date_str; date_str=$(date '+%a %d %b  %H:%M')
    printf "\n%b%b" "$C_SEC" "$BLD"
    printf "┏"; local w=0; while [ "$w" -lt 100 ]; do printf "━"; w=$((w+1)); done; printf "┓\n"
    printf "┃  ◆ SECURITY%88s  ┃\n" "$date_str"
    printf "┃  Firewall rules · Caddy routes · Docker bindings · Networks%42s┃\n" ""
    printf "┗"; w=0; while [ "$w" -lt 100 ]; do printf "━"; w=$((w+1)); done; printf "┛%b\n" "$RST"

    # Section colors
    local C_FW="\033[38;5;203m"     # A) Firewall: red
    local C_WEB="\033[38;5;75m"     # B) Web Server: cyan
    local C_AUTH="\033[38;5;220m"   # C) Auth: gold
    local C_RPRX="\033[38;5;44m"   # D) Rev Proxy: teal
    local C_VPN="\033[38;5;177m"   # E) VPN: magenta
    local C_CTR="\033[38;5;114m"   # F) Container: mint
    local C_SCRT="\033[38;5;183m"  # G) Secrets: lavender

    local _topo_cache="$CC_CACHE_DIR/cloud-topology.json"
    local _conf_cache="$CC_CACHE_DIR/cloud-configs.json"
    local w=0

    # ══════════════════════════════════════════════════════════════════════
    # A) FIREWALL — Consolidated cross-reference + detail sub-sections
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ A) FIREWALL ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_FW" "$RST"
    printf "  ${C_DIM}Internet → VPS FW (OCI/GCP) → OS iptables → Docker DNAT${RST}\n"
    printf "  ${C_DIM}Docker bypasses iptables INPUT via DNAT — only VPS firewall + bind address matter for containers${RST}\n"
    printf "  ${BLD}%-15s %-20s %-22s %-6s %-6s %-6s %s${RST}\n" \
        "VM" "Service" "Binding" "VPS" "OS" "Bind" "Verdict"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    # Pre-compute VPS + OS firewall port lookups
    local fw_count; fw_count=$(_d '.mesh.firewalls | length' 2>/dev/null || echo 0)
    local vps_ports_json; vps_ports_json=$(_d '[.mesh.firewalls[] | select(.scope == "vps") | .rules[] | .port | tostring] | unique' 2>/dev/null || echo '[]')
    local os_fw_json="{}"; [ -f "$_topo_cache" ] && os_fw_json=$(jq '[.os_firewalls[] | {(.vm): [.rules[].port | tostring]}] | add // {}' "$_topo_cache" 2>/dev/null || echo '{}')

    local svc_count; svc_count=$(_d '.services | length')
    local si=0
    while [ "$si" -lt "$svc_count" ]; do
        local sname svm sport
        sname=$(_d -r ".services[$si].name")
        svm=$(_d -r ".services[$si].vm")
        sport=$(_jq -r ".service_details[\"$sname\"].port // \"\"")
        if [ -n "$sport" ] && [ "$sport" != "—" ] && [ "$sport" != "null" ]; then
            local host_port; host_port=$(echo "$sport" | grep -oP '^\d+' | head -1)
            local is_wg_bound=false is_lo_bound=false
            echo "$sport" | grep -qP '^10\.\d+\.\d+\.\d+:' && is_wg_bound=true
            echo "$sport" | grep -qP '^127\.0\.0\.1:' && is_lo_bound=true

            local vps_ok="no"
            [ -n "$host_port" ] && echo "$vps_ports_json" | jq -e "index(\"$host_port\")" >/dev/null 2>&1 && vps_ok="yes"

            local vm_alias; vm_alias=$(_d -r ".mesh.vms[] | select(.id == \"$svm\" or .alias == \"$svm\") | .alias // \"$svm\"" 2>/dev/null || echo "$svm")
            local os_ok="no"
            [ -n "$host_port" ] && echo "$os_fw_json" | jq -e ".\"$vm_alias\" // [] | index(\"$host_port\")" >/dev/null 2>&1 && os_ok="yes"

            local bind_lbl="pub"
            $is_wg_bound && bind_lbl="wg"
            $is_lo_bound && bind_lbl="lo"

            local verdict="${C_OK}safe${RST}"
            if [ "$vps_ok" = "yes" ] && [ "$bind_lbl" = "pub" ]; then
                verdict="${C_ERR}PUBLIC${RST}"
            elif [ "$vps_ok" = "yes" ] && [ "$bind_lbl" = "wg" ]; then
                verdict="${C_OK}wg-only${RST}"
            elif [ "$bind_lbl" = "lo" ]; then
                verdict="${C_OK}local${RST}"
            elif [ "$vps_ok" = "no" ]; then
                verdict="${C_OK}blocked${RST}"
            fi

            local vps_c="$C_OK" os_c="$C_OK" bind_c="$C_OK"
            [ "$vps_ok" = "yes" ] && vps_c="$C_WARN"
            [ "$os_ok" = "yes" ] && os_c="$C_WARN"
            [ "$bind_lbl" = "pub" ] && bind_c="$C_WARN"

            printf "  %-15s %-20s %-22s %b%-6s%b %b%-6s%b %b%-6s%b %b\n" \
                "$svm" "$sname" "$sport" \
                "$vps_c" "$vps_ok" "$RST" \
                "$os_c" "$os_ok" "$RST" \
                "$bind_c" "$bind_lbl" "$RST" \
                "$verdict"
        fi
        si=$((si+1))
    done

    # ── A.1) VPS Firewall ──
    printf "\n%b    ── A.1) VPS Firewall (cloud provider) ──%b\n" "$C_FW" "$RST"
    printf "    ${BLD}%-10s %8s %-6s %-22s %s${RST}\n" \
        "Provider" "Port" "Proto" "Source" "Description"
    printf "    ${C_DIM}"
    w=0; while [ "$w" -lt 95 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local fwi=0 vps_found=false
    while [ "$fwi" -lt "$fw_count" ]; do
        local fw_scope; fw_scope=$(_d -r ".mesh.firewalls[$fwi].scope")
        if [ "$fw_scope" = "vps" ]; then
            vps_found=true
            local fw_prov; fw_prov=$(_d -r ".mesh.firewalls[$fwi].provider")
            local rule_count; rule_count=$(_d ".mesh.firewalls[$fwi].rules | length")
            local ri=0
            while [ "$ri" -lt "$rule_count" ]; do
                local rport rproto rsrc rdesc
                rport=$(_d -r ".mesh.firewalls[$fwi].rules[$ri].port")
                rproto=$(_d -r ".mesh.firewalls[$fwi].rules[$ri].protocol")
                rsrc=$(_d -r ".mesh.firewalls[$fwi].rules[$ri].source")
                rdesc=$(_d -r ".mesh.firewalls[$fwi].rules[$ri].description // \"—\"")
                printf "    %-10s %8s %-6s %-22s %s\n" "$fw_prov" "$rport" "$rproto" "$rsrc" "$rdesc"
                ri=$((ri+1))
            done
        fi
        fwi=$((fwi+1))
    done
    [ "$vps_found" = "false" ] && printf "    ${C_DIM}No VPS-level firewall rules${RST}\n"

    # ── A.2) OS iptables ──
    printf "\n%b    ── A.2) OS iptables (home-manager) ──%b\n" "$C_FW" "$RST"
    printf "    ${C_DIM}Policy: INPUT DROP · ACCEPT: lo, wg0, established, ICMP, SSH:22, WG:51820 + below${RST}\n"
    printf "    ${BLD}%-16s %8s %-6s %s${RST}\n" \
        "VM" "Port" "Proto" "Description"
    printf "    ${C_DIM}"
    w=0; while [ "$w" -lt 95 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local os_fw_count=0
    [ -f "$_topo_cache" ] && os_fw_count=$(jq '.os_firewalls | length' "$_topo_cache" 2>/dev/null || echo 0)
    if [ "$os_fw_count" -gt 0 ]; then
        local ofi=0
        while [ "$ofi" -lt "$os_fw_count" ]; do
            local of_vm; of_vm=$(jq -r ".os_firewalls[$ofi].vm" "$_topo_cache")
            local of_rc; of_rc=$(jq ".os_firewalls[$ofi].rules | length" "$_topo_cache")
            if [ "$of_rc" -eq 0 ]; then
                printf "    ${C_OK}%-16s${RST} ${C_DIM}%-8s %-6s %s${RST}\n" "$of_vm" "—" "—" "DROP all (no public ports)"
            else
                local ori=0
                while [ "$ori" -lt "$of_rc" ]; do
                    local ofport ofproto ofdesc
                    ofport=$(jq -r ".os_firewalls[$ofi].rules[$ori].port" "$_topo_cache")
                    ofproto=$(jq -r ".os_firewalls[$ofi].rules[$ori].proto" "$_topo_cache")
                    ofdesc=$(jq -r ".os_firewalls[$ofi].rules[$ori].desc // \"—\"" "$_topo_cache")
                    if [ "$ori" -eq 0 ]; then
                        printf "    %-16s %8s %-6s %s\n" "$of_vm" "$ofport" "$ofproto" "$ofdesc"
                    else
                        printf "    %-16s %8s %-6s %s\n" "" "$ofport" "$ofproto" "$ofdesc"
                    fi
                    ori=$((ori+1))
                done
            fi
            ofi=$((ofi+1))
        done
    else
        printf "    ${C_DIM}No OS firewall data (rebuild topology)${RST}\n"
    fi

    # ── A.2b) FORWARD chain ──
    printf "\n%b    ── A.2b) FORWARD chain (home-manager) ──%b\n" "$C_FW" "$RST"
    local fw_global_exists=false
    [ -f "$_topo_cache" ] && jq -e '.os_firewall_global' "$_topo_cache" >/dev/null 2>&1 && fw_global_exists=true
    if [ "$fw_global_exists" = "true" ]; then
        local docker_ipt; docker_ipt=$(jq -r '.os_firewall_global.docker_iptables' "$_topo_cache")
        local fwd_policy; fwd_policy=$(jq -r '.os_firewall_global.forward_policy' "$_topo_cache")
        local docker_sub; docker_sub=$(jq -r '.os_firewall_global.docker_subnet' "$_topo_cache")
        local wg_sub; wg_sub=$(jq -r '.os_firewall_global.wg_subnet' "$_topo_cache")
        printf "    ${C_DIM}Docker iptables: ${RST}%b${RST} ${C_DIM}│ Policy: FORWARD %s │ Docker: %s │ WG: %s${RST}\n" \
            "$([ "$docker_ipt" = "false" ] && printf "${C_OK}disabled (we own all)${RST}" || printf "${C_ERR}enabled (Docker manages)${RST}")" \
            "$fwd_policy" "$docker_sub" "$wg_sub"
        printf "    ${BLD}%-10s %-18s %-18s %s${RST}\n" "Action" "Source" "Destination" "Description"
        printf "    ${C_DIM}"
        w=0; while [ "$w" -lt 95 ]; do printf "─"; w=$((w+1)); done
        printf "${RST}\n"
        local fwd_count; fwd_count=$(jq '.os_firewall_global.forward_rules | length' "$_topo_cache" 2>/dev/null || echo 0)
        local fi=0
        while [ "$fi" -lt "$fwd_count" ]; do
            local fa fs fd fdesc
            fa=$(jq -r ".os_firewall_global.forward_rules[$fi].action" "$_topo_cache")
            fs=$(jq -r ".os_firewall_global.forward_rules[$fi].source" "$_topo_cache")
            fd=$(jq -r ".os_firewall_global.forward_rules[$fi].destination" "$_topo_cache")
            fdesc=$(jq -r ".os_firewall_global.forward_rules[$fi].desc" "$_topo_cache")
            printf "    %-10s %-18s %-18s %s\n" "$fa" "$fs" "$fd" "$fdesc"
            fi=$((fi+1))
        done
    else
        printf "    ${C_DIM}No FORWARD data (rebuild topology)${RST}\n"
    fi

    # ── A.2c) NAT POSTROUTING ──
    printf "\n%b    ── A.2c) NAT POSTROUTING (home-manager) ──%b\n" "$C_FW" "$RST"
    if [ "$fw_global_exists" = "true" ]; then
        printf "    ${BLD}%-14s %-18s %-18s %s${RST}\n" "Action" "Source" "Destination" "Description"
        printf "    ${C_DIM}"
        w=0; while [ "$w" -lt 95 ]; do printf "─"; w=$((w+1)); done
        printf "${RST}\n"
        local nat_count; nat_count=$(jq '.os_firewall_global.nat_rules | length' "$_topo_cache" 2>/dev/null || echo 0)
        local ni=0
        while [ "$ni" -lt "$nat_count" ]; do
            local na ns nd ndesc
            na=$(jq -r ".os_firewall_global.nat_rules[$ni].action" "$_topo_cache")
            ns=$(jq -r ".os_firewall_global.nat_rules[$ni].source" "$_topo_cache")
            nd=$(jq -r ".os_firewall_global.nat_rules[$ni].destination" "$_topo_cache")
            ndesc=$(jq -r ".os_firewall_global.nat_rules[$ni].desc" "$_topo_cache")
            printf "    %-14s %-18s %-18s %s\n" "$na" "$ns" "$nd" "$ndesc"
            ni=$((ni+1))
        done
    else
        printf "    ${C_DIM}No NAT data (rebuild topology)${RST}\n"
    fi

    # ── A.3) Docker Port Bindings ──
    printf "\n%b    ── A.3) Docker Port Bindings ──%b\n" "$C_FW" "$RST"
    printf "    ${BLD}%-15s %-22s %-24s${RST}\n" \
        "VM" "Service" "Binding"
    printf "    ${C_DIM}"
    w=0; while [ "$w" -lt 95 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    si=0
    local port_found=false
    while [ "$si" -lt "$svc_count" ]; do
        local sname svm svc_ports
        sname=$(_d -r ".services[$si].name")
        svm=$(_d -r ".services[$si].vm")
        svc_ports=$(_jq -r ".service_details[\"$sname\"].port // \"—\"")
        if [ "$svc_ports" != "—" ] && [ "$svc_ports" != "null" ]; then
            port_found=true
            local bind_c="$RST"
            echo "$svc_ports" | grep -qP '^10\.\d+\.\d+\.\d+:' && bind_c="$C_OK"
            echo "$svc_ports" | grep -qP '^127\.0\.0\.1:' && bind_c="$C_OK"
            echo "$svc_ports" | grep -qP '^\d+:\d' && [ "$bind_c" = "$RST" ] && bind_c="$C_WARN"
            printf "    %-15s %-22s %b%-24s%b\n" "$svm" "$sname" "$bind_c" "$svc_ports" "$RST"
        fi
        si=$((si+1))
    done
    [ "$port_found" = "false" ] && printf "    ${C_DIM}No port bindings found${RST}\n"

    # ══════════════════════════════════════════════════════════════════════
    # B) WEB SERVER — Caddy TLS, security headers, rate limits
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ B) WEB SERVER — Caddy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_WEB" "$RST"
    printf "  ${C_DIM}TLS: automatic Let's Encrypt · Security headers: HSTS, X-Frame, CSP · Rate limits per-site${RST}\n"
    printf "  ${BLD}%-42s %-16s %-14s %s${RST}\n" \
        "Domain" "TLS" "Headers" "Limits"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    if [ -f "$_conf_cache" ]; then
        local route_count; route_count=$(jq '.infra.caddy.routes | length' "$_conf_cache" 2>/dev/null || echo 0)
        local ci=0
        while [ "$ci" -lt "$route_count" ]; do
            local cdomain; cdomain=$(jq -r ".infra.caddy.routes[$ci].domain" "$_conf_cache")
            printf "  %-42s %b%-16s%b %b%-14s%b %b%s%b\n" \
                "$cdomain" "$C_OK" "auto" "$RST" "$C_OK" "import security" "$RST" "$C_OK" "per-site" "$RST"
            ci=$((ci+1))
        done
        [ "$route_count" -eq 0 ] && printf "  ${C_DIM}No Caddy routes found${RST}\n"
    else
        printf "  ${C_DIM}cloud-configs.json not cached${RST}\n"
    fi

    # ══════════════════════════════════════════════════════════════════════
    # C) AUTH — Authelia ACL rules
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ C) AUTH — Authelia ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_AUTH" "$RST"
    printf "  ${C_DIM}2FA (TOTP/WebAuthn) · OIDC bearer tokens · Cookie sessions${RST}\n"
    printf "  ${BLD}%-42s %-16s %s${RST}\n" \
        "Domain" "Policy" "Resources"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    if [ -f "$_conf_cache" ]; then
        local acl_count; acl_count=$(jq '.infra.authelia.acl | length' "$_conf_cache" 2>/dev/null || echo 0)
        local ai=0
        while [ "$ai" -lt "$acl_count" ]; do
            local adomain apolicy aresources
            adomain=$(jq -r ".infra.authelia.acl[$ai].domain" "$_conf_cache")
            apolicy=$(jq -r ".infra.authelia.acl[$ai].policy" "$_conf_cache")
            aresources=$(jq -r ".infra.authelia.acl[$ai].resources // [] | join(\", \")" "$_conf_cache")
            [ -z "$aresources" ] && aresources="*"
            local pol_color="$C_OK"
            case "$apolicy" in
                bypass)     pol_color="$C_WARN" ;;
                one_factor) pol_color="$C_INFO" ;;
                two_factor) pol_color="$C_OK" ;;
                deny)       pol_color="$C_ERR" ;;
            esac
            printf "  %-42s %b%-16s%b %s\n" "$adomain" "$pol_color" "$apolicy" "$RST" "$aresources"
            ai=$((ai+1))
        done
        [ "$acl_count" -eq 0 ] && printf "  ${C_DIM}No ACL rules found${RST}\n"
    else
        printf "  ${C_DIM}cloud-configs.json not cached${RST}\n"
    fi

    # ══════════════════════════════════════════════════════════════════════
    # D) REV PROXY — Caddy routing
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ D) REV PROXY — Caddy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_RPRX" "$RST"
    printf "  ${BLD}%-42s %-24s %-16s${RST}\n" \
        "Domain" "Upstream" "Auth"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    if [ -f "$_conf_cache" ]; then
        local route_count; route_count=$(jq '.infra.caddy.routes | length' "$_conf_cache" 2>/dev/null || echo 0)
        local ci=0
        while [ "$ci" -lt "$route_count" ]; do
            local cdomain cupstream cauth
            cdomain=$(jq -r ".infra.caddy.routes[$ci].domain" "$_conf_cache")
            cupstream=$(jq -r ".infra.caddy.routes[$ci].upstream" "$_conf_cache")
            cauth=$(jq -r ".infra.caddy.routes[$ci].auth" "$_conf_cache")
            local auth_color="$C_DIM"
            case "$cauth" in
                none)               auth_color="$C_WARN" ;;
                authelia+bearer)    auth_color="$C_OK" ;;
                3-tier)             auth_color="$C_INFO" ;;
            esac
            printf "  %-42s %-24s %b%s%b\n" "$cdomain" "$cupstream" "$auth_color" "$cauth" "$RST"
            ci=$((ci+1))
        done
        [ "$route_count" -eq 0 ] && printf "  ${C_DIM}No Caddy routes found${RST}\n"
    else
        printf "  ${C_DIM}cloud-configs.json not cached${RST}\n"
    fi

    # ══════════════════════════════════════════════════════════════════════
    # E) VPN — WireGuard mesh
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ E) VPN — WireGuard ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_VPN" "$RST"
    printf "  ${C_DIM}Hub-and-spoke mesh: gcp-proxy is hub, all others connect through it${RST}\n"
    printf "  ${BLD}%-16s %-12s %-8s %-28s${RST}\n" \
        "Peer" "WG IP" "Role" "Endpoint"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local wg_count=0
    [ -f "$_topo_cache" ] && wg_count=$(jq '.wireguard.peers | length' "$_topo_cache" 2>/dev/null || echo 0)
    if [ "$wg_count" -gt 0 ]; then
        local wi=0
        while [ "$wi" -lt "$wg_count" ]; do
            local wname wip wrole wendpoint
            wname=$(jq -r ".wireguard.peers[$wi].name" "$_topo_cache")
            wip=$(jq -r ".wireguard.peers[$wi].wg_ip" "$_topo_cache")
            wrole=$(jq -r ".wireguard.peers[$wi].role" "$_topo_cache")
            wendpoint=$(jq -r ".wireguard.peers[$wi].endpoint" "$_topo_cache")
            local role_color="$C_DIM"
            case "$wrole" in hub) role_color="$C_OK" ;; spoke) role_color="$C_INFO" ;; client) role_color="$C_WARN" ;; esac
            printf "  %-16s %-12s %b%-8s%b %s\n" "$wname" "$wip" "$role_color" "$wrole" "$RST" "$wendpoint"
            wi=$((wi+1))
        done
    else
        printf "  ${C_DIM}No WireGuard data (rebuild topology)${RST}\n"
    fi

    # ══════════════════════════════════════════════════════════════════════
    # F) CONTAINER — Docker networks & isolation
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ F) CONTAINER — Docker ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_CTR" "$RST"
    printf "  ${BLD}%-30s %s${RST}\n" "Network" "Services"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local net_json="[]"
    if [ -f "$_topo_cache" ]; then
        net_json=$(jq '
            [.services | to_entries[] |
             .key as $svc |
             (.value.networks // [])[] |
             {network: ., service: $svc}
            ] | group_by(.network) | map({
                network: .[0].network,
                services: [.[].service] | join(", ")
            })
        ' "$_topo_cache" 2>/dev/null || echo "[]")
    fi

    local net_count; net_count=$(echo "$net_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "$net_count" -gt 0 ]; then
        local ni=0
        while [ "$ni" -lt "$net_count" ]; do
            local nname nsvcs
            nname=$(echo "$net_json" | jq -r ".[$ni].network")
            nsvcs=$(echo "$net_json" | jq -r ".[$ni].services")
            printf "  %-30s %s\n" "$nname" "$nsvcs"
            ni=$((ni+1))
        done
    else
        printf "  ${C_DIM}No Docker networks found${RST}\n"
    fi

    # ══════════════════════════════════════════════════════════════════════
    # G) SECRETS — sops/age encrypted credentials
    # ══════════════════════════════════════════════════════════════════════
    printf "\n%b  ━━ G) SECRETS — sops/age ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_SCRT" "$RST"
    printf "  ${BLD}%-25s %-12s %-12s %s${RST}\n" \
        "Service" "Encrypted" "Deployed" "Status"
    printf "  ${C_DIM}"
    w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local cloud_dir="$HOME/git/cloud-infra"
    local sol_dir="$cloud_dir/a_solutions"
    if [ -d "$sol_dir" ]; then
        local sec_found=false
        for svc_dir in "$sol_dir"/*/; do
            local svc_name; svc_name=$(basename "$svc_dir" | sed 's/^[a-z]*-[a-z]*_//')
            local has_enc=false has_dep=false
            [ -f "$svc_dir/src/secrets.yaml" ] && has_enc=true
            [ -f "$svc_dir/dist/.secrets" ] && has_dep=true
            $has_enc || $has_dep || continue
            sec_found=true
            local sestatus="${C_OK}OK${RST}"
            if $has_enc && ! $has_dep; then
                sestatus="${C_ERR}NOT DEPLOYED${RST}"
            elif ! $has_enc && $has_dep; then
                sestatus="${C_WARN}NO SOURCE${RST}"
            fi
            printf "  %-25s %b%-12s%b %b%-12s%b %b\n" \
                "$svc_name" \
                "$($has_enc && echo "$C_OK" || echo "$C_DIM")" "$has_enc" "$RST" \
                "$($has_dep && echo "$C_OK" || echo "$C_WARN")" "$has_dep" "$RST" \
                "$sestatus"
        done
        $sec_found || printf "  ${C_DIM}No services with secrets${RST}\n"
    else
        printf "  ${C_DIM}cloud/a_solutions not found${RST}\n"
    fi
}

# =============================================================================
# G) WEBSERVER - Dev servers detection
# =============================================================================

# Resolve listening port for a PID: try ss (desktop), then parse cmd args
_get_pid_port() {
    local pid="$1"
    # Try ss with pid filter (works on full Linux with CAP_NET_ADMIN)
    local port
    port=$(ss -tlnp 2>/dev/null | grep "pid=$pid," | grep -oP ':\K\d+' | head -1)
    [ -n "$port" ] && { echo "$port"; return; }
    # Fallback: parse --port / -p / PORT= from command args
    local args; args=$(ps -o args= -p "$pid" 2>/dev/null || echo "")
    port=$(echo "$args" | grep -oP '(?:--port[= ]|(?<!\w)-p[= ])\K\d+' | head -1)
    [ -n "$port" ] && { echo "$port"; return; }
    echo "?"
}

# Format uptime seconds to human string
_fmt_uptime() {
    local s="$1"
    if [ "$s" -lt 3600 ] 2>/dev/null; then echo "$((s / 60))m"
    else echo "$((s / 3600))h"; fi
}

render_webservers() {
    [ -z "$CC_DATA" ] && collect_all
    printf "  ${BLD}%-17s %-6s %-10s %-12s %-26s %-8s %-7s State${RST}\n" \
        "DEV SERVER" "Port" "Runtime" "Framework" "Project" "PID" "Up"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local ws_count; ws_count=$(_d '.webservers | length')
    if [ "$ws_count" -gt 0 ]; then
        local i=0
        while [ "$i" -lt "$ws_count" ]; do
            local wname wport wrt wfw wproj wpid wup
            wname=$(_d -r ".webservers[$i].name")
            wport=$(_d -r ".webservers[$i].port")
            wrt=$(_d -r ".webservers[$i].runtime")
            wfw=$(_d -r ".webservers[$i].framework")
            wproj=$(_d -r ".webservers[$i].project")
            wpid=$(_d -r ".webservers[$i].pid")
            wup=$(_d -r ".webservers[$i].uptime_secs")
            printf "  %-17s %-6s %-10s %-12s %-26s %-8s %-7s ${C_OK}${S_RUN} RUN${RST}\n" \
                "$wname" "$wport" "$wrt" "$wfw" "$wproj" "$wpid" "$(_fmt_uptime "$wup")"
            i=$((i+1))
        done
    else
        printf "  ${C_DIM}No dev servers running${RST}\n"
    fi
}

# =============================================================================
# SUMMARY GAUGES
# =============================================================================

compute_gauges() {
    # All gauges pre-computed in collect_all() — just read from CC_DATA
    [ -z "$CC_DATA" ] && collect_all
    GAUGE_HM_CUR=$(_d -r '.gauges.hm_cur // 0')
    GAUGE_HM_MAX=$(_d -r '.gauges.hm_max // 0')
    GAUGE_MESH_CUR=$(_d -r '.gauges.mesh_cur')
    GAUGE_MESH_MAX=$(_d -r '.gauges.mesh_max')
    GAUGE_GIT_CUR=$(_d -r '.gauges.git_cur')
    GAUGE_GIT_MAX=$(_d -r '.gauges.git_max')
    GAUGE_DRIVE_CUR=$(_d -r '.gauges.drive_cur')
    GAUGE_DRIVE_MAX=$(_d -r '.gauges.drive_max')
    GAUGE_SYNC_CUR=$(_d -r '.gauges.sync_cur')
    GAUGE_SYNC_MAX=$(_d -r '.gauges.sync_max')
}

# =============================================================================
# G) HOME-MANAGER FLAKES - Status & Deploy
# =============================================================================

render_home_manager() {
    [ -z "$CC_DATA" ] && collect_all
    printf "  ${BLD}%-20s %-14s %-34s %-16s Generation${RST}\n" \
        "HOME-MANAGER" "Type" "Path" "Git"
    printf "  ${C_DIM}"
    local w=0; while [ "$w" -lt 99 ]; do printf "─"; w=$((w+1)); done
    printf "${RST}\n"

    local hm_count; hm_count=$(_d '.home_manager | length')
    local i=0
    while [ "$i" -lt "$hm_count" ]; do
        local hname htype hpath henabled hdirty hgit_label hgen
        hname=$(_d -r ".home_manager[$i].name")
        htype=$(_d -r ".home_manager[$i].type")
        hpath=$(_d -r ".home_manager[$i].path")
        henabled=$(_d -r ".home_manager[$i].enabled")
        hdirty=$(_d -r ".home_manager[$i].dirty")
        hgit_label=$(_d -r ".home_manager[$i].git_label")
        hgen=$(_d -r ".home_manager[$i].generation")

        if [ "$henabled" = "false" ]; then
            printf "  ${C_DIM}%-20s %-14s %-34s DISABLED${RST}\n" "$hname" "$htype" "$hpath"
            i=$((i+1)); continue
        fi

        # Color the git label
        local git_display
        case "$hgit_label" in
            clean)    git_display="${C_OK}clean${RST}" ;;
            dirty)    git_display="${C_WARN}dirty (${hdirty} files)${RST}" ;;
            ahead:*)  git_display="${C_INFO}ahead (+${hgit_label#ahead:})${RST}" ;;
            *)        git_display="$hgit_label" ;;
        esac

        printf "  %-20s %-14s %-34s %b  %s\n" \
            "$hname" "$htype" "$hpath" "$git_display" "$hgen"
        i=$((i+1))
    done

    if [ "$hm_count" -eq 0 ]; then printf "  ${C_DIM}No flakes configured${RST}\n"; fi
}

hm_build() {
    local hm_count; hm_count=$(_jq '.home_manager_flakes | length')
    [ "$hm_count" -eq 0 ] && { printf "${C_WARN}No flakes configured${RST}\n"; return; }

    printf "\n${BLD}Select flake to build:${RST}\n"
    local i=0
    while [ "$i" -lt "$hm_count" ]; do
        local hname hdesc; hname=$(_jq -r ".home_manager_flakes[$i].name"); hdesc=$(_jq -r ".home_manager_flakes[$i].description")
        printf "  ${C_INFO}%d${RST}) %-16s %s\n" "$((i+1))" "$hname" "$hdesc"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return

    local idx=$((ch-1))
    local hname hpath
    hname=$(_jq -r ".home_manager_flakes[$idx].name")
    hpath=$(_jq -r ".home_manager_flakes[$idx].path" | sed "s|~|$HOME|")
    local bscript="$hpath/build.sh"
    [ ! -f "$bscript" ] && { printf "${C_ERR}build.sh not found: %s${RST}\n" "$bscript"; return; }

    printf "${C_INFO}[+]${RST} Building %s...\n" "$hname"
    bash "$bscript" build
}

hm_switch() {
    local hm_count; hm_count=$(_jq '.home_manager_flakes | length')
    [ "$hm_count" -eq 0 ] && { printf "${C_WARN}No flakes configured${RST}\n"; return; }

    printf "\n${BLD}Select flake to switch (apply):${RST}\n"
    local i=0
    while [ "$i" -lt "$hm_count" ]; do
        local hname hdesc; hname=$(_jq -r ".home_manager_flakes[$i].name"); hdesc=$(_jq -r ".home_manager_flakes[$i].description")
        printf "  ${C_INFO}%d${RST}) %-16s %s\n" "$((i+1))" "$hname" "$hdesc"
        i=$((i+1))
    done
    printf "  ${C_DIM}0${RST}) Cancel\n${BLD}Choice:${RST} "
    read -r ch
    [ "$ch" = "0" ] || [ -z "$ch" ] && return

    local idx=$((ch-1))
    local hname hpath htype
    hname=$(_jq -r ".home_manager_flakes[$idx].name")
    hpath=$(_jq -r ".home_manager_flakes[$idx].path" | sed "s|~|$HOME|")
    htype=$(_jq -r ".home_manager_flakes[$idx].type")
    local bscript="$hpath/build.sh"
    [ ! -f "$bscript" ] && { printf "${C_ERR}build.sh not found: %s${RST}\n" "$bscript"; return; }

    local subcmd="switch"
    [ "$htype" = "nixos" ] && subcmd="switch"
    printf "${C_INFO}[+]${RST} Switching %s (%s)...\n" "$hname" "$htype"
    bash "$bscript" "$subcmd"
}

# =============================================================================
# ALERT STRIP
# =============================================================================

render_alerts() {
    [ -z "$CC_DATA" ] && collect_all
    local alerts=""
    local vm_down; vm_down=$(_d -r '.alerts.vm_down')
    local dirty_count; dirty_count=$(_d -r '.alerts.dirty_repos')
    local drives_down; drives_down=$(_d -r '.alerts.drives_down')
    local sync_run; sync_run=$(_d -r '.alerts.sync_running')

    [ "$vm_down" -gt 0 ] 2>/dev/null && alerts="${alerts}  ${C_ALERT}${S_WARN} ${vm_down} VMs unmounted${RST}"
    [ "$dirty_count" -gt 0 ] 2>/dev/null && alerts="${alerts}  ${C_WARN}${S_WARN} ${dirty_count} repos dirty${RST}"
    [ "$drives_down" -gt 0 ] 2>/dev/null && alerts="${alerts}  ${C_ALERT}${S_WARN} ${drives_down} drives unmounted${RST}"
    [ "$sync_run" -gt 0 ] 2>/dev/null && alerts="${alerts}  ${C_OK}${S_DOT} ${sync_run} sync running${RST}"

    printf "%b" "$alerts"
}

# =============================================================================
# MAIN DASHBOARD RENDER
# =============================================================================

render_dashboard() {
    local mode="${1:-print}"  # "print" = one-shot, "interactive" = loop
    if [ "$mode" = "interactive" ]; then clear; fi

    # Single-source: collect all data once, all renderers read from CC_DATA
    collect_all
    compute_gauges

    # ── Header ──
    local hostname_str="${HM_PROFILE:-$(hostname 2>/dev/null || echo 'unknown')}"
    local date_str; date_str=$(date '+%a %d %b  %H:%M')

    printf "%b%b" "$BG_HEAD" "$C_HEAD"
    printf "┏"
    local w=0; while [ "$w" -lt 100 ]; do printf "━"; w=$((w+1)); done
    printf "┓\n"
    printf "┃  ◆ CLOUD CONNECT%65s%18s  ┃\n" "diego@${hostname_str}" "$date_str"
    local wd_short; wd_short=$(echo "$GIT_WORKDIR" | sed "s|$HOME|~|")
    local md_short; md_short=$(echo "$MOUNT_DIR" | sed "s|$HOME|~|")
    local merge_label="SERVER"
    [ "$MERGE_STRATEGY" = "ours" ] && merge_label="LOCAL"
    printf "┃  Git: %-28s  Mounts: %-26s  Merge: %-18s  ┃\n" "$wd_short" "$md_short" "$merge_label ($MERGE_STRATEGY)"
    printf "┗"
    w=0; while [ "$w" -lt 100 ]; do printf "━"; w=$((w+1)); done
    printf "┛%b\n" "$RST"

    # ── Gauge Strip ──
    printf "  ${C_HM}HM${RST} "
    gauge_bar "$GAUGE_HM_CUR" "$GAUGE_HM_MAX" 6
    printf " ${C_DIM}%s/%s${RST}" "$GAUGE_HM_CUR" "$GAUGE_HM_MAX"
    printf "  ${C_MESH}MESH${RST} "
    gauge_bar "$GAUGE_MESH_CUR" "$GAUGE_MESH_MAX" 12
    printf " ${C_DIM}%s/%s${RST}" "$GAUGE_MESH_CUR" "$GAUGE_MESH_MAX"
    printf "  ${C_GIT}GIT${RST} "
    gauge_bar "$GAUGE_GIT_CUR" "$GAUGE_GIT_MAX" 12
    printf " ${C_DIM}%s/%s${RST}" "$GAUGE_GIT_CUR" "$GAUGE_GIT_MAX"
    printf "  ${C_DRIVE}FUSE DRIVES${RST} "
    gauge_bar "$GAUGE_DRIVE_CUR" "$GAUGE_DRIVE_MAX" 10
    printf " ${C_DIM}%s/%s${RST}" "$GAUGE_DRIVE_CUR" "$GAUGE_DRIVE_MAX"
    printf "  ${C_SYNC}SYNC${RST} "
    gauge_bar "$GAUGE_SYNC_CUR" "$GAUGE_SYNC_MAX" 6
    printf " ${C_DIM}%s/%s${RST}" "$GAUGE_SYNC_CUR" "$GAUGE_SYNC_MAX"

    # Running jobs count
    local rj; rj=$(sync_get_running_jobs 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    [ "$rj" -gt 0 ] && printf "  ${C_OK}${S_PLAY} %s jobs${RST}" "$rj"
    printf "\n"

    # ── Alert Strip ──
    render_alerts
    printf "\n"

    # ── A) HOME-MANAGER FLAKES ──
    printf "\n%b━━ A) HOME-MANAGER FLAKES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_HM" "$RST"
    render_home_manager

    # ── B) MESH ──
    printf "\n%b━━ B) MESH ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_MESH" "$RST"
    render_mesh

    # ── C) GIT ──
    printf "\n%b━━ C) GIT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_GIT" "$RST"
    render_git

    # ── D) FUSE DRIVES ──
    printf "\n%b━━ D) FUSE DRIVES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_DRIVE" "$RST"
    render_drives

    # ── E) SYNC ──
    printf "\n%b━━ E) SYNC ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_SYNC" "$RST"
    render_sync

    # ── F) DATA SERVERS ──
    printf "\n%b━━ F) DATA SERVERS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_SRVR" "$RST"
    render_servers

    # ── G) WEBSERVER ──
    printf "\n%b━━ G) WEBSERVER ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_WEB" "$RST"
    render_webservers

    # ── H) SERVICES ──
    printf "\n%b━━ H) SERVICES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_SVC" "$RST"
    if [ "$CC_PROFILE" = "compact" ]; then
        local svc_total; svc_total=$(_d '.services | length')
        printf "  %s services configured  ${C_DIM}— run ${RST}${BLD}connect.sh full${RST}${C_DIM} for details${RST}\n" "$svc_total"
    else
        render_services
    fi

    # ── I) SECURITY ──
    printf "\n%b━━ I) SECURITY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$C_SEC" "$RST"
    local fw_vps_count fw_vm_count fw_port_count fw_caddy_count fw_acl_count fw_wg_count
    fw_vps_count=$(_d '[.mesh.firewalls[] | select(.scope == "vps") | .rules[]] | length' 2>/dev/null || echo 0)
    local _topo_c="$CC_CACHE_DIR/cloud-topology.json"
    fw_vm_count=0; fw_wg_count=0
    [ -f "$_topo_c" ] && fw_vm_count=$(jq '[.os_firewalls[].rules[]] | length' "$_topo_c" 2>/dev/null || echo 0)
    [ -f "$_topo_c" ] && fw_wg_count=$(jq '.wireguard.peers | length' "$_topo_c" 2>/dev/null || echo 0)
    fw_port_count=$(_d '.services | map(select(.port != "—" and .port != null)) | length' 2>/dev/null || echo 0)
    local _conf_c="$CC_CACHE_DIR/cloud-configs.json"
    fw_caddy_count=0; fw_acl_count=0
    [ -f "$_conf_c" ] && fw_caddy_count=$(jq '.infra.caddy.routes | length' "$_conf_c" 2>/dev/null || echo 0)
    [ -f "$_conf_c" ] && fw_acl_count=$(jq '.infra.authelia.acl | length' "$_conf_c" 2>/dev/null || echo 0)
    printf "  \033[38;5;203mA)${RST}${C_DIM}Firewall %s+%s+%s${RST}" "$fw_vps_count" "$fw_vm_count" "$fw_port_count"
    printf "  \033[38;5;75mB)${RST}${C_DIM}WebSrv %s${RST}" "$fw_caddy_count"
    printf "  \033[38;5;220mC)${RST}${C_DIM}Auth %s${RST}" "$fw_acl_count"
    printf "  \033[38;5;44mD)${RST}${C_DIM}RevProxy %s${RST}" "$fw_caddy_count"
    printf "  \033[38;5;177mE)${RST}${C_DIM}VPN %s${RST}" "$fw_wg_count"
    printf "  \033[38;5;114mF)${RST}${C_DIM}Container${RST}"
    printf "  \033[38;5;183mG)${RST}${C_DIM}Secrets${RST}\n"
    printf "  ${C_DIM}— run ${RST}${BLD}connect security${RST}${C_DIM} for details${RST}\n"

    # ── Log ──
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        local log_size log_lines log_errs log_warns
        log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
        log_errs=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo 0)
        log_warns=$(grep -c "WARN" "$LOG_FILE" 2>/dev/null || echo 0)
        printf "\n  ${C_DIM}Log: %s | %s lines | " "$log_size" "$log_lines"
        [ "$log_errs" -gt 0 ] && printf "${C_ERR}%s errors${RST}${C_DIM}" "$log_errs" || printf "0 errors"
        printf " | "
        [ "$log_warns" -gt 0 ] && printf "${C_WARN}%s warnings${RST}" "$log_warns" || printf "0 warnings"
        printf "${RST}\n"
    fi

    # ── Commands ──
    printf "\n%b━━ COMMANDS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$BLD" "$RST"
    printf "  ${C_HM}HM${RST}     ${C_DIM}hm-build  hm-switch${RST}\n"
    printf "  ${C_MESH}MESH${RST}   ${C_DIM}mount-vm  unmount-vm  mount-all-vm  unmount-all  mount-phone  unmount-phone${RST}\n"
    printf "  ${C_MESH}OCI${RST}    ${C_DIM}flex-start  flex-stop  flex-reset  flex-status${RST}\n"
    printf "  ${C_GIT}GIT${RST}    ${C_DIM}sync  pull  push  commit  fetch  fetch-status  clone  dirty  git-notok  git-refresh${RST}\n"
    printf "  ${C_GIT}   ${RST}    ${C_DIM}untracked  unstaged  ignored  merge  restore-symlinks  git-remotes  git-branches  git-tags${RST}\n"
    printf "  ${C_GIT}   ${RST}    ${C_DIM}git-log  git-stash-list  git-diff  git-gc  git-prune${RST}\n"
    printf "  ${C_DRIVE}DRIVE${RST}  ${C_DIM}mount-drive  unmount-drive  mount-all-drives  unmount-all-drives  toggle-drives${RST}\n"
    printf "  ${C_SYNC}SYNC${RST}   ${C_DIM}sync-run  sync-run-bg  sync-run-rule  sync-to  bisync-to  sync-quick  sync-status  sync-list${RST}\n"
    printf "  ${C_SYNC}    ${RST}   ${C_DIM}sync-add  sync-delete  sync-toggle  sync-edit  sync-jobs  sync-cancel  sync-cancel-id  sync-kill  sync-clear-jobs${RST}\n"
    printf "  ${C_SRVR}DATA SRVR${RST}   ${C_DIM}server-start  server-stop  server-restart  server-mode  server-status  bisync${RST}\n"
    printf "  ${C_DIM}SETUP${RST}  ${C_DIM}settings  config-set  deps  deps-core  deps-phone  deps-cloud  remotes  view-log  clear-log  edit-workdir  edit-config${RST}\n"
    printf "  ${C_SEC}SECURITY${RST} ${C_DIM}security${RST}\n"
    printf "  ${C_DIM}────${RST}   ${C_DIM}refresh  full  compact  resume  logs  help  quit${RST}\n"
    printf "%b" "$BLD"
    w=0; while [ "$w" -lt 102 ]; do printf "━"; w=$((w+1)); done
    printf "%b\n" "$RST"
    printf "▸ "
}

# =============================================================================
# INTERACTIVE LOOP (CLI-first: type command + Enter)
# =============================================================================

_dispatch_cmd() {
    local cmd="$1"
    case "$cmd" in
        # ── Git ──
        sync)                git_cmd_sync ;;
        pull)                git_cmd_pull ;;
        push)                git_cmd_push ;;
        commit)              git_cmd_commit ;;
        fetch)               git_cmd_fetch ;;
        fetch-status)        git_cmd_fetch_status ;;
        clone)               git_cmd_clone_menu ;;
        untracked)           git_cmd_untracked ;;
        unstaged)            git_cmd_unstaged ;;
        ignored)             git_cmd_ignored ;;
        workdir)             edit_workdir ;;
        merge)               git_toggle_merge ;;
        status)              render_git ;;

        # ── Mesh (VM mounts) ──
        mount-vm)            select_and_mount_vm ;;
        unmount-vm)          select_and_unmount_vm ;;
        mount-all-vm)        _mount_all_vms ;;
        unmount-all)         _unmount_all_vms; _unmount_all_drives; unmount_phone ;;
        mount-phone)         mount_phone ;;
        unmount-phone)       unmount_phone ;;

        # ── OCI Flex ──
        flex-start)          flex_select_and_action "start" ;;
        flex-stop)           flex_select_and_action "stop" ;;
        flex-reset)          flex_select_and_action "reset" ;;
        flex-status)         flex_select_and_action "status" ;;

        # ── Drives ──
        mount-drive)         select_and_mount_drive ;;
        unmount-drive)       select_and_unmount_drive ;;
        mount-all-drives)    _mount_all_drives ;;
        unmount-all-drives)  _unmount_all_drives ;;
        toggle-drives)       _toggle_all_drives ;;

        # ── Sync ──
        sync-run)            sync_run_all ;;
        sync-add)            sync_add_rule_wizard ;;
        sync-delete)         sync_delete_rule ;;
        sync-toggle)         sync_toggle_rule ;;
        sync-quick)          sync_quick_menu ;;
        sync-edit)           sync_edit_rules ;;
        sync-jobs)           sync_show_jobs ;;
        sync-cancel)         sync_cancel_job ;;
        sync-kill)           sync_kill_all ;;
        sync-clear-jobs)     sync_clear_completed ;;

        # ── Servers ──
        server-start)        server_start ;;
        server-stop)         server_stop ;;
        server-restart)      server_restart ;;
        server-mode)         server_mode ;;
        server-status)       server_status ;;
        bisync)              server_bisync ;;

        # ── Home-Manager ──
        hm-build)            hm_build ;;
        hm-switch)           hm_switch ;;

        # ── Sync (extra) ──
        sync-run-rule)       sync_run_rule_interactive ;;
        sync-list)           sync_list_cli ;;
        sync-run-bg)         sync_run_all_bg ;;
        sync-to)             printf "Source: "; read -r _src; printf "Dest: "; read -r _dst; sync_adhoc "$_src" "$_dst" ;;
        bisync-to)           printf "Path 1: "; read -r _p1; printf "Path 2: "; read -r _p2; bisync_adhoc "$_p1" "$_p2" ;;
        sync-cancel-id)      printf "Job ID: "; read -r _jid; sync_cancel_by_id "$_jid" ;;
        sync-status)         sync_full_status ;;
        dirty)               git_cmd_dirty ;;

        # ── Git (extra) ──
        restore-symlinks)    restore_symlinks ;;
        git-refresh)         render_git ;;
        git-notok)           git_cmd_dirty ;;
        git-remotes)         git_cmd_remotes ;;
        git-branches)        git_cmd_branches ;;
        git-tags)            git_cmd_tags ;;
        git-log)             git_cmd_log ;;
        git-stash-list)      git_cmd_stash_list ;;
        git-diff)            git_cmd_diff ;;
        git-gc)              git_cmd_gc ;;
        git-prune)           git_cmd_prune ;;

        # ── Security ──
        security)            render_security ;;

        # ── View modes ──
        compact)             CC_PROFILE="compact" ;;
        full)                CC_PROFILE="full" ;;
        resume)              CC_PROFILE="resume" ;;

        # ── Setup ──
        settings)            settings_menu ;;
        deps)                deps_menu ;;
        deps-core)           install_deps_category "core" ;;
        deps-phone)          install_deps_category "phone" ;;
        deps-cloud)          install_deps_category "cloud" ;;
        remotes)             configure_remote_menu ;;
        edit-workdir)        edit_workdir ;;
        clear-log)           clear_log ;;
        view-log|log)        view_log ;;
        edit-config)         edit_config ;;
        config-set)          printf "Key: "; read -r _ck; printf "Value: "; read -r _cv; config_set "$_ck" "$_cv" ;;

        # ── Global ──
        refresh|r)           cc_probe_env; cc_build_mesh; cc_build_hm; load_config ;;
        logs)                _logs_json ;;
        help|h|\?)           show_help ;;
        quit|q|exit)         printf "\n"; exit 0 ;;
        "")                  return 0 ;;  # Empty input = refresh

        *)  printf "${C_ERR}Unknown command: %s${RST}  (type ${BLD}help${RST} for commands)\n" "$cmd" ;;
    esac
}

CC_PROFILE="full"  # full | compact | resume

run_tui() {
    local profile="${1:-$CC_PROFILE}"
    CC_PROFILE="$profile"
    while true; do
        CC_DATA=""  # force re-collection each refresh
        if [ "$CC_PROFILE" = "resume" ]; then
            clear
            _resume_view
            printf "\n  ${C_DIM}[r]efresh  [f]ull  [c]ompact  [q]uit  or type command:${RST} "
        else
            render_dashboard "interactive"
        fi
        read -r cmd || exit 0
        printf "\n"
        case "$cmd" in
            f|full)    CC_PROFILE="full" ;;
            c|compact) CC_PROFILE="compact" ;;
            s|resume)  CC_PROFILE="resume" ;;
            *)         _dispatch_cmd "$cmd" ;;
        esac
    done
}

# POSIX single-key reader (no bashisms)
_read_key() {
    local _old_tty
    _old_tty=$(stty -g)
    stty raw -echo
    dd bs=1 count=1 2>/dev/null
    stty "$_old_tty"
}

_wait_key() {
    local _old_tty
    _old_tty=$(stty -g)
    stty raw -echo
    dd bs=1 count=1 >/dev/null 2>&1
    stty "$_old_tty"
}

run_keys() {
    local profile="${1:-$CC_PROFILE}"
    CC_PROFILE="$profile"
    while true; do
        CC_DATA=""  # force re-collection each refresh
        if [ "$CC_PROFILE" = "resume" ]; then
            clear
            _resume_view
        else
            render_dashboard "interactive"
        fi
        printf "\n"
        printf "  ${C_DIM}Keys: ${RST}"
        printf "${C_HM}a${RST}${C_DIM})hm ${RST}"
        printf "${C_MESH}b${RST}${C_DIM})mesh ${RST}"
        printf "${C_GIT}c${RST}${C_DIM})git ${RST}"
        printf "${C_DRIVE}d${RST}${C_DIM})drives ${RST}"
        printf "${C_SYNC}e${RST}${C_DIM})sync ${RST}"
        printf "${C_SRVR}f${RST}${C_DIM})servers ${RST}"
        printf "${C_WEB}g${RST}${C_DIM})web ${RST}"
        printf "${C_SVC}h${RST}${C_DIM})services ${RST}"
        printf "${C_SEC}i${RST}${C_DIM})security ${RST}"
        printf "${C_DIM}r)refresh  p)profile  q)quit${RST}\n"
        printf "  ${C_DIM}▸${RST} "

        local key
        key=$(_read_key) || exit 0
        printf "\n"
        case "$key" in
            a) render_home_manager ;;
            b) render_mesh ;;
            c) render_git ;;
            d) render_drives ;;
            e) render_sync ;;
            f) render_servers ;;
            g) render_webservers ;;
            h) render_services ;;
            i) render_security ;;
            r) ;; # refresh = just loop
            p) case "$CC_PROFILE" in
                   full)    CC_PROFILE="compact" ;;
                   compact) CC_PROFILE="resume" ;;
                   resume)  CC_PROFILE="full" ;;
               esac
               printf "  ${C_INFO}Profile: %s${RST}\n" "$CC_PROFILE"; sleep 0.3 ;;
            q) printf "\n"; exit 0 ;;
            # Section actions via shift keys
            A) hm_switch ;;
            B) select_and_mount_vm ;;
            C) git_cmd_sync ;;
            D) select_and_mount_drive ;;
            E) sync_run_all ;;
            F) server_start ;;
            ?) show_help; printf "\n  ${C_DIM}Press any key...${RST}"; _wait_key ;;
            *) printf "  ${C_DIM}Unknown key: %s${RST}\n" "$key"; sleep 0.3 ;;
        esac
    done
}

# =============================================================================
# CLI INTERFACE
# =============================================================================

show_help() {
    printf "\n"
    printf "  %b       __                __                                       _   %b\n" "$C_MESH" "$RST"
    printf "  %b  ____/ /___  __  ______/ /     _________  ____  ____  ___  _____/ /_ %b\n" "$C_MESH" "$RST"
    printf "  %b / ___/ / _ \\/ / / / __  /_____/ ___/ __ \\/ __ \\/ __ \\/ _ \\/ ___/ __/ %b\n" "$C_GIT" "$RST"
    printf "  %b/ /__/ / /_/ / /_/ / /_/ /_____/ /__/ /_/ / / / / / / /  __/ /__/ /_  %b\n" "$C_SYNC" "$RST"
    printf "  %b\\___/_/\\___/\\__,_/\\__,_/      \\___/\\____/_/ /_/_/ /_/\\___/\\___/\\__/  %b\n" "$C_SRVR" "$RST"
    printf "\n"
    printf "  %b%b Unified Command Center %b— 73 commands across 9 sections%b\n" "$BLD" "$C_HEAD" "$C_DIM" "$RST"
    printf "  %bHM, VM mesh, git repos, cloud drives, sync, file servers, dev servers, services, security%b\n\n" "$C_DIM" "$RST"

    printf "  %bSYNTAX%b\n" "$BLD" "$RST"
    printf "    %bconnect%b                         %b# REPL keybind mode, full (default)%b\n" "$C_INFO" "$RST" "$C_DIM" "$RST"
    printf "    %bconnect%b %brepl%b %b[full|compact|resume]%b    %b# REPL keybind mode%b\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %bconnect%b %btui%b %b[full|compact|resume]%b     %b# TUI mode (type commands)%b\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %bconnect%b %bstatus%b %b[full|compact|resume]%b  %b# Single-run dashboard, exit%b\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %bconnect%b %blogs%b                    %b# JSON dump of all data%b\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %bconnect%b %b<command>%b               %b# Run a single command%b\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %bconnect%b %b-h%b | %b--help%b             %b# This help page%b\n\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"

    printf "  %bMODES%b\n" "$BLD" "$RST"
    printf "    %bREPL%b     %b(default)%b  Single keypress navigation: %ba-i%b sections, %bShift%b actions, %bp%b profile, %br%b refresh\n" "$C_INFO" "$RST" "$C_DIM" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_OK" "$RST"
    printf "    %bTUI%b                Type full commands + Enter, same keybinds also work via %bfull%b/%bcompact%b/%bresume%b\n" "$C_INFO" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_OK" "$RST"
    printf "    %bStatus%b             Print dashboard once and exit\n\n" "$C_INFO" "$RST"

    # ── A) MESH ──
    printf "  %b━━ A) HOME-MANAGER%b %b— Nix flake build/switch for VM configs%b %b(2 commands)%b\n" "$C_HM" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bhm-build%b             Build home-manager flake\n" "$C_HM" "$RST"
    printf "    %bhm-switch%b            Build + activate home-manager\n\n" "$C_HM" "$RST"

    printf "  %b━━ B) MESH%b %b— WireGuard VPN, VM mounts, OCI lifecycle, phone%b %b(10 commands)%b\n" "$C_MESH" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bmount-vm%b [NAME]      Mount single VM via SSHFS %b(interactive picker)%b\n" "$C_MESH" "$RST" "$C_DIM" "$RST"
    printf "    %bunmount-vm%b [NAME]    Unmount single VM\n" "$C_MESH" "$RST"
    printf "    %bmount-all-vm%b         Mount all configured VMs\n" "$C_MESH" "$RST"
    printf "    %bunmount-all%b          Unmount everything %b(VMs + drives + phone)%b\n" "$C_MESH" "$RST" "$C_DIM" "$RST"
    printf "    %bmount-phone%b          Mount phone via KDE Connect\n" "$C_MESH" "$RST"
    printf "    %bunmount-phone%b        Unmount phone\n" "$C_MESH" "$RST"
    printf "    %bflex-start%b [NAME]    Start OCI A1.Flex VM\n" "$C_MESH" "$RST"
    printf "    %bflex-stop%b [NAME]     Stop OCI A1.Flex VM\n" "$C_MESH" "$RST"
    printf "    %bflex-reset%b [NAME]    Reset OCI A1.Flex VM\n" "$C_MESH" "$RST"
    printf "    %bflex-status%b [NAME]   Show OCI A1.Flex VM status\n\n" "$C_MESH" "$RST"

    # ── B) GIT ──
    printf "  %b━━ C) GIT%b %b— Multi-repo management, sync, fetch, branches, stash%b %b(23 commands)%b\n" "$C_GIT" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bsync%b                 Commit + pull + push all repos\n" "$C_GIT" "$RST"
    printf "    %bpull%b                 Pull all repos\n" "$C_GIT" "$RST"
    printf "    %bpush%b                 Push all repos\n" "$C_GIT" "$RST"
    printf "    %bcommit%b               Commit all dirty repos\n" "$C_GIT" "$RST"
    printf "    %bfetch%b                Fetch all repos %b(parallel)%b\n" "$C_GIT" "$RST" "$C_DIM" "$RST"
    printf "    %bfetch-status%b         Parallel fetch + status table\n" "$C_GIT" "$RST"
    printf "    %bclone%b                Clone menu %b(multi-select)%b\n" "$C_GIT" "$RST" "$C_DIM" "$RST"
    printf "    %bdirty%b                Show repos with issues %b(dirty/behind/ahead)%b\n" "$C_GIT" "$RST" "$C_DIM" "$RST"
    printf "    %bgit-refresh%b          Fast local-only status table\n" "$C_GIT" "$RST"
    printf "    %buntracked%b            List untracked files\n" "$C_GIT" "$RST"
    printf "    %bunstaged%b             List unstaged changes\n" "$C_GIT" "$RST"
    printf "    %bignored%b              List ignored files\n" "$C_GIT" "$RST"
    printf "    %bgit-remotes%b          Show all remotes\n" "$C_GIT" "$RST"
    printf "    %bgit-branches%b         Show all branches\n" "$C_GIT" "$RST"
    printf "    %bgit-tags%b             Show all tags\n" "$C_GIT" "$RST"
    printf "    %bgit-log%b              Show last 10 commits per repo\n" "$C_GIT" "$RST"
    printf "    %bgit-stash-list%b       Show stashes across repos\n" "$C_GIT" "$RST"
    printf "    %bgit-diff%b             Show unstaged diffs %b(--stat)%b\n" "$C_GIT" "$RST" "$C_DIM" "$RST"
    printf "    %bgit-gc%b               Run garbage collection\n" "$C_GIT" "$RST"
    printf "    %bgit-prune%b            Prune unreachable objects\n" "$C_GIT" "$RST"
    printf "    %bmerge%b                Toggle merge strategy %b(ours/theirs)%b\n" "$C_GIT" "$RST" "$C_DIM" "$RST"
    printf "    %brestore-symlinks%b     Restore 0.spec symlinks\n" "$C_GIT" "$RST"
    printf "    %bgit-notok%b            Same as dirty\n\n" "$C_GIT" "$RST"

    # ── C) DRIVES ──
    printf "  %b━━ D) FUSE DRIVES%b %b— Rclone cloud drive mounts (GDrive, etc)%b %b(5 commands)%b\n" "$C_DRIVE" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bmount-drive%b [NAME]   Mount a cloud drive %b(interactive picker)%b\n" "$C_DRIVE" "$RST" "$C_DIM" "$RST"
    printf "    %bunmount-drive%b [NAME] Unmount a cloud drive\n" "$C_DRIVE" "$RST"
    printf "    %bmount-all-drives%b     Mount all drives\n" "$C_DRIVE" "$RST"
    printf "    %bunmount-all-drives%b   Unmount all drives\n" "$C_DRIVE" "$RST"
    printf "    %btoggle-drives%b        Toggle all %b(mount unmounted, unmount mounted)%b\n\n" "$C_DRIVE" "$RST" "$C_DIM" "$RST"

    # ── D) SYNC ──
    printf "  %b━━ E) SYNC%b %b— Rclone sync/bisync rules, background jobs%b %b(17 commands)%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bsync-run%b             Run all enabled rules\n" "$C_SYNC" "$RST"
    printf "    %bsync-run-bg%b          Run all in background %b(non-interactive)%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"
    printf "    %bsync-run-rule%b NAME   Run a specific rule %b[--dry-run] [--background]%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"
    printf "    %bsync-add%b             Add new rule %b(wizard)%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"
    printf "    %bsync-delete%b          Delete a rule\n" "$C_SYNC" "$RST"
    printf "    %bsync-toggle%b          Enable/disable a rule\n" "$C_SYNC" "$RST"
    printf "    %bsync-quick%b           One-time sync %b(no saved rule)%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"
    printf "    %bsync-edit%b            Edit rules file in \$EDITOR\n" "$C_SYNC" "$RST"
    printf "    %bsync-list%b            List all rules with details\n" "$C_SYNC" "$RST"
    printf "    %bsync-status%b          Full status %b(remotes + rules + jobs + log)%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"
    printf "    %bsync-jobs%b            Show running jobs\n" "$C_SYNC" "$RST"
    printf "    %bsync-cancel%b          Cancel a job\n" "$C_SYNC" "$RST"
    printf "    %bsync-cancel-id%b ID    Cancel job by ID\n" "$C_SYNC" "$RST"
    printf "    %bsync-kill%b            Kill all sync jobs\n" "$C_SYNC" "$RST"
    printf "    %bsync-clear-jobs%b      Clear completed/failed\n" "$C_SYNC" "$RST"
    printf "    %bsync-to%b SRC DEST     Ad-hoc one-way sync %b[--dry-run]%b\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"
    printf "    %bbisync-to%b P1 P2      Ad-hoc bidirectional %b[--dry-run] [--resync]%b\n\n" "$C_SYNC" "$RST" "$C_DIM" "$RST"

    # ── E) DATA SERVERS ──
    printf "  %b━━ F) DATA SERVERS%b %b— WebDAV, SFTP, HTTP+Eruda, Unison bisync%b %b(6 commands)%b\n" "$C_SRVR" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bserver-start%b         Start a server %b(WebDAV/SFTP/HTTP picker)%b\n" "$C_SRVR" "$RST" "$C_DIM" "$RST"
    printf "    %bserver-stop%b          Stop a running server\n" "$C_SRVR" "$RST"
    printf "    %bserver-restart%b       Restart a running server\n" "$C_SRVR" "$RST"
    printf "    %bserver-mode%b          Toggle %blan%b/%blocal%b bind mode %b(persists to config)%b\n" "$C_SRVR" "$RST" "$C_OK" "$RST" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %bserver-status%b        Show server status table\n" "$C_SRVR" "$RST"
    printf "    %bbisync%b               Run Unison bidirectional sync\n\n" "$C_SRVR" "$RST"

    # ── F) SERVICES ──
    printf "  %b━━ H) SERVICES%b %b— Cloud services deployed across VMs%b %b(read-only)%b\n\n" "$C_SVC" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"

    # ── G) WEBSERVER ──
    printf "  %b━━ G) WEBSERVER%b %b— Auto-detected dev servers (Vite, SvelteKit, etc)%b %b(read-only)%b\n\n" "$C_WEB" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"


    # ── H) HOME-MANAGER ──

    # ── Setup ──
    printf "  %b━━ SETUP%b %b— Dependencies, config, logs%b %b(11 commands)%b\n" "$C_DIM" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bsettings%b             Settings menu %b(dirs, merge strategy)%b\n" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bconfig-set%b K V       Set a config value\n" "$C_DIM" "$RST"
    printf "    %bdeps%b                 Dependency status + install\n" "$C_DIM" "$RST"
    printf "    %bdeps-core%b            Install core deps %b(git, jq, rclone)%b\n" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bdeps-phone%b           Install phone deps %b(kdeconnect)%b\n" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bdeps-cloud%b           Install cloud deps %b(oci, gh, gcloud)%b\n" "$C_DIM" "$RST" "$C_DIM" "$RST"
    printf "    %bremotes%b              Configure rclone remotes\n" "$C_DIM" "$RST"
    printf "    %bedit-workdir%b         Change git working directory\n" "$C_DIM" "$RST"
    printf "    %bedit-config%b          Open config JSON in editor\n" "$C_DIM" "$RST"
    printf "    %bview-log%b             Show last 30 log lines\n" "$C_DIM" "$RST"
    printf "    %bclear-log%b            Truncate log file\n\n" "$C_DIM" "$RST"

    # ── Examples ──
    printf "  %bEXAMPLES%b\n" "$BLD" "$RST"
    printf "    %b$%b connect                              %b# REPL mode, full (default)%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect repl compact                 %b# REPL mode, compact (no services detail)%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect repl resume                  %b# REPL mode, resume (one-liner summary)%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect tui                          %b# TUI mode (type commands)%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect status                       %b# Single-run dashboard%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect logs | jq .mesh              %b# JSON data, pipe to jq%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect sync-run-bg                  %b# Sync all in background%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect mount-all-vm                 %b# Mount all VMs%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect server-start                 %b# Start a file server%b\n" "$C_OK" "$RST" "$C_DIM" "$RST"
    printf "    %b$%b connect flex-start && connect mount-vm   %b# Boot + mount VM%b\n\n" "$C_OK" "$RST" "$C_DIM" "$RST"

    # ── Footer ──
    printf "  %bConfig:%b  %s/connect-*.json\n" "$C_DIM" "$RST" "$SCRIPT_DIR"
    printf "  %bTotal:%b   %b73 commands%b %b(A:2 B:10 C:23 D:5 E:17 F:6 Setup:11)%b  %b+ 3 read-only sections (G,H,I)%b\n\n" "$C_DIM" "$RST" "$C_INFO" "$RST" "$C_DIM" "$RST" "$C_DIM" "$RST"
}

# =============================================================================
# CLI HELPERS
# =============================================================================

_mount_all_vms() {
    local vc vi vn vr
    vc=$(_jq '.mesh.vms | length'); vi=0
    while [ "$vi" -lt "$vc" ]; do
        vn=$(_jq -r ".mesh.vms[$vi].name"); vr=$(_jq -r ".mesh.vms[$vi].remote")
        mount_vm "$vn" "$vr"; vi=$((vi+1))
    done
}

_unmount_all_vms() {
    local vc vi vn
    vc=$(_jq '.mesh.vms | length'); vi=0
    while [ "$vi" -lt "$vc" ]; do
        vn=$(_jq -r ".mesh.vms[$vi].name"); unmount_vm "$vn"; vi=$((vi+1))
    done
}

_mount_all_drives() {
    local dc di dn dr
    dc=$(_jq '.fuse_drives | length'); di=0
    while [ "$di" -lt "$dc" ]; do
        dn=$(_jq -r ".fuse_drives[$di].name"); dr=$(_jq -r ".fuse_drives[$di].remote")
        mount_drive "$dn" "$dr"; di=$((di+1))
    done
}

_unmount_all_drives() {
    local dc di dn
    dc=$(_jq '.fuse_drives | length'); di=0
    while [ "$di" -lt "$dc" ]; do
        dn=$(_jq -r ".fuse_drives[$di].name"); unmount_drive "$dn"; di=$((di+1))
    done
}

_toggle_all_drives() {
    local dc di dn dr
    dc=$(_jq '.fuse_drives | length'); di=0
    while [ "$di" -lt "$dc" ]; do
        dn=$(_jq -r ".fuse_drives[$di].name"); dr=$(_jq -r ".fuse_drives[$di].remote")
        if is_mounted "$MOUNT_DIR/$dn"; then
            unmount_drive "$dn"
        else
            mount_drive "$dn" "$dr"
        fi
        di=$((di+1))
    done
}

_resume_view() {
    [ -z "$CC_DATA" ] && collect_all
    printf "\n${BLD}━━━ Resume ━━━${RST}\n\n"

    # HOME-MANAGER: one liner
    local hm_count; hm_count=$(_d '.home_manager | length')
    local hm_clean=0 hm_dirty=0 i=0
    while [ "$i" -lt "$hm_count" ]; do
        local hd; hd=$(_d -r ".home_manager[$i].dirty")
        [ "$hd" -gt 0 ] 2>/dev/null && hm_dirty=$((hm_dirty+1)) || hm_clean=$((hm_clean+1))
        i=$((i+1))
    done
    printf "  ${C_HM}HM FLAKES${RST}  %s flakes" "$hm_count"
    [ "$hm_clean" -gt 0 ] && printf "  ${C_OK}%s clean${RST}" "$hm_clean"
    [ "$hm_dirty" -gt 0 ] && printf "  ${C_WARN}%s dirty${RST}" "$hm_dirty"
    printf "\n"

    # MESH: one liner per VM
    local vm_count; vm_count=$(_d '.mesh.vms | length')
    local vm_up=$(_d -r '.gauges.mesh_cur')
    printf "  ${C_MESH}MESH${RST}   %s/%s VMs " "$vm_up" "$vm_count"
    local v=0; while [ "$v" -lt "$vm_count" ]; do
        local name mup
        name=$(_d -r ".mesh.vms[$v].name")
        mup=$(_d -r ".mesh.vms[$v].mounts_up")
        [ "$mup" -gt 0 ] 2>/dev/null && printf "${C_OK}${S_DOT}%s${RST} " "$name" || printf "${C_DIM}${S_STOP}%s${RST} " "$name"
        v=$((v+1))
    done
    local phone_stat; phone_stat=$(_d -r '.mesh.phone.status')
    [ "$phone_stat" = "mounted" ] && printf "${C_OK}${S_DOT}phone${RST}" || printf "${C_DIM}${S_STOP}phone${RST}"
    printf "\n"

    # GIT: one liner summary from pre-computed totals
    local gt_total gt_cloned gt_clean gt_dirty gt_push gt_pull
    gt_total=$(_d -r '.git.totals.total')
    gt_cloned=$(_d -r '.git.totals.cloned')
    gt_clean=$(_d -r '.git.totals.clean')
    gt_dirty=$(_d -r '.git.totals.dirty')
    gt_push=$(_d -r '.git.totals.push')
    gt_pull=$(_d -r '.git.totals.pull')
    printf "  ${C_GIT}GIT${RST}    %s/%s cloned" "$gt_cloned" "$gt_total"
    [ "$gt_clean" -gt 0 ] 2>/dev/null && printf "  ${C_OK}%s clean${RST}" "$gt_clean"
    [ "$gt_dirty" -gt 0 ] 2>/dev/null && printf "  ${C_WARN}%s dirty${RST}" "$gt_dirty"
    [ "$gt_push" -gt 0 ] 2>/dev/null && printf "  ${C_WARN}%s ahead${RST}" "$gt_push"
    [ "$gt_pull" -gt 0 ] 2>/dev/null && printf "  ${C_INFO}%s behind${RST}" "$gt_pull"
    printf "\n"

    # DRIVES: one liner
    local drive_count; drive_count=$(_d '.drives.cloud | length')
    local drive_up=0 d=0
    while [ "$d" -lt "$drive_count" ]; do
        local dname dm
        dname=$(_d -r ".drives.cloud[$d].name")
        dm=$(_d -r ".drives.cloud[$d].mounted")
        [ "$dm" = "true" ] && { drive_up=$((drive_up+1)); printf ""; }
        d=$((d+1))
    done
    printf "  ${C_DRIVE}DRIVE${RST}  %s/%s mounted " "$drive_up" "$drive_count"
    d=0; while [ "$d" -lt "$drive_count" ]; do
        local dname dm
        dname=$(_d -r ".drives.cloud[$d].name")
        dm=$(_d -r ".drives.cloud[$d].mounted")
        [ "$dm" = "true" ] && printf "${C_OK}${S_DOT}%s${RST} " "$dname" || printf "${C_DIM}${S_STOP}%s${RST} " "$dname"
        d=$((d+1))
    done
    printf "\n"

    # SYNC: one liner
    local rules; rules=$(_d '.sync.rules')
    local rule_count; rule_count=$(echo "$rules" | jq 'length')
    local enabled_cnt; enabled_cnt=$(echo "$rules" | jq '[.[] | select(.enabled == true)] | length')
    local run_count; run_count=$(_d '.sync.running_jobs | length')
    printf "  ${C_SYNC}SYNC${RST}   %s rules (%s enabled)" "$rule_count" "$enabled_cnt"
    [ "$run_count" -gt 0 ] && printf "  ${C_OK}${S_PLAY} %s running${RST}" "$run_count"
    printf "\n"

    # SERVERS: one liner
    local srv_count; srv_count=$(_d '.servers.data_servers | length')
    local srv_up=0 s=0
    while [ "$s" -lt "$srv_count" ]; do
        local sr; sr=$(_d -r ".servers.data_servers[$s].running")
        [ "$sr" = "true" ] && srv_up=$((srv_up+1))
        s=$((s+1))
    done
    printf "  ${C_SRVR}DATA SRVR${RST}   %s/%s servers running\n" "$srv_up" "$srv_count"

    # SERVICES: one liner (last)
    local svc_total; svc_total=$(_d '.services | length')
    printf "  ${C_SVC}SERVICES${RST}   %s services across %s VMs\n" "$svc_total" "$vm_count"

    printf "\n"
}

_logs_json() {
    # Single-source: collect all data once, output CC_DATA
    [ -z "$CC_DATA" ] && collect_all
    printf '%s\n' "$CC_DATA"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Handle deps/help commands BEFORE requiring jq (like mount.sh)
    case "${1:-}" in
        deps)            deps_menu; return ;;
        deps-core)       install_deps_category "core"; return ;;
        deps-phone)      install_deps_category "phone"; return ;;
        deps-cloud)      install_deps_category "cloud"; return ;;
        --help|-h|help)
            if ! command -v jq >/dev/null 2>&1; then
                printf "${C_ERR}${S_FAIL}${RST} jq not installed — showing minimal help\n\n"
                printf "${BLD}Dependency commands (work without jq):${RST}\n"
                printf "  deps           Show dependency status\n"
                printf "  deps-core      Install core deps (git, jq, rclone, fusermount)\n"
                printf "  deps-phone     Install phone deps (kdeconnect, qdbus)\n"
                printf "  deps-cloud     Install cloud deps (oci, gh, gcloud)\n"
                printf "\nRun ${C_INFO}deps-core${RST} first, then ${C_INFO}--help${RST} for full help.\n"
                return
            fi
            ;;
    esac

    local _main_t0; _main_t0=$(date +%s%N 2>/dev/null || echo 0)
    _main_perf() {
        local now; now=$(date +%s%N 2>/dev/null || echo 0)
        local ms=$(( (now - _main_t0) / 1000000 ))
        printf >&2 "  [perf] %-20s %5dms\n" "$1" "$ms"
        _main_t0=$now
    }
    cc_probe_env;  _main_perf "probe_env"
    cc_build_mesh; _main_perf "build_mesh"
    cc_build_hm;   _main_perf "build_hm"
    load_config;   _main_perf "load_config"

    case "${1:-}" in
        # ── Modes ──
        "")              run_keys "${2:-full}" ;;
        repl)            run_keys "${2:-full}" ;;
        tui)             run_tui "${2:-full}" ;;
        status)
            CC_PROFILE="${2:-full}"
            if [ "$CC_PROFILE" = "resume" ]; then
                collect_all; _resume_view
            else
                render_dashboard
            fi
            ;;
        logs)            _logs_json ;;
        --help|-h|help)  show_help ;;

        # ── Git ──
        git-status)      render_git ;;
        git-sync)        git_cmd_sync ;;
        git-pull)        git_cmd_pull ;;
        git-push)        git_cmd_push ;;
        git-commit)      git_cmd_commit ;;
        git-fetch)       git_cmd_fetch ;;
        git-fetch-status) git_cmd_fetch_status ;;
        git-clone)       git_cmd_clone_menu ;;
        git-untracked)   git_cmd_untracked ;;
        git-unstaged)    git_cmd_unstaged ;;
        git-ignored)     git_cmd_ignored ;;
        git-workdir)     edit_workdir ;;
        git-merge)       git_toggle_merge ;;
        git-dirty)       git_cmd_dirty ;;
        git-notok)       git_cmd_dirty ;;
        git-refresh)     render_git ;;
        git-remotes)     git_cmd_remotes ;;
        git-branches)    git_cmd_branches ;;
        git-tags)        git_cmd_tags ;;
        git-log)         git_cmd_log ;;
        git-stash-list)  git_cmd_stash_list ;;
        git-diff)        git_cmd_diff ;;
        git-gc)          git_cmd_gc ;;
        git-prune)       git_cmd_prune ;;

        # ── Mesh (VM mounts) ──
        mount-vm)
            if [ -n "${2:-}" ]; then
                mount_vm "$2" "$2"
            else
                select_and_mount_vm
            fi ;;
        unmount-vm)
            if [ -n "${2:-}" ]; then
                unmount_vm "$2"
            else
                select_and_unmount_vm
            fi ;;
        mount-all-vm)    _mount_all_vms ;;
        unmount-all)
            _unmount_all_vms
            _unmount_all_drives
            unmount_phone ;;
        mount-phone)     mount_phone ;;
        unmount-phone)   unmount_phone ;;

        # ── OCI Flex ──
        flex-start)      flex_select_and_action "start" ;;
        flex-stop)       flex_select_and_action "stop" ;;
        flex-reset)      flex_select_and_action "reset" ;;
        flex-status)     flex_select_and_action "status" ;;

        # ── Drives ──
        mount-drive)
            if [ -n "${2:-}" ]; then
                local dr; dr=$(_jq -r ".fuse_drives[] | select(.name==\"$2\") | .remote")
                [ -n "$dr" ] && mount_drive "$2" "$dr" || printf "${C_ERR}Drive not found: %s${RST}\n" "$2"
            else
                select_and_mount_drive
            fi ;;
        unmount-drive)
            if [ -n "${2:-}" ]; then
                unmount_drive "$2"
            else
                select_and_unmount_drive
            fi ;;
        mount-all-drives)   _mount_all_drives ;;
        unmount-all-drives) _unmount_all_drives ;;
        toggle-drives)      _toggle_all_drives ;;

        # ── Sync ──
        sync-run)        sync_run_all ;;
        sync-add)        sync_add_rule_wizard ;;
        sync-delete)     sync_delete_rule ;;
        sync-toggle)     sync_toggle_rule ;;
        sync-quick)      sync_quick_menu ;;
        sync-edit)       sync_edit_rules ;;
        sync-jobs)       sync_show_jobs ;;
        sync-cancel)     sync_cancel_job ;;
        sync-kill)       sync_kill_all ;;
        sync-clear-jobs) sync_clear_completed ;;
        sync-run-rule)   shift; sync_run_rule_cli "$@" ;;
        sync-list)       sync_list_cli ;;
        sync-run-bg)     sync_run_all_bg ;;
        sync-to)         shift; sync_adhoc "$@" ;;
        bisync-to)       shift; bisync_adhoc "$@" ;;
        sync-cancel-id)  shift; sync_cancel_by_id "$@" ;;
        sync-status)     sync_full_status ;;

        # ── Servers ──
        server-start)    server_start ;;
        server-stop)     server_stop ;;
        server-restart)  server_restart ;;
        server-mode)     server_mode ;;
        server-status)   server_status ;;
        bisync)          server_bisync ;;

        # ── Home-Manager ──
        hm-build)        hm_build ;;
        hm-switch)       hm_switch ;;

        # ── Security ──
        security)        render_security ;;

        # ── Setup ──
        settings)        settings_menu ;;
        deps)            deps_menu ;;
        deps-core)       install_deps_category "core" ;;
        deps-phone)      install_deps_category "phone" ;;
        deps-cloud)      install_deps_category "cloud" ;;
        remotes)         configure_remote_menu ;;
        edit-workdir)    edit_workdir ;;
        clear-log)       clear_log ;;
        view-log)        view_log ;;
        edit-config)     edit_config ;;
        config-set)      shift; config_set "$@" ;;
        restore-symlinks) restore_symlinks ;;

        # ── Legacy aliases ──
        status)          render_git ;;
        sync)            git_cmd_sync ;;
        pull)            git_cmd_pull ;;
        push)            git_cmd_push ;;
        commit)          git_cmd_commit ;;
        fetch)           git_cmd_fetch ;;
        clone)           git_cmd_clone_menu ;;
        mount)           _mount_all_vms; _mount_all_drives ;;
        unmount)         _unmount_all_vms; _unmount_all_drives ;;

        *)
            printf "${C_ERR}Unknown command: %s${RST}\n\n" "$1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
