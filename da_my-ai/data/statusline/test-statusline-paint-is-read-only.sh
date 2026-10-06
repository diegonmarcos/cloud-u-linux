#!/usr/bin/env bash
# The rule this enforces: A STATUS LINE MAY ONLY READ FILES AT PAINT. Measured
# 2026-10-06 on the phone: the paint spawned the five machine-wide helpers
# inline whenever no daemon had published .blocks — which on the phone is
# always — and Android's OOM killer took every claude session down with it.
# Two halves, both grep-based like test-statusline-tokscan.sh: the paint path
# forks no helper and pipes stdin into jq exactly once; the one refresher it
# may launch is detached, nice'd, time-capped and lock-serialised. Then one
# live run: with helpers that stall, a cold paint still returns at once and
# the batch lands in the cache behind it.
#   bash test-statusline-paint-is-read-only.sh
set -u
D="$(cd "$(dirname "$0")" && pwd)"
SL="$D/statusline-command.sh"; RF="$D/claude-status-refresh.sh"; MCP="$D/claude-mcp-status.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
n=0; ok() { n=$((n+1)); }

code=$(grep -v '^[[:space:]]*#' "$SL")
rcode=$(grep -v '^[[:space:]]*#' "$RF")

# ── paint path ───────────────────────────────────────────────────────────────
printf '%s\n' "$code" | grep -q 'bash "\$HOME/.claude/claude-[a-z]*-status\.sh"' \
    && fail "paint path spawns a status helper"; ok
[ "$(printf '%s\n' "$code" | grep -c '"\$input" | jq')" = 1 ] \
    || fail "stdin must be parsed by exactly one jq"; ok
[ "$(printf '%s\n' "$code" | grep -c '| *jq ')" = 1 ] \
    || fail "a second jq reads from a pipe on the paint path"; ok
printf '%s\n' "$code" | grep -q 'claude mcp list\|curl ' && fail "paint path probes the network"; ok

# ── the launch: detached, nice'd, redirected, behind the lock and the TTL ────
launch=$(printf '%s\n' "$code" | grep 'claude-status-refresh\.sh')
[ "$(printf '%s\n' "$launch" | grep -c .)" = 1 ] || fail "refresher launched from more than one place"; ok
printf '%s' "$launch" | grep -q '^[[:space:]]*setsid nice -n 19 bash ' || fail "launch is not setsid + nice 19"; ok
printf '%s' "$launch" | grep -q '</dev/null >/dev/null 2>&1 &$'      || fail "launch is not redirected and backgrounded"; ok
printf '%s\n' "$code" | grep -q 'mkdir "\$blocks_lock" 2>/dev/null; then' || fail "launch is not gated on the lock"; ok
printf '%s\n' "$code" | grep -q '"\$_age" -ge "\$blocks_ttl"'            || fail "launch is not gated on the TTL"; ok
printf '%s\n' "$code" | grep -q 'CLAUDE_STATUS_TTL:-300'                 || fail "TTL default is not 300"; ok

# ── the refresher: one bounded batch, lock freed on every exit ───────────────
printf '%s\n' "$rcode" | grep -q '^timeout 20 bash -c'                   || fail "refresher batch is not under timeout 20"; ok
printf '%s\n' "$rcode" | grep -q 'trap .*rmdir "\$LOCK"'                 || fail "refresher does not free the lock on exit"; ok
[ "$(printf '%s\n' "$rcode" | grep -c 'claude-[a-z]*-status\.sh')" = 5 ] || fail "refresher must run exactly the five helpers"; ok
printf '%s\n' "$rcode" | grep -q 'jq\|usage\.json'                        && fail "refresher must not parse usage json"; ok
printf '%s\n' "$rcode" | grep -q 'CLAUDE_MCP_PROBE_TIMEOUT=20'            || fail "refresher does not cap the MCP probe at 20 s"; ok
grep -q 'timeout 5 curl'                        "$MCP" || fail "MCP probe is not 5 s per server"; ok
grep -q 'CLAUDE_MCP_PROBE_TIMEOUT:-60'          "$MCP" || fail "MCP probe overall cap is not overridable"; ok

# ── live: stalled helpers, cold cache → instant paint, batch lands behind ────
command -v jq >/dev/null 2>&1 || { echo "ok ($n static checks; jq absent, live run skipped)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.claude"
cp "$RF" "$tmp/home/.claude/"
for h in mcp flags plugins hooks; do
    printf '#!/usr/bin/env bash\nsleep 1; printf "%%s" "%s-ok"\n' "$h" > "$tmp/home/.claude/claude-$h-status.sh"
done
input='{"model":{"display_name":"x"},"workspace":{"current_dir":"/"},"session_id":"paint-ro","transcript_path":"/dev/null"}'
start=$(date +%s%N)
out=$(printf '%s' "$input" | HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp" STATUSLINE_RENDER=1 timeout 10 bash "$SL" 2>/dev/null)
ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$ms" -lt 5000 ] || fail "cold paint waited on the helpers (${ms} ms)"; ok
printf '%s' "$out" | grep -q 'mcp-ok' && fail "cold paint rendered helper output it could only have spawned"; ok
[ -d "$tmp/claude-status.cache.lock" ] || fail "paint did not take the lock before launching"; ok
sleep 6
[ -s "$tmp/claude-status.cache" ] || fail "refresher wrote no cache"; ok
[ "$(wc -l < "$tmp/claude-status.cache")" = 5 ] || fail "cache is not five lines"; ok
[ -d "$tmp/claude-status.cache.lock" ] && fail "refresher left the lock held"; ok
out=$(printf '%s' "$input" | HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp" STATUSLINE_RENDER=1 timeout 10 bash "$SL" 2>/dev/null)
printf '%s' "$out" | grep -q 'mcp-ok' || fail "warm paint did not read the cache"; ok
[ -d "$tmp/claude-status.cache.lock" ] && fail "warm paint under TTL launched a refresher"; ok

echo "ok ($n checks)"
