#!/usr/bin/env bash
# my-webserver engine. The Node Single Executable Application binary is built
# remotely only (see build.json's _remote_note + ship-my-webserver-app.yml) —
# this script never attempts that build. It only supports running the source
# directly (dev) and a syntax check.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

log()  { printf '\033[0;36m[my-webserver]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[my-webserver] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cmd_dev() {
  local port="${1:-8000}"
  local dir="${2:-$HOME}"
  command -v node >/dev/null 2>&1 || die "node required"
  log "Running src/my-webserver.cjs on port $port, root $dir"
  node src/my-webserver.cjs "$port" "$dir"
}

cmd_check() {
  command -v node >/dev/null 2>&1 || die "node required"
  node --check src/my-webserver.cjs
  log "syntax OK"
}

case "${1:-}" in
  dev)   shift; cmd_dev "${1:-}" "${2:-}" ;;
  check) cmd_check ;;
  *)
    echo "Usage: $0 [dev [port] [dir]|check]"
    echo "  The release binary is built remotely by GHA (ship-my-webserver-app.yml) — never locally."
    ;;
esac
