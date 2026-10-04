#!/bin/sh
# Claude Code rescue — 12-fallback chain with hard timeouts. Designed for
# nix-on-droid / Termux on aarch64 Android, but works on x86_64 Linux too.
#
# Goals:
#   - At least one fallback MUST work given any halfway-functional environment
#   - Each fallback is fully isolated — failure or hang in one never leaks
#   - Tight per-fallback timeout — total worst-case ~12 minutes if every step
#     burns its budget; happy path is sub-second (cached binary)
#   - First successful fallback caches the resolved binary at a stable path
#     so subsequent runs hit the fast path
#
# Usage:
#   claude-rescue [args passed to claude]
#   claude-rescue --version       # quick smoke test
#   FORCE_REFETCH=1 claude-rescue # ignore cache, re-download
#
# Exit codes:
#   0   claude executed successfully (exits with claude's own code)
#   1   all 12 fallbacks failed
set -u

CACHE_DIR="$HOME/.local/share/claude-rescue"
CACHE_BIN="$CACHE_DIR/claude"
NPM_PKG="@anthropic-ai/claude-code"

# UV_USE_IO_URING=0: io_uring breaks on Android kernels. Pre-set for any
# fallback that runs Node so we don't have to repeat it everywhere.
export UV_USE_IO_URING=0
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export TERM="${TERM:-xterm-256color}"

# Force-refetch wipes the cache so fallback 6/7 are forced to re-download.
if [ "${FORCE_REFETCH:-0}" = "1" ]; then
  rm -f "$CACHE_BIN" 2>/dev/null
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# ── Self-test mode ────────────────────────────────────────────────────────
# `claude-rescue --self-test` runs a dry-run of every fallback (no exec, just
# detection) and prints a green/red report. Useful for verifying the rescue
# chain stays healthy after a flake rebuild.
if [ "${1:-}" = "--self-test" ]; then
  printf "claude-rescue self-test (no claude execution)\n\n"
  _green=0; _red=0
  check() {
    _n="$1"; _desc="$2"; _path="$3"
    if [ -e "$_path" ] || command -v "$(basename "$_path")" >/dev/null 2>&1; then
      printf "  \033[0;32m✓\033[0m [%2d] %s — %s\n" "$_n" "$_desc" "$_path"
      _green=$((_green + 1))
    else
      printf "  \033[0;31m✗\033[0m [%2d] %s — %s (not present)\n" "$_n" "$_desc" "$_path"
      _red=$((_red + 1))
    fi
  }
  check 1 "cache"          "$CACHE_BIN"
  check 2 "nix-profile"    "$HOME/.nix-profile/bin/claude"
  check 3 "npm-cache"      "$HOME/.node_modules/node_modules/.bin/claude"
  check 4 "local-bin"      "$HOME/.local/bin/claude"
  check 5 "termux-app"     "/data/data/com.termux/files/usr/bin/claude"
  for _t in 6:musl-dl 7:glibc-dl 8:podman 9:docker 10:nix-run 11:npx 12:npm-bootstrap; do
    _n="${_t%%:*}"; _d="${_t#*:}"
    case "$_d" in
      *-dl)         _bin=$(command -v curl); _label="curl present" ;;
      podman)       _bin=$(command -v podman); _label="podman present" ;;
      docker)       _bin=$(command -v docker); _label="docker present" ;;
      nix-run)      _bin=$(command -v nix); _label="nix present" ;;
      npx)          _bin=$(command -v npx); _label="npx present" ;;
      npm-bootstrap) _bin=$(command -v npm); _label="npm present" ;;
    esac
    if [ -n "${_bin:-}" ]; then
      printf "  \033[0;32m✓\033[0m [%2d] %s — %s (%s)\n" "$_n" "$_d" "$_label" "$_bin"
      _green=$((_green + 1))
    else
      printf "  \033[0;33m·\033[0m [%2d] %s — %s missing (skipped on real run)\n" "$_n" "$_d" "$_label"
      _red=$((_red + 1))
    fi
  done
  printf "\n%d/%d fallbacks viable\n" "$_green" "$((_green + _red))"
  [ "$_green" -gt 0 ] && exit 0 || exit 1
fi

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_DIM='\033[2m'; C_RST='\033[0m'
TOTAL=12

step() { printf "${C_DIM}[%2d/%d]${C_RST} %s\n" "$1" "$TOTAL" "$2" >&2; }
ok()   { printf "${C_GREEN}      ✓ %s${C_RST}\n" "$*" >&2; }
fail() { printf "${C_YEL}      ✗ %s${C_RST}\n" "$*" >&2; }
die()  { printf "${C_RED}\nALL %d FALLBACKS FAILED${C_RST}\n" "$TOTAL" >&2; exit 1; }

# Quick liveness test: does this binary respond to --version within 3s?
test_bin() {
  _b="$1"
  [ -x "$_b" ] || return 1
  timeout 3 "$_b" --version >/dev/null 2>&1
}

# If a fallback gives us a working binary, cache + exec it. Never returns
# on success.
adopt_and_exec() {
  _b="$1"; shift
  if test_bin "$_b"; then
    if [ "$_b" != "$CACHE_BIN" ] && [ -f "$_b" ]; then
      cp "$_b" "$CACHE_BIN" 2>/dev/null && chmod +x "$CACHE_BIN" 2>/dev/null
    fi
    ok "claude OK at $_b — exec'ing"
    exec "$_b" "$@"
  fi
  return 1
}

# Detect aarch64 vs x86_64 + musl vs glibc for the native-binary fallbacks.
# Termux/nix-on-droid is bionic, but the musl static build works on bionic.
detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x64" ;;
    *)             ARCH="" ;;
  esac
}
detect_arch

###############################################################################
# 1) Cached binary (instant)
###############################################################################
step 1 "cached binary at $CACHE_BIN"
adopt_and_exec "$CACHE_BIN" "$@" || fail "no cached binary"

###############################################################################
# 2) Nix profile (~/.nix-profile/bin/claude — declarative install, if any)
###############################################################################
step 2 "~/.nix-profile/bin/claude"
adopt_and_exec "$HOME/.nix-profile/bin/claude" "$@" || fail "not in nix profile"

###############################################################################
# 3) npm shared cache (~/.node_modules/node_modules/.bin/claude)
###############################################################################
step 3 "~/.node_modules/node_modules/.bin/claude (npm shared cache)"
adopt_and_exec "$HOME/.node_modules/node_modules/.bin/claude" "$@" || fail "not in npm cache"

###############################################################################
# 4) ~/.local/bin (manual install) and PATH lookup
###############################################################################
step 4 "PATH lookup / ~/.local/bin"
for _p in "$HOME/.local/bin/claude" "$HOME/bin/claude" "$(command -v claude 2>/dev/null)"; do
  [ -n "$_p" ] && adopt_and_exec "$_p" "$@"
done
fail "not on PATH"

###############################################################################
# 5) Sibling Termux app (com.termux, separate from com.termux.nix)
###############################################################################
step 5 "/data/data/com.termux/files/usr/bin/claude (regular Termux app)"
adopt_and_exec "/data/data/com.termux/files/usr/bin/claude" "$@" || fail "no regular Termux install"

###############################################################################
# 6) Native musl tarball download (most portable on Android/bionic)
###############################################################################
step 6 "download native musl arm64 binary from npm registry (60s)"
if [ -n "$ARCH" ] && command -v curl >/dev/null 2>&1; then
  _ver=$(timeout 8 curl -sf "https://registry.npmjs.org/${NPM_PKG}/latest" 2>/dev/null \
    | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$_ver" ]; then
    _plat="linux-${ARCH}-musl"
    _url="https://registry.npmjs.org/${NPM_PKG}-${_plat}/-/${NPM_PKG#@anthropic-ai/}-${_plat}-${_ver}.tgz"
    _tmp=$(mktemp -d 2>/dev/null) && \
      timeout 60 curl -sfL "$_url" -o "$_tmp/c.tgz" 2>/dev/null && \
      tar -C "$_tmp" -xzf "$_tmp/c.tgz" 2>/dev/null && \
      [ -f "$_tmp/package/claude" ] && \
      chmod +x "$_tmp/package/claude" && \
      cp "$_tmp/package/claude" "$CACHE_BIN" && \
      chmod +x "$CACHE_BIN" && \
      rm -rf "$_tmp" && \
      adopt_and_exec "$CACHE_BIN" "$@"
    rm -rf "$_tmp" 2>/dev/null
  fi
fi
fail "musl download failed"

###############################################################################
# 7) Native glibc tarball download (fallback if musl variant missing)
###############################################################################
step 7 "download native glibc arm64 binary from npm registry (60s)"
if [ -n "$ARCH" ] && command -v curl >/dev/null 2>&1; then
  _ver=$(timeout 8 curl -sf "https://registry.npmjs.org/${NPM_PKG}/latest" 2>/dev/null \
    | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$_ver" ]; then
    _plat="linux-${ARCH}"
    _url="https://registry.npmjs.org/${NPM_PKG}-${_plat}/-/${NPM_PKG#@anthropic-ai/}-${_plat}-${_ver}.tgz"
    _tmp=$(mktemp -d 2>/dev/null) && \
      timeout 60 curl -sfL "$_url" -o "$_tmp/c.tgz" 2>/dev/null && \
      tar -C "$_tmp" -xzf "$_tmp/c.tgz" 2>/dev/null && \
      [ -f "$_tmp/package/claude" ] && \
      chmod +x "$_tmp/package/claude" && \
      cp "$_tmp/package/claude" "$CACHE_BIN" && \
      chmod +x "$CACHE_BIN" && \
      rm -rf "$_tmp" && \
      adopt_and_exec "$CACHE_BIN" "$@"
    rm -rf "$_tmp" 2>/dev/null
  fi
fi
fail "glibc download failed"

###############################################################################
# 8) Podman container — clean room, no proot interference
###############################################################################
step 8 "podman container with node:22-slim + npx (60s)"
if command -v podman >/dev/null 2>&1; then
  timeout 60 podman run --rm \
    -e ANTHROPIC_API_KEY -e TERM \
    -v "$HOME:/host-home:ro" \
    --user root node:22-slim \
    sh -c "npm install -g $NPM_PKG --no-audit --no-fund 2>/dev/null && claude $*" 2>&1 \
    && exit 0
fi
fail "podman unavailable or failed"

###############################################################################
# 9) Docker container (alternate to podman)
###############################################################################
step 9 "docker container with node:22-slim (60s)"
if command -v docker >/dev/null 2>&1; then
  timeout 60 docker run --rm \
    -e ANTHROPIC_API_KEY -e TERM \
    --user root node:22-slim \
    sh -c "npm install -g $NPM_PKG --no-audit --no-fund 2>/dev/null && claude $*" 2>&1 \
    && exit 0
fi
fail "docker unavailable or failed"

###############################################################################
# 10) nix run nixpkgs#nodejs_22 + npx (uses nix store, no global state)
###############################################################################
step 10 "nix run nodejs_22 + npx claude-code (90s)"
if command -v nix >/dev/null 2>&1; then
  timeout 90 nix --extra-experimental-features 'nix-command flakes' \
    run nixpkgs#nodejs_22 -- -e "
      const { spawn } = require('child_process');
      const args = ['-y', '$NPM_PKG'].concat(process.argv.slice(1));
      const p = spawn('npx', args, { stdio: 'inherit', env: process.env });
      p.on('exit', c => process.exit(c));
    " "$@" 2>&1 \
    && exit 0
fi
fail "nix run unavailable or failed"

###############################################################################
# 11) System npx (any) with hard memory cap
###############################################################################
step 11 "system npx with NODE_OPTIONS memory cap (120s)"
if command -v npx >/dev/null 2>&1; then
  NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=512" \
    timeout 120 npx -y "$NPM_PKG" "$@" \
    && exit 0
fi
fail "npx unavailable or OOM-killed"

###############################################################################
# 12) Raw npm install in a fresh tmpdir (last resort, slowest)
###############################################################################
step 12 "raw npm install in tmpdir + run (180s)"
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  _tmp=$(mktemp -d 2>/dev/null) && \
    cd "$_tmp" && \
    timeout 30 npm init -y >/dev/null 2>&1 && \
    NODE_OPTIONS="--max-old-space-size=512" \
      timeout 150 npm install "$NPM_PKG" --no-audit --no-fund >/dev/null 2>&1 && \
    [ -x "./node_modules/.bin/claude" ] && \
    cp "./node_modules/.bin/claude" "$CACHE_BIN" 2>/dev/null && \
    chmod +x "$CACHE_BIN" 2>/dev/null && \
    cd / && rm -rf "$_tmp" && \
    adopt_and_exec "$CACHE_BIN" "$@"
  cd / 2>/dev/null
  rm -rf "$_tmp" 2>/dev/null
fi
fail "raw npm install failed"

###############################################################################
# All 12 exhausted
###############################################################################
die
