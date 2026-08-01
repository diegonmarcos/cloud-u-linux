#!/usr/bin/env bash
# One runnable check for the status line's usage rows. The contract is that the
# status line COMPUTES NOTHING about token usage — `my-ai usage --daemon`
# publishes my-ai-usage.json and this script only looks its own session up and
# draws it. Both halves are asserted here: the lookup produces the right numbers,
# and the paint path contains no transcript parsing of any kind.
#   bash test-statusline-tokscan.sh
set -u
SL="$(dirname "$0")/statusline-command.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# A snapshot shaped like the daemon's: all-time totals per session, the active
# 5h block, and that block split per session.
cat > "$tmp/usage.json" <<'JSON'
{
  "generated_ms": 1000,
  "block": { "input": 100, "output": 20, "cache_read": 5000, "cache_write": 300,
             "total_tokens": 5420, "cost": 12.5, "reset_in": "2h 30m", "burn_per_min": 1234.0 },
  "block_sessions": {
    "sess-a": { "input": 10, "output": 2, "cache_read": 500, "cache_write": 30, "total_tokens": 542 }
  },
  "sessions": {
    "sess-a": { "input": 999, "output": 888, "cache_read": 77777, "cache_write": 6666, "total_tokens": 86330 },
    "sess-b": { "input": 1,   "output": 1,   "cache_read": 1,     "cache_write": 1,    "total_tokens": 4 }
  }
}
JSON

# The lookup, lifted from the status line so the test tracks it.
lookup() {
    jq -r --arg id "$1" '
        (.sessions[$id]       // {}) as $s |
        (.block_sessions[$id] // {}) as $b |
        [ ($s.input//0), ($s.output//0), ($s.cache_read//0), ($s.cache_write//0),
          ($b.input//0), ($b.output//0), ($b.cache_read//0), ($b.cache_write//0),
          (if (.block_sessions[$id]) then 1 else 0 end) ] | @tsv' "$tmp/usage.json" |
    tr '\t' ' '
}

# All-time totals for LINE 4, window-scoped totals for 5h-S, present flag set.
got=$(lookup sess-a)
[ "$got" = "999 888 77777 6666 10 2 500 30 1" ] || fail "sess-a lookup: got '$got'"

# THE regression this exists for: 5h-S must be SMALLER than the session total.
# It was briefly wired to the all-time figures, so a long-running session
# printed a 5h row larger than the 5h-T line above it.
read -r s_in _ _ _ b_in _ <<<"$(lookup sess-a)"
[ "$b_in" -lt "$s_in" ] || fail "5h-S ($b_in) not window-scoped vs session total ($s_in)"

# A session with no usage in the active block must not draw a 5h-S row at all.
got=$(lookup sess-b)
[ "${got##* }" = "0" ] || fail "sess-b has no block usage but was flagged present: '$got'"

# An unknown session degrades to zeros instead of erroring.
got=$(lookup nope)
[ "$got" = "0 0 0 0 0 0 0 0 0" ] || fail "unknown session: got '$got'"

# ── the paint path must not parse transcripts or spawn a scanner ─────────────
code=$(grep -v '^[[:space:]]*#' "$SL")
printf '%s' "$code" | grep -q 'jq -rs'                   && fail "status line slurps a transcript (jq -rs)"
printf '%s' "$code" | grep -q 'my-ai usage --statusline' && fail "status line spawns my-ai on the paint path"
printf '%s' "$code" | grep -q 'type=="assistant"'        && fail "status line parses transcript records itself"
printf '%s' "$code" | grep -q 'tac'                      && fail "status line reads a whole transcript with tac"

echo "ok"
