#!/bin/sh
# mesh — WireGuard Mesh VPN Manager
# POSIX-compliant shell script
#
# Flags:    mesh -s|--status  -c|--configs  -p|--peers  -l|--logs
#           mesh -a|--all     -j|--json     -h|--help   --check
# Commands: mesh up  down  full  split

# No set -e: this tool probes peers where failures are expected

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/mesh.json"

# Colors (disable if not a terminal)
init_colors() {
    if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_RED="\033[31m"
        C_GREEN="\033[32m"
        C_YELLOW="\033[33m"
        C_BLUE="\033[34m"
        C_MAGENTA="\033[35m"
        C_CYAN="\033[36m"
        C_DIM="\033[2m"
        C_BG_RED="\033[41m"
        C_BG_GREEN="\033[42m"
        C_BG_YELLOW="\033[43m"
        C_WHITE="\033[37m"
    else
        C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
        C_MAGENTA='' C_CYAN='' C_DIM='' C_BG_RED='' C_BG_GREEN='' C_BG_YELLOW='' C_WHITE=''
    fi

    OK="${C_GREEN}✓${C_RESET}"
    FAIL="${C_RED}✗${C_RESET}"
    WARN="${C_YELLOW}!${C_RESET}"
    INFO="${C_BLUE}→${C_RESET}"

    BADGE_UP="${C_BG_GREEN}${C_WHITE}${C_BOLD} UP ${C_RESET}"
    BADGE_DOWN="${C_BG_RED}${C_WHITE}${C_BOLD} DOWN ${C_RESET}"
    BADGE_SPLIT="${C_BG_GREEN}${C_WHITE}${C_BOLD} SPLIT ${C_RESET}"
    BADGE_FULL="${C_BG_YELLOW}${C_WHITE}${C_BOLD} FULL ${C_RESET}"

    DOT_UP="${C_GREEN}●${C_RESET}"
    DOT_DOWN="${C_RED}○${C_RESET}"
    DOT_STALE="${C_YELLOW}◐${C_RESET}"
    DOT_LOCAL="${C_CYAN}◉${C_RESET}"
    DOT_UNKNOWN="${C_DIM}?${C_RESET}"
    DOT_HUB="${C_GREEN}★${C_RESET}"
    DOT_HUB_DOWN="${C_RED}★${C_RESET}"
}

init_colors

# =============================================================================
# CONFIG PARSER
# =============================================================================

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "$FAIL ${C_RED}Config not found: $CONFIG_FILE${C_RESET}\n"; exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf "$FAIL ${C_RED}jq is required but not installed${C_RESET}\n"; exit 1
    fi

    WG_ADDRESS=$(jq -r '.interface.address' "$CONFIG_FILE")
    WG_CONFIG_DIR=$(jq -r '.interface.config_dir' "$CONFIG_FILE" | sed "s|^~|$HOME|")
    WG_CONFIG_FILE=$(jq -r '.interface.config_file' "$CONFIG_FILE")
    WG_TUNNEL=$(jq -r '.interface.tunnel_name' "$CONFIG_FILE")
    WG_CONF="$WG_CONFIG_DIR/$WG_CONFIG_FILE"

    HUB_NAME=$(jq -r '.hub.name' "$CONFIG_FILE")
    HUB_PORT=$(jq -r '.hub.port' "$CONFIG_FILE")
    HUB_PUBKEY=$(jq -r '.hub.public_key' "$CONFIG_FILE")
    HUB_PUB_IP=$(jq -r '.hub.public_ip' "$CONFIG_FILE")
    HUB_WG_IP=$(jq -r '.hub.wg_ip' "$CONFIG_FILE")

    PEER_COUNT=$(jq '.peers | length' "$CONFIG_FILE")
}

# =============================================================================
# BACKEND DETECTION
# =============================================================================

detect_backend() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files "wireguard-${WG_TUNNEL}.service" >/dev/null 2>&1; then
            BACKEND="systemd"; BACKEND_UNIT="wireguard-${WG_TUNNEL}.service"; return
        fi
    fi
    BACKEND="wg-quick"; BACKEND_UNIT=""
}

is_android() {
    [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]
}

tcp_probe() {
    # TCP reachability: nc (preferred) with /dev/tcp fallback
    host="$1"; port="$2"; wait="${3:-2}"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$wait" "$host" "$port" >/dev/null 2>&1
    else
        timeout "$wait" bash -c "echo > /dev/tcp/${host}/${port}" >/dev/null 2>&1
    fi
}

tunnel_is_up() {
    # On Android, ip link is restricted — probe hub via TCP
    if is_android; then
        tcp_probe "$HUB_WG_IP" 22 2
        return $?
    fi
    ip link show "$WG_TUNNEL" >/dev/null 2>&1
}

# =============================================================================
# TUNNEL MODE DETECTION (full vs split)
# =============================================================================

# Detect tunnel mode from live AllowedIPs or config file
# Sets TUNNEL_MODE to "full", "split", or "unknown"
detect_tunnel_mode() {
    TUNNEL_MODE="unknown"
    TUNNEL_ALLOWED_IPS=""

    # Try live wg show first
    if tunnel_is_up && command -v wg >/dev/null 2>&1; then
        TUNNEL_ALLOWED_IPS=$(sudo wg show "$WG_TUNNEL" allowed-ips 2>/dev/null | head -1 | cut -f2- | tr '\t' ', ' || true)
    fi

    # Fallback to config file
    if [ -z "$TUNNEL_ALLOWED_IPS" ] && [ -f "$WG_CONF" ]; then
        TUNNEL_ALLOWED_IPS=$(grep -i '^AllowedIPs' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
    fi

    case "$TUNNEL_ALLOWED_IPS" in
        *0.0.0.0/0*) TUNNEL_MODE="full" ;;
        *10.0.0.0/24*) TUNNEL_MODE="split" ;;
        "") TUNNEL_MODE="unknown" ;;
        *) TUNNEL_MODE="split" ;;
    esac
}

# =============================================================================
# UTILITIES
# =============================================================================

fmt_bytes() {
    bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then printf "0 B"; return; fi
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%d.%d GiB" "$((bytes / 1073741824))" "$(( (bytes % 1073741824) * 10 / 1073741824 ))"
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%d.%d MiB" "$((bytes / 1048576))" "$(( (bytes % 1048576) * 10 / 1048576 ))"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%d KiB" "$((bytes / 1024))"
    else
        printf "%d B" "$bytes"
    fi
}

fmt_handshake_age() {
    ts="$1"
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then printf "never"; return; fi
    now=$(date +%s); diff=$((now - ts))
    if [ "$diff" -lt 0 ]; then printf "future?"
    elif [ "$diff" -lt 60 ]; then printf "%ds ago" "$diff"
    elif [ "$diff" -lt 3600 ]; then printf "%dm ago" "$((diff / 60))"
    elif [ "$diff" -lt 86400 ]; then printf "%dh ago" "$((diff / 3600))"
    else printf "%dd ago" "$((diff / 86400))"; fi
}

fmt_duration() {
    secs="$1"
    if [ "$secs" -ge 86400 ]; then printf "%dd %dh" "$((secs / 86400))" "$(( (secs % 86400) / 3600 ))"
    elif [ "$secs" -ge 3600 ]; then printf "%dh %dm" "$((secs / 3600))" "$(( (secs % 3600) / 60 ))"
    elif [ "$secs" -ge 60 ]; then printf "%dm %ds" "$((secs / 60))" "$((secs % 60))"
    else printf "%ds" "$secs"; fi
}

handshake_color() {
    ts="$1"
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then printf '%s' "$C_RED"; return; fi
    now=$(date +%s); diff=$((now - ts))
    if [ "$diff" -lt 120 ]; then printf '%s' "$C_GREEN"
    elif [ "$diff" -lt 300 ]; then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_RED"; fi
}

latency_color() {
    ms="$1"
    if [ -z "$ms" ] || [ "$ms" = "-" ]; then printf '%s' "$C_DIM"; return; fi
    int_ms=$(printf '%s' "$ms" | cut -d. -f1)
    if [ "$int_ms" -lt 50 ]; then printf '%s' "$C_GREEN"
    elif [ "$int_ms" -lt 150 ]; then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_RED"; fi
}

loss_color() {
    pct="$1"
    if [ "$pct" = "0" ]; then printf '%s' "$C_GREEN"
    elif [ "$pct" -le 33 ]; then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_RED"; fi
}

cpad() { printf "${2}%-${1}s${C_RESET}" "$3"; }

# =============================================================================
# INTERFACE INFO: MTU, uptime, listening port
# =============================================================================

get_mtu() {
    if tunnel_is_up; then
        ip -j link show "$WG_TUNNEL" 2>/dev/null | jq -r '.[0].mtu // empty' 2>/dev/null || true
    fi
}

get_tunnel_uptime() {
    if [ "$BACKEND" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        ts=$(systemctl show "$BACKEND_UNIT" -p ActiveEnterTimestamp --value 2>/dev/null || true)
        if [ -n "$ts" ] && [ "$ts" != "" ]; then
            epoch=$(date -d "$ts" +%s 2>/dev/null || true)
            if [ -n "$epoch" ]; then
                now=$(date +%s)
                fmt_duration "$((now - epoch))"
                return
            fi
        fi
    fi
    # Fallback: interface creation time from /sys
    if [ -d "/sys/class/net/$WG_TUNNEL" ]; then
        created=$(stat -c %Y "/sys/class/net/$WG_TUNNEL" 2>/dev/null || true)
        if [ -n "$created" ]; then
            now=$(date +%s)
            fmt_duration "$((now - created))"
            return
        fi
    fi
}

# =============================================================================
# WG SHOW DUMP PARSER
# =============================================================================

load_wg_dump() {
    WG_DUMP_LOADED=0; WG_DUMP_PEER_COUNT=0
    WG_IFACE_PUBKEY=""; WG_IFACE_LISTEN_PORT=""

    if ! command -v wg >/dev/null 2>&1; then return 0; fi
    if ! tunnel_is_up; then return 0; fi

    dump=$(sudo wg show "$WG_TUNNEL" dump 2>/dev/null) || { return 0; }

    iface_line=$(printf '%s\n' "$dump" | head -1)
    WG_IFACE_PUBKEY=$(printf '%s' "$iface_line" | cut -f2)
    WG_IFACE_LISTEN_PORT=$(printf '%s' "$iface_line" | cut -f3)

    # Cache: pubkey\tendpoint\thandshake\trx\ttx\tkeepalive\tallowed_ips
    printf '%s\n' "$dump" | tail -n +2 | while IFS='	' read -r pubkey psk endpoint allowed_ips handshake rx tx keepalive; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pubkey" "$endpoint" "$handshake" "$rx" "$tx" "$keepalive" "$allowed_ips"
    done > "$SCRIPT_DIR/.wg_dump_cache"

    WG_DUMP_PEER_COUNT=$(wc -l < "$SCRIPT_DIR/.wg_dump_cache" 2>/dev/null || echo 0)
    WG_DUMP_LOADED=1
}

get_wg_peer_data() {
    search_key="$1"
    if [ "$WG_DUMP_LOADED" != "1" ] || [ ! -f "$SCRIPT_DIR/.wg_dump_cache" ]; then return 1; fi
    line=$(grep "^${search_key}	" "$SCRIPT_DIR/.wg_dump_cache" 2>/dev/null) || return 1
    printf '%s' "$line"
}

cleanup_wg_cache() { rm -f "$SCRIPT_DIR/.wg_dump_cache"; }

# =============================================================================
# PING WITH RTT + LOSS (3 packets)
# =============================================================================

# Returns: rtt_ms loss_pct (space-separated). Empty on failure.
get_ping_stats() {
    wg_ip="$1"
    if ! tunnel_is_up; then return 0; fi
    result=$(ping -c 3 -W 2 "$wg_ip" 2>/dev/null) || { return 0; }
    rtt=$(printf '%s' "$result" | sed -n 's|.*/\([0-9.]*\)/.*|\1|p')
    loss=$(printf '%s' "$result" | sed -n 's/.* \([0-9]*\)% .*/\1/p')
    if [ -n "$rtt" ]; then
        printf '%s %s' "$rtt" "${loss:-0}"
    fi
    return 0
}

# =============================================================================
# ENDPOINT ROAMING DETECTION
# =============================================================================

# Compare configured endpoint (mesh.json public_ip:port) vs live wg endpoint
detect_roaming() {
    configured="$1"   # e.g. 35.226.147.64
    live_ep="$2"      # e.g. 35.226.147.64:51820
    if [ -z "$live_ep" ] || [ "$live_ep" = "(none)" ]; then return 0; fi
    live_ip=$(printf '%s' "$live_ep" | sed 's/:.*//')
    if [ "$live_ip" != "$configured" ]; then
        printf '%s' "$live_ip"
    fi
    return 0
}

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

detect_env() {
    if is_android; then echo "termux"
    elif [ -f /etc/nixos/configuration.nix ]; then echo "nixos"
    elif command -v home-manager >/dev/null 2>&1; then echo "home-manager"
    elif command -v apt-get >/dev/null 2>&1; then echo "debian"
    elif command -v pacman >/dev/null 2>&1; then echo "arch"
    else echo "unknown"
    fi
}

install_hint() {
    dep="$1"; env="$2"
    case "$env" in
        termux)       printf "${C_DIM}→ rebuild termux flake: ~/git/cloud-unix/bb_flakes_termux/build.sh${C_RESET}" ;;
        nixos)        printf "${C_DIM}→ add to desktop flake + rebuild: ~/git/cloud-unix/ba_flakes_desktop/build.sh${C_RESET}" ;;
        home-manager) printf "${C_DIM}→ home-manager switch${C_RESET}" ;;
        debian)
            case "$dep" in
                nc|netcat) printf "${C_DIM}→ sudo apt-get install netcat-openbsd${C_RESET}" ;;
                jq)        printf "${C_DIM}→ sudo apt-get install jq${C_RESET}" ;;
                wg)        printf "${C_DIM}→ sudo apt-get install wireguard-tools${C_RESET}" ;;
                ping)      printf "${C_DIM}→ sudo apt-get install iputils-ping${C_RESET}" ;;
                *)         printf "${C_DIM}→ sudo apt-get install ${dep}${C_RESET}" ;;
            esac ;;
        arch)
            case "$dep" in
                nc|netcat) printf "${C_DIM}→ sudo pacman -S openbsd-netcat${C_RESET}" ;;
                jq)        printf "${C_DIM}→ sudo pacman -S jq${C_RESET}" ;;
                wg)        printf "${C_DIM}→ sudo pacman -S wireguard-tools${C_RESET}" ;;
                *)         printf "${C_DIM}→ sudo pacman -S ${dep}${C_RESET}" ;;
            esac ;;
        *) printf "${C_DIM}→ install ${dep} via your package manager${C_RESET}" ;;
    esac
}

check_deps() {
    printf "${C_BOLD}=== Dependency Check ===${C_RESET}\n\n"
    env=$(detect_env)
    printf "  Environment: ${C_CYAN}${env}${C_RESET}\n\n"
    missing_required=""

    printf "${C_BOLD}Required:${C_RESET}\n"
    for dep in jq nc; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf "  $OK ${C_GREEN}%-12s${C_RESET} %s\n" "$dep" "$("$dep" --version 2>&1 | head -1)"
        else
            printf "  $FAIL ${C_RED}%-12s${C_RESET} not found  " "$dep"
            install_hint "$dep" "$env"; printf "\n"
            missing_required="${missing_required}${dep} "
        fi
    done
    # ip only required on non-Android
    if ! is_android; then
        if command -v ip >/dev/null 2>&1; then
            printf "  $OK ${C_GREEN}%-12s${C_RESET} %s\n" "ip" "$(ip --version 2>&1 | head -1)"
        else
            printf "  $FAIL ${C_RED}%-12s${C_RESET} not found  " "ip"
            install_hint "ip" "$env"; printf "\n"
            missing_required="${missing_required}ip "
        fi
    fi

    printf "\n${C_BOLD}Optional:${C_RESET}\n"
    for dep in wg ping sudo journalctl systemctl; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf "  $OK ${C_GREEN}%-12s${C_RESET}\n" "$dep"
        else
            printf "  $WARN ${C_YELLOW}%-12s${C_RESET} not found  " "$dep"
            install_hint "$dep" "$env"; printf "\n"
        fi
    done

    printf "\n${C_BOLD}Capabilities:${C_RESET}\n"
    if command -v wg >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        printf "  $OK wg show dump      ${C_DIM}handshake, transfer, endpoint, keepalive${C_RESET}\n"
    else
        printf "  $WARN wg show dump      ${C_DIM}needs wg + sudo${C_RESET}\n"
    fi
    if command -v nc >/dev/null 2>&1; then
        printf "  $OK peer probing      ${C_DIM}TCP reachability via nc${C_RESET}\n"
    else
        printf "  $WARN peer probing     ${C_DIM}/dev/tcp fallback (nc missing)${C_RESET}\n"
    fi
    if command -v ping >/dev/null 2>&1 && ! is_android; then
        printf "  $OK ping stats        ${C_DIM}RTT + packet loss${C_RESET}\n"
    else
        printf "  $WARN ping stats        ${C_DIM}unavailable (Android/missing)${C_RESET}\n"
    fi
    if command -v journalctl >/dev/null 2>&1; then
        printf "  $OK journal logs      ${C_DIM}tunnel event history${C_RESET}\n"
    else
        printf "  $WARN journal logs      ${C_DIM}needs journalctl${C_RESET}\n"
    fi

    if [ -n "$missing_required" ]; then
        printf "\n$FAIL ${C_RED}Missing required: ${missing_required}${C_RESET}\n"; return 1
    else
        printf "\n$OK ${C_GREEN}All required dependencies installed${C_RESET}\n"; return 0
    fi
}

# =============================================================================
# ACTION COMMANDS: up, down, full, split
# =============================================================================

cmd_up() {
    if tunnel_is_up; then
        printf "$WARN ${C_YELLOW}Tunnel ${WG_TUNNEL} is already up${C_RESET}\n"; return 0
    fi
    if is_android; then
        printf "$WARN ${C_YELLOW}Android detected — WireGuard is managed by the WireGuard app${C_RESET}\n"
        printf "$INFO Enable the tunnel in the ${C_BOLD}WireGuard app${C_RESET} (Play Store), then re-run mesh\n"
        return 0
    fi
    printf "$INFO Starting tunnel ${C_BOLD}${WG_TUNNEL}${C_RESET}...\n"
    if [ "$BACKEND" = "systemd" ]; then
        if sudo systemctl start "$BACKEND_UNIT" 2>&1; then
            printf "$OK ${C_GREEN}Tunnel started (systemd: ${BACKEND_UNIT})${C_RESET}\n"
        else printf "$FAIL ${C_RED}Failed to start tunnel${C_RESET}\n"; return 1; fi
    else
        if [ ! -f "$WG_CONF" ]; then
            printf "$FAIL ${C_RED}Config not found: ${WG_CONF}${C_RESET}\n"; return 1
        fi
        if sudo wg-quick up "$WG_CONF" 2>&1; then
            printf "$OK ${C_GREEN}Tunnel started (wg-quick)${C_RESET}\n"
        else printf "$FAIL ${C_RED}Failed to start tunnel${C_RESET}\n"; return 1; fi
    fi
}

cmd_down() {
    if ! tunnel_is_up; then
        printf "$WARN ${C_YELLOW}Tunnel ${WG_TUNNEL} is already down${C_RESET}\n"; return 0
    fi
    if is_android; then
        printf "$WARN ${C_YELLOW}Android detected — disable the tunnel in the ${C_BOLD}WireGuard app${C_RESET}\n"
        return 0
    fi
    printf "$INFO Stopping tunnel ${C_BOLD}${WG_TUNNEL}${C_RESET}...\n"
    if [ "$BACKEND" = "systemd" ]; then
        if sudo systemctl stop "$BACKEND_UNIT" 2>&1; then
            printf "$OK ${C_GREEN}Tunnel stopped (systemd)${C_RESET}\n"
        else printf "$FAIL ${C_RED}Failed to stop tunnel${C_RESET}\n"; return 1; fi
    else
        if sudo wg-quick down "$WG_CONF" 2>&1; then
            printf "$OK ${C_GREEN}Tunnel stopped (wg-quick)${C_RESET}\n"
        else printf "$FAIL ${C_RED}Failed to stop tunnel${C_RESET}\n"; return 1; fi
    fi
}

cmd_full() {
    if ! tunnel_is_up; then
        printf "$FAIL ${C_RED}Tunnel is down — start with: mesh up${C_RESET}\n"; return 1
    fi
    if ! command -v wg >/dev/null 2>&1; then
        printf "$FAIL ${C_RED}wg command not found${C_RESET}\n"; return 1
    fi

    printf "$INFO Switching to ${C_BOLD}full tunnel${C_RESET} (all traffic via WireGuard)...\n"

    # Set AllowedIPs to 0.0.0.0/0 for the hub peer
    sudo wg set "$WG_TUNNEL" peer "$HUB_PUBKEY" allowed-ips 0.0.0.0/0 2>&1
    # Add default route through wg0
    sudo ip route replace default dev "$WG_TUNNEL" 2>&1 || true

    printf "$OK ${C_GREEN}Full tunnel enabled — all traffic routes through %s${C_RESET}\n" "$HUB_NAME"
    detect_tunnel_mode
    printf "  Mode:     %b  ${C_DIM}AllowedIPs: %s${C_RESET}\n" "$BADGE_FULL" "$TUNNEL_ALLOWED_IPS"
}

cmd_split() {
    if ! tunnel_is_up; then
        printf "$FAIL ${C_RED}Tunnel is down — start with: mesh up${C_RESET}\n"; return 1
    fi
    if ! command -v wg >/dev/null 2>&1; then
        printf "$FAIL ${C_RED}wg command not found${C_RESET}\n"; return 1
    fi

    printf "$INFO Switching to ${C_BOLD}split tunnel${C_RESET} (only mesh traffic via WireGuard)...\n"

    # Set AllowedIPs to mesh subnet only
    sudo wg set "$WG_TUNNEL" peer "$HUB_PUBKEY" allowed-ips 10.0.0.0/24 2>&1
    # Remove default route through wg0 if present
    sudo ip route del default dev "$WG_TUNNEL" 2>/dev/null || true

    printf "$OK ${C_GREEN}Split tunnel enabled — only 10.0.0.0/24 routes through %s${C_RESET}\n" "$HUB_NAME"
    detect_tunnel_mode
    printf "  Mode:     %b  ${C_DIM}AllowedIPs: %s${C_RESET}\n" "$BADGE_SPLIT" "$TUNNEL_ALLOWED_IPS"
}

# =============================================================================
# SECTION: STATUS
# =============================================================================

section_status() {
    printf "\n${C_DIM}──${C_RESET} ${C_BOLD}Status${C_RESET} ${C_DIM}──────────────────────────────────────────────────────────${C_RESET}\n\n"

    # Tunnel state
    if tunnel_is_up; then
        printf "  Tunnel:   %b" "$BADGE_UP"
    else
        printf "  Tunnel:   %b" "$BADGE_DOWN"
    fi
    if is_android; then
        printf "  ${C_DIM}managed by WireGuard app${C_RESET}"
    elif [ "$BACKEND" = "systemd" ]; then
        unit_state=$(systemctl is-active "$BACKEND_UNIT" 2>/dev/null || echo "unknown")
        printf "  ${C_DIM}systemd: ${BACKEND_UNIT} [${unit_state}]${C_RESET}"
    else
        printf "  ${C_DIM}wg-quick${C_RESET}"
    fi
    printf "\n"

    # Tunnel mode (full/split)
    detect_tunnel_mode
    if [ "$TUNNEL_MODE" = "full" ]; then
        printf "  Mode:     %b  ${C_DIM}AllowedIPs: %s${C_RESET}\n" "$BADGE_FULL" "$TUNNEL_ALLOWED_IPS"
    elif [ "$TUNNEL_MODE" = "split" ]; then
        printf "  Mode:     %b  ${C_DIM}AllowedIPs: %s${C_RESET}\n" "$BADGE_SPLIT" "$TUNNEL_ALLOWED_IPS"
    else
        printf "  Mode:     ${C_DIM}unknown${C_RESET}\n"
    fi

    printf "  Local:    ${C_CYAN}%s${C_RESET}\n" "$WG_ADDRESS"

    # MTU
    mtu=$(get_mtu)
    if [ -n "$mtu" ]; then
        if [ "$mtu" -lt 1400 ] 2>/dev/null; then
            printf "  MTU:      ${C_YELLOW}%s${C_RESET} ${C_DIM}(low — may cause fragmentation)${C_RESET}\n" "$mtu"
        else
            printf "  MTU:      ${C_DIM}%s${C_RESET}\n" "$mtu"
        fi
    fi

    # Uptime
    uptime_str=$(get_tunnel_uptime)
    if [ -n "$uptime_str" ]; then
        printf "  Uptime:   ${C_DIM}%s${C_RESET}\n" "$uptime_str"
    fi

    # Load wg dump + show listening port
    load_wg_dump
    if [ "$WG_DUMP_LOADED" = "1" ] && [ -n "$WG_IFACE_LISTEN_PORT" ]; then
        printf "  Port:     ${C_DIM}%s/udp${C_RESET}\n" "$WG_IFACE_LISTEN_PORT"
    fi

    # Routes
    routes=$(ip route show dev "$WG_TUNNEL" 2>/dev/null | tr '\n' ' ' || true)
    if [ -n "$routes" ]; then
        printf "  Routes:   ${C_DIM}%s${C_RESET}\n" "$routes"
    fi

    # ── Hub health alert ──
    hub_alive=0
    if tunnel_is_up; then
        if is_android || ! command -v ping >/dev/null 2>&1; then
            tcp_probe "$HUB_WG_IP" 22 2 && hub_alive=1
        elif ping -c 1 -W 2 "$HUB_WG_IP" >/dev/null 2>&1; then
            hub_alive=1
        fi
    fi
    if [ "$hub_alive" = "0" ] && tunnel_is_up; then
        printf "\n  ${C_BG_RED}${C_WHITE}${C_BOLD} ✗ HUB DOWN ${C_RESET} ${C_RED}%s (%s) is unreachable — entire mesh is degraded${C_RESET}\n" "$HUB_NAME" "$HUB_WG_IP"
    fi

    # ── Peer table ──
    printf "\n"
    if [ "$WG_DUMP_LOADED" = "1" ]; then
        printf "  ${C_BOLD}%-2s%-17s %-12s %-24s %-11s %-21s %-8s %s${C_RESET}\n" \
            "" "NAME" "WG IP" "ENDPOINT" "HANDSHAKE" "TX / RX" "PING" "LOSS"
    else
        printf "  ${C_BOLD}%-2s%-17s %-12s %-18s %-24s %-8s %s${C_RESET}\n" \
            "" "NAME" "WG IP" "PUBLIC IP" "ROLE" "PING" "LOSS"
    fi
    printf "  ${C_DIM}────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}\n"

    always_on_total=0
    always_on_up=0

    i=0
    while [ "$i" -lt "$PEER_COUNT" ]; do
        name=$(jq -r ".peers[$i].name" "$CONFIG_FILE")
        wg_ip=$(jq -r ".peers[$i].wg_ip" "$CONFIG_FILE")
        pub_ip=$(jq -r ".peers[$i].public_ip" "$CONFIG_FILE")
        pub_key=$(jq -r ".peers[$i].public_key" "$CONFIG_FILE")
        role=$(jq -r ".peers[$i].role" "$CONFIG_FILE")
        avail=$(jq -r ".peers[$i].availability" "$CONFIG_FILE")

        # Local peer
        if [ "$name" = "local" ]; then
            printf "  %b " "$DOT_LOCAL"
            cpad 17 "$C_CYAN" "$name (you)"
            printf " %-12s " "$wg_ip"
            if [ "$WG_DUMP_LOADED" = "1" ]; then
                cpad 24 "$C_DIM" "—"; printf " "
                cpad 11 "$C_DIM" "—"; printf " "
                cpad 21 "$C_DIM" "—"; printf " "
                cpad 8 "$C_DIM" "—"; printf " "
                cpad 5 "$C_DIM" "—"
            else
                printf "%-18s " "$pub_ip"; printf "%-24s " "$role"
                cpad 8 "$C_DIM" "—"; printf " "; cpad 5 "$C_DIM" "—"
            fi
            printf "\n"
            i=$((i + 1)); continue
        fi

        # ── Collect data ──
        endpoint_plain="" endpoint_color=""
        handshake_plain="" handshake_ts=""
        transfer_plain=""
        rtt_plain="—" rtt_color="$C_DIM"
        loss_plain="—" loss_pct_color="$C_DIM"
        dot="" roam_note=""

        if [ "$WG_DUMP_LOADED" = "1" ] && peer_data=$(get_wg_peer_data "$pub_key"); then
            ep_raw=$(printf '%s' "$peer_data" | cut -f2)
            handshake_ts=$(printf '%s' "$peer_data" | cut -f3)
            rx=$(printf '%s' "$peer_data" | cut -f4)
            tx=$(printf '%s' "$peer_data" | cut -f5)
            keepalive=$(printf '%s' "$peer_data" | cut -f6)

            if [ "$ep_raw" = "(none)" ] || [ -z "$ep_raw" ]; then
                endpoint_plain="(none)"; endpoint_color="$C_DIM"
            else
                endpoint_plain="$ep_raw"; endpoint_color=""
                # Endpoint roaming check
                roamed_ip=$(detect_roaming "$pub_ip" "$ep_raw")
                if [ -n "$roamed_ip" ]; then
                    roam_note=" ${C_YELLOW}!roam${C_RESET}"
                fi
            fi

            handshake_plain=$(fmt_handshake_age "$handshake_ts")
            transfer_plain="$(fmt_bytes "$tx") / $(fmt_bytes "$rx")"

            if [ -z "$handshake_ts" ] || [ "$handshake_ts" = "0" ]; then
                dot="$DOT_DOWN"
            else
                now=$(date +%s); age=$((now - handshake_ts))
                if [ "$age" -lt 300 ]; then dot="$DOT_UP"; else dot="$DOT_STALE"; fi
            fi
        else
            endpoint_plain="$pub_ip"; endpoint_color="$C_DIM"
            handshake_plain="—"; handshake_ts=""
            transfer_plain="—"

            if tunnel_is_up; then
                if tcp_probe "$wg_ip" 22 2; then dot="$DOT_UP"; else dot="$DOT_DOWN"; fi
            else
                dot="$DOT_UNKNOWN"
            fi
        fi

        # Ping stats (RTT + loss)
        if tunnel_is_up; then
            stats=$(get_ping_stats "$wg_ip")
            if [ -n "$stats" ]; then
                rtt_val=$(printf '%s' "$stats" | cut -d' ' -f1)
                loss_val=$(printf '%s' "$stats" | cut -d' ' -f2)
                rtt_plain="${rtt_val}ms"
                rtt_color=$(latency_color "$rtt_val")
                loss_plain="${loss_val}%"
                loss_pct_color=$(loss_color "$loss_val")
                dot="$DOT_UP"
            fi
        fi

        # Hub gets special dot
        if [ "$name" = "$HUB_NAME" ]; then
            if [ "$dot" = "$DOT_UP" ]; then dot="$DOT_HUB"; else dot="$DOT_HUB_DOWN"; fi
        fi

        # Track always-on peer health
        if [ "$avail" = "always-on" ] && [ "$name" != "local" ]; then
            always_on_total=$((always_on_total + 1))
            # Check if UP (rtt_plain != "—")
            if [ "$rtt_plain" != "—" ]; then
                always_on_up=$((always_on_up + 1))
            fi
        fi

        # ── Print row ──
        printf "  %b " "$dot"
        printf "%-17s " "$name"
        printf "%-12s " "$wg_ip"

        if [ "$WG_DUMP_LOADED" = "1" ]; then
            cpad 24 "$endpoint_color" "$endpoint_plain"; printf " "
            cpad 11 "$(handshake_color "$handshake_ts")" "$handshake_plain"; printf " "
            cpad 21 "" "$transfer_plain"; printf " "
            cpad 8 "$rtt_color" "$rtt_plain"; printf " "
            cpad 5 "$loss_pct_color" "$loss_plain"
            [ -n "$roam_note" ] && printf "%b" "$roam_note"
        else
            printf "%-18s " "$pub_ip"; printf "%-24s " "$role"
            cpad 8 "$rtt_color" "$rtt_plain"; printf " "
            cpad 5 "$loss_pct_color" "$loss_plain"
        fi
        printf "\n"

        i=$((i + 1))
    done

    cleanup_wg_cache

    # Legend
    printf "\n  ${C_DIM}%b hub  %b UP  %b DOWN  %b STALE (>5m)  %b you${C_RESET}" \
        "$DOT_HUB" "$DOT_UP" "$DOT_DOWN" "$DOT_STALE" "$DOT_LOCAL"

    # Mesh completeness
    if [ "$always_on_total" -gt 0 ]; then
        if [ "$always_on_up" -eq "$always_on_total" ]; then
            printf "    $OK ${C_GREEN}%d/%d always-on peers reachable${C_RESET}" "$always_on_up" "$always_on_total"
        else
            printf "    $WARN ${C_YELLOW}%d/%d always-on peers reachable${C_RESET}" "$always_on_up" "$always_on_total"
        fi
    fi
    printf "\n"
}

# =============================================================================
# SECTION: CONFIGS
# =============================================================================

section_configs() {
    printf "\n${C_DIM}──${C_RESET} ${C_BOLD}Configs${C_RESET} ${C_DIM}─────────────────────────────────────────────────────────${C_RESET}\n\n"

    if [ "$BACKEND" = "systemd" ]; then
        unit_state=$(systemctl is-active "$BACKEND_UNIT" 2>/dev/null || echo "unknown")
        printf "  Backend:  ${C_GREEN}systemd${C_RESET} (${BACKEND_UNIT}) [${unit_state}]\n"
    else
        printf "  Backend:  ${C_YELLOW}wg-quick${C_RESET}\n"
    fi

    # NixOS declarative
    printf "\n  ${C_BOLD}NixOS declarative${C_RESET} ${C_DIM}(/etc/nixos → networking.wireguard):${C_RESET}\n"
    if [ "$BACKEND" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        printf "    Interface:  %s, %s\n" "$WG_TUNNEL" "$WG_ADDRESS"
        printf "    PrivateKey: %s/privatekey\n" "$WG_CONFIG_DIR"
        printf "    Peer:       %.10s...%s → %s:%s\n" "$HUB_PUBKEY" \
            "$(printf '%s' "$HUB_PUBKEY" | tail -c 4)" "$HUB_PUB_IP" "$HUB_PORT"
        printf "    AllowedIPs: 10.0.0.0/24\n"

        is_enabled=$(systemctl is-enabled "$BACKEND_UNIT" 2>/dev/null | head -1 || echo "unknown")
        if [ "$is_enabled" = "enabled" ]; then
            printf "    AutoStart:  ${C_GREEN}enabled${C_RESET}\n"
        else
            printf "    AutoStart:  ${C_DIM}disabled${C_RESET} (wantedBy = [])\n"
        fi
    else
        printf "    ${C_DIM}No systemd unit found for wireguard-${WG_TUNNEL}${C_RESET}\n"
    fi

    # Vault config
    printf "\n  ${C_BOLD}Vault config${C_RESET} ${C_DIM}(%s):${C_RESET}\n" "$WG_CONF"
    if [ -f "$WG_CONF" ]; then
        while IFS= read -r line; do printf "    %s\n" "$line"; done < "$WG_CONF"
    else
        printf "    ${C_RED}File not found${C_RESET}\n"
    fi

    # Drift
    printf "\n  ${C_BOLD}Drift check:${C_RESET}\n"
    drift_detect
}

drift_detect() {
    if [ ! -f "$WG_CONF" ]; then
        printf "    $WARN ${C_YELLOW}Cannot check drift — vault config not found${C_RESET}\n"; return
    fi

    drift_found=0
    vault_address=$(grep -i '^Address' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
    vault_endpoint=$(grep -i '^Endpoint' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
    vault_pubkey=$(grep -i '^PublicKey' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
    vault_allowed=$(grep -i '^AllowedIPs' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)

    if [ -n "$vault_address" ] && [ "$vault_address" != "$WG_ADDRESS" ]; then
        printf "    $FAIL ${C_RED}Address diverged${C_RESET}: NixOS=${C_CYAN}%s${C_RESET}  vault=${C_YELLOW}%s${C_RESET}\n" "$WG_ADDRESS" "$vault_address"
        drift_found=1
    fi
    expected_endpoint="${HUB_PUB_IP}:${HUB_PORT}"
    if [ -n "$vault_endpoint" ] && [ "$vault_endpoint" != "$expected_endpoint" ]; then
        printf "    $FAIL ${C_RED}Endpoint diverged${C_RESET}: mesh.json=${C_CYAN}%s${C_RESET}  vault=${C_YELLOW}%s${C_RESET}\n" "$expected_endpoint" "$vault_endpoint"
        drift_found=1
    fi
    if [ -n "$vault_pubkey" ] && [ "$vault_pubkey" != "$HUB_PUBKEY" ]; then
        printf "    $FAIL ${C_RED}Hub PublicKey diverged${C_RESET}\n"
        drift_found=1
    fi

    # Tunnel mode drift: config says split but live is full (or vice versa)
    detect_tunnel_mode
    if [ -n "$vault_allowed" ]; then
        case "$vault_allowed" in
            *0.0.0.0/0*) cfg_mode="full" ;;
            *) cfg_mode="split" ;;
        esac
        if [ "$TUNNEL_MODE" != "unknown" ] && [ "$TUNNEL_MODE" != "$cfg_mode" ]; then
            printf "    $WARN ${C_YELLOW}Tunnel mode drift${C_RESET}: config=${C_CYAN}%s${C_RESET}  live=${C_YELLOW}%s${C_RESET}\n" "$cfg_mode" "$TUNNEL_MODE"
            drift_found=1
        fi
    fi

    if [ "$drift_found" = "0" ]; then
        printf "    $OK ${C_GREEN}NixOS, mesh.json, and vault configs are in sync${C_RESET}\n"
    fi
}

# =============================================================================
# SECTION: PEERS (static topology)
# =============================================================================

section_peers() {
    printf "\n${C_DIM}──${C_RESET} ${C_BOLD}Peers${C_RESET} ${C_DIM}───────────────────────────────────────────────────────────${C_RESET}\n\n"

    printf "  ${C_BOLD}%-18s %-12s %-18s %-26s %s${C_RESET}\n" "NAME" "WG IP" "PUBLIC IP" "ROLE" "AVAIL"
    printf "  ${C_DIM}──────────────────────────────────────────────────────────────────────────────────${C_RESET}\n"

    i=0
    while [ "$i" -lt "$PEER_COUNT" ]; do
        name=$(jq -r ".peers[$i].name" "$CONFIG_FILE")
        wg_ip=$(jq -r ".peers[$i].wg_ip" "$CONFIG_FILE")
        pub_ip=$(jq -r ".peers[$i].public_ip" "$CONFIG_FILE")
        role=$(jq -r ".peers[$i].role" "$CONFIG_FILE")
        avail=$(jq -r ".peers[$i].availability" "$CONFIG_FILE")

        if [ "$name" = "local" ]; then
            printf "  ${C_CYAN}%-18s${C_RESET} %-12s %-18s %-26s %s\n" "$name (you)" "$wg_ip" "$pub_ip" "$role" "$avail"
        elif [ "$name" = "$HUB_NAME" ]; then
            printf "  ${C_GREEN}%-18s${C_RESET} %-12s %-18s %-26s %s\n" "$name (hub)" "$wg_ip" "$pub_ip" "$role" "$avail"
        else
            printf "  %-18s %-12s %-18s %-26s %s\n" "$name" "$wg_ip" "$pub_ip" "$role" "$avail"
        fi
        i=$((i + 1))
    done

    printf "\n  ${C_DIM}Topology:  hub-and-spoke (all traffic routes through %s)${C_RESET}\n" "$HUB_NAME"
    printf "  ${C_DIM}Subnet:    10.0.0.0/24${C_RESET}\n"
    printf "  ${C_DIM}Hub port:  %s${C_RESET}\n" "$HUB_PORT"
}

# =============================================================================
# SECTION: LOGS (journal entries)
# =============================================================================

section_logs() {
    printf "\n${C_DIM}──${C_RESET} ${C_BOLD}Logs${C_RESET} ${C_DIM}────────────────────────────────────────────────────────────${C_RESET}\n\n"

    if ! command -v journalctl >/dev/null 2>&1; then
        printf "  ${C_DIM}journalctl not available${C_RESET}\n"
        return
    fi

    unit_pattern=""
    if [ "$BACKEND" = "systemd" ] && [ -n "$BACKEND_UNIT" ]; then
        unit_pattern="$BACKEND_UNIT"
    else
        unit_pattern="wg-quick@${WG_TUNNEL}.service"
    fi

    entries=$(journalctl -u "$unit_pattern" --no-pager -n 15 --output short-iso 2>/dev/null || true)
    if [ -z "$entries" ]; then
        printf "  ${C_DIM}No journal entries for %s${C_RESET}\n" "$unit_pattern"
    else
        printf '%s\n' "$entries" | while IFS= read -r line; do
            # Color error lines red, warning yellow
            case "$line" in
                *error*|*Error*|*FAIL*|*failed*)
                    printf "  ${C_RED}%s${C_RESET}\n" "$line" ;;
                *warn*|*Warn*)
                    printf "  ${C_YELLOW}%s${C_RESET}\n" "$line" ;;
                *)
                    printf "  ${C_DIM}%s${C_RESET}\n" "$line" ;;
            esac
        done
    fi
}

# =============================================================================
# SECTION: HELP BRIEF
# =============================================================================

section_help_brief() {
    printf "\n${C_DIM}──${C_RESET} ${C_BOLD}Help${C_RESET} ${C_DIM}────────────────────────────────────────────────────────────${C_RESET}\n\n"

    printf "  ${C_BOLD}mesh${C_RESET}                  Full dashboard (--all)\n"
    printf "  ${C_GREEN}mesh up${C_RESET}               Start VPN tunnel\n"
    printf "  ${C_RED}mesh down${C_RESET}             Stop VPN tunnel\n"
    printf "  ${C_GREEN}mesh full${C_RESET}             All traffic via WireGuard\n"
    printf "  ${C_GREEN}mesh split${C_RESET}            Only mesh traffic via WireGuard\n"
    printf "  mesh ${C_CYAN}-s${C_RESET}, ${C_CYAN}--status${C_RESET}     Live tunnel + peer connectivity\n"
    printf "  mesh ${C_CYAN}-c${C_RESET}, ${C_CYAN}--configs${C_RESET}    WireGuard config sources + drift\n"
    printf "  mesh ${C_CYAN}-p${C_RESET}, ${C_CYAN}--peers${C_RESET}      Static peer topology\n"
    printf "  mesh ${C_CYAN}-l${C_RESET}, ${C_CYAN}--logs${C_RESET}       WireGuard journal entries\n"
    printf "  mesh ${C_CYAN}-j${C_RESET}, ${C_CYAN}--json${C_RESET}       Export full state as JSON\n"
    printf "  mesh ${C_CYAN}-h${C_RESET}, ${C_CYAN}--help${C_RESET}       Detailed help + README\n"
    printf "  mesh ${C_CYAN}--check${C_RESET}          Verify dependencies\n"
}

# =============================================================================
# FULL HELP
# =============================================================================

show_help() {
    printf "${C_BOLD}mesh — WireGuard Mesh VPN Manager${C_RESET}\n\n"

    printf "${C_BOLD}USAGE${C_RESET}\n"
    printf "  mesh [flag|command]\n\n"

    printf "${C_BOLD}READ-ONLY FLAGS${C_RESET}\n"
    printf "  ${C_CYAN}-s${C_RESET}, ${C_CYAN}--status${C_RESET}        Live tunnel + wg show + ping RTT + packet loss\n"
    printf "  ${C_CYAN}-c${C_RESET}, ${C_CYAN}--configs${C_RESET}       Config sources + drift detection (incl. mode drift)\n"
    printf "  ${C_CYAN}-p${C_RESET}, ${C_CYAN}--peers${C_RESET}         Static peer topology table from mesh.json\n"
    printf "  ${C_CYAN}-l${C_RESET}, ${C_CYAN}--logs${C_RESET}          WireGuard journal/systemd log entries\n"
    printf "  ${C_CYAN}-a${C_RESET}, ${C_CYAN}--all${C_RESET}           All sections combined (default when no args)\n"
    printf "  ${C_CYAN}-j${C_RESET}, ${C_CYAN}--json${C_RESET} [FILE]   Export full mesh state as JSON (stdout or file)\n"
    printf "  ${C_CYAN}-h${C_RESET}, ${C_CYAN}--help${C_RESET}          This help message\n"
    printf "  ${C_CYAN}--check${C_RESET}             Verify required/optional dependencies\n\n"

    printf "${C_BOLD}ACTION COMMANDS${C_RESET}\n"
    printf "  ${C_GREEN}up${C_RESET}                  Start WireGuard tunnel (systemd or wg-quick)\n"
    printf "  ${C_RED}down${C_RESET}                Stop WireGuard tunnel\n"
    printf "  ${C_GREEN}full${C_RESET}                Switch to full tunnel (all traffic via WG hub)\n"
    printf "  ${C_GREEN}split${C_RESET}               Switch to split tunnel (only 10.0.0.0/24 via WG)\n\n"

    printf "${C_BOLD}TUNNEL MODES${C_RESET}\n\n"
    printf "  ${C_BOLD}Split tunnel${C_RESET} ${C_DIM}(default)${C_RESET}\n"
    printf "    AllowedIPs = 10.0.0.0/24\n"
    printf "    Only mesh traffic routes through WireGuard.\n"
    printf "    Internet traffic goes direct (or via system VPN).\n\n"

    printf "  ${C_BOLD}Full tunnel${C_RESET}\n"
    printf "    AllowedIPs = 0.0.0.0/0\n"
    printf "    ALL traffic routes through the WireGuard hub.\n"
    printf "    Internet exits via %s (%s).\n\n" "$HUB_NAME" "$HUB_PUB_IP"

    printf "${C_BOLD}MESH TOPOLOGY${C_RESET}\n\n"

    printf "  Hub-and-spoke: all peers connect to ${C_CYAN}%s${C_RESET} (%s:%s).\n" "$HUB_NAME" "$HUB_PUB_IP" "$HUB_PORT"
    printf "  If the hub goes down, the entire mesh is unreachable.\n\n"

    printf "  ${C_DIM}                         ┌──────────────┐${C_RESET}\n"
    printf "  ${C_DIM}              ┌──────────┤${C_RESET}  ${C_GREEN}gcp-proxy${C_RESET}   ${C_DIM}├──────────┐${C_RESET}\n"
    printf "  ${C_DIM}              │          │${C_RESET}  ${C_DIM}10.0.0.1${C_RESET}     ${C_DIM}│          │${C_RESET}\n"
    printf "  ${C_DIM}              │          └──────┬───────┘          │${C_RESET}\n"
    printf "  ${C_DIM}              │                 │                  │${C_RESET}\n"
    printf "  ${C_DIM}     ┌────────┼────────┬────────┼────────┬────────┼────────┐${C_RESET}\n"
    printf "  ${C_DIM}     │        │        │        │        │        │        │${C_RESET}\n"
    printf "  ${C_DIM}  ┌──┴───┐ ┌──┴───┐ ┌──┴───┐ ┌──┴───┐ ┌──┴───┐ ┌──┴───┐ ┌──┴───┐${C_RESET}\n"
    printf "  ${C_DIM}  │${C_RESET}${C_CYAN}local${C_RESET} ${C_DIM}│ │${C_RESET}mail  ${C_DIM}│ │${C_RESET}analy.${C_DIM}│ │${C_RESET}apps  ${C_DIM}│ │${C_RESET}apps-1${C_DIM}│ │${C_RESET}apps-2${C_DIM}│ │${C_RESET}gcp-t4${C_DIM}│${C_RESET}\n"
    printf "  ${C_DIM}  │${C_RESET} .0.5  ${C_DIM}│ │${C_RESET} .0.3  ${C_DIM}│ │${C_RESET} .0.4  ${C_DIM}│ │${C_RESET} .0.6  ${C_DIM}│ │${C_RESET} .0.2  ${C_DIM}│ │${C_RESET} .0.7  ${C_DIM}│ │${C_RESET} .0.8  ${C_DIM}│${C_RESET}\n"
    printf "  ${C_DIM}  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘${C_RESET}\n\n"

    printf "  ${C_BOLD}Subnet:${C_RESET}     10.0.0.0/24\n"
    printf "  ${C_BOLD}Hub port:${C_RESET}   %s (UDP)\n" "$HUB_PORT"
    printf "  ${C_BOLD}Hub key:${C_RESET}    %.20s...%s\n\n" "$HUB_PUBKEY" "$(printf '%s' "$HUB_PUBKEY" | tail -c 4)"

    printf "${C_BOLD}STATUS INDICATORS${C_RESET}\n"
    printf "  %b hub     %b UP      %b DOWN    %b STALE (>5m)   %b you\n" \
        "$DOT_HUB" "$DOT_UP" "$DOT_DOWN" "$DOT_STALE" "$DOT_LOCAL"
    printf "  ${C_YELLOW}!roam${C_RESET}    Endpoint IP changed from configured (NAT rebind/roaming)\n\n"

    printf "${C_BOLD}COLOR CODING${C_RESET}\n"
    printf "  ${C_GREEN}Green${C_RESET}    Healthy: handshake <2m, ping <50ms, 0%% loss\n"
    printf "  ${C_YELLOW}Yellow${C_RESET}   Warning: handshake 2-5m, ping 50-150ms, <33%% loss\n"
    printf "  ${C_RED}Red${C_RESET}      Problem: handshake >5m/never, ping >150ms, >33%% loss\n\n"

    printf "${C_BOLD}CONFIG FILES${C_RESET}\n"
    printf "  mesh.json:     %s\n" "$CONFIG_FILE"
    printf "  wg0.conf:      %s\n" "$WG_CONF"
    printf "  Private key:   %s/privatekey\n\n" "$WG_CONFIG_DIR"

    printf "${C_BOLD}DEPENDENCIES${C_RESET}\n"
    printf "  Required:  jq, ip\n"
    printf "  Optional:  wg+sudo (dump), ping (RTT+loss), nc (fallback), systemctl, journalctl\n"
}

# =============================================================================
# JSON EXPORT
# =============================================================================

cmd_json() {
    output_file="${1:-}"

    tunnel_up="false"; tunnel_is_up && tunnel_up="true"
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Tunnel mode
    detect_tunnel_mode

    # Backend
    unit_state=""; is_enabled=""
    if [ "$BACKEND" = "systemd" ]; then
        unit_state=$(systemctl is-active "$BACKEND_UNIT" 2>/dev/null || echo "unknown")
        is_enabled=$(systemctl is-enabled "$BACKEND_UNIT" 2>/dev/null | head -1 || echo "unknown")
    fi

    # Interface
    mtu=$(get_mtu); uptime_str=$(get_tunnel_uptime)
    routes_text=""
    if tunnel_is_up; then routes_text=$(ip route show dev "$WG_TUNNEL" 2>/dev/null || true); fi

    load_wg_dump

    vault_exists="false"; [ -f "$WG_CONF" ] && vault_exists="true"

    # Drift
    drift_arr="[]"
    if [ -f "$WG_CONF" ]; then
        va=$(grep -i '^Address' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
        ve=$(grep -i '^Endpoint' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
        vp=$(grep -i '^PublicKey' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
        vl=$(grep -i '^AllowedIPs' "$WG_CONF" 2>/dev/null | sed 's/.*= *//' | head -1)
        drift_arr=$(jq -n '[]' \
            | if [ -n "$va" ] && [ "$va" != "$WG_ADDRESS" ]; then
                jq --arg e "$WG_ADDRESS" --arg a "$va" '. + [{"field":"address","expected":$e,"actual":$a}]'; else cat; fi \
            | if [ -n "$ve" ] && [ "$ve" != "${HUB_PUB_IP}:${HUB_PORT}" ]; then
                jq --arg e "${HUB_PUB_IP}:${HUB_PORT}" --arg a "$ve" '. + [{"field":"endpoint","expected":$e,"actual":$a}]'; else cat; fi \
            | if [ -n "$vp" ] && [ "$vp" != "$HUB_PUBKEY" ]; then
                jq --arg e "$HUB_PUBKEY" --arg a "$vp" '. + [{"field":"hub_public_key","expected":$e,"actual":$a}]'; else cat; fi)
    fi

    # Peers
    peers_arr="[]"
    i=0
    while [ "$i" -lt "$PEER_COUNT" ]; do
        name=$(jq -r ".peers[$i].name" "$CONFIG_FILE")
        wg_ip=$(jq -r ".peers[$i].wg_ip" "$CONFIG_FILE")
        pub_ip=$(jq -r ".peers[$i].public_ip" "$CONFIG_FILE")
        pub_key=$(jq -r ".peers[$i].public_key" "$CONFIG_FILE")
        role=$(jq -r ".peers[$i].role" "$CONFIG_FILE")
        avail=$(jq -r ".peers[$i].availability" "$CONFIG_FILE")

        wg_endpoint=""; wg_hs=""; wg_hs_age=""; wg_rx=""; wg_tx=""; wg_keepalive=""; wg_allowed=""

        if [ "$WG_DUMP_LOADED" = "1" ] && [ "$name" != "local" ] && peer_data=$(get_wg_peer_data "$pub_key"); then
            ep_raw=$(printf '%s' "$peer_data" | cut -f2)
            hs_raw=$(printf '%s' "$peer_data" | cut -f3)
            rx_raw=$(printf '%s' "$peer_data" | cut -f4)
            tx_raw=$(printf '%s' "$peer_data" | cut -f5)
            ka_raw=$(printf '%s' "$peer_data" | cut -f6)
            ai_raw=$(printf '%s' "$peer_data" | cut -f7)

            [ "$ep_raw" != "(none)" ] && [ -n "$ep_raw" ] && wg_endpoint="$ep_raw"
            if [ -n "$hs_raw" ] && [ "$hs_raw" != "0" ]; then
                wg_hs="$hs_raw"; wg_hs_age="$(($(date +%s) - hs_raw))"
            fi
            wg_rx="$rx_raw"; wg_tx="$tx_raw"
            [ "$ka_raw" != "off" ] && [ -n "$ka_raw" ] && wg_keepalive="$ka_raw"
            [ -n "$ai_raw" ] && wg_allowed="$ai_raw"
        fi

        rtt=""; loss=""; reach=""
        if [ "$name" != "local" ] && tunnel_is_up; then
            stats=$(get_ping_stats "$wg_ip")
            if [ -n "$stats" ]; then
                rtt=$(printf '%s' "$stats" | cut -d' ' -f1)
                loss=$(printf '%s' "$stats" | cut -d' ' -f2)
                reach="true"
            else
                reach="false"
            fi
        fi

        roamed=""
        if [ -n "$wg_endpoint" ]; then
            roamed=$(detect_roaming "$pub_ip" "$wg_endpoint")
        fi

        peer_json=$(jq -n \
            --arg name "$name" --arg wg_ip "$wg_ip" --arg pub_ip "$pub_ip" \
            --arg pub_key "$pub_key" --arg role "$role" --arg avail "$avail" \
            --arg ep "$wg_endpoint" --arg hs "$wg_hs" --arg hs_age "$wg_hs_age" \
            --arg rx "$wg_rx" --arg tx "$wg_tx" --arg ka "$wg_keepalive" --arg ai "$wg_allowed" \
            --arg rtt "$rtt" --arg loss "$loss" --arg reach "$reach" --arg roam "$roamed" \
            '{
                name: $name, wg_ip: $wg_ip, public_ip: $pub_ip, public_key: $pub_key,
                role: $role, availability: $avail,
                wg_endpoint: (if $ep == "" then null else $ep end),
                wg_handshake_epoch: (if $hs == "" then null else ($hs|tonumber) end),
                wg_handshake_age_s: (if $hs_age == "" then null else ($hs_age|tonumber) end),
                wg_rx_bytes: (if $rx == "" then null else ($rx|tonumber) end),
                wg_tx_bytes: (if $tx == "" then null else ($tx|tonumber) end),
                wg_keepalive_s: (if $ka == "" then null else ($ka|tonumber) end),
                wg_allowed_ips: (if $ai == "" then null else $ai end),
                ping_rtt_ms: (if $rtt == "" then null else ($rtt|tonumber) end),
                ping_loss_pct: (if $loss == "" then null else ($loss|tonumber) end),
                ping_reachable: (if $reach == "" then null elif $reach == "true" then true else false end),
                endpoint_roamed_to: (if $roam == "" then null else $roam end)
            }')

        peers_arr=$(printf '%s' "$peers_arr" | jq --argjson p "$peer_json" '. + [$p]')
        i=$((i + 1))
    done
    cleanup_wg_cache

    full_json=$(jq -n \
        --arg ts "$timestamp" --arg tun "$WG_TUNNEL" --argjson up "$tunnel_up" \
        --arg addr "$WG_ADDRESS" --arg mode "$TUNNEL_MODE" --arg aips "$TUNNEL_ALLOWED_IPS" \
        --arg be "$BACKEND" --arg bu "$BACKEND_UNIT" --arg bs "$unit_state" --arg ben "$is_enabled" \
        --arg mtu "$mtu" --arg upt "$uptime_str" \
        --arg ipub "$([ "$WG_DUMP_LOADED" = "1" ] && printf '%s' "$WG_IFACE_PUBKEY" || true)" \
        --arg iport "$([ "$WG_DUMP_LOADED" = "1" ] && printf '%s' "$WG_IFACE_LISTEN_PORT" || true)" \
        --arg routes "$routes_text" \
        --arg cm "$CONFIG_FILE" --arg cw "$WG_CONF" --argjson ce "$vault_exists" --argjson dr "$drift_arr" \
        --arg hn "$HUB_NAME" --arg hip "$HUB_PUB_IP" --argjson hp "$HUB_PORT" --arg hk "$HUB_PUBKEY" \
        --argjson peers "$peers_arr" \
        '{
            timestamp: $ts,
            tunnel: {
                name: $tun, up: $up, address: $addr,
                mode: $mode, allowed_ips: $aips,
                mtu: (if $mtu == "" then null else ($mtu|tonumber) end),
                uptime: (if $upt == "" then null else $upt end),
                backend: {
                    type: $be,
                    unit: (if $bu == "" then null else $bu end),
                    state: (if $bs == "" then null else $bs end),
                    enabled: (if $ben == "" then null else $ben end)
                }
            },
            wg_interface: (if $ipub == "" then null else {public_key:$ipub, listen_port:$iport} end),
            routes: ($routes | split("\n") | map(select(. != ""))),
            config: { mesh_json:$cm, wg_conf:$cw, vault_exists:$ce, drift:$dr },
            mesh: {
                topology:"hub-and-spoke", subnet:"10.0.0.0/24",
                hub: { name:$hn, public_ip:$hip, port:$hp, public_key:$hk }
            },
            peers: $peers
        }')

    if [ -n "$output_file" ]; then
        printf '%s\n' "$full_json" > "$output_file"
        printf "$OK ${C_GREEN}JSON exported to ${C_BOLD}%s${C_RESET}\n" "$output_file"
    else
        printf '%s\n' "$full_json"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    case "${1:-}" in
        --check) check_deps; exit $? ;;
    esac

    load_config
    detect_backend

    case "${1:-}" in
        -h|--help)      show_help ;;
        -s|--status)    section_status ;;
        -c|--configs)   section_configs ;;
        -p|--peers)     section_peers ;;
        -l|--logs)      section_logs ;;
        -j|--json)      cmd_json "${2:-}" ;;
        -a|--all|"")
            printf "\n${C_BOLD}=== WireGuard Mesh VPN ===${C_RESET}"
            section_configs
            section_peers
            section_logs
            section_help_brief
            section_status
            printf "\n"
            ;;
        up)             cmd_up ;;
        down)           cmd_down ;;
        full)           cmd_full ;;
        split)          cmd_split ;;
        *)
            printf "$FAIL ${C_RED}Unknown option: $1${C_RESET}\n\n"
            printf "  Run ${C_CYAN}mesh --help${C_RESET} for usage.\n"
            exit 1
            ;;
    esac
}

main "$@"
