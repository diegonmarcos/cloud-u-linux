#!/bin/sh
# LLM launchers — goose, claude/gemini, claude-malloc-termux
# Usage: llms.sh [goose|claude|malloc-termux]
set -eu

R='\033[0m'; C='\033[1;36m'; Y='\033[1;33m'; G='\033[1;32m'
W='\033[1;37m'; D='\033[0;90m'; RED='\033[1;31m'

_check_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "  ${RED}%s not found${R}\n" "$1"
    return 1
  fi
  printf "  ${G}%-16s${R} %s\n" "$1" "$(command -v "$1")"
  return 0
}

# Ensure node + npm are available — OS-agnostic install
_ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    printf "  ${G}node${R}  %s  (%s)\n" "$(node --version 2>/dev/null)" "$(command -v node)"
    printf "  ${G}npm${R}   %s  (%s)\n" "$(npm --version 2>/dev/null)" "$(command -v npm)"
    return 0
  fi

  printf "  ${Y}node/npm not found — installing...${R}\n"

  # ── Step 1: try sudo install (native package manager) ──
  _installed=false
  _S=""
  if [ "$(id -u)" = "0" ]; then
    _S=""  # already root
  else
    for _p in /run/wrappers/bin/sudo /usr/bin/sudo /usr/local/bin/sudo; do
      [ -x "$_p" ] && $_p -n true 2>/dev/null && _S="$_p" && break
    done
  fi

  if [ "$(id -u)" = "0" ] || [ -n "$_S" ]; then
    printf "  ${Y}Trying system install...${R}\n"
    if command -v apt-get >/dev/null 2>&1; then
      $_S apt-get update -qq && $_S apt-get install -y -qq nodejs npm && _installed=true
    elif command -v dnf >/dev/null 2>&1; then
      $_S dnf install -y nodejs npm && _installed=true
    elif command -v pacman >/dev/null 2>&1; then
      $_S pacman -Sy --noconfirm nodejs npm && _installed=true
    fi
  fi

  # Also try rootless package managers (no sudo needed)
  if [ "$_installed" = false ]; then
    if command -v brew >/dev/null 2>&1; then
      brew install node && _installed=true
    elif command -v pkg >/dev/null 2>&1; then
      pkg install nodejs && _installed=true
    fi
  fi

  # ── Step 2: fallback — curl nix, then nix-shell nodejs ──
  if [ "$_installed" = false ]; then
    # Get nix if not present
    if ! command -v nix-shell >/dev/null 2>&1; then
      if command -v curl >/dev/null 2>&1; then
        printf "  ${Y}No sudo — installing nix (rootless)...${R}\n"
        curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
        [ -f "${HOME}/.nix-profile/etc/profile.d/nix.sh" ] && . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
      elif command -v wget >/dev/null 2>&1; then
        printf "  ${Y}No sudo — installing nix (rootless)...${R}\n"
        wget -qO- https://nixos.org/nix/install | sh -s -- --no-daemon
        [ -f "${HOME}/.nix-profile/etc/profile.d/nix.sh" ] && . "${HOME}/.nix-profile/etc/profile.d/nix.sh"
      fi
    fi

    # Create nix-shell wrappers for node/npm/npx
    if command -v nix-shell >/dev/null 2>&1; then
      printf "  ${Y}Using nix-shell for node (rootless)${R}\n"
      _bin="${HOME}/.local/bin"
      mkdir -p "$_bin"
      for _cmd in node npm npx; do
        printf '#!/bin/sh\nexec nix-shell -p nodejs --run "%s $*"\n' "$_cmd" > "$_bin/$_cmd"
        chmod +x "$_bin/$_cmd"
      done
      export PATH="$_bin:$PATH"
      printf "  ${G}Created nix-shell wrappers${R}  %s/{node,npm,npx}\n" "$_bin"
      _installed=true
    else
      printf "  ${RED}Cannot get node — no sudo, no nix, no curl/wget${R}\n"
      return 1
    fi
  fi

  if [ "$_installed" = false ]; then
    printf "  ${RED}No way to get node — need nix, sudo, brew, pkg, podman, or curl${R}\n"
    return 1
  fi

  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    printf "  ${G}Installed${R}  node %s  npm %s\n" "$(node --version 2>/dev/null)" "$(npm --version 2>/dev/null)"
    return 0
  else
    printf "  ${RED}node/npm install failed${R}\n"
    return 1
  fi
}

do_goose() {
  printf "\n${C}── Goose Install ──${R}\n\n"

  if command -v goose >/dev/null 2>&1; then
    _ver=$(goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '?')
    printf "  ${G}goose already installed${R}  v%s  (%s)\n\n" "$_ver" "$(command -v goose)"
    return 0
  fi

  # Install via official installer
  printf "  ${Y}Installing goose...${R}\n\n"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://github.com/block/goose/releases/latest/download/download_cli.sh | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://github.com/block/goose/releases/latest/download/download_cli.sh | sh
  else
    printf "  ${RED}curl/wget not found${R}\n"
    return 1
  fi

  if command -v goose >/dev/null 2>&1; then
    _ver=$(goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '?')
    printf "\n  ${G}Installed${R}  v%s\n\n" "$_ver"
  else
    printf "\n  ${RED}Install failed${R} — check output above\n\n"
    return 1
  fi
}

do_claude() {
  printf "\n${C}── Claude / Gemini CLI Install ──${R}\n\n"

  # Node.js prerequisite
  printf "  ${Y}Node.js${R}\n"
  _ensure_node || return 1
  printf "\n"

  # Claude Code (npx — no sudo, no global install)
  printf "  ${Y}Claude Code${R}\n"
  printf "  ${D}npx @anthropic-ai/claude-code${R}\n"
  npx @anthropic-ai/claude-code --version 2>/dev/null && printf "  ${G}Ready${R}\n" || printf "  ${RED}Failed${R}\n"
  printf "\n"

  # Gemini CLI (npx — no sudo, no global install)
  printf "  ${Y}Gemini CLI${R}\n"
  printf "  ${D}npx @anthropic-ai/gemini-cli${R}\n"
  npx @anthropic-ai/gemini-cli --version 2>/dev/null && printf "  ${G}Ready${R}\n" || printf "  ${RED}Failed${R}\n"
  printf "\n"
}

do_malloc_termux() {
  printf "\n${C}── Claude Code Malloc Fix (Termux/Android) ──${R}\n\n"
  # Matches bb_flakes_termux/src/flake.nix sessionVariables:
  #   LD_PRELOAD = mimalloc, MIMALLOC_PAGE_RESET=0, MIMALLOC_LARGE_OS_PAGES=0, MALLOC_ARENA_MAX=2
  # Packages: jemalloc + mimalloc

  _ok=true

  # 1. Install allocator libs via nix
  printf "  ${Y}Allocator libraries${R}\n"
  if command -v nix >/dev/null 2>&1; then
    for _pkg in jemalloc mimalloc; do
      _lib="${HOME}/.nix-profile/lib/lib${_pkg}.so"
      if [ -f "$_lib" ]; then
        printf "  ${G}%-10s${R} %s\n" "$_pkg" "$_lib"
      else
        printf "  ${Y}Installing %s...${R}\n" "$_pkg"
        nix profile install "nixpkgs#${_pkg}" 2>/dev/null && printf "  ${G}Installed${R}\n" || { printf "  ${RED}Failed${R}\n"; _ok=false; }
      fi
    done
  else
    printf "  ${RED}nix not found${R} — install nix first\n"
    printf "  ${D}curl -L https://nixos.org/nix/install | sh${R}\n"
    _ok=false
  fi
  printf "\n"

  # 2. Node.js prerequisite
  printf "  ${Y}Node.js${R}\n"
  _ensure_node || _ok=false
  printf "\n"

  # 3. Claude Code via npx (no sudo, no global install)
  printf "  ${Y}Claude Code${R}\n"
  printf "  ${D}npx @anthropic-ai/claude-code${R}\n"
  npx @anthropic-ai/claude-code --version 2>/dev/null && printf "  ${G}Ready${R}\n" || { printf "  ${RED}Failed${R}\n"; _ok=false; }
  printf "\n"

  # 3. Show env vars to set (from termux flake)
  _mimalloc_path="${HOME}/.nix-profile/lib/libmimalloc.so"
  printf "  ${Y}Session variables (set by termux flake):${R}\n"
  printf "  ${D}LD_PRELOAD=${R}%s\n" "$_mimalloc_path"
  printf "  ${D}MIMALLOC_PAGE_RESET=${R}0\n"
  printf "  ${D}MIMALLOC_LARGE_OS_PAGES=${R}0\n"
  printf "  ${D}MALLOC_ARENA_MAX=${R}2\n\n"

  if [ "$_ok" = true ]; then
    printf "  ${G}All dependencies installed.${R}\n"
    printf "  ${D}Run:  ~/git/cloud-unix/bb_flakes_termux/build.sh switch  to apply env vars${R}\n\n"
  else
    printf "  ${RED}Some dependencies missing — see errors above${R}\n\n"
  fi
}

# ── dispatch ──
_cmd="${1:-}"
[ $# -ge 1 ] && shift
case "$_cmd" in
  goose)         do_goose "$@" ;;
  claude)        do_claude "$@" ;;
  malloc-termux) do_malloc_termux "$@" ;;
  *)
    printf "\n${C}── LLM Launchers ──${R}\n\n"
    printf "  ${Y}45a${R}  goose           AI agent (Goose + MCP)\n"
    printf "  ${Y}45b${R}  claude/gemini   Claude Code / Gemini CLI\n"
    printf "  ${Y}45c${R}  malloc-termux   Claude Code with jemalloc (Termux)\n\n"
    printf "> "
    read -r _pick
    case "$_pick" in
      1|a|goose)                do_goose ;;
      2|b|claude|gemini)        do_claude ;;
      3|c|malloc|malloc-termux) do_malloc_termux ;;
      *) printf "  ${D}Cancelled${R}\n" ;;
    esac
    ;;
esac
