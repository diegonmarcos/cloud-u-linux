#!/usr/bin/env bash
# claude-status-refresh.sh — the ONE process that may run the five machine-wide
# status helpers (mcp / flags / skl / sys / rul). The status line never does.
#
# Why this exists (measured 2026-10-06 on the phone, proot Debian under
# Android): the status line fell back to spawning all five helpers inline when
# no my-ai daemon had published .blocks — and on the phone no daemon ever will
# (the release 404s for that arch), so "fallback" was the permanent path: five
# bash forks + jq + git per paint, per session, every 5 s, and the MCP helper
# probing eleven servers over curl on top. Android's OOM killer answered with
# signal 9 to every claude session. The rule, now binding: A STATUS LINE MAY
# ONLY READ FILES AT PAINT. This script is the only thing that forks, and it
# is bounded four ways: nice 19 (and idle IO class where allowed), timeout 20
# over the whole batch, one lock shared by every session, and a TTL the paint
# checks before it even launches us.
#
# Contract with statusline-command.sh (the only caller):
#   - paint holds $CACHE.lock (mkdir) BEFORE launching us, detached, never waited;
#   - we write $CACHE atomically: exactly five lines, mcp/flags/skl/sys/rul,
#     in that order, each helper's output flattened to one line;
#   - we free the lock on every exit path, including being timed out.
# Memory: nothing here reads my-ai-usage.json or a transcript; the batch holds
# five short strings and nothing that grows with session length.
set -u

CACHE="${XDG_RUNTIME_DIR:-/tmp}/claude-status.cache"
LOCK="$CACHE.lock"
HELPERS="${CLAUDE_STATUS_HELPERS:-$HOME/.claude}"
cwd="${1:-$PWD}"

trap 'rm -f "$CACHE.tmp"; rmdir "$LOCK" 2>/dev/null' EXIT
# Lowest IO class too, where the kernel lets us — on proot/Android it may not.
command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1

# Each helper is one $(...) so a multi-line answer cannot shift the cache rows.
# The MCP helper's own detached probe is capped at 20 s overall and 5 s per
# server (CLAUDE_MCP_PROBE_TIMEOUT) — it escapes the batch timeout below by
# design (setsid), so it carries its own bound.
export CLAUDE_MCP_PROBE_TIMEOUT=20
timeout 20 bash -c '
    one() { local v; v=$("$@" 2>/dev/null); printf "%s\n" "${v//$'"'"'\n'"'"'/ }"; }
    one bash "$1/claude-mcp-status.sh" "$2"
    one bash "$1/claude-flags-status.sh" --format ansi
    one bash "$1/claude-plugins-status.sh" --part skl --format ansi
    one bash "$1/claude-plugins-status.sh" --part sys --format ansi
    one bash "$1/claude-hooks-status.sh" --format ansi
' _ "$HELPERS" "$cwd" > "$CACHE.tmp" 2>/dev/null
# Only a complete batch replaces the cache; a timed-out partial keeps the old one.
if [ "$(wc -l < "$CACHE.tmp" 2>/dev/null)" = "5" ]; then
    mv -f "$CACHE.tmp" "$CACHE"
fi
