#!/usr/bin/env bash
# test-claude-mcp-status.sh — the statusline MCP dot must not go green on a
# service that is gone.
#
# Regression under test: the probe used to score ANY http code other than 000
# as "on". Every fleet MCP sits behind the shared mcp.diegonmarcos.com reverse
# proxy, which answers 502 when the backend container is absent — so the dot
# stayed green while google-workspace-mcp did not exist on oci-apps at all.
#
# The two halves matter equally and pull in opposite directions, which is why
# both are asserted here: a gateway error must read as down, and a plain 4xx
# must still read as up (a live streamable-HTTP MCP rejects a bare GET with
# 400/405 — that is the protocol, not an outage). A "fix" that flipped all
# non-2xx to off would turn every healthy MCP grey and is caught below.

set -u
SCRIPT="$(dirname "$0")/claude-mcp-status.sh"
fails=0

check() {
  local code="$1" want="$2" got
  got="$(bash "$SCRIPT" --verdict "$code")"
  if [ "$got" = "$want" ]; then
    printf 'ok    http %-4s -> %-3s\n' "${code:-<empty>}" "$got"
  else
    printf 'FAIL  http %-4s -> %-3s (want %s)\n' "${code:-<empty>}" "$got" "$want"
    fails=$((fails + 1))
  fi
}

# Backend absent behind a live proxy — the outage this test exists for.
check 502 off
check 503 off
check 504 off

# No connection at all.
check 000 off
check ""  off

# Live MCP endpoint: rejects a bare GET, but is emphatically up.
check 400 on
check 405 on
check 401 on
check 404 on
check 200 on

if [ "$fails" -eq 0 ]; then
  echo "PASS — all verdicts correct"
  exit 0
fi
echo "FAIL — $fails verdict(s) wrong"
exit 1
