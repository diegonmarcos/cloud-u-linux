#!/usr/bin/env bash
# test-listen-error.sh — a server that cannot take its port must SAY so.
#
# The bug this was written for: server.listen() had no 'error' listener, so a
# failed bind was an unhandled 'error' event. EventEmitter rethrows those, and
# the entire diagnosis was 14 lines of Node internals —
#
#   node:events:497
#         throw er; // Unhandled 'error' event
#   Error: listen EADDRINUSE: address already in use 127.0.0.1:8000
#       at Server.setupListenHandle [as _listen2] (node:net:1941:16)
#       ...
#
# — with the one fact a reader needs (the port is taken; pick another) buried
# in the middle of a stack that suggests a crash in the server rather than a
# busy socket.
#
# That is survivable in a terminal, where you can just retype the command. It
# is not survivable anywhere the process is started FOR you and its stderr
# lands in a log pane: #288 wants this server launched from an Android app, and
# port 8000 on a phone is very likely ALREADY held by the Nix-on-Droid
# instance, because Android shares 127.0.0.1 across every app sandbox. The
# first run of the new launcher is the MOST likely one to hit this.
#
# Asserts on the real script, against a real occupied port. No mocks: the
# scenario is two processes wanting one socket, and that is cheap to just do.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SELF_DIR/src/my-webserver.cjs"

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }

# High, odd port: low ones need privileges (a different errno, a different
# assertion) and a common one might genuinely be in use by something else,
# which would pass this test for the wrong reason.
PORT=48771
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "=== listen error: port $PORT held by another process ==="

node -e "require('net').createServer().listen($PORT,'127.0.0.1',()=>{
           process.stdout.write('held\n'); setTimeout(()=>process.exit(0), 20000); })" \
     > "$TMP/holder.out" 2>&1 &
HOLDER=$!
trap 'kill $HOLDER 2>/dev/null; rm -rf "$TMP"' EXIT

for _ in $(seq 1 40); do
  grep -q held "$TMP/holder.out" 2>/dev/null && break
  sleep 0.1
done
grep -q held "$TMP/holder.out" 2>/dev/null || {
  echo "  FAIL — could not occupy $PORT to set the scenario up"; exit 1; }

HTTPD_VERBOSE=0 node "$SRC" "$PORT" "$TMP" > "$TMP/out" 2>&1
RC=$?
OUT="$(cat "$TMP/out")"

bad=0
check() {  # check <what> <condition-result>
  if [ "$2" = "0" ]; then echo "  ok   — $1"; else echo "  FAIL — $1"; bad=$((bad+1)); fi
}

# Non-zero exit is what lets a supervisor tell a refused port from a clean stop.
[ "$RC" -ne 0 ]; check "exits non-zero (got $RC)" $?

# The three facts a reader needs, none of which the stack trace led with.
grep -q "did not start"        <<<"$OUT"; check "says it did not start"          $?
grep -q "EADDRINUSE"           <<<"$OUT"; check "names the errno"                $?
grep -q "$PORT"                <<<"$OUT"; check "names the port"                 $?
grep -qi "different port"      <<<"$OUT"; check "says what to do about it"       $?

# The regression itself: if the 'error' listener is ever removed, Node's
# rethrow comes back and THIS is what reappears.
! grep -q "Unhandled 'error' event" <<<"$OUT"; check "no unhandled-error rethrow" $?
! grep -q "node:net:"               <<<"$OUT"; check "no Node-internals stack"    $?

# A banner claiming a URL that was never bound is worse than no banner: it is
# the process reporting itself alive as it dies.
! grep -q "━━━ my-webserver ━━━" <<<"$OUT"; check "does not print the alive banner" $?

echo "  --- what the operator actually sees ---"
sed 's/^/      /' <<<"$OUT" | head -10

if [ "$bad" -ne 0 ]; then echo "=== listen error: FAIL ($bad) ==="; exit 1; fi
echo "=== listen error: PASS ==="
