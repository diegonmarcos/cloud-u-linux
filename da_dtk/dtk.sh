#!/bin/sh
# Diego's Toolkit (DTK) — unified CLI for aliases, containers, connect, and ops
# Usage: ./dtk.sh                # interactive
#        ./dtk.sh <cmd> [args]   # direct
# OS-agnostic POSIX: NixOS, Arch, Debian, Fedora, macOS, Termux
set -eu

# Logging — dual output:
#   dtk.log  — raw verbose (set -x trace + stdout, with ANSI)
#   dtk.md   — clean markdown (stdout only, ANSI stripped)
LOGFILE="${HOME:-/tmp}/dtk.log"
MDFILE="${HOME:-/tmp}/dtk.md"
_LOG_USER=$(whoami 2>/dev/null || echo "?")
_LOG_HOST=$(hostname -s 2>/dev/null || echo "?")
_LOG_TS() { date '+%Y-%m-%d %H:%M:%S'; }

# Strip ANSI escape codes for markdown output
_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[[0-9;]*[A-Za-z]//g'; }

# Log everything: stdout to screen + log + md, stderr (set -x) to log only
if [ -z "${_DTK_LOGGING:-}" ]; then
  export _DTK_LOGGING=1
  # stdout → screen + log (raw with ANSI)
  # md logging handled per-command inside _resolve_shortcode wrapper
  [ ! -f "$MDFILE" ] && printf "# DTK Log\n" > "$MDFILE"
  if [ -t 1 ]; then
    "$0" "$@" 2>>"$LOGFILE" | tee -a "$LOGFILE"
  else
    "$0" "$@" 2>>"$LOGFILE"
  fi
  exit $?
fi

# Second invocation: stderr goes to LOGFILE, stdout goes to tee (screen + log)
export PS4='[$(date "+%H:%M:%S")] '
_log() { echo "[$(_LOG_TS)] $*" >&2; }
_log "════════ dtk.sh $* ════════ ${_LOG_USER}@${_LOG_HOST} ════════"

# Enable verbose trace — goes to stderr → log file
set -x
set -x

# Find sudo for commands that need elevation (do NOT exec as root — breaks SSH config)
_SUDO=""
for p in /run/wrappers/bin/sudo /usr/bin/sudo /usr/local/bin/sudo; do
  [ -x "$p" ] && _SUDO="$p" && break
done

# $S — sudo prefix for commands needing root, empty if already root
# Only set $S if sudo works without password (NOPASSWD configured)
S=""
if [ "$(id -u)" != "0" ] && [ -n "$_SUDO" ]; then
  if $_SUDO -n true 2>/dev/null; then
    S="$_SUDO"
  fi
fi

# Fix repo ownership if mixed root/user runs left wrong permissions
_DTK_REPO="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$_DTK_REPO/.git" ] && ! git -C "$_DTK_REPO" status >/dev/null 2>&1; then
  if [ -n "$S" ]; then
    $S chown -R "$(id -u):$(id -g)" "$_DTK_REPO" 2>/dev/null
  elif [ "$(id -u)" = "0" ]; then
    chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$_DTK_REPO" 2>/dev/null
  fi
fi

# Force real system binaries FIRST (bypass nix guardrail wrappers)
export PATH="/run/wrappers/bin:/usr/bin:/usr/sbin:/usr/local/bin:/bin:/sbin:/nix/var/nix/profiles/default/bin:${HOME:-/root}/.nix-profile/bin:/run/current-system/sw/bin:$PATH"

# Stop systemd journal from flooding the terminal
if [ -n "$_SUDO" ]; then
  $S dmesg -n 1 2>/dev/null || true
  $S systemctl stop systemd-journald-audit.socket 2>/dev/null || true
  $S sh -c 'echo 0 > /proc/sys/kernel/printk' 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════
# SYSTEM DETECTION — populated once, used by all commands
# ═══════════════════════════════════════════════════════════════════

SYS_OS="unknown"; SYS_DISTRO="unknown"; SYS_PKG="none"
SYS_HAS_NIX=false; SYS_HAS_DOCKER=false; SYS_DOCKER_PATH=""
SYS_ARCH="unknown"; SYS_ARCH_SHORT="unknown"
SYS_HOSTNAME="unknown"; SYS_CPUS="?"; SYS_RAM_MB="?"
SYS_KERNEL="?"; SYS_INIT="other"

detect_system() {
  # OS / Distro
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYS_OS="${ID:-unknown}"
    SYS_DISTRO="${PRETTY_NAME:-$ID}"
    case "$ID" in
      nixos)                         SYS_PKG="nix" ;;
      arch|manjaro)                  SYS_PKG="pacman" ;;
      debian|ubuntu|pop|mint)        SYS_PKG="apt" ;;
      fedora|rhel|centos|rocky|alma) SYS_PKG="dnf" ;;
    esac
  elif [ -d /data/data/com.termux ]; then
    SYS_OS="termux"; SYS_DISTRO="Termux (Android)"; SYS_PKG="pkg"
  elif command -v sw_vers >/dev/null 2>&1; then
    SYS_OS="macos"; SYS_DISTRO="macOS $(sw_vers -productVersion 2>/dev/null)"; SYS_PKG="brew"
  fi

  # Has nix?
  if command -v nix >/dev/null 2>&1; then
    SYS_HAS_NIX=true
    [ "$SYS_PKG" = "none" ] && SYS_PKG="nix"
  fi

  # Architecture
  SYS_ARCH=$(uname -m 2>/dev/null || echo "unknown")
  case "$SYS_ARCH" in
    x86_64|amd64)  SYS_ARCH_SHORT="x86" ;;
    aarch64|arm64) SYS_ARCH_SHORT="arm64" ;;
    armv7l|armhf)  SYS_ARCH_SHORT="arm32" ;;
    *)             SYS_ARCH_SHORT="$SYS_ARCH" ;;
  esac

  SYS_HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
  SYS_CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "?")

  if [ -f /proc/meminfo ]; then
    SYS_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  elif command -v sysctl >/dev/null 2>&1; then
    SYS_RAM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
  fi

  SYS_KERNEL=$(uname -r 2>/dev/null || echo "?")

  if command -v docker >/dev/null 2>&1; then
    SYS_HAS_DOCKER=true
    SYS_DOCKER_PATH=$(command -v docker)
  fi

  if command -v systemctl >/dev/null 2>&1; then
    SYS_INIT="systemd"
  elif [ -f /sbin/openrc ]; then
    SYS_INIT="openrc"
  fi
}

show_banner() { set +x 2>/dev/null
  R='\033[0m'; B='\033[1;34m'; C='\033[1;36m'; G='\033[1;32m'
  Y='\033[1;33m'; M='\033[1;35m'; W='\033[1;37m'; D='\033[0;90m'
  nix_icon="$D off$R"; [ "$SYS_HAS_NIX" = true ] && nix_icon="${G}ON${R}"
  docker_icon="$D off$R"; [ "$SYS_HAS_DOCKER" = true ] && docker_icon="${G}ON${R}"
  _kern="${SYS_KERNEL%%[-+]*}"

  printf '\n'
  printf "${C}  ██████╗ ${B}████████╗${M}██╗  ██╗${R}\n"
  printf "${C}  ██╔══██╗${B}╚══██╔══╝${M}██║ ██╔╝${R}\n"
  printf "${C}  ██║  ██║${B}   ██║   ${M}█████╔╝ ${R}  ${W}Diego's Toolkit${R}\n"
  printf "${C}  ██║  ██║${B}   ██║   ${M}██╔═██╗ ${R}  ${D}OS-agnostic VM & container manager${R}\n"
  printf "${C}  ██████╔╝${B}   ██║   ${M}██║  ██╗${R}\n"
  printf "${C}  ╚═════╝ ${B}   ╚═╝   ${M}╚═╝  ╚═╝${R}\n"
  printf '\n'
  _uptime=$(uptime -p 2>/dev/null | sed 's/up //')
  [ -z "$_uptime" ] && _uptime=$(uptime 2>/dev/null | sed 's/.*up //' | sed 's/,.*//' | sed 's/^ *//')
  [ -z "$_uptime" ] && _uptime="?"
  _disk=$(LANG=C command df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2}' || echo "?")
  _mem_used=$(free -m 2>/dev/null | awk '/Mem/{print $3}' || echo "?")
  _load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "?")
  _wg_ip=$(ip -4 addr show wg0 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1 || echo "down")
  _containers=$(docker ps -q 2>/dev/null | wc -l || echo "0")
  nix_icon="$D off$R"; [ "$SYS_HAS_NIX" = true ] && nix_icon="${G}ON${R}"
  docker_icon="$D off$R"; [ "$SYS_HAS_DOCKER" = true ] && docker_icon="${G}ON${R}"

  _swap=$(free -m 2>/dev/null | awk '/Swap/{printf "%d/%dMB", $3, $2}' || echo "?")
  _ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
  _users=$(who 2>/dev/null | wc -l || echo "?")
  _procs=$(ps aux 2>/dev/null | wc -l || echo "?")
  _shell=$(basename "${SHELL:-sh}" 2>/dev/null)

  _ip=$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || echo "?")

  printf "  ${G}system${R}\n"
  printf "  ${D}══════════════════════════════════════════════════════════════════════════════════${R}\n"
  printf "  ${Y}infos${R}\n"
  printf "  ${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  # Col widths: label=6 val=15 | label=6 val=22 | label=6 val=17 | label=6 val=11 | label=6 val=*
  _F="  ${Y}%-6s${R} ${W}%-15s${R} ${Y}%-6s${R} ${W}%-22s${R} ${Y}%-6s${R} ${W}%-17s${R} ${Y}%-6s${R} ${W}%-11s${R} ${Y}%-6s${R} ${W}%s${R}\n"
  # Row 1: Identity (static)
  printf "$_F" "host" "$SYS_HOSTNAME" "os" "$SYS_DISTRO" "arch" "$SYS_ARCH" "kernel" "$_kern" "shell" "$_shell"
  # Row 2: Config (static)
  _nix_v="off"; [ "$SYS_HAS_NIX" = true ] && _nix_v="ON"
  _dok_v="off"; [ "$SYS_HAS_DOCKER" = true ] && _dok_v="ON"
  printf "$_F" "pkg" "$SYS_PKG" "init" "$SYS_INIT" "nix" "$_nix_v" "docker" "$_dok_v" "cont." "$_containers"
  # Row 3: Network (semi-static)
  printf "$_F" "ip" "$_ip" "wg0" "$_wg_ip" "users" "$_users" "procs" "$_procs" "uptime" "$_uptime"
  # Row 4: Resources (dynamic)
  printf "$_F" "cpu" "${SYS_CPUS} cores" "ram" "${_mem_used}/${SYS_RAM_MB}MB" "swap" "$_swap" "disk" "$_disk" "load" "$_load"
  printf "  ${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  printf '\n'
}

_BANNER_SHOWN=false
show_menu_header() { set +x 2>/dev/null
  R='\033[0m'; C='\033[1;36m'; D='\033[0;90m'
  if [ "$_BANNER_SHOWN" = false ]; then
    show_banner
    _BANNER_SHOWN=true
  else
    printf "\n"
  fi

  # Menu — rendered from registry.json (single source of truth), grouped by domain.
  dtk_menu
  printf "  ${D}(b)ack  (q)uit  (r)efresh   |   type a shortcode (30a), id (observe.btop), or 'domain command'${R}\n"
  printf "  ${D}12) commands sub-index: 120-1226 (e.g. 1215 full-rescue) — see 'dtk ref commands'${R}\n\n"
}

detect_system

# ═══════════════════════════════════════════════════════════════════
# VM Map (POSIX: case statement instead of associative array)
# ═══════════════════════════════════════════════════════════════════

PROJECT="diegonmarcos-infra-prod"

# Module paths — tools grouped by domain under commands/<domain>/<name>/
_DTK_DIR="$(cd "$(dirname "$0")" && pwd)"
DTK_ROOT="$_DTK_DIR"; export DTK_ROOT
_REF_DIR="$_DTK_DIR/commands/ref"
_OBS_DIR="$_DTK_DIR/commands/observe"
_CON_DIR="$_DTK_DIR/commands/connect"
_PROV_DIR="$_DTK_DIR/commands/provision"
_REC_DIR="$_DTK_DIR/commands/recover"
_BUILD_DIR="$_DTK_DIR/build"
_ALIASES_DIR="$_DTK_DIR/commands/ref/aliases"
# Catalog kernel — registry.json is the single source of truth
. "$_DTK_DIR/core/registry.sh"
. "$_DTK_DIR/core/dispatch.sh"
. "$_DTK_DIR/core/menu.sh"

# ═══════════════════════════════════════════════════════════════════
# POSIX menu picker
# ═══════════════════════════════════════════════════════════════════

pick() { set +x 2>/dev/null
  _label="$1"; shift
  echo "$_label"
  _i=1
  for _item in "$@"; do
    printf "  %d) %s\n" "$_i" "$_item"
    _i=$((_i + 1))
  done
  printf "> "
  read -r _idx || { echo; PICK="back"; return 0; }
  case "$_idx" in b|B) PICK="back"; _log "pick: back"; set -x 2>/dev/null; return 0 ;; q|Q) _log "pick: quit"; echo "Bye."; exit 0 ;; esac
  # Try as menu item first, then as global shortcode
  _num=$((_idx)) 2>/dev/null || _num=0
  if [ "$_num" -ge 1 ] 2>/dev/null && [ "$_num" -le $# ] 2>/dev/null; then
    _idx=$_num
  else
    # Global shortcodes: if input looks like a multi-digit shortcode, route it
    case "$_idx" in [1-5][0-9a-f]*) _resolve_shortcode "$_idx"; PICK="back"; return 0 ;; esac
    echo "Invalid"; return 1
  fi
  _c=0
  for _item in "$@"; do
    _c=$((_c + 1))
    [ "$_c" -eq "$_idx" ] && PICK="$_item" && _log "pick: $_label → $_item" && set -x 2>/dev/null && return 0
  done
}

# ═══════════════════════════════════════════════════════════════════
# A) ALIASES — toolchain list (all aliases/functions by category)
# ═══════════════════════════════════════════════════════════════════

do_aliases() { set +x 2>/dev/null
  _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _ALIASES_JSON="$_SCRIPT_DIR/commands/ref/aliases/aliases.json"

  # 3-column layout: key+val | key+val | key+val
  jq -r '
    to_entries[] |
    .key as $cat |
    "H:" + $cat,
    (.value | paths(scalars) as $p | (.key = ($p | last) | .val = getpath($p)) |
      "\(.key)|\(.val)")
  ' "$_ALIASES_JSON" 2>/dev/null | awk -F'|' '
    BEGIN {
      C = "\033[1;36m"; Y = "\033[1;33m"; R = "\033[0m"
      n = 0; COLS = 3; KW = 12; VW = 16
    }
    /^H:/ { sub(/^H:/, ""); lines[n] = "H|" $0; n++; next }
    { if ($1 != "") { lines[n] = $1 "|" $2; n++ } }
    END {
      i = 0
      while (i < n) {
        if (substr(lines[i], 1, 2) == "H|") {
          printf "  " C "── %s ──" R "\n", substr(lines[i], 3)
          i++; continue
        }
        col = 0
        while (col < COLS && i < n && substr(lines[i], 1, 2) != "H|") {
          split(lines[i], a, "|"); k = a[1]; v = a[2]
          if (k == "") { i++; continue }
          if (length(v) > VW) v = substr(v, 1, VW-1) "…"
          printf "  " Y "%-*s" R "%-*s", KW, k, VW, v
          col++; i++
        }
        if (col > 0) printf "\n"
      }
      printf "\n"
    }
  '
}

do_tools() { set +x 2>/dev/null
  _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _TOOLS_JSON="$_SCRIPT_DIR/commands/ref/aliases/tools.json"

  # 5-column layout: tool names (keys only) by category
  jq -r '
    to_entries[] |
    "H:" + .key,
    (.value | keys_unsorted[])
  ' "$_TOOLS_JSON" 2>/dev/null | awk '
    BEGIN {
      C = "\033[1;36m"; G = "\033[1;32m"; R = "\033[0m"; D = "\033[0;90m"
      n = 0; COLS = 5; W = 16
    }
    /^H:/ { sub(/^H:/, ""); lines[n] = "H|" $0; n++; next }
    { if ($0 != "") { lines[n] = $0; n++ } }
    END {
      i = 0
      while (i < n) {
        if (substr(lines[i], 1, 2) == "H|") {
          printf "  " C "── %s ──" R "\n", substr(lines[i], 3)
          i++; continue
        }
        col = 0
        while (col < COLS && i < n && substr(lines[i], 1, 2) != "H|") {
          t = lines[i]
          if (length(t) > W-2) t = substr(t, 1, W-3) "…"
          printf "  " G "%-*s" R, W-2, t
          col++; i++
        }
        if (col > 0) printf "\n"
      }
      printf "\n"
    }
  '
}

do_tools_help() { set +x 2>/dev/null
  _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _TOOLS_JSON="$_SCRIPT_DIR/commands/ref/aliases/tools.json"

  # 1-column: tool name + description, grouped by category
  jq -r '
    to_entries[] |
    "H:" + .key,
    (.value | to_entries[] | "\(.key)|\(.value)")
  ' "$_TOOLS_JSON" 2>/dev/null | awk -F'|' '
    BEGIN {
      C = "\033[1;36m"; G = "\033[1;32m"; D = "\033[0;90m"; R = "\033[0m"
    }
    /^H:/ { sub(/^H:/, ""); printf "  " C "── %s ──" R "\n", $0; next }
    {
      if ($1 != "") printf "  " G "%-18s" R D "%s" R "\n", $1, $2
    }
    END { printf "\n" }
  '
}

# ═══════════════════════════════════════════════════════════════════
# B) CONTAINERS — pull & run dev environment container
# ═══════════════════════════════════════════════════════════════════

# Find docker binary by full path (skip shell aliases/wrappers)
find_docker() {
  DOCKER="" RUNTIME="docker"
  # 1a. From systemd service ExecStart
  if [ -f /etc/systemd/system/docker.service ]; then
    _dockerd=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' /etc/systemd/system/docker.service 2>/dev/null || true)
    if [ -n "$_dockerd" ]; then
      _dir=$(dirname "$_dockerd" 2>/dev/null)
      [ -x "${_dir}/docker" ] && { DOCKER="${_dir}/docker"; return 0; }
    fi
  fi
  # 1b. Known full paths
  for p in \
    /run/current-system/sw/bin/docker \
    /usr/bin/docker \
    /usr/local/bin/docker \
    /nix/var/nix/profiles/default/bin/docker \
    "${HOME}/.nix-profile/bin/docker" \
    /opt/homebrew/bin/docker \
    /data/data/com.termux.nix/files/home/.nix-profile/bin/docker; do
    [ -x "$p" ] && { DOCKER="$p"; return 0; }
  done
  # 1c. command -v (last resort)
  _found=$(command -v docker 2>/dev/null || true)
  [ -n "$_found" ] && { DOCKER="$_found"; return 0; }
  return 1
}

# Find podman by full path
find_podman() {
  _PODMAN=""
  for p in /usr/bin/podman /usr/local/bin/podman /run/current-system/sw/bin/podman \
           "${HOME}/.nix-profile/bin/podman" /nix/var/nix/profiles/default/bin/podman; do
    [ -x "$p" ] && { _PODMAN="$p"; return 0; }
  done
  _PODMAN=$(command -v podman 2>/dev/null || true)
  [ -n "$_PODMAN" ] && return 0
  return 1
}

# Shared: ensure container runtime is ready
ensure_runtime() {
  DOCKER=""; RUNTIME="docker"
  find_docker || true
  if [ -z "$DOCKER" ]; then
    echo "Docker not found — installing for $SYS_PKG..."
    case "$SYS_PKG" in
      apt)    apt-get update -qq && apt-get install -y -qq docker.io ;;
      dnf)    dnf install -y --skip-unavailable docker ;;
      pacman) pacman -Sy --noconfirm docker ;;
      nix)
        if [ "$SYS_OS" = "nixos" ]; then
          echo "On NixOS: virtualisation.docker.enable = true; then nixos-rebuild switch"
          echo "Trying nix-shell fallback..."
        fi
        exec nix-shell -p docker --run "sh $0 $1" ;;
      brew)   brew install --cask docker ;;
      pkg)    echo "Docker not available on Termux"; exit 1 ;;
      *)      echo "No supported package manager — install docker manually"; exit 1 ;;
    esac
    find_docker || true
    [ -z "$DOCKER" ] && { echo "ERROR: docker not found after install"; exit 1; }
  fi
  if ! "$DOCKER" info >/dev/null 2>&1; then
    echo "Docker daemon not running — starting..."
    if [ "$SYS_INIT" = "systemd" ]; then
      systemctl start docker 2>/dev/null || true
      _w=0; while [ $_w -lt 15 ]; do "$DOCKER" info >/dev/null 2>&1 && break; sleep 1; _w=$((_w + 1)); done
    elif command -v service >/dev/null 2>&1; then
      service docker start 2>/dev/null || true; sleep 3
    elif [ "$SYS_OS" = "macos" ]; then
      open -a Docker 2>/dev/null || true
      _w=0; while [ $_w -lt 30 ]; do "$DOCKER" info >/dev/null 2>&1 && break; sleep 1; _w=$((_w + 1)); done
    fi
  fi
  if ! "$DOCKER" info >/dev/null 2>&1; then
    if find_podman; then
      echo "Docker failed — podman fallback ($_PODMAN)"
      DOCKER="$_PODMAN"; RUNTIME="podman"
      "$DOCKER" system migrate 2>/dev/null || true
    else
      echo "ERROR: Neither docker nor podman available"; exit 1
    fi
  fi
  echo "Using: $RUNTIME ($DOCKER)"
}

# ── docker-run: pick profile then launch ─────────────────────────────
do_docker_run() {
  _variant="${1:-}"
  _profile="${2:-}"
  _extra_cmd="${3:-}"

  # ── Pick image variant ──────────────────────────────────────────
  if [ -z "$_variant" ]; then
    show_menu_header
    pick "Image:" deb-nix deb-apt
    [ "$PICK" = "back" ] && return 0
    _variant="$PICK"
  fi
  # Normalize legacy names
  case "$_variant" in
    diego-cli|diego-gui|diego-tty)
      _profile=$(echo "$_variant" | sed 's/diego-//')
      _variant="deb-nix" ;;
  esac

  # ── Pick profile ────────────────────────────────────────────────
  if [ -z "$_profile" ]; then
    show_menu_header
    pick "Profile:" cli gui tty
    [ "$PICK" = "back" ] && return 0
    _profile="$PICK"
  fi

  # ── Resolve image ──────────────────────────────────────────────
  case "$_variant" in
    deb-nix) IMG="ghcr.io/diegonmarcos/diego-deb-nix:latest" ;;
    deb-apt) IMG="ghcr.io/diegonmarcos/diego-deb-apt:latest" ;;
    *)       IMG="ghcr.io/diegonmarcos/diego-deb-nix:latest" ;;
  esac
  HOME_DIR="${HOME:-/root}"
  ensure_runtime "docker-run"

  # Show banner inside container after launch
  _HELLO='
R="\033[0m"; C="\033[1;36m"; B="\033[1;34m"; M="\033[1;35m"; W="\033[1;37m"; D="\033[0;90m"; Y="\033[1;33m"; G="\033[1;32m"
printf "\n"
printf "${C}  ██████╗ ${B}████████╗${M}██╗  ██╗${R}\n"
printf "${C}  ██╔══██╗${B}╚══██╔══╝${M}██║ ██╔╝${R}\n"
printf "${C}  ██║  ██║${B}   ██║   ${M}█████╔╝ ${R}  ${W}Diego'\''s Container${R}\n"
printf "${C}  ██║  ██║${B}   ██║   ${M}██╔═██╗ ${R}  ${D}Profile: PROFILE_PLACEHOLDER${R}\n"
printf "${C}  ██████╔╝${B}   ██║   ${M}██║  ██╗${R}\n"
printf "${C}  ╚═════╝ ${B}   ╚═╝   ${M}╚═╝  ╚═╝${R}\n"
printf "\n"
_h=$(hostname -s 2>/dev/null || echo "?")
_os=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d "\"" || uname -s)
_arch=$(uname -m 2>/dev/null || echo "?")
_kern=$(uname -r 2>/dev/null || echo "?"); _kern=${_kern%%[-+]*}
_cpu=$(nproc 2>/dev/null || echo "?")
_ram=$(awk "/MemTotal/{printf \"%d\", \$2/1024}" /proc/meminfo 2>/dev/null || echo "?")
_nix="off"; command -v nix >/dev/null 2>&1 && _nix="${G}ON${R}"
_dk="off"; command -v docker >/dev/null 2>&1 && _dk="${G}ON${R}"
printf "  ${Y}host${R}  ${W}%-20s${R}  ${Y}os${R}    ${W}%s${R}\n" "$_h" "$_os"
printf "  ${Y}arch${R}  ${W}%-20s${R}  ${Y}kernel${R}  ${W}%s${R}\n" "$_arch" "$_kern"
printf "  ${Y}cpu${R}   ${W}%-20s${R}  ${Y}ram${R}     ${W}%sMB${R}\n" "$_cpu cores" "$_ram"
printf "  ${Y}nix${R}   $_nix                        ${Y}docker${R}  $_dk\n"
printf "  ${D}──────────────────────────────────────────────${R}\n"
printf "\n"
'
  _HELLO=$(printf '%s' "$_HELLO" | sed "s/PROFILE_PLACEHOLDER/$_variant \/ $_profile/")

  echo "=== docker-run [$_profile]: $IMG ==="
  "$DOCKER" pull "$IMG"

  # Add image + label info to hello banner
  _IMG_SIZE=$("$DOCKER" image inspect "$IMG" --format '{{.Size}}' 2>/dev/null || echo "0")
  _IMG_SIZE_MB=$(( _IMG_SIZE / 1024 / 1024 ))
  _IMG_CREATED=$("$DOCKER" image inspect "$IMG" --format '{{.Created}}' 2>/dev/null | cut -c1-10 || echo "?")
  _IMG_ARCH=$("$DOCKER" image inspect "$IMG" --format '{{.Architecture}}' 2>/dev/null || echo "?")
  _lbl() { _v=$("$DOCKER" image inspect "$IMG" --format "{{index .Config.Labels \"$1\"}}" 2>/dev/null); [ "$_v" != "<no value>" ] && [ -n "$_v" ] && echo "$_v" || echo "$2"; }
  _IMG_DIGEST=$("$DOCKER" image inspect "$IMG" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//' | cut -c1-19 || echo "?")
  _IMG_LAYERS=$("$DOCKER" image inspect "$IMG" --format '{{len .RootFS.Layers}}' 2>/dev/null || echo "?")
  _IMG_SRC=$(_lbl "org.opencontainers.image.source" "github.com/diegonmarcos/cloud-unix")
  _IMG_DESC=$(_lbl "org.opencontainers.image.description" "Nix dev env (nix profile install)")
  _IMG_DFILE=$(_lbl "diego.image.dockerfile.path" "ba_flakes_desktop/src/container/Containerfile")
  _IMG_COMPOSE=$(_lbl "diego.image.compose.path" "ba_flakes_desktop/src/container/compose.yaml")
  _IMG_FLAKE=$(_lbl "diego.image.flake.path" "ba_flakes_desktop/src/")
  _IMG_GHCR=$(_lbl "diego.image.ghcr" "$IMG")
  _IMG_RUNNER=$(_lbl "diego.image.runner" "~/git/cloud-mykonsole-dtk/dtk.sh containers {cli|gui|tty}")
  _IMG_SHELL=$(_lbl "diego.image.packages.shell" "fish starship eza bat fd rg fzf jq")
  _IMG_LANG=$(_lbl "diego.image.packages.lang" "rust go node python ruby gcc llvm")
  _IMG_CLOUD=$(_lbl "diego.image.packages.cloud" "docker kubectl helm terraform sops age")
  _IMG_META=$(_lbl "diego.image.container.path" "~/.image-meta/ (Containerfile + compose.yaml)")

  _HELLO="${_HELLO}
printf \"  \${Y}image\${R} \${W}%-20s\${R}  \${Y}size\${R}    \${W}%sMB\${R}\n\" \"$_IMG_ARCH\" \"$_IMG_SIZE_MB\"
printf \"  \${Y}built\${R} \${W}%-20s\${R}  \${Y}tag\${R}     \${W}%s\${R}\n\" \"$_IMG_CREATED\" \"latest\"
printf \"  \${Y}layers\${R}\${W}%-19s\${R}  \${Y}digest\${R}  \${W}%s\${R}\n\" \" $_IMG_LAYERS\" \"$_IMG_DIGEST\"
printf \"  \${D}──────────────────────────────────────────────\${R}\n\"
printf \"  \${Y}ghcr\${R}      \${W}%s\${R}\n\" \"$_IMG_GHCR\"
printf \"  \${Y}src\${R}       \${W}%s\${R}\n\" \"$_IMG_SRC\"
printf \"  \${Y}flake\${R}     \${W}%s\${R}\n\" \"$_IMG_FLAKE\"
printf \"  \${Y}file\${R}      \${D}%s\${R}\n\" \"$_IMG_DFILE\"
printf \"  \${Y}compose\${R}   \${D}%s\${R}\n\" \"$_IMG_COMPOSE\"
printf \"  \${Y}embedded\${R}  \${D}%s\${R}\n\" \"$_IMG_META\"
printf \"  \${Y}runner\${R}    \${D}%s\${R}\n\" \"$_IMG_RUNNER\"
printf \"  \${D}──────────────────────────────────────────────\${R}\n\"
printf \"  \${Y}shell\${R}     \${D}%s\${R}\n\" \"$_IMG_SHELL\"
printf \"  \${Y}lang\${R}      \${D}%s\${R}\n\" \"$_IMG_LANG\"
printf \"  \${Y}cloud\${R}     \${D}%s\${R}\n\" \"$_IMG_CLOUD\"
printf \"  \${D}──────────────────────────────────────────────\${R}\n\"
printf \"  \${D}%s\${R}\n\" \"$_IMG_DESC\"
printf \"\n\"
"

  # Shell commands: show banner then drop to shell (or run tty command)
  SHELL_CMD="${_HELLO}
exec fish 2>/dev/null || exec bash 2>/dev/null || exec sh"
  _NIX_PATH="/home/${USER:-root}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/sbin"

  case "$_profile" in
    cli)
      MOUNTS="-v $HOME_DIR:$HOME_DIR"
      [ -S /var/run/docker.sock ] && MOUNTS="$MOUNTS -v /var/run/docker.sock:/var/run/docker.sock"
      [ -d /etc/wireguard ]       && MOUNTS="$MOUNTS -v /etc/wireguard:/etc/wireguard:ro"
      [ -d /opt ]                 && MOUNTS="$MOUNTS -v /opt:/opt"

      FLAGS="--privileged --network host --pid host"
      [ "$RUNTIME" = "podman" ] && FLAGS="--privileged --network host"

      "$DOCKER" run -it --rm \
        --name diego-cli \
        --hostname "${SYS_HOSTNAME}-cli" \
        $FLAGS $MOUNTS \
        -w "$HOME_DIR" \
        -e HOME="$HOME_DIR" -e USER="${USER:-root}" \
        -e TERM="${TERM:-xterm-256color}" \
        -e PATH="$_NIX_PATH" \
        "$IMG" bash -c "$SHELL_CMD"
      ;;

    gui)
      _UID=$(id -u 2>/dev/null || echo 1000)
      _XDG="${XDG_RUNTIME_DIR:-/run/user/$_UID}"

      MOUNTS="-v $HOME_DIR:$HOME_DIR:rslave"
      MOUNTS="$MOUNTS -v /tmp:/tmp:rslave"
      MOUNTS="$MOUNTS -v /dev:/dev:rslave"
      MOUNTS="$MOUNTS -v /sys:/sys:rslave"
      MOUNTS="$MOUNTS -v /dev/pts -v /dev/null:/dev/ptmx"
      [ -d "$_XDG" ]              && MOUNTS="$MOUNTS -v $_XDG:$_XDG:rslave"
      [ -S /var/run/docker.sock ] && MOUNTS="$MOUNTS -v /var/run/docker.sock:/var/run/docker.sock"
      [ -d /etc/wireguard ]       && MOUNTS="$MOUNTS -v /etc/wireguard:/etc/wireguard:ro"
      [ -d /opt ]                 && MOUNTS="$MOUNTS -v /opt:/opt"
      [ -d /nix ]                 && MOUNTS="$MOUNTS -v /nix:/nix"
      [ -d /var/log/journal ]     && MOUNTS="$MOUNTS -v /var/log/journal:/var/log/journal"
      MOUNTS="$MOUNTS -v /etc/hosts:/etc/hosts:ro"
      MOUNTS="$MOUNTS -v /etc/resolv.conf:/etc/resolv.conf:ro"
      MOUNTS="$MOUNTS -v /etc/hostname:/etc/hostname:ro"

      FLAGS="--privileged --network host --pid host --ipc host"
      FLAGS="$FLAGS --security-opt label=disable --security-opt apparmor=unconfined"
      FLAGS="$FLAGS --pids-limit=-1 --ulimit host"
      [ "$RUNTIME" = "podman" ] && FLAGS="$FLAGS --userns keep-id"

      "$DOCKER" run -it --rm \
        --name diego-gui \
        --hostname "${SYS_HOSTNAME}-gui" \
        $FLAGS $MOUNTS \
        -w "$HOME_DIR" \
        -e HOME="$HOME_DIR" -e USER="${USER:-root}" \
        -e TERM="${TERM:-xterm-256color}" \
        -e DISPLAY="${DISPLAY:-}" \
        -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        -e XDG_RUNTIME_DIR="$_XDG" \
        -e DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        -e PULSE_SERVER="${PULSE_SERVER:-}" \
        -e SHELL=fish \
        -e PATH="$_NIX_PATH" \
        "$IMG" bash -c "$SHELL_CMD"
      ;;

    tty)
      _CMD="${_extra_cmd:-bash}"
      MOUNTS="-v $HOME_DIR:$HOME_DIR"
      [ -S /var/run/docker.sock ] && MOUNTS="$MOUNTS -v /var/run/docker.sock:/var/run/docker.sock"
      [ -d /etc/wireguard ]       && MOUNTS="$MOUNTS -v /etc/wireguard:/etc/wireguard:ro"
      [ -d /opt ]                 && MOUNTS="$MOUNTS -v /opt:/opt"

      FLAGS="--privileged --network host --pid host"

      "$DOCKER" run --rm \
        --name diego-tty \
        --hostname "${SYS_HOSTNAME}-tty" \
        $FLAGS $MOUNTS \
        -w "$HOME_DIR" \
        -e HOME="$HOME_DIR" -e USER="${USER:-root}" \
        -e TERM=dumb \
        -e PATH="$_NIX_PATH" \
        "$IMG" bash -c "${_HELLO}
$_CMD"
      ;;

    *) echo "Unknown profile: $_profile (use: cli, gui, or tty)"; exit 1 ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════
# GIT CLONE — public (HTTPS) and private (SSH)
# ═══════════════════════════════════════════════════════════════════

_gcl_repos() {
  _proto="$1"  # https or ssh
  _target="${HOME:-/root}/git"
  _user="diegonmarcos"
  mkdir -p "$_target"

  # Public repos — always accessible
  _public="unix cloud cloud-data front front-data tools"
  # Private repos — need auth (SSH key or gh token)
  _private="vault notes"

  # Prevent git from prompting for credentials (fail fast instead)
  export GIT_TERMINAL_PROMPT=0

  printf "\n\033[1;36m── git clone (%s) ──\033[0m\n" "$_proto"

  for _name in $_public $_private; do
    case "$_proto" in
      https) _url="https://github.com/${_user}/${_name}.git" ;;
      ssh)   _url="git@github.com:${_user}/${_name}.git" ;;
    esac

    if [ -d "$_target/$_name" ]; then
      printf "  \033[1;33m%-14s\033[0m exists, pulling... "  "$_name"
      git -C "$_target/$_name" pull --ff-only 2>&1 | head -1 || echo "failed"
    else
      printf "  \033[1;32m%-14s\033[0m cloning... " "$_name"
      git clone --quiet "$_url" "$_target/$_name" 2>/dev/null && echo "done" || echo "skipped (no access)"
    fi
  done

  unset GIT_TERMINAL_PROMPT
  printf "\n"
}

do_gcl_https() { _gcl_repos https; }
do_gcl_ssh()   { _gcl_repos ssh; }

do_konsole_cfg() {
  _DTK="$(cd "$(dirname "$0")" && pwd)"
  _src_qc="$_DTK/assets/konsole/konsolequickcommandsconfig"
  _src_ssh="$_DTK/assets/konsole/konsolesshconfig"
  _dst_qc="${HOME:-/root}/.config/konsolequickcommandsconfig"
  _dst_ssh="${HOME:-/root}/.config/konsolesshconfig"

  printf "\n\033[1;36m── Konsole Quick Commands + SSH Config ──\033[0m\n"

  if [ ! -f "$_src_qc" ] || [ ! -f "$_src_ssh" ]; then
    echo "  ERROR: asset files not found in $_DTK/assets/konsole/"
    echo "  Run: git clone https://github.com/diegonmarcos/cloud-mykonsole-dtk.git ~/git/cloud-mykonsole-dtk"
    return 1
  fi

  cp "$_src_qc" "$_dst_qc" && printf "  \033[1;32minstalled\033[0m %s\n" "$_dst_qc"
  cp "$_src_ssh" "$_dst_ssh" && printf "  \033[1;32minstalled\033[0m %s\n" "$_dst_ssh"
  printf "\n  Restart Konsole to pick up changes.\n\n"
}

do_sudoers_nopasswd() { set +x 2>/dev/null
  R='\033[0m'; C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; D='\033[0;90m'
  _user="${USER:-$(whoami)}"
  _rule="$_user ALL=(ALL) NOPASSWD: ALL"
  _file="/etc/sudoers.d/99-${_user}-nopasswd"

  printf "\n${C}── sudoers NOPASSWD ──${R}\n"
  if [ -f "$_file" ] && grep -q "$_user" "$_file" 2>/dev/null; then
    printf "  ${G}already configured${R}: %s\n" "$_file"
    printf "  ${D}%s${R}\n\n" "$_rule"
    return 0
  fi

  printf "  ${Y}Setting up${R}: %s\n" "$_file"
  printf "  ${D}%s${R}\n" "$_rule"
  $S sh -c "echo '$_rule' > '$_file' && chmod 440 '$_file'"
  if [ $? -eq 0 ]; then
    printf "  ${G}Done${R} — sudo will not prompt for password.\n\n"
  else
    printf "  ${Y}Failed${R} — check sudo access.\n\n"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# C) CONNECT — unified dashboard (git/mounts/sync/servers)
# ═══════════════════════════════════════════════════════════════════

do_connect() {
  _connect_sh="$(cd "$(dirname "$0")" && pwd)/commands/connect/dashboard/connect.sh"
  if [ -f "$_connect_sh" ]; then
    sh "$_connect_sh" "$@"
  else
    echo "connect.sh not found at: $_connect_sh"
    echo "Clone tools repo: git clone https://github.com/diegonmarcos/cloud-mykonsole-dtk.git ~/git/cloud-mykonsole-dtk"
    exit 1
  fi
}

do_top_batch() {
  printf "\n\033[1;36m── top (batch mode) ──\033[0m\n\n"
  top -b -n 1 | head -40
}

# do_sysmon — registry 'observe.sysmon' (30d): our own system monitor
# (btop-style graphs + glances panels), rendered natively in the cloud-terminal
# webview. Opens the Tauri app on the Home profile where it's the default tab.
do_sysmon() {
  if command -v cloud-terminal >/dev/null 2>&1; then
    setsid cloud-terminal home >/dev/null 2>&1 &
    echo "→ opened Cloud Terminal system monitor (Home profile)"
  else
    echo "cloud-terminal not installed — run: ~/git/cloud-unix/da_cloud-terminal/build.sh install"
  fi
}

do_local_iotop() {
  printf "\n\033[1;36m── iotop ──\033[0m\n\n"
  sudo iotop 2>/dev/null || sudo iotop-c 2>/dev/null || { echo "iotop not found"; return 1; }
}

# do_sysstat_all — registry 'observe.sysstat' (31): run the full quartet.
do_sysstat_all() { do_sysstat iostat; do_sysstat mpstat; do_sysstat pidstat; do_sysstat vmstat; }
do_sysstat() {
  _cmd="${1:-}"
  if [ -z "$_cmd" ]; then
    pick "sysstat:" iostat mpstat pidstat sar
    [ "$PICK" = "back" ] && return 0
    _cmd="$PICK"
  fi
  printf "\n\033[1;36m── %s ──\033[0m\n\n" "$_cmd"
  case "$_cmd" in
    iostat)  iostat -xz 2 5 2>/dev/null || echo "iostat not found (install sysstat)" ;;
    mpstat)  mpstat -P ALL 2 5 2>/dev/null || echo "mpstat not found (install sysstat)" ;;
    pidstat) pidstat -u -d 2 5 2>/dev/null || echo "pidstat not found (install sysstat)" ;;
    sar)     sar -u -r -d 1 10 2>/dev/null || echo "sar not found (install sysstat)" ;;
    vmstat)  vmstat 1 5 2>/dev/null || echo "vmstat not found (install procps)" ;;
    *)       echo "Unknown: $_cmd" ;;
  esac
}

do_local_btop() {
  printf "\n\033[1;36m── local btop ──\033[0m\n\n"
  _s="local-btop"
  tmux kill-session -t "$_s" 2>/dev/null || true
  tmux new-session -d -s "$_s" "btop 2>/dev/null || htop 2>/dev/null || top; read"
  _tmux_enable_titles "$_s"
  tmux select-pane -t "$_s" -t 1 -T "local / btop"
  tmux attach-session -t "$_s"
}

do_batch_htop() {
  printf "\n\033[1;36m── remote btop-dash ──\033[0m\n"
  printf "  4-pane: htop on all VMs\n\n"
  _s="remote-btop"
  tmux kill-session -t "$_s" 2>/dev/null || true
  _first=true
  for _vm in gcp-proxy oci-mail oci-analytics oci-apps; do
    if $_first; then
      tmux new-session -d -s "$_s" "ssh $_vm -t 'btop 2>/dev/null || htop 2>/dev/null || top'; read"
      _first=false
    else
      tmux split-window -t "$_s" "ssh $_vm -t 'btop 2>/dev/null || htop 2>/dev/null || top'; read"
    fi
  done
  tmux select-layout -t "$_s" tiled
  _tmux_enable_titles "$_s"
  _i=1; for _vm in gcp-proxy oci-mail oci-analytics oci-apps; do
    tmux select-pane -t "$_s" -t $_i -T "$_vm / ssh $_vm -t btop"
    _i=$((_i + 1))
  done
  tmux attach-session -t "$_s"
}

do_journal_dash() {
  _sub="${1:-}"
  R='\033[0m'; C='\033[1;36m'; D='\033[0;90m'

  if [ -z "$_sub" ]; then
    show_menu_header
    pick "Journal dashboard:" transport priority unit
    [ "$PICK" = "back" ] && return 0
    _sub="$PICK"
  fi

  case "$_sub" in
    transport|t) _journal_dash_transport ;;
    priority|p)  _journal_dash_priority ;;
    unit|u)      _journal_dash_unit ;;
    *)           echo "Unknown: $_sub (use: transport, priority, unit)" ;;
  esac
}

# Helper: enable pane titles for a session
_tmux_enable_titles() {
  tmux set-option -t "$1" pane-border-status top
  tmux set-option -t "$1" pane-border-format " #{pane_title} "
}

_journal_dash_transport() {
  printf "\n\033[1;36m── journal-dash-transport ──\033[0m\n"
  printf "  2x2: kernel | syslog | stdout | journal\n\n"
  _s="jdash-transport"
  tmux kill-session -t "$_s" 2>/dev/null || true
  tmux new-session -d -s "$_s" \
    "journalctl _TRANSPORT=kernel -f --no-pager -o short-iso; read"
  tmux split-window -t "$_s" \
    "journalctl _TRANSPORT=syslog -f --no-pager -o short-iso; read"
  tmux split-window -t "$_s" \
    "journalctl _TRANSPORT=stdout -f --no-pager -o short-iso; read"
  tmux split-window -t "$_s" \
    "journalctl _TRANSPORT=journal -f --no-pager -o short-iso; read"
  tmux select-layout -t "$_s" tiled
  _tmux_enable_titles "$_s"
  _i=1; for _t in "kernel / _TRANSPORT=kernel" "syslog / _TRANSPORT=syslog" "stdout / _TRANSPORT=stdout" "journal / _TRANSPORT=journal"; do
    tmux select-pane -t "$_s" -t $_i -T "$_t"; _i=$((_i + 1))
  done
  tmux attach-session -t "$_s"
}

_journal_dash_priority() {
  printf "\n\033[1;36m── journal-dash-priority ──\033[0m\n"
  printf "  8 panes: emerg(0) | alert(1) | crit(2) | err(3) | warn(4) | notice(5) | info(6) | debug(7)\n\n"
  _s="jdash-priority"
  tmux kill-session -t "$_s" 2>/dev/null || true
  _names="emerg alert crit err warning notice info debug"
  _i=0; _first=true
  for _name in $_names; do
    _cmd="journalctl -p $_i..$_i -f --no-pager -o short-iso; read"
    if $_first; then
      tmux new-session -d -s "$_s" "$_cmd"
      _first=false
    else
      tmux split-window -t "$_s" "$_cmd"
      tmux select-layout -t "$_s" tiled
    fi
    _i=$((_i + 1))
  done
  tmux select-layout -t "$_s" tiled
  _tmux_enable_titles "$_s"
  _i=1; _p=0
  for _name in $_names; do
    tmux select-pane -t "$_s" -t $_i -T "$_name / -p $_p..$_p"
    _i=$((_i + 1)); _p=$((_p + 1))
  done
  tmux attach-session -t "$_s"
}

_journal_dash_unit() {
  printf "\n\033[1;36m── journal-dash-unit ──\033[0m\n"
  printf "  2x2: kernel+network+ssh+storage | system | docker | others\n\n"
  _s="jdash-unit"
  tmux kill-session -t "$_s" 2>/dev/null || true
  tmux new-session -d -s "$_s" \
    "journalctl -k -u NetworkManager -u wpa_supplicant -u sshd -u ssh -u rescue-ssh -u udisks2 -u fstrim -f --no-pager -o short-iso; read"
  tmux split-window -t "$_s" \
    "journalctl -u nix-daemon -u nix-gc -u earlyoom -u disk-watchdog -u systemd-logind -u systemd-timesyncd -u thermald -u polkit -f --no-pager -o short-iso; read"
  tmux split-window -t "$_s" \
    "journalctl -u docker -f --no-pager -o short-iso; read"
  tmux split-window -t "$_s" \
    "journalctl -f --no-pager -o short-iso _TRANSPORT=stdout; read"
  tmux select-layout -t "$_s" tiled
  _tmux_enable_titles "$_s"
  _i=1; for _t in \
    "kernel+net+ssh+storage / -k -u NetworkManager -u sshd ..." \
    "system / -u nix-daemon -u earlyoom -u systemd-logind ..." \
    "docker / -u docker" \
    "others / _TRANSPORT=stdout"; do
    tmux select-pane -t "$_s" -t $_i -T "$_t"; _i=$((_i + 1))
  done
  tmux attach-session -t "$_s"
}

do_docker_stats_dash() {
  printf "\n\033[1;36m── remote docker-stats ──\033[0m\n"
  printf "  4-pane: docker stats on all VMs\n\n"
  _s="remote-docker-stats"
  tmux kill-session -t "$_s" 2>/dev/null || true
  _first=true
  for _vm in gcp-proxy oci-mail oci-analytics oci-apps; do
    _cmd="ssh $_vm -t 'docker stats 2>/dev/null || echo no docker'; read"
    if $_first; then
      tmux new-session -d -s "$_s" "$_cmd"
      _first=false
    else
      tmux split-window -t "$_s" "$_cmd"
    fi
  done
  tmux select-layout -t "$_s" tiled
  _tmux_enable_titles "$_s"
  _i=1; for _vm in gcp-proxy oci-mail oci-analytics oci-apps; do
    tmux select-pane -t "$_s" -t $_i -T "$_vm / docker stats"
    _i=$((_i + 1))
  done
  tmux attach-session -t "$_s"
}

do_journal_watch_n35() {
  printf "\n\033[1;36m── journal watch (last 35, refresh 5s) ──\033[0m\n\n"
  watch -n 5 -c "journalctl -n 35 --no-pager -o short-iso"
}

do_remote_journal() {
  printf "\n\033[1;36m── remote journal-dash ──\033[0m\n"
  printf "  4-pane: journal -f on all VMs\n\n"
  _s="remote-journal"
  tmux kill-session -t "$_s" 2>/dev/null || true
  _first=true
  for _vm in gcp-proxy oci-mail oci-analytics oci-apps; do
    _cmd="ssh $_vm -t 'journalctl -f --no-pager -o short-iso 2>/dev/null || tail -f /var/log/syslog 2>/dev/null || echo no journal'; read"
    if $_first; then
      tmux new-session -d -s "$_s" "$_cmd"
      _first=false
    else
      tmux split-window -t "$_s" "$_cmd"
    fi
  done
  tmux select-layout -t "$_s" tiled
  _tmux_enable_titles "$_s"
  _i=1; for _vm in gcp-proxy oci-mail oci-analytics oci-apps; do
    tmux select-pane -t "$_s" -t $_i -T "$_vm / ssh $_vm journalctl -f"
    _i=$((_i + 1))
  done
  tmux attach-session -t "$_s"
}

# ═══════════════════════════════════════════════════════════════════
# QUICK COMMANDS — delegates to cloud-container-orchestrator.sh
# ═══════════════════════════════════════════════════════════════════

_QC="bash $_DTK_DIR/build/flake-engines/cloud-container-orchestrator/cloud-container-orchestrator.sh"

# Map command number to orchestrator command name (matches pick order in do_qc_vm)
_qc_cmd_by_num() {
  case "$1" in
    1) echo htop ;; 2) echo journalctl-f ;;
    3) echo journal-docker ;; 4) echo journal-sshd ;; 5) echo journal-wg ;;
    6) echo journal-cinit ;; 7) echo journal-kernel ;; 8) echo journal-errors ;;
    9) echo systemctl-status ;; 10) echo systemctl-list ;;
    11) echo docker-start ;; 12) echo docker-stop ;; 13) echo docker-ps ;;
    14) echo docker-stats ;; 15) echo docker-exec ;; 16) echo dashboard ;;
    17) echo oci-start ;; 18) echo oci-stop ;; 19) echo oci-reset ;; 20) echo oci-serial ;;
    21) echo gcloud-start ;; 22) echo gcloud-stop ;; 23) echo gcloud-reset ;; 24) echo gcloud-serial ;;
    *) echo "" ;;
  esac
}

# Direct VM+command: 20a13 → gcp-proxy docker-ps
do_qc_vm_direct() {
  _vm="$1"; _cmd_num="$2"
  _cmd=$(_qc_cmd_by_num "$_cmd_num")
  if [ -z "$_cmd" ]; then
    echo "Invalid command number: $_cmd_num (1-24)"
    return 1
  fi
  $_QC "vm-$_cmd" "$_vm"
}

do_qc_vm() {
  _vm="${1:-}"
  R='\033[0m'; C='\033[1;36m'; Y='\033[1;33m'; D='\033[0;90m'
  if [ -z "$_vm" ]; then
    show_menu_header
    pick "VM:" gcp-proxy oci-mail oci-analytics oci-apps gcp-t4
    [ "$PICK" = "back" ] && return 0
    _vm="$PICK"
  fi
  printf "\n${C}── VM: $_vm ──${R}\n"
  # Provider-specific cloud commands
  _cloud_cmds=""
  case "$_vm" in
    oci-*)     _cloud_cmds="oci-start oci-stop oci-reset oci-serial" ;;
    gcp-*)     _cloud_cmds="gcloud-start gcloud-stop gcloud-reset gcloud-serial" ;;
  esac
  pick "Command:" \
    ssh ssh-dropbear \
    htop journalctl-f \
    journal-docker journal-sshd journal-wg journal-cinit journal-kernel journal-errors \
    systemctl-status systemctl-list \
    docker-start docker-stop docker-ps docker-stats docker-exec \
    dashboard \
    $_cloud_cmds
  [ "$PICK" = "back" ] && return 0
  case "$PICK" in
    dashboard)       $_QC vm-dashboard "$_vm" ;;
    *)               $_QC "vm-$PICK" "$_vm" ;;
  esac
}

do_qc_ssh() {
  _vm="${1:-}"
  if [ -z "$_vm" ]; then
    show_menu_header
    pick "SSH to:" gcp-proxy oci-mail oci-analytics oci-apps gcp-t4
    [ "$PICK" = "back" ] && return 0
    _vm="$PICK"
  fi
  printf "\n\033[1;36m── SSH: $_vm ──\033[0m\n"
  ssh "$_vm"
}

do_qc_orchestrate() {
  R='\033[0m'; C='\033[1;36m'
  printf "\n${C}── Orchestration (all VMs) ──${R}\n"
  pick "Command:" \
    mode-ssh mode-dropbear mode-serial mode-status \
    htop journalctl-f \
    journal-docker journal-sshd journal-wg journal-cinit journal-kernel journal-errors \
    systemctl-status systemctl-list \
    docker-start docker-stop docker-ps docker-stats \
    dashboard-stats dashboard-journal script-push
  [ "$PICK" = "back" ] && return 0
  case "$PICK" in
    mode-*) $_QC "$PICK" ;;
    *)      $_QC "all-$PICK" ;;
  esac
}

do_qc_local() {
  R='\033[0m'; C='\033[1;36m'
  printf "\n${C}── Local ──${R}\n"
  pick "Command:" \
    htop journalctl-f \
    journal-docker journal-sshd journal-wg journal-cinit journal-kernel journal-errors \
    systemctl-status systemctl-list \
    docker-start docker-stop docker-ps docker-stats docker-exec
  [ "$PICK" = "back" ] && return 0
  $_QC "local-$PICK"
}

do_qc_desktop() {
  R='\033[0m'; C='\033[1;36m'
  printf "\n${C}── Desktop ──${R}\n"
  pick "Command:" \
    tui dtk dtk-install dtk-docker dtk-git-clone dtk-info dtk-commands dtk-ssh \
    desktop-htop hm-switch nixos-switch \
    git-status-all wg-status docker-ps-local free-mem disk-usage konsole-script-push
  [ "$PICK" = "back" ] && return 0
  $_QC "$PICK"
}

do_qc_vps() {
  _cat="${1:-}"
  R='\033[0m'; C='\033[1;36m'
  printf "\n${C}── VPS / Cloud ──${R}\n"
  if [ -z "$_cat" ]; then
    pick "Category:" cloud gh-actions gh-repos gh-registry
    [ "$PICK" = "back" ] && return 0
    _cat="$PICK"
  fi
  case "$_cat" in
    cloud)
      pick "Cloud:" oci-list oci-details oci-vnics gcloud-list gcloud-details gcloud-billing
      [ "$PICK" = "back" ] && return 0
      $_QC "$PICK" ;;
    gh-actions)
      pick "GH Actions:" runs-cloud failed-cloud log-cloud workflows runs-unix runs-front
      [ "$PICK" = "back" ] && return 0
      $_QC "gha-$PICK" ;;
    gh-repos)
      pick "GH Repos:" status list prs issues commits
      [ "$PICK" = "back" ] && return 0
      $_QC "gh-${PICK}" ;;
    gh-registry)
      pick "GHCR:" list versions count inspect latest visibility
      [ "$PICK" = "back" ] && return 0
      $_QC "ghcr-$PICK" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════
# D) OTHERS — ssh, git-clone, install, commands, info
# ═══════════════════════════════════════════════════════════════════
# D) OTHERS — logic in commands/<domain>/ modules, these are thin delegators
# ═══════════════════════════════════════════════════════════════════

do_all_commands() { set +x 2>/dev/null
  R='\033[0m'; C='\033[1;36m'; Y='\033[1;33m'; D='\033[0;90m'
  printf "\n${C}── All DTK Commands ──${R}\n"
  # Two-column: shortcode + description
  _cmds="
10|aliases (3-col)
11|webhooks (once, default)
11a|webhooks once (explicit)
11b|webhooks watch (poll loop)
12|commands (this list)
13|rescue-sshd (termux openssh recovery, self-heal on :8022 conflict)
14|rebuild-flake (termux git pull + build.sh switch)
15|claude-rescue (12-fallback chain for the claude binary)
20|quick-cmds (picker)
20a|VM gcp-proxy
20b|VM oci-mail
20c|VM oci-analytics
20d|VM oci-apps
20e|VM gcp-t4
20f|orchestrate (all VMs)
20g|local commands
20h|desktop commands
20i|vps cloud (oci/gcloud)
20j|vps gh-actions
20k|vps gh-repos
20l|vps gh-registry
21|SSH (picker)
22|mode (ssh/dropbear/serial)
22a|mode ssh
22b|mode dropbear
22c|mode serial
22d|mode status
21a|SSH gcp-proxy
21b|SSH oci-mail
21c|SSH oci-analytics
21d|SSH oci-apps
21e|SSH gcp-t4
21f|SSH github
30|monitors (btop)
30a|btop
30b|iotop
30c|top-batch
31|sysstat
31a|iostat
31b|mpstat
31c|pidstat
31d|sar
32|journal-dash (picker)
32a|journal transport (4-pane)
32b|journal priority (8-pane)
32c|journal unit (4-pane)
32d|journal watch -n35
33|connect dashboard
34|remote monitors
34a|btop-dash (4-pane)
34b|journal-dash remote (4-pane)
34c|docker-stats (4-pane)
40|containers
40a|nix {cli|gui|tty} = {40a0|40a1|40a2}
40b|apt {cli|gui|tty} = {40b0|40b1|40b2}
41|nixos
41a|hm {cli|gui|tty} = {41a0|41a1|41a2}
42|shell setup
42a|fish+tools (sudo)
42b|fish (no sudo)
42c|konsole quick-cmds install
43|git
43a|git clone (https)
43b|git clone (ssh)
44|sys
44a|sudoers-nopasswd
50|help
51|infos (all)
51a|sys-info
51b|sys-net-resource
51c|sys-paths
51d|sys-envs
51e|tools-table
51f|tools-help
51g|sys-mounts
52|deps
52a|deps-drift
52b|deps-solver
"
  echo "$_cmds" | awk -F'|' '
    BEGIN { C="\033[1;36m"; Y="\033[1;33m"; R="\033[0m"; n=0 }
    /\|/ { keys[n]=$1; vals[n]=$2; n++ }
    END {
      for (i=0; i<n; i+=2) {
        gsub(/^ +/,"",keys[i]); gsub(/^ +/,"",vals[i])
        left = sprintf("  " Y "%-6s" R "%-28s", keys[i], vals[i])
        if (i+1 < n) {
          gsub(/^ +/,"",keys[i+1]); gsub(/^ +/,"",vals[i+1])
          printf "  " Y "%-6s" R "%-28s" Y "%-6s" R "%s\n", keys[i], vals[i], keys[i+1], vals[i+1]
        } else {
          printf "  " Y "%-6s" R "%s\n", keys[i], vals[i]
        }
      }
      printf "\n"
    }
  '
}

do_deps_drift() { set +x 2>/dev/null
  R='\033[0m'; G='\033[1;32m'; Y='\033[1;33m'; RED='\033[0;31m'; D='\033[0;90m'; W='\033[1;37m'; C='\033[1;36m'
  _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _DEPS_JSON="$_SCRIPT_DIR/deps.json"

  printf "\n${G}deps-drift${R} ${D}(declared vs installed)${R}\n"
  printf "${D}══════════════════════════════════════════════════════════════════════════════════${R}\n"

  _req_total=0; _req_miss=0; _rec_total=0; _rec_miss=0; _opt_total=0; _opt_miss=0

  for _level in required recommended optional; do
    _count=0; _miss=0
    jq -r ".${_level} | keys[]" "$_DEPS_JSON" 2>/dev/null | while read -r _bin; do
      _count=$((_count + 1))
      command -v "$_bin" >/dev/null 2>&1 || _miss=$((_miss + 1))
    done
  done

  # Verbose: show every dep per level
  _sum_req=""; _sum_rec=""; _sum_opt=""
  for _level in required recommended optional; do
    case "$_level" in
      required)    _icon="$RED"; _label="REQUIRED" ;;
      recommended) _icon="$Y";   _label="RECOMMENDED" ;;
      optional)    _icon="$D";   _label="OPTIONAL" ;;
    esac
    printf "  ${C}%s${R}\n" "$_label"
    _total=$(jq ".${_level} | length" "$_DEPS_JSON" 2>/dev/null)
    _miss=0
    jq -r ".${_level} | to_entries[] | \"\(.key)\t\(.value)\"" "$_DEPS_JSON" 2>/dev/null | \
    while IFS="$(printf '\t')" read -r _bin _desc; do
      if command -v "$_bin" >/dev/null 2>&1; then
        _ver=$(command -v "$_bin" 2>/dev/null)
        printf "  ${G}✓${R}  ${W}%-14s${R} ${D}%s${R}\n" "$_bin" "$_desc"
      else
        _miss=$((_miss + 1))
        printf "  ${_icon}✗  %-14s %s${R}\n" "$_bin" "$_desc"
      fi
    done
    printf "\n"
  done

  # ── Full toolchain (tools.json) ────────────────────────────
  _TOOLS_JSON="$_SCRIPT_DIR/commands/ref/aliases/tools.json"
  if [ -f "$_TOOLS_JSON" ]; then
    printf "  ${C}FULL TOOLCHAIN${R} ${D}(tools.json)${R}\n"
    _tools_total=$(jq '[.[] | keys[]] | length' "$_TOOLS_JSON" 2>/dev/null)
    _tools_miss=0
    jq -r 'to_entries[] | .key as $cat | .value | keys_unsorted[] | $cat + "\t" + .' "$_TOOLS_JSON" 2>/dev/null | \
    while IFS="$(printf '\t')" read -r _cat _tool; do
      _b="$_tool"
      case "$_tool" in
        ripgrep) _b="rg" ;; wireguard) _b="wg" ;; gnupg) _b="gpg" ;; netcat) _b="nc" ;;
        wireshark) _b="tshark" ;; p7zip) _b="7z" ;; wl-clipboard) _b="wl-copy" ;;
        imagemagick) _b="convert" ;; obs-studio) _b="obs" ;; jupyterlab) _b="jupyter" ;;
        R) _b="R" ;; helm|kubernetes-helm) _b="helm" ;; docker-compose) _b="docker-compose" ;;
        docker-buildx) _b="docker" ;;
        torch|scikit-learn|numpy|pandas|scipy|matplotlib|polars|dask|pydantic|scrapy|ipython) _b="python3" ;;
      esac
      if ! command -v "$_b" >/dev/null 2>&1; then
        printf "  ${RED}✗${R}  ${Y}%-18s${R} ${D}(%s)${R}\n" "$_tool" "$_cat"
      fi
    done
    _tools_miss_count=$(jq -r '[.[] | keys_unsorted[]] | .[]' "$_TOOLS_JSON" 2>/dev/null | while read -r _t; do
      _b="$_t"
      case "$_t" in
        ripgrep) _b="rg" ;; wireguard) _b="wg" ;; gnupg) _b="gpg" ;; netcat) _b="nc" ;;
        wireshark) _b="tshark" ;; p7zip) _b="7z" ;; wl-clipboard) _b="wl-copy" ;;
        imagemagick) _b="convert" ;; obs-studio) _b="obs" ;; jupyterlab) _b="jupyter" ;;
        R) _b="R" ;; helm|kubernetes-helm) _b="helm" ;;
        torch|scikit-learn|numpy|pandas|scipy|matplotlib|polars|dask|pydantic|scrapy|ipython) _b="python3" ;;
      esac
      command -v "$_b" >/dev/null 2>&1 || echo x
    done | wc -l)
    _tools_found=$((_tools_total - _tools_miss_count))
    printf "\n"
  fi

  # Summary table
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  printf "  ${C}summary${R}\n"
  for _level in required recommended optional; do
    case "$_level" in
      required)    _icon="$RED" ;; recommended) _icon="$Y" ;; optional) _icon="$D" ;;
    esac
    _total=$(jq ".${_level} | length" "$_DEPS_JSON" 2>/dev/null)
    _miss=$(jq -r ".${_level} | keys[]" "$_DEPS_JSON" 2>/dev/null | while read -r _b; do
      command -v "$_b" >/dev/null 2>&1 || echo x
    done | wc -l)
    _found=$((_total - _miss))
    if [ "$_miss" -eq 0 ]; then
      printf "  ${G}✓${R}  %-14s ${G}%s/%s${R}\n" "$_level" "$_found" "$_total"
    else
      printf "  ${_icon}✗  %-14s %s/%s ${_icon}(%s missing)${R}\n" "$_level" "$_found" "$_total" "$_miss"
    fi
  done
  if [ -f "$_TOOLS_JSON" ]; then
    if [ "$_tools_miss_count" -eq 0 ]; then
      printf "  ${G}✓${R}  %-14s ${G}%s/%s${R}\n" "toolchain" "$_tools_found" "$_tools_total"
    else
      printf "  ${RED}✗${R}  %-14s %s/%s ${RED}(%s missing)${R}\n" "toolchain" "$_tools_found" "$_tools_total" "$_tools_miss_count"
    fi
  fi
  printf "\n"
}

do_tools_deps_solver() { set +x 2>/dev/null
  R='\033[0m'; G='\033[1;32m'; Y='\033[1;33m'; RED='\033[0;31m'; D='\033[0;90m'; W='\033[1;37m'; C='\033[1;36m'
  _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _TOOLS_JSON="$_SCRIPT_DIR/commands/ref/aliases/tools.json"
  _DEPS_JSON="$_SCRIPT_DIR/deps.json"

  # ── Part 1: DTK runtime deps (deps.json) ──────────────────────────
  printf "\n${G}deps-solver${R}\n"
  printf "${D}══════════════════════════════════════════════════════════════════════════════════${R}\n"
  printf "  ${C}DTK runtime dependencies${R} ${D}(deps.json)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"

  for _level in required recommended optional; do
    case "$_level" in
      required)    _color="$RED" ;;
      recommended) _color="$Y" ;;
      optional)    _color="$D" ;;
    esac
    _level_total=0; _level_miss=0
    jq -r ".${_level} | to_entries[] | \"\(.key)\t\(.value)\"" "$_DEPS_JSON" 2>/dev/null | \
    while IFS="$(printf '\t')" read -r _bin _desc; do
      _level_total=$((_level_total + 1))
      if command -v "$_bin" >/dev/null 2>&1; then
        printf "  ${G}✓${R}  %-14s ${D}%s${R}\n" "$_bin" "$_desc"
      else
        _level_miss=$((_level_miss + 1))
        printf "  ${_color}✗  %-14s %s${R}\n" "$_bin" "$_desc"
      fi
    done
    printf "\n"
  done

  # ── Part 2: Full toolchain (tools.json) ────────────────────────────
  printf "  ${C}Full toolchain${R} ${D}(tools.json)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"

  _total=0; _found=0; _missing=0; _missing_list=""

  # Read all tool names from tools.json
  jq -r 'to_entries[] | .key as $cat | .value | keys_unsorted[] | $cat + "\t" + .' "$_TOOLS_JSON" 2>/dev/null | \
  while IFS="$(printf '\t')" read -r _cat _tool; do
    _total=$((_total + 1))
    # Map tool names to actual binary names
    _bin="$_tool"
    case "$_tool" in
      ripgrep) _bin="rg" ;; node) _bin="node" ;; tsc) _bin="tsc" ;;
      sass) _bin="sass" ;; python3) _bin="python3" ;; virtualenv) _bin="virtualenv" ;;
      torch) _bin="python3" ;; scikit-learn|numpy|pandas|scipy|matplotlib|polars|dask|pydantic|bokeh|sympy|beautifulsoup4|scrapy|httpx|requests|seaborn|plotly|pyarrow|ipython) _bin="python3" ;;
      jupyterlab) _bin="jupyter" ;; docker-compose) _bin="docker-compose" ;; docker-buildx) _bin="docker" ;;
      wireguard) _bin="wg" ;; gnupg) _bin="gpg" ;; netcat) _bin="nc" ;;
      wireshark) _bin="tshark" ;; kubernetes-helm|helm) _bin="helm" ;;
      p7zip) _bin="7z" ;; wl-clipboard) _bin="wl-copy" ;; xclip) _bin="xclip" ;;
      R) _bin="R" ;; imagemagick) _bin="convert" ;; obs-studio) _bin="obs" ;;
    esac

    if command -v "$_bin" >/dev/null 2>&1; then
      _found=$((_found + 1))
    else
      _missing=$((_missing + 1))
      printf "  ${RED}✗${R}  ${Y}%-18s${R} ${D}(%s)${R}\n" "$_tool" "$_cat"
      _missing_list="${_missing_list} ${_tool}"
    fi
  done

  # Summary (vars lost in pipe subshell, re-count)
  _total_count=$(jq '[.[] | keys[]] | length' "$_TOOLS_JSON" 2>/dev/null)
  _missing_count=$(jq -r '[.[] | keys_unsorted[]] | .[]' "$_TOOLS_JSON" 2>/dev/null | while read -r _t; do
    _b="$_t"
    case "$_t" in
      ripgrep) _b="rg" ;; wireguard) _b="wg" ;; gnupg) _b="gpg" ;; netcat) _b="nc" ;;
      wireshark) _b="tshark" ;; p7zip) _b="7z" ;; wl-clipboard) _b="wl-copy" ;;
      imagemagick) _b="convert" ;; obs-studio) _b="obs" ;; jupyterlab) _b="jupyter" ;;
      R) _b="R" ;; helm|kubernetes-helm) _b="helm" ;;
      torch|scikit-learn|numpy|pandas|scipy|matplotlib|polars|dask|pydantic|bokeh|sympy|beautifulsoup4|scrapy|httpx|requests|seaborn|plotly|pyarrow|ipython) _b="python3" ;;
    esac
    command -v "$_b" >/dev/null 2>&1 || echo "$_t"
  done | wc -l)
  _found_count=$((_total_count - _missing_count))

  printf "\n${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  printf "  ${W}total${R} %-6s ${G}found${R} %-6s ${RED}missing${R} %s\n" "$_total_count" "$_found_count" "$_missing_count"

  if [ "$_missing_count" -gt 0 ]; then
    # Always use apt — fast, simple, works everywhere (even alongside nix)
    if command -v apt-get >/dev/null 2>&1; then
      printf "\n  ${Y}%s missing DTK deps${R} — installing via apt...\n" "$_missing_count"
      _APT_JSON="$_SCRIPT_DIR/deps-apt.json"
      # Only install DTK runtime deps (deps.json), NOT the full toolchain (tools.json)
      _pkgs=$(jq -r '[.required, .recommended, .optional] | add | keys[]' "$_DEPS_JSON" 2>/dev/null | while read -r _t; do
        if ! command -v "$_t" >/dev/null 2>&1; then
          _apt=$(jq -r --arg t "$_t" '.[$t] // ""' "$_APT_JSON" 2>/dev/null)
          [ -n "$_apt" ] && echo "$_apt"
        fi
      done | sort -u | tr '\n' ' ')
      if [ -n "$_pkgs" ]; then
        printf "  ${C}apt-get install${R} %s\n\n" "$_pkgs"
        # Fix dpkg: kill stuck apt, remove corrupt updates, clear locks, configure
        if [ -n "$S" ]; then
          printf "  ${D}fixing dpkg state...${R}\n"
          $S sh -c '
            kill -9 $(fuser /var/lib/dpkg/lock-frontend 2>/dev/null) 2>/dev/null
            rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
            for f in /var/lib/dpkg/updates/*; do
              [ -f "$f" ] && head -1 "$f" | grep -q "^Package:" 2>/dev/null || rm -f "$f"
            done
            dpkg --configure -a
          ' 2>&1 || true
        fi
        printf "  ${D}apt-get update${R}\n"
        $S apt-get update -qq 2>&1 || true
        printf "  ${D}apt-get install${R}\n"
        $S apt-get install -y $_pkgs 2>&1 || true
      fi
    elif command -v pacman >/dev/null 2>&1; then
      printf "\n  ${Y}pacman detected${R} — install missing with pacman\n"
    else
      printf "\n  ${RED}No apt or pacman found${R} — install tools manually\n"
    fi
  else
    printf "\n  ${G}All tools installed!${R}\n"
  fi
  printf "\n"
}

do_ssh()       { sh "$_CON_DIR/ssh/ssh.sh" "$@"; }

do_git_clone() { sh "$_PROV_DIR/git-clone/git-clone.sh" "$@"; }

do_install()   { sh "$_PROV_DIR/install/install.sh" "$@"; }
do_commands()  { sh "$_REF_DIR/commands/commands.sh" "$@"; }
do_info()      { sh "$_OBS_DIR/info/info.sh" "$@"; }

do_sys_info_menu() {
  printf "\n\033[1;36m── 51) infos ──\033[0m\n"
  printf "  51a sys-info         Static system identity\n"
  printf "  51b sys-net-resource Dynamic network + resources\n"
  printf "  51c sys-paths        Flake & engine paths\n"
  printf "  51d sys-envs         Environment variables\n"
  printf "  51e tools-table      Installed tools (5-col)\n"
  printf "  51f tools-help       Installed tools (with descriptions)\n"
  printf "  51g sys-mounts       Declared storage (LUKS, btrfs, partitions, swap)\n"
  printf "\n  ${C}52) deps${R}\n"
  printf "  52a deps-drift       Declared vs installed (summary)\n"
  printf "  52b deps-solver      Full toolchain check (detailed)\n\n"
}

do_sys_info() { set +x 2>/dev/null
  R='\033[0m'; Y='\033[1;33m'; W='\033[1;37m'; G='\033[1;32m'; D='\033[0;90m'
  _kern=$(uname -r 2>/dev/null | sed 's/[-+].*//')
  printf "\n${G}sys-info${R} ${D}(static)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  _F="  ${Y}%-12s${R} ${W}%s${R}\n"
  printf "$_F" "hostname" "$(hostname 2>/dev/null)"
  printf "$_F" "os" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
  printf "$_F" "arch" "$(uname -m)"
  printf "$_F" "kernel" "$_kern"
  printf "$_F" "shell" "$(basename "${SHELL:-sh}")"
  printf "$_F" "pkg" "$(if command -v nix >/dev/null 2>&1; then echo nix; elif command -v apt >/dev/null 2>&1; then echo apt; else echo unknown; fi)"
  printf "$_F" "init" "$(command -v systemctl >/dev/null && echo systemd || echo other)"
  printf "$_F" "nix" "$(command -v nix >/dev/null && echo ON || echo off)"
  printf "$_F" "docker" "$(command -v docker >/dev/null && echo ON || echo off)"
  printf "$_F" "cpu-model" "$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ //')"
  printf "$_F" "cpu-cores" "$(nproc 2>/dev/null)"
  printf "$_F" "ram-total" "$(free -h 2>/dev/null | awk '/Mem/{print $2}')"
  printf "$_F" "swap-total" "$(free -h 2>/dev/null | awk '/Swap/{print $2}')"
  printf "$_F" "disk-total" "$(LANG=C command df -h / 2>/dev/null | awk 'NR==2{print $2}')"
  printf "$_F" "boot-id" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8)"
  printf "\n"
}

do_sys_net_resource() { set +x 2>/dev/null
  R='\033[0m'; Y='\033[1;33m'; W='\033[1;37m'; G='\033[1;32m'; D='\033[0;90m'
  printf "\n${G}sys-net-resource${R} ${D}(dynamic)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  _F="  ${Y}%-12s${R} ${W}%s${R}\n"
  printf "$_F" "uptime" "$(uptime -p 2>/dev/null | sed 's/up //' || uptime 2>/dev/null | sed 's/.*up //;s/,.*//')"
  printf "$_F" "load" "$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
  printf "$_F" "ram-used" "$(free -h 2>/dev/null | awk '/Mem/{print $3"/"$2}')"
  printf "$_F" "swap-used" "$(free -h 2>/dev/null | awk '/Swap/{print $3"/"$2}')"
  printf "$_F" "disk-used" "$(LANG=C command df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
  printf "$_F" "ip" "$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}')"
  printf "$_F" "wg0" "$(ip -4 addr show wg0 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1 || echo down)"
  printf "$_F" "dns" "$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)"
  printf "$_F" "gateway" "$(ip route 2>/dev/null | awk '/default/{print $3; exit}')"
  printf "$_F" "users" "$(who 2>/dev/null | wc -l)"
  printf "$_F" "procs" "$(ps aux 2>/dev/null | wc -l)"
  printf "$_F" "containers" "$(docker ps -q 2>/dev/null | wc -l)"
  printf "$_F" "listening" "$(ss -tlnp 2>/dev/null | tail -n+2 | wc -l) ports"
  printf "\n"
}

do_sys_paths() { set +x 2>/dev/null
  R='\033[0m'; Y='\033[1;33m'; W='\033[1;37m'; G='\033[1;32m'; D='\033[0;90m'
  printf "\n${G}sys-paths${R} ${D}(flakes & engines)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  _F="  ${Y}%-20s${R} ${W}%s${R}\n"
  printf "$_F" "nixos-host" "~/git/cloud-unix/aa_nixos-surface_host/"
  printf "$_F" "hm-desktop" "~/git/cloud-unix/ba_flakes_desktop/"
  printf "$_F" "hm-termux" "~/git/cloud-unix/bb_flakes_termux/"
  printf "$_F" "cloud-repo" "~/git/cloud-infra/"
  printf "$_F" "front-repo" "~/git/front/"
  printf "$_F" "tools-repo" "~/git/cloud-mykonsole-dtk/"
  printf "$_F" "vault-repo" "~/git/cloud-vault/"
  printf "${D}  engines:${R}\n"
  printf "$_F" "cloud-engine" "~/git/cloud-mykonsole-dtk/build/flake-engines/cloud-engine/"
  printf "$_F" "cloud-orchestrator" "~/git/cloud-mykonsole-dtk/build/flake-engines/cloud-orchestrator/"
  printf "$_F" "front-engine" "~/git/cloud-mykonsole-dtk/build/flake-engines/front-engine/"
  printf "$_F" "front-orchestrator" "~/git/cloud-mykonsole-dtk/build/flake-engines/front-orchestrator/"
  printf "$_F" "container-orch." "~/git/cloud-mykonsole-dtk/build/flake-engines/cloud-container-orchestrator/"
  printf "$_F" "nix-os-desktop" "~/git/cloud-mykonsole-dtk/build/flake-engines/nix-os-desktop/"
  printf "$_F" "nix-hm-desktop" "~/git/cloud-mykonsole-dtk/build/flake-engines/nix-hm-desktop/"
  printf "$_F" "nix-hm-termux" "~/git/cloud-mykonsole-dtk/build/flake-engines/nix-hm-termux/"
  printf "\n"
}

do_sys_envs() { set +x 2>/dev/null
  R='\033[0m'; Y='\033[1;33m'; W='\033[1;37m'; G='\033[1;32m'; D='\033[0;90m'
  printf "\n${G}sys-envs${R} ${D}(environment variables)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  _F="  ${Y}%-16s${R} ${W}%s${R}\n"
  printf "$_F" "HOME" "${HOME:-?}"
  printf "$_F" "USER" "${USER:-?}"
  printf "$_F" "SHELL" "${SHELL:-?}"
  printf "$_F" "TERM" "${TERM:-?}"
  printf "$_F" "EDITOR" "${EDITOR:-?}"
  printf "$_F" "LANG" "${LANG:-?}"
  printf "$_F" "XDG_SESSION" "${XDG_SESSION_TYPE:-?}"
  printf "$_F" "DISPLAY" "${DISPLAY:-?}"
  printf "$_F" "WAYLAND" "${WAYLAND_DISPLAY:-?}"
  printf "$_F" "GOPATH" "${GOPATH:-?}"
  printf "$_F" "CARGO_HOME" "${CARGO_HOME:-?}"
  printf "$_F" "NPM_PREFIX" "${npm_config_prefix:-?}"
  printf "$_F" "NIX_PROFILES" "${NIX_PROFILES:-?}"
  printf "${D}  PATH entries:${R}\n"
  echo "$PATH" | tr ':' '\n' | while read -r _p; do
    printf "  ${D}%s${R}\n" "$_p"
  done
  printf "\n"
}
do_sys_mounts() { set +x 2>/dev/null
  R='\033[0m'; Y='\033[1;33m'; W='\033[1;37m'; G='\033[1;32m'; D='\033[0;90m'; C='\033[1;36m'
  _nixos_src="$HOME/git/cloud-unix/aa_nixos-surface_host/src"
  _fs="$_nixos_src/modules/hardware_filesystems.nix"
  _boot="$_nixos_src/modules/hardware_boot.nix"
  _prot="$_nixos_src/modules/configuration_system-protection.nix"

  # Collect runtime data once
  _df_data=$(df -k 2>/dev/null | awk 'NR>1 { printf "%s|%s|%s|%s\n", $6, $2, $3, $5 }')
  _swap_rt=$(swapon --bytes --noheadings 2>/dev/null)
  _grand_total_kb=0; _grand_used_kb=0

  # Helper: get runtime size for a mount → sets _sz_used _sz_total _sz_pct _sz_total_kb _sz_used_kb
  _mnt_sz() {
    _sz_used="-"; _sz_total="-"; _sz_pct="-"; _sz_total_kb=0; _sz_used_kb=0
    local line; while IFS= read -r line; do
      local mnt_f=${line%%|*}; local rest=${line#*|}
      if [ "$mnt_f" = "$1" ]; then
        local tk=${rest%%|*}; rest=${rest#*|}; local uk=${rest%%|*}; _sz_pct=${rest#*|}
        _sz_total_kb=$tk; _sz_used_kb=$uk
        _sz_total=$(awk "BEGIN{printf \"%.1fG\", $tk/1048576}")
        _sz_used=$(awk "BEGIN{printf \"%.1fG\", $uk/1048576}")
        break
      fi
    done <<EOF
$_df_data
EOF
  }

  printf "\n${G}sys-mounts${R} ${D}(declared storage — from nix source)${R}\n"
  printf "${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"

  # 1. LUKS
  printf "\n${C}LUKS Volumes${R}\n"
  printf "  ${Y}%-4s %-20s %-52s %-20s${R}\n" "#" "Name" "Device" "Source"
  printf "  ${D}%-4s %-20s %-52s %-20s${R}\n" "─" "────" "──────" "──────"
  if [ -f "$_boot" ]; then
    awk '
      /luks\.devices\."/ {
        gsub(/.*luks\.devices\."/, ""); gsub(/".*/, "")
        name = $0; getline
        while ($0 !~ /};/) {
          if ($0 ~ /device =/) { dev = $0; gsub(/.*= "/, "", dev); gsub(/".*/, "", dev) }
          getline
        }
        printf "  %-4s %-20s %-52s %-20s\n", "1", name, dev, "hardware_boot.nix"
      }
    ' "$_boot"
  fi

  # 2. Btrfs
  printf "\n${C}Btrfs Subvolume Mounts${R}\n"
  printf "  ${Y}%-4s %-42s %-26s %-8s %-8s %-6s %-20s${R}\n" "#" "Mount" "Subvolume" "Used" "Total" "%" "Source"
  printf "  ${D}%-4s %-42s %-26s %-8s %-8s %-6s %-20s${R}\n" "─" "─────" "─────────" "────" "─────" "──" "──────"
  _btrfs_n=0; _btrfs_total_kb=0; _btrfs_used_kb=0
  if [ -f "$_fs" ]; then
    _btrfs_lines=$(awk '
      /fileSystems\."/ {
        gsub(/.*fileSystems\."/, ""); gsub(/".*/, "")
        mount = $0; fs = ""; subvol = ""
        while (1) {
          getline
          if ($0 ~ /fsType =/) { fs = $0; gsub(/.*= "/, "", fs); gsub(/".*/, "", fs) }
          if ($0 ~ /subvol=/) { subvol = $0; gsub(/.*subvol=/, "", subvol); gsub(/".*/, "", subvol) }
          if ($0 ~ /subvolid=/) { subvol = $0; gsub(/.*subvolid=/, "", subvol); gsub(/".*/, "", subvol); subvol = "subvolid=" subvol }
          if ($0 ~ /};/) break
        }
        if (fs == "btrfs") printf "%s|%s\n", mount, subvol
      }
    ' "$_fs")
    while IFS='|' read -r _mnt _subvol; do
      [ -z "$_mnt" ] && continue
      _btrfs_n=$(( _btrfs_n + 1 ))
      _mnt_sz "$_mnt"
      _btrfs_total_kb=$(( _btrfs_total_kb + _sz_total_kb ))
      _btrfs_used_kb=$(( _btrfs_used_kb + _sz_used_kb ))
      _grand_total_kb=$(( _grand_total_kb + _sz_total_kb ))
      _grand_used_kb=$(( _grand_used_kb + _sz_used_kb ))
      printf "  %-4s %-42s %-26s %-8s %-8s %-6s %-20s\n" "$_btrfs_n" "$_mnt" "$_subvol" "$_sz_used" "$_sz_total" "$_sz_pct" "hardware_filesystems.nix"
    done <<EOF
$_btrfs_lines
EOF
    if [ "$_btrfs_n" -gt 0 ]; then
      _sub_t=$(awk "BEGIN{printf \"%.1fG\", $_btrfs_total_kb/1048576}")
      _sub_u=$(awk "BEGIN{printf \"%.1fG\", $_btrfs_used_kb/1048576}")
      _sub_p=$(( _btrfs_total_kb > 0 ? _btrfs_used_kb * 100 / _btrfs_total_kb : 0 ))
      printf "  ${D}%-4s %-42s %-26s %-8s %-8s %-6s${R}\n" "" "" "Subtotal ($_btrfs_n)" "$_sub_u" "$_sub_t" "${_sub_p}%"
    fi
  fi

  # 3. Partitions
  printf "\n${C}Partition Mounts${R}\n"
  printf "  ${Y}%-4s %-24s %-40s %-8s %-8s %-8s %-6s %-20s${R}\n" "#" "Mount" "Device" "Type" "Used" "Total" "%" "Source"
  printf "  ${D}%-4s %-24s %-40s %-8s %-8s %-8s %-6s %-20s${R}\n" "─" "─────" "──────" "────" "────" "─────" "──" "──────"
  _part_n=0; _part_total_kb=0; _part_used_kb=0
  if [ -f "$_fs" ]; then
    _part_lines=$(awk '
      /fileSystems\."/ {
        gsub(/.*fileSystems\."/, ""); gsub(/".*/, "")
        mount = $0; dev = ""; fs = ""
        while (1) {
          getline
          if ($0 ~ /device =/) { dev = $0; gsub(/.*= "/, "", dev); gsub(/".*/, "", dev) }
          if ($0 ~ /fsType =/) { fs = $0; gsub(/.*= "/, "", fs); gsub(/".*/, "", fs) }
          if ($0 ~ /};/) break
        }
        if (fs == "ext4" || fs == "vfat") printf "%s|%s|%s\n", mount, dev, fs
      }
    ' "$_fs")
    while IFS='|' read -r _mnt _dev _fstype; do
      [ -z "$_mnt" ] && continue
      _part_n=$(( _part_n + 1 ))
      _mnt_sz "$_mnt"
      _part_total_kb=$(( _part_total_kb + _sz_total_kb ))
      _part_used_kb=$(( _part_used_kb + _sz_used_kb ))
      _grand_total_kb=$(( _grand_total_kb + _sz_total_kb ))
      _grand_used_kb=$(( _grand_used_kb + _sz_used_kb ))
      printf "  %-4s %-24s %-40s %-8s %-8s %-8s %-6s %-20s\n" "$_part_n" "$_mnt" "$_dev" "$_fstype" "$_sz_used" "$_sz_total" "$_sz_pct" "hardware_filesystems.nix"
    done <<EOF
$_part_lines
EOF
    if [ "$_part_n" -gt 0 ]; then
      _sub_t=$(awk "BEGIN{printf \"%.1fG\", $_part_total_kb/1048576}")
      _sub_u=$(awk "BEGIN{printf \"%.1fG\", $_part_used_kb/1048576}")
      _sub_p=$(( _part_total_kb > 0 ? _part_used_kb * 100 / _part_total_kb : 0 ))
      printf "  ${D}%-4s %-24s %-40s %-8s %-8s %-8s %-6s${R}\n" "" "" "Subtotal ($_part_n)" "" "$_sub_u" "$_sub_t" "${_sub_p}%"
    fi
  fi

  # 4. tmpfs
  printf "\n${C}tmpfs${R}\n"
  printf "  ${Y}%-4s %-24s %-16s %-8s %-8s %-6s %-20s${R}\n" "#" "Mount" "Declared" "Used" "Total" "%" "Source"
  printf "  ${D}%-4s %-24s %-16s %-8s %-8s %-6s %-20s${R}\n" "─" "─────" "────────" "────" "─────" "──" "──────"
  _tmpfs_n=0; _tmpfs_total_kb=0; _tmpfs_used_kb=0
  if [ -f "$_fs" ]; then
    _tmpfs_lines=$(awk '
      /fileSystems\."/ {
        gsub(/.*fileSystems\."/, ""); gsub(/".*/, "")
        mount = $0; fs = ""; size = ""
        while (1) {
          getline
          if ($0 ~ /fsType =/) { fs = $0; gsub(/.*= "/, "", fs); gsub(/".*/, "", fs) }
          if ($0 ~ /size=/) { size = $0; gsub(/.*size=/, "", size); gsub(/".*/, "", size) }
          if ($0 ~ /};/) break
        }
        if (fs == "tmpfs") printf "%s|%s\n", mount, size
      }
    ' "$_fs")
    while IFS='|' read -r _mnt _declared; do
      [ -z "$_mnt" ] && continue
      _tmpfs_n=$(( _tmpfs_n + 1 ))
      _mnt_sz "$_mnt"
      _tmpfs_total_kb=$(( _tmpfs_total_kb + _sz_total_kb ))
      _tmpfs_used_kb=$(( _tmpfs_used_kb + _sz_used_kb ))
      _grand_total_kb=$(( _grand_total_kb + _sz_total_kb ))
      _grand_used_kb=$(( _grand_used_kb + _sz_used_kb ))
      printf "  %-4s %-24s %-16s %-8s %-8s %-6s %-20s\n" "$_tmpfs_n" "$_mnt" "$_declared" "$_sz_used" "$_sz_total" "$_sz_pct" "hardware_filesystems.nix"
    done <<EOF
$_tmpfs_lines
EOF
    if [ "$_tmpfs_n" -gt 0 ]; then
      _sub_t=$(awk "BEGIN{printf \"%.1fG\", $_tmpfs_total_kb/1048576}")
      _sub_u=$(awk "BEGIN{printf \"%.1fG\", $_tmpfs_used_kb/1048576}")
      _sub_p=$(( _tmpfs_total_kb > 0 ? _tmpfs_used_kb * 100 / _tmpfs_total_kb : 0 ))
      printf "  ${D}%-4s %-24s %-16s %-8s %-8s %-6s${R}\n" "" "" "Subtotal ($_tmpfs_n)" "$_sub_u" "$_sub_t" "${_sub_p}%"
    fi
  fi

  # 5. Swap
  printf "\n${C}Swap Devices${R}\n"
  printf "  ${Y}%-4s %-40s %-28s %-8s %-8s %-6s %-20s${R}\n" "#" "Device" "Type" "Used" "Total" "%" "Source"
  printf "  ${D}%-4s %-40s %-28s %-8s %-8s %-6s %-20s${R}\n" "─" "──────" "────" "────" "─────" "──" "──────"
  _swap_n=0; _swap_total_kb=0; _swap_used_kb=0
  if [ -f "$_fs" ]; then
    _swap_devs=$(awk '
      /swapDevices/ { inside=1; next }
      inside && /device =/ {
        dev = $0; gsub(/.*= "/, "", dev); gsub(/".*/, "", dev)
        print dev
      }
      inside && /\];/ { inside=0 }
    ' "$_fs")
    while IFS= read -r _sdev; do
      [ -z "$_sdev" ] && continue
      _swap_n=$(( _swap_n + 1 ))
      _s_used="-"; _s_total="-"; _s_pct="-"
      while IFS= read -r _sline; do
        case "$_sline" in *"$_sdev"*)
          set -- $_sline  # NAME TYPE SIZE USED PRIO
          if [ $# -ge 4 ]; then
            _s_total=$(awk "BEGIN{printf \"%.1fG\", $3/1073741824}")
            _s_used=$(awk "BEGIN{printf \"%.1fG\", $4/1073741824}")
            _s_pct=$(( $3 > 0 ? $4 * 100 / $3 : 0 ))"%"
            _swap_total_kb=$(( _swap_total_kb + $3 / 1024 ))
            _swap_used_kb=$(( _swap_used_kb + $4 / 1024 ))
          fi; break ;;
        esac
      done <<EOF2
$_swap_rt
EOF2
      printf "  %-4s %-40s %-28s %-8s %-8s %-6s %-20s\n" "$_swap_n" "$_sdev" "swap file" "$_s_used" "$_s_total" "$_s_pct" "hardware_filesystems.nix"
    done <<EOF
$_swap_devs
EOF
  fi
  if [ -f "$_prot" ]; then
    _zram_info=$(awk '
      /zramSwap[[:space:]]*=/ { inside=1; alg=""; pct=""; prio=""; next }
      inside && /algorithm/ { alg=$0; gsub(/.*= "/, "", alg); gsub(/".*/, "", alg) }
      inside && /memoryPercent/ { pct=$0; gsub(/.*= /, "", pct); gsub(/;.*/, "", pct) }
      inside && /priority/ { prio=$0; gsub(/.*= /, "", prio); gsub(/;.*/, "", prio) }
      inside && /};/ {
        inside=0
        printf "%s|%s|%s", alg, pct, prio
      }
    ' "$_prot")
    if [ -n "$_zram_info" ]; then
      IFS='|' read -r _zalg _zpct _zprio <<EOF
$_zram_info
EOF
      _desc="zram ($_zalg, ${_zpct}% RAM, prio $_zprio)"
      _swap_n=$(( _swap_n + 1 ))
      _s_used="-"; _s_total="-"; _s_pct="-"
      while IFS= read -r _sline; do
        case "$_sline" in */dev/zram*)
          set -- $_sline
          if [ $# -ge 4 ]; then
            _s_total=$(awk "BEGIN{printf \"%.1fG\", $3/1073741824}")
            _s_used=$(awk "BEGIN{printf \"%.1fG\", $4/1073741824}")
            _s_pct=$(( $3 > 0 ? $4 * 100 / $3 : 0 ))"%"
            _swap_total_kb=$(( _swap_total_kb + $3 / 1024 ))
            _swap_used_kb=$(( _swap_used_kb + $4 / 1024 ))
          fi; break ;;
        esac
      done <<EOF2
$_swap_rt
EOF2
      printf "  %-4s %-40s %-28s %-8s %-8s %-6s %-20s\n" "$_swap_n" "/dev/zram0" "$_desc" "$_s_used" "$_s_total" "$_s_pct" "config_system-protection.nix"
    fi
  fi
  if [ "$_swap_n" -gt 0 ]; then
    _sub_t=$(awk "BEGIN{printf \"%.1fG\", $_swap_total_kb/1048576}")
    _sub_u=$(awk "BEGIN{printf \"%.1fG\", $_swap_used_kb/1048576}")
    _sub_p=$(( _swap_total_kb > 0 ? _swap_used_kb * 100 / _swap_total_kb : 0 ))
    printf "  ${D}%-4s %-40s %-28s %-8s %-8s %-6s${R}\n" "" "" "Subtotal ($_swap_n)" "$_sub_u" "$_sub_t" "${_sub_p}%"
  fi

  # Grand totals
  _grand_total_kb=$(( _grand_total_kb + _swap_total_kb ))
  _grand_used_kb=$(( _grand_used_kb + _swap_used_kb ))

  # Summary
  _luks=0
  [ -f "$_boot" ] && _luks=$(grep -c 'luks\.devices\.' "$_boot" 2>/dev/null)
  _swap_total_n=$(( _swap_n ))
  _total=$(( _luks + _btrfs_n + _part_n + _tmpfs_n + _swap_total_n ))
  _gt=$(awk "BEGIN{printf \"%.1fG\", $_grand_total_kb/1048576}")
  _gu=$(awk "BEGIN{printf \"%.1fG\", $_grand_used_kb/1048576}")
  _gp=$(( _grand_total_kb > 0 ? _grand_used_kb * 100 / _grand_total_kb : 0 ))
  printf "\n${C}Summary${R}  LUKS: ${W}%s${R}  Btrfs: ${W}%s${R}  Partitions: ${W}%s${R}  tmpfs: ${W}%s${R}  Swap: ${W}%s${R}  Total: ${G}%s${R}  │  ${W}%s${R} / ${W}%s${R} (${G}%s%%${R})\n\n" \
    "$_luks" "$_btrfs_n" "$_part_n" "$_tmpfs_n" "$_swap_total_n" "$_total" "$_gu" "$_gt" "$_gp"
}

do_engines()   { sh "$_BUILD_DIR/flake-engines/engines.sh" "$@"; }
do_webhooks()  { sh "$_REC_DIR/webhooks/webhooks.sh" "$@"; }
# rescue-sshd: one-shot openssh sshd recovery on nix-on-droid (Termux).
# Recipe per nix-community/nix-on-droid issue #32. Lives entirely inside
# tools/, no dependency on the unix flake checkout being present.
do_rescue_sshd() { sh "$_REC_DIR/rescue-sshd/rescue-sshd.sh" "$@"; }

# rebuild-flake: pull ~/git/cloud-unix + run bb_flakes_termux/build.sh switch.
# One-command path to apply latest committed flake state on termux.
do_rebuild_flake() { sh "$_REC_DIR/rebuild-flake/rebuild-flake.sh" "$@"; }

# claude-rescue: 12-fallback chain to get the claude binary running. Each
# fallback is timeout-bounded; first success caches the binary at
# ~/.local/share/claude-rescue/claude for instant subsequent runs.
do_claude_rescue() { sh "$_REC_DIR/claude-rescue/claude-rescue.sh" "$@"; }
do_others()    { sh "$_DTK_DIR/.archive/others.sh" "$@"; }

# ═══════════════════════════════════════════════════════════════════
# E) HELP
# ═══════════════════════════════════════════════════════════════════

do_help() { set +x 2>/dev/null
  R='\033[0m'; C='\033[1;36m'; Y='\033[1;33m'; D='\033[0;90m'; W='\033[1;37m'
  printf "\n${C}Diego's Toolkit (DTK)${R} — unified CLI\n\n"
  printf "${Y}Usage:${R}\n"
  printf "  dtk.sh                        ${D}# interactive menu${R}\n"
  printf "  dtk.sh <command> [args]        ${D}# direct${R}\n\n"
  printf "${Y}Main Menu:${R}\n"
  # Fixed-width printf layout — same shortcut grid as show_menu_header
  # but no `column` dependency (works on minimal/Termux without util-linux).
  _R() { printf "  ${D}%-14s%-19s%-20s%-23s%s${R}\n" "$1" "$2" "$3" "$4" "$5"; }
  _S() { printf "  ${D}%-18s%-18s%-18s%-19s%s${R}\n" "$1" "$2" "$3" "$4" "$5"; }
  printf "  ${Y}%-14s%-17s%-20s%-22s%s${R}\n" "1) cmds-local" "2) cmds-cloud" "3) dashboards" "4) setups" "5) infos"
  printf "  ${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  _R "10 aliases"   "20 quick-cmds"      "local"              "40 containers"        "50 help"
  _R "11 webhooks"  "  20a gcp-proxy"    "30 monitors"        "  40a nix {c|g|t}"    "51 infos"
  _R "12 commands"  "  20b oci-mail"     "  30a btop"         "  40b apt {c|g|t}"    "  51a sys-info"
  _R "  (120-1226)" "  20c oci-analy"    "  30b iotop"        "41 nixos"             "  51b sys-net-res"
  _R ""             "  20d oci-apps"     "  30c top-batch"    "  41a hm {c|g|t}"     "  51c sys-paths"
  _R ""             "  20e gcp-t4"       "31 sysstat"         "42 shell"             "  51d sys-envs"
  _R ""             "  20f orchestrate"  "  31a iostat"       "  42a fish+tools"     "  51e tools-table"
  _R ""             "  20g local"        "  31b mpstat"       "  42b fish"           "  51f tools-help"
  _R ""             "  20h desktop"      "  31c pidstat"      "  42c konsole-cfg"    "  51g sys-mounts"
  _R ""             "  20i vps-cloud"    "  31d sar"          "43 git"               "52 deps"
  _R ""             "  20j gh-actions"   "  31e vmstat"       "  43a gcl-https"      "  52a deps-drift"
  _R ""             "  20k gh-repos"     "32 journal-dash"    "  43b gcl-ssh"        "  52b deps-solver"
  _R ""             "  20l gh-registry"  "  32a transport"    "44 sys"               ""
  _R ""             "21 ssh"             "  32b priority"     "  44a sudoers"        ""
  _R ""             "  21a gcp-proxy"    "  32c unit"         "45 llms"              ""
  _R ""             "  21b oci-mail"     "  32d watch-n35"    "  45a goose"          ""
  _R ""             "  21c oci-analy"    "33 connect"         "  45b claude/gemini"  ""
  _R ""             "  21d oci-apps"     "remote"             "  45c malloc-termux"  ""
  _R ""             "  21e gcp-t4"       "34 monitors"        "46 vault"             ""
  _R ""             "  21f github"       "  34a btop-dash"    "  46a vault-build"    ""
  _R ""             "22 mode"            "  34b journal-dash" "  46b env-vars-export" ""
  _R ""             "  22a ssh"          "  34c docker-stats" ""                     ""
  _R ""             "  22b dropbear"     ""                   ""                     ""
  _R ""             "  22c serial"       ""                   ""                     ""
  _R ""             "  22d status"       ""                   ""                     ""
  printf "  ${D}──────────────────────────────────────────────────────────────────────────────────${R}\n"
  printf "  ${D}12) commands:${R}\n"
  _S "120 fish-install" "125 stop-docker"  "1210 free-mem"    "1215 full-rescue"  "1220 ssh-restart"
  _S "121 flush-ipt"    "126 start-docker" "1211 disk-usage"  "1216 tmux-web"     "1221 wg-debug"
  _S "122 rst-sshd"     "127 docker-ps"    "1212 kill-wdog"   "1217 fix-wg-ip"    "1222 sshd-debug"
  _S "123 rst-wg"       "128 wg-status"    "1213 journal-sil" "1218 guardrail"    "1223 vm-health"
  _S "124 rst-docker"   "129 iptables"     "1214 fix-journal" "1219 fix-nix-path" "1224 fix-all"
  _S ""                 ""                 ""                 ""                  "1225 mem-emerg"
  _S ""                 ""                 ""                 ""                  "1226 hm-rescue"
  printf "  ${D}──────────────────────────────────────────────────────────────────────────────────${R}\n\n"
  printf "${Y}Direct Commands:${R}\n"
  printf "  dtk.sh aliases                  ${D}# all shell aliases (3-column)${R}\n"
  printf "  dtk.sh tools                    ${D}# all installed CLI tools (5-column)${R}\n"
  printf "  dtk.sh containers [img] [prof] ${D}# deb-nix cli | deb-apt gui${R}\n"
  printf "  dtk.sh btop                    ${D}# local btop (tmux)${R}\n"
  printf "  dtk.sh journal-dash [t|p|u]   ${D}# local journal (transport/priority/unit)${R}\n"
  printf "  dtk.sh connect                 ${D}# cloud connect dashboard${R}\n"
  printf "  dtk.sh btop-dash              ${D}# htop on all VMs (tmux 2x2)${R}\n"
  printf "  dtk.sh remote-journal         ${D}# journal on all VMs (tmux 2x2)${R}\n"
  printf "  dtk.sh ssh                     ${D}# GCP serial/ssh/rescue${R}\n"
  printf "  dtk.sh git-clone [path]        ${D}# clone all repos${R}\n"
  printf "  dtk.sh install                 ${D}# install dev toolchain${R}\n"
  printf "  dtk.sh commands [n]            ${D}# run quick command by number${R}\n"
  printf "  dtk.sh info                    ${D}# show installed tools${R}\n"
  printf "  dtk.sh engines                 ${D}# launch build engines${R}\n"
  printf "  dtk.sh fix-journal             ${D}# silence journal spam${R}\n"
  printf "  dtk.sh full-rescue             ${D}# flush iptables + restart sshd/wg${R}\n\n"
}

# ═══════════════════════════════════════════════════════════════════
# ENTRY POINT — set -x starts here (after quiet setup)
# ═══════════════════════════════════════════════════════════════════
_md_log_cmd() {
  # Append command header to dtk.md for interactive mode
  printf "\n---\n\n## %s — %s@%s — \`dtk %s\`\n\n\`\`\`\n" \
    "$(_LOG_TS)" "${USER:-?}" "$(hostname -s 2>/dev/null || echo ?)" "$1" >> "$MDFILE"
}
_md_log_end() { printf '```\n' >> "$MDFILE"; }

_resolve_shortcode_inner() {
  _code="$1"
  # Parametric/concatenated shortcodes the registry can't express as one entry
  # (a number tail selects a sub-item): handle here, everything else → registry.
  case "$_code" in
    11a)        do_webhooks once ; return 0 ;;
    12[0-9]*)   do_commands "${_code#12}" ; return 0 ;;
    20a[0-9]*)  do_qc_vm_direct gcp-proxy     "${_code#20a}" ; return 0 ;;
    20b[0-9]*)  do_qc_vm_direct oci-mail      "${_code#20b}" ; return 0 ;;
    20c[0-9]*)  do_qc_vm_direct oci-analytics "${_code#20c}" ; return 0 ;;
    20d[0-9]*)  do_qc_vm_direct oci-apps      "${_code#20d}" ; return 0 ;;
    20e[0-9]*)  do_qc_vm_direct gcp-t4        "${_code#20e}" ; return 0 ;;
  esac
  # Data-driven dispatch from registry.json (resolves shortcode | id | name).
  dtk_dispatch "$_code"
  return $?
}

_resolve_shortcode() {
  _code="$1"
  _log "shortcode: $_code"
  _md_log_cmd "$_code"
  # Capture output for md logging
  _sc_raw="${TMPDIR:-/tmp}/dtk-sc-$$"
  _resolve_shortcode_inner "$_code" | tee "$_sc_raw"
  _rc=$?
  _strip_ansi < "$_sc_raw" >> "$MDFILE"
  _md_log_end
  rm -f "$_sc_raw"
  return $_rc
}

set +x 2>/dev/null
if [ $# -ge 1 ]; then
  case "$1" in
    # Shortcodes: 2+ digits (e.g. 16, 44, 448, 4415)
    [1-5][0-9a-f]*) _resolve_shortcode "$1" ;;
    aliases)        do_aliases ;;
    tools)          do_tools ;;
    tools-help)     do_tools_help ;;
    gcl-https)      do_gcl_https ;;
    gcl-ssh)        do_gcl_ssh ;;
    git-clone)      do_gcl_https ;;
    btop)           do_local_btop ;;
    batch-htop|btop-dash) do_batch_htop ;;
    journal-dash)   do_journal_dash "${2:-}" ;;
    journal-transport) do_journal_dash transport ;;
    journal-priority)  do_journal_dash priority ;;
    journal-unit)      do_journal_dash unit ;;
    remote-journal) do_remote_journal ;;
    containers)     shift; sh "$(cd "$(dirname "$0")" && pwd)/commands/provision/containers/containers.sh" "$@" ;;
    docker-run)     shift; sh "$(cd "$(dirname "$0")" && pwd)/commands/provision/containers/containers.sh" "$@" ;;
    docker-start)   sh "$(cd "$(dirname "$0")" && pwd)/commands/provision/containers/containers.sh" deb-nix cli ;;
    connect)        shift; do_connect "$@" ;;
    others)         shift; do_others "$@" ;;
    ssh)            do_ssh ;;
    git-clone-old)  do_git_clone "${2:-$HOME/git}" ;;
    install)        do_install ;;
    commands)       do_commands "${2:-}" ;;
    info)           do_info ;;
    engines)        do_engines "${2:-}" ;;
    fix-journal)    do_commands 14 ;;
    full-rescue)    do_commands 15 ;;
    refresh|r|pull) _repo_dir="$(cd "$(dirname "$0")" && pwd)"; echo "Pulling latest from remote..."; git -C "$_repo_dir" fetch --all && git -C "$_repo_dir" reset --hard "origin/$(git -C "$_repo_dir" rev-parse --abbrev-ref HEAD)" && echo "Updated to $(git -C "$_repo_dir" log --oneline -1)" && exec "$0" ;;
    help|--help|-h) do_help ;;
    # id (observe.paths), domain+name (observe paths), or bare name (btop) → registry.
    # Only an UNRESOLVED token (rc 127) prints help; a resolved command's own
    # non-zero exit is passed through untouched.
    *)              dtk_dispatch "$@"; _rc=$?; [ "$_rc" = 127 ] && { do_help; exit 1; }; exit "$_rc" ;;
  esac
else
  set +x 2>/dev/null
  # Non-interactive (no TTY on stdin) → show banner + help and exit
  if ! [ -t 0 ]; then
    detect_system 2>/dev/null || true
    show_banner
    do_help
    printf "\033[1;33mTip:\033[0m no TTY detected — use \033[1;37mdtk.sh <command>\033[0m for direct execution.\n"
    printf "     For interactive menu, run inside a terminal: \033[0;90mdocker exec -it <ctr> sh dtk.sh\033[0m\n\n"
    exit 0
  fi
  while true; do
    show_menu_header
    printf "> "
    read -r _input || { echo; echo "Bye."; exit 0; }
    case "$_input" in
      1)  do_aliases; do_tools ;;
      2)  printf "\n  20 quick-cmds  21 ssh\n\n" ;;
      3)  do_connect ;;
      4)  sh "$(cd "$(dirname "$0")" && pwd)/commands/provision/containers/containers.sh" ;;
      5)  do_help ;;
      b|back) continue ;;
      r|refresh) _repo_dir="$(cd "$(dirname "$0")" && pwd)"; echo "Pulling latest from remote..."; git -C "$_repo_dir" fetch --all -q && git -C "$_repo_dir" reset --hard origin/$(git -C "$_repo_dir" rev-parse --abbrev-ref HEAD) -q && echo "Updated to $(git -C "$_repo_dir" log --oneline -1)" && exec "$0" ;;
      q)  echo "Bye."; exit 0 ;;
      # Shortcodes: 2+ digits — route through resolver
      [1-5][0-9a-f]*) _resolve_shortcode "$_input" ;;
      # id (observe.btop), 'domain command', or bare name → registry dispatch
      *)  dtk_dispatch $_input || echo "Invalid — shortcode (30a), id (observe.btop), 'domain command', or 1-5/b/q/r" ;;
    esac
  done
fi
