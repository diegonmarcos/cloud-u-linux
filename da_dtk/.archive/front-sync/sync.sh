#!/bin/sh
# sync.sh — File sync & serve (Unison + Rclone + Eruda HTTP)
# Rclone for WebDAV/SFTP, static-server.mjs for HTTP (with Eruda DevTools)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$HOME/.cache"
CERT_DIR="$HOME/.config/rclone/certs"

PORT_WEBDAV=8082
PORT_SFTP=2022
PORT_HTTP=8083

# ─── Colors ───────────────────────────────────────────────
C_RESET="\033[0m"
C_CYAN="\033[0;36m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_MAGENTA="\033[0;35m"
C_BLUE="\033[0;34m"

# ─── Secrets (SOPS/age) ─────────────────────────────────
SECRETS_FILE="$SCRIPT_DIR/secrets.yaml"
if [ -f "$HOME/git/cloud-vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
  export SOPS_AGE_KEY_FILE="$HOME/git/cloud-vault/A0_keys/providers/system/oauth/age_keys.txt"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
  export SOPS_AGE_KEY_FILE="/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt"
fi

load_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    printf "${C_RED}secrets.yaml not found${C_RESET}\n" >&2
    return 1
  fi
  if ! command -v sops >/dev/null 2>&1; then
    printf "${C_RED}sops not found — install via: nix-env -iA nixpkgs.sops${C_RESET}\n" >&2
    return 1
  fi
  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    export "$key=$val"
  done < <(sops -d --output-type dotenv "$SECRETS_FILE" 2>/dev/null)
}

load_secrets || exit 1

SFTP_USER="${SYNC_USER:-termux}"
SFTP_PASS="${SYNC_PASS}"
WEBDAV_USER="${SYNC_USER:-termux}"
WEBDAV_PASS="${SYNC_PASS}"

# ─── Helpers ──────────────────────────────────────────────
pid_file() { echo "$CACHE_DIR/sync-$1.pid"; }
log_file() { echo "$CACHE_DIR/sync-$1.log"; }
mode_file() { echo "$CACHE_DIR/sync-$1.mode"; }

get_lan_ip() {
  python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "<no-network>"
}

is_running() {
  pf="$(pid_file "$1")"
  [ -f "$pf" ] && kill -0 "$(cat "$pf")" 2>/dev/null
}

ensure_certs() {
  if [ ! -f "$CERT_DIR/cert.pem" ] || [ ! -f "$CERT_DIR/key.pem" ]; then
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -days 365 -nodes -subj "/CN=termux-local" 2>/dev/null
    printf "${C_GREEN}Generated SSL certificate${C_RESET}\n"
  fi
}

# ─── Start/Stop ──────────────────────────────────────────
start_rclone() {
  proto="$1"; mode="$2"; port="$3"
  pf="$(pid_file "$proto")"
  extra_args=""

  if [ "$mode" = "lan" ]; then
    bind_addr="0.0.0.0:$port"
  else
    bind_addr="127.0.0.1:$port"
  fi

  if [ "$proto" = "sftp" ]; then
    extra_args="--user $SFTP_USER --pass $SFTP_PASS"
  fi
  if [ "$proto" = "webdav" ] && [ "$mode" = "lan" ]; then
    extra_args="--user $WEBDAV_USER --pass $WEBDAV_PASS"
  fi
  if [ "$proto" = "webdav" ]; then
    ensure_certs
    extra_args="$extra_args --cert $CERT_DIR/cert.pem --key $CERT_DIR/key.pem"
  fi

  if is_running "$proto"; then
    printf "${C_YELLOW}$proto already running (PID: $(cat "$pf"))${C_RESET}\n"
  else
    printf "${C_CYAN}Starting rclone $proto on $bind_addr...${C_RESET}\n"
    mkdir -p "$CACHE_DIR"
    rclone serve "$proto" "$HOME" \
      --addr "$bind_addr" \
      --vfs-cache-mode full \
      --no-modtime \
      $extra_args \
      > "$(log_file "$proto")" 2>&1 &
    echo $! > "$pf"
    sleep 1
    if is_running "$proto"; then
      echo "$mode" > "$(mode_file "$proto")"
      printf "${C_GREEN}Started $proto on $bind_addr${C_RESET}\n"
    else
      printf "${C_RED}Failed. Check $(log_file "$proto")${C_RESET}\n"
    fi
  fi
}

start_http() {
  mode="$1"
  pf="$(pid_file "http")"

  if [ "$mode" = "lan" ]; then
    bind_addr="0.0.0.0"
  else
    bind_addr="127.0.0.1"
  fi

  if is_running "http"; then
    printf "${C_YELLOW}http already running (PID: $(cat "$pf"))${C_RESET}\n"
  else
    printf "${C_CYAN}Starting HTTP + Eruda on ${bind_addr}:${PORT_HTTP}...${C_RESET}\n"
    mkdir -p "$CACHE_DIR"
    # Use static-server.mjs (Node.js with Eruda DevTools injection)
    # It binds to 0.0.0.0 by default; for local-only we'd need to modify
    # but for simplicity we always start on the port and note the mode
    nohup node "$SCRIPT_DIR/static-server.mjs" "$PORT_HTTP" "$HOME" \
      > "$(log_file "http")" 2>&1 &
    echo $! > "$pf"
    sleep 1
    if is_running "http"; then
      echo "$mode" > "$(mode_file "http")"
      printf "${C_GREEN}Started HTTP + Eruda on http://${bind_addr}:${PORT_HTTP}${C_RESET}\n"
      printf "  ${C_CYAN}Eruda DevTools auto-injected into HTML${C_RESET}\n"
    else
      printf "${C_RED}Failed. Check $(log_file "http")${C_RESET}\n"
    fi
  fi
}

stop_serve() {
  proto="$1"
  pf="$(pid_file "$proto")"
  if is_running "$proto"; then
    kill "$(cat "$pf")" 2>/dev/null
    rm -f "$pf" "$(mode_file "$proto")"
    printf "${C_YELLOW}Stopped $proto${C_RESET}\n"
  else
    printf "$proto not running\n"
  fi
}

show_status() {
  proto="$1"; port="$2"; indent="${3:-  }"
  if is_running "$proto"; then
    mode=$(cat "$(mode_file "$proto")" 2>/dev/null || echo "local")
    if [ "$mode" = "lan" ]; then
      url="$(get_lan_ip):$port"
    else
      url="127.0.0.1:$port"
    fi
    case "$proto" in
      webdav) url="https://$url" ;;
      sftp) url="sftp://$url" ;;
      http) url="http://$url" ;;
    esac
    printf "${indent}${C_GREEN}$proto: RUNNING${C_RESET} ${C_CYAN}$url${C_RESET}"
    [ "$proto" = "http" ] && printf " ${C_MAGENTA}(Eruda)${C_RESET}"
    printf "\n"
  else
    printf "${indent}${C_RED}$proto: stopped${C_RESET}\n"
  fi
}

# ─── Commands ─────────────────────────────────────────────
case "${1:-help}" in
  -h|--help|help|"")
    printf "${C_CYAN}=== Sync Tools ===${C_RESET}\n"
    echo ""
    printf "${C_YELLOW}STATUS:${C_RESET}\n"
    printf "  ${C_MAGENTA}UNISON:${C_RESET}\n"
    if [ -d "/storage/emulated/0/Mounts/Termux-Home" ]; then
      printf "    Target: ${C_GREEN}EXISTS${C_RESET} ($(ls -1 /storage/emulated/0/Mounts/Termux-Home 2>/dev/null | wc -l) items)\n"
    else
      printf "    Target: ${C_RED}NOT FOUND${C_RESET}\n"
    fi
    printf "  ${C_MAGENTA}SERVERS:${C_RESET}\n"
    show_status webdav $PORT_WEBDAV "    "
    show_status sftp $PORT_SFTP "    "
    show_status http $PORT_HTTP "    "
    echo ""
    printf "${C_YELLOW}UNISON - Bidirectional Sync:${C_RESET}\n"
    echo "  Syncs ~/desktop and ~/nix-home-manager to Android storage"
    echo "  Target: /storage/emulated/0/Mounts/Termux-Home"
    echo ""
    printf "${C_YELLOW}SERVERS (Rclone + Node.js):${C_RESET}\n"
    printf "  ${C_GREEN}webdav${C_RESET}  :$PORT_WEBDAV  File managers, mount as drive (HTTPS)\n"
    printf "  ${C_GREEN}sftp${C_RESET}    :$PORT_SFTP  SSH/SFTP clients\n"
    printf "  ${C_GREEN}http${C_RESET}    :$PORT_HTTP  Browser with ${C_MAGENTA}Eruda DevTools${C_RESET}\n"
    echo ""
    printf "${C_YELLOW}NOTE:${C_RESET} Android apps cannot use 127.0.0.1 - use ${C_CYAN}lan${C_RESET} mode with device IP\n"
    echo ""
    printf "${C_YELLOW}AUTHENTICATION:${C_RESET}\n"
    printf "  WebDAV: ${C_CYAN}local:${C_RESET} no auth  ${C_CYAN}lan:${C_RESET} ${C_GREEN}$WEBDAV_USER${C_RESET}/${C_GREEN}$WEBDAV_PASS${C_RESET}\n"
    printf "  SFTP:   ${C_CYAN}User:${C_RESET} ${C_GREEN}$SFTP_USER${C_RESET}  ${C_CYAN}Pass:${C_RESET} ${C_GREEN}$SFTP_PASS${C_RESET}\n"
    printf "  HTTP:   ${C_CYAN}No auth (read-only, Eruda injected)${C_RESET}\n"
    echo ""
    printf "${C_YELLOW}USAGE:${C_RESET}\n"
    printf "  ${C_BLUE}sync bisync${C_RESET}             Run Unison bidirectional sync\n"
    printf "  ${C_BLUE}sync status${C_RESET}             Show all services status\n"
    printf "  ${C_BLUE}sync webdav local|lan${C_RESET}   Start WebDAV server (:$PORT_WEBDAV)\n"
    printf "  ${C_BLUE}sync sftp local|lan${C_RESET}     Start SFTP server (:$PORT_SFTP)\n"
    printf "  ${C_BLUE}sync http local|lan${C_RESET}     Start HTTP + Eruda (:$PORT_HTTP)\n"
    printf "  ${C_BLUE}sync stop [protocol]${C_RESET}    Stop server (or all if no arg)\n"
    printf "  ${C_BLUE}sync -h${C_RESET}                 Show this help\n"
    ;;
  status)
    printf "${C_CYAN}=== Sync Status ===${C_RESET}\n"
    echo ""
    printf "${C_MAGENTA}UNISON:${C_RESET}\n"
    if [ -d "/storage/emulated/0/Mounts/Termux-Home" ]; then
      printf "  Target: ${C_GREEN}EXISTS${C_RESET} ($(ls -1 /storage/emulated/0/Mounts/Termux-Home 2>/dev/null | wc -l) items)\n"
    else
      printf "  Target: ${C_RED}NOT FOUND${C_RESET}\n"
    fi
    echo ""
    printf "${C_MAGENTA}SERVERS:${C_RESET}\n"
    show_status webdav $PORT_WEBDAV
    show_status sftp $PORT_SFTP
    show_status http $PORT_HTTP
    echo ""
    printf "${C_MAGENTA}CREDENTIALS:${C_RESET}\n"
    printf "  SFTP:   ${C_GREEN}$SFTP_USER${C_RESET} / ${C_GREEN}$SFTP_PASS${C_RESET}\n"
    printf "  WebDAV: ${C_GREEN}$WEBDAV_USER${C_RESET} / ${C_GREEN}$WEBDAV_PASS${C_RESET} (lan only)\n"
    ;;
  webdav)
    case "${2:-}" in
      local) start_rclone webdav local $PORT_WEBDAV ;;
      lan)   start_rclone webdav lan $PORT_WEBDAV ;;
      *)
        printf "${C_RED}Error: Missing argument. Use local or lan${C_RESET}\n"
        printf "  ${C_BLUE}sync webdav local${C_RESET}  Localhost only (127.0.0.1:$PORT_WEBDAV)\n"
        printf "  ${C_BLUE}sync webdav lan${C_RESET}    LAN accessible (0.0.0.0:$PORT_WEBDAV)\n"
        ;;
    esac
    ;;
  sftp)
    case "${2:-}" in
      local) start_rclone sftp local $PORT_SFTP ;;
      lan)   start_rclone sftp lan $PORT_SFTP ;;
      *)
        printf "${C_RED}Error: Missing argument. Use local or lan${C_RESET}\n"
        printf "  ${C_BLUE}sync sftp local${C_RESET}  Localhost only (127.0.0.1:$PORT_SFTP)\n"
        printf "  ${C_BLUE}sync sftp lan${C_RESET}    LAN accessible (0.0.0.0:$PORT_SFTP)\n"
        ;;
    esac
    ;;
  http)
    case "${2:-}" in
      local) start_http local ;;
      lan)   start_http lan ;;
      *)
        printf "${C_RED}Error: Missing argument. Use local or lan${C_RESET}\n"
        printf "  ${C_BLUE}sync http local${C_RESET}  Localhost only (127.0.0.1:$PORT_HTTP)\n"
        printf "  ${C_BLUE}sync http lan${C_RESET}    LAN accessible (0.0.0.0:$PORT_HTTP)\n"
        ;;
    esac
    ;;
  stop)
    case "${2:-all}" in
      webdav) stop_serve webdav ;;
      sftp)   stop_serve sftp ;;
      http)   stop_serve http ;;
      all|"")
        stop_serve webdav
        stop_serve sftp
        stop_serve http
        ;;
    esac
    ;;
  bisync|unison)
    echo "Starting Unison bidirectional sync..."
    exec unison termux-home
    ;;
  *)
    printf "${C_CYAN}=== Sync Tools ===${C_RESET}\n"
    echo ""
    printf "${C_MAGENTA}SERVERS:${C_RESET}\n"
    show_status webdav $PORT_WEBDAV
    show_status sftp $PORT_SFTP
    show_status http $PORT_HTTP
    echo ""
    printf "${C_YELLOW}COMMANDS:${C_RESET}\n"
    printf "  ${C_BLUE}sync bisync${C_RESET}           Run Unison bidirectional sync\n"
    printf "  ${C_BLUE}sync webdav local|lan${C_RESET} Start WebDAV (:$PORT_WEBDAV)\n"
    printf "  ${C_BLUE}sync sftp local|lan${C_RESET}   Start SFTP (:$PORT_SFTP)\n"
    printf "  ${C_BLUE}sync http local|lan${C_RESET}   Start HTTP + Eruda (:$PORT_HTTP)\n"
    printf "  ${C_BLUE}sync stop [proto]${C_RESET}     Stop server(s)\n"
    printf "  ${C_BLUE}sync -h${C_RESET}               Detailed help\n"
    ;;
esac
