#!/usr/bin/env bash
# Universal launcher for local (stdio) MCP servers run via `tsx`.
#
# WHY THIS EXISTS:
#   Node's ESM loader does NOT honour NODE_PATH for bare-specifier imports
#   (e.g. `import ... from "@modelcontextprotocol/sdk/..."`). ESM only
#   resolves bare imports by walking up the directory tree from the importing
#   file looking for a `node_modules/`. Setting NODE_PATH in the MCP env block
#   therefore has no effect for these servers — they need a `node_modules`
#   symlink physically beside the source.
#
#   Additionally, several cloud/ services share one physical `shared/` lib tree
#   via a symlink into another service (e.g.
#   user-ai_cloud-cgc-mcp/src/code/shared ->
#   infra-api_c3-infra-api/src/code/shared). Node resolves modules from the
#   *realpath* of the imported file, so the dir that physically owns `shared/`
#   ALSO needs a `node_modules` symlink, not just the server's own dir.
#
# WHAT IT DOES:
#   1. Ensures a `node_modules` symlink in the server's own directory.
#   2. If the server has a `shared/` symlink, ensures a `node_modules` symlink
#      in the directory that physically owns that shared tree.
#   3. execs `npx tsx <entry>`.
#
# Idempotent + self-healing: missing symlinks are (re)created on every launch,
# existing real node_modules dirs are left untouched.
#
# Usage: mcp-local-launch.sh /abs/path/to/index.ts [extra tsx args...]
# Shared modules root resolution order:
#   $MCP_SHARED_MODULES  ->  $NODE_PATH  ->  $HOME/.node_modules/node_modules
set -eu

ENTRY="${1:?usage: mcp-local-launch.sh <entry.ts> [args...]}"
shift
DIR="$(cd "$(dirname "$ENTRY")" && pwd)"
SHARED="${MCP_SHARED_MODULES:-${NODE_PATH:-$HOME/.node_modules/node_modules}}"

# Create a node_modules symlink in $1 -> $SHARED, unless something already
# occupies that path (real install or pre-existing symlink).
link_node_modules() {
  _d="$1"
  [ -d "$_d" ] || return 0
  if [ ! -e "$_d/node_modules" ] && [ -d "$SHARED" ]; then
    ln -sfn "$SHARED" "$_d/node_modules"
  fi
}

# 1) the server's own directory
link_node_modules "$DIR"

# 2) the physical owner of a symlinked shared/ tree (Node resolves from realpath)
if [ -L "$DIR/shared" ]; then
  link_node_modules "$(dirname "$(readlink -f "$DIR/shared")")"
fi

# cloud-cgc-mcp only: keep the LOCAL octocode DB tracking the GHCR upstream
# (single source of truth, identical to oci-apps). Guarded to ≤ once/24h,
# non-fatal, and a no-op until the producer (ship-cgc-db) has seeded GHCR.
# Blocks briefly so the DB is consistent before the server opens it.
case "$ENTRY" in
  */user-ai_cloud-cgc-mcp/*)
    _pull="$HOME/git/cloud-infra/1_cicd/src/scripts/cloud-cgc-db-pull.sh"
    _stamp="$HOME/.cache/cgc-db-pull.stamp"
    if [ -f "$_pull" ] && command -v docker >/dev/null 2>&1; then
      if [ ! -f "$_stamp" ] || [ -n "$(find "$_stamp" -mtime +1 2>/dev/null)" ]; then
        mkdir -p "$(dirname "$_stamp")"
        sh "$_pull" >/dev/null 2>&1 && : > "$_stamp" || true
      fi
    fi
    ;;
esac

exec npx tsx "$ENTRY" "$@"
