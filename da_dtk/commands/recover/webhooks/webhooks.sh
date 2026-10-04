#!/bin/sh
# DTK Webhooks — bidirectional remote execution bridge via ntfy
# Claude publishes commands to ntfy topic, VM fetches+runs+returns output
#
# Flow:
#   1. Sender posts a command to ntfy topic: dtk-cmd-<target-hostname>
#   2. Receiver runs: webhooks.sh once   (single fetch)
#                  or webhooks.sh watch  (poll loop)
#   3. Receiver executes the command, posts output to dtk-out-<receiver-hostname>
#   4. Sender reads output from dtk-out-<receiver-hostname>
#
# Modes:
#   once                          — fetch one command from local CMD topic, run, post output, exit
#   watch                         — poll loop on local CMD topic
#   post  [message]               — post a manual message to local OUT topic (default: "<host> webhook ready")
#   cmd   <target-host> <cmd...>  — send a command to a REMOTE node's CMD topic (dtk-cmd-<target-host>)
#   test                          — local round-trip self-test (post echo, fetch, run, verify in OUT)
set -eu

# ntfy internal access — no Authelia. Check health with JSON response (not HTML redirect)
NTFY_BASE=""
for _url in "http://localhost:8090" "http://127.0.0.1:8090" "http://10.0.0.1:8090"; do
  _resp=$(curl -sf -m 2 "$_url/v1/health" 2>/dev/null || echo "")
  case "$_resp" in *healthy*) NTFY_BASE="$_url"; break ;; esac
done
if [ -z "$NTFY_BASE" ]; then
  echo "  ERROR: ntfy not reachable on any internal address"
  echo "  Tried: localhost:8090, 127.0.0.1:8090, 10.0.0.1:8090"
  exit 1
fi
# Node identity. Source order:
#   1. $DTK_NODE_NAME (declared by flake — required on Android/Termux where
#      `hostname -s` returns "localhost" because sethostname() is blocked)
#   2. `hostname -s` (works on NixOS/cloud VMs that declare networking.hostName)
#   3. literal "unknown" (last resort — guarantees the script doesn't crash)
VM_NAME="${DTK_NODE_NAME:-$(hostname -s 2>/dev/null || echo unknown)}"
CMD_TOPIC="dtk-cmd-${VM_NAME}"
OUT_TOPIC="dtk-out-${VM_NAME}"

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""
command -v sudo >/dev/null 2>&1 || SUDO=""
# Verify sudo binary is actually functional (setuid bit + ownership). Use the
# same PATH that run_command uses, so we test the *same* sudo we'll actually
# invoke. On NixOS the working setuid wrapper lives in /run/wrappers/bin.
if [ -n "$SUDO" ]; then
  _SUDO_CHECK_PATH="/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin"
  _sudo_check=$(PATH="$_SUDO_CHECK_PATH" sudo -n true 2>&1) || true
  case "$_sudo_check" in
    *"must be owned"*|*"setuid"*|*"effective uid"*) SUDO="" ;;
  esac
fi

# ── Helpers ──────────────────────────────────────────────────────

ntfy_fetch() {
  # Fetch latest message from a topic (poll=true = don't wait, since=1h = last hour)
  curl -sf "${NTFY_BASE}/${1}/json?poll=1&since=5m" 2>/dev/null | tail -1
}

ntfy_post() {
  # Post message to a topic, with title
  _topic="$1"; _title="$2"; shift 2
  _body="$*"
  # ntfy has 4096 byte message limit — truncate if needed
  _len=$(printf '%s' "$_body" | wc -c)
  if [ "$_len" -gt 3800 ]; then
    _body="$(printf '%s' "$_body" | head -c 3800)
... [TRUNCATED — ${_len} bytes total]"
  fi
  curl -sf -X POST "${NTFY_BASE}/${_topic}" \
    -H "Title: ${_title}" \
    -H "Tags: dtk,${VM_NAME}" \
    -d "$_body" >/dev/null 2>&1
}

run_command() {
  _cmd="$1"
  echo "  Executing: $_cmd"
  echo "────────────────────────────────────────"
  # PATH order: setuid wrappers first (NixOS-specific, no-op elsewhere), then
  # nix paths, then standard. /run/wrappers/bin is required on NixOS — that's
  # where setuid sudo lives; /run/current-system/sw/bin/sudo is unprivileged.
  _FULL_PATH="/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin"
  if [ -n "$SUDO" ]; then
    _output=$(PATH="$_FULL_PATH" $SUDO -E sh -c "$_cmd" 2>&1) || true
  else
    _output=$(PATH="$_FULL_PATH" sh -c "$_cmd" 2>&1) || true
  fi
  echo "$_output"
  echo "────────────────────────────────────────"
  # Post output back
  ntfy_post "$OUT_TOPIC" "${VM_NAME}: command result" "$ ${_cmd}
${_output}"
  echo "  Output posted to ${OUT_TOPIC}"
}

# ── Main ─────────────────────────────────────────────────────────

MODE="${1:-once}"

echo "══════════════════════════════════════════════"
echo "  DTK Webhooks — ${VM_NAME}"
echo "══════════════════════════════════════════════"
echo "  CMD topic: ${CMD_TOPIC}"
echo "  OUT topic: ${OUT_TOPIC}"
echo "  Mode: ${MODE}"
echo ""

case "$MODE" in
  once)
    echo "  Fetching latest command..."
    MSG=$(ntfy_fetch "$CMD_TOPIC")
    if [ -z "$MSG" ]; then
      echo "  No commands in queue (last 5 min)"
      echo "  Waiting for command (60s timeout)..."
      # Wait for a message (long-poll)
      MSG=$(curl -sf "${NTFY_BASE}/${CMD_TOPIC}/json?poll=1&since=5m" 2>/dev/null | tail -1)
      [ -z "$MSG" ] && echo "  Timeout — no command received" && exit 0
    fi
    # Extract message body from JSON — jq/python3 properly decode unicode escapes (\u0026 → &)
    CMD=""
    if command -v jq >/dev/null 2>&1; then
      CMD=$(echo "$MSG" | jq -r '.message // empty' 2>/dev/null || echo "")
    elif command -v python3 >/dev/null 2>&1; then
      CMD=$(echo "$MSG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")
    fi
    # sed fallback — extract then decode JSON unicode escapes
    if [ -z "$CMD" ]; then
      CMD=$(echo "$MSG" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
      [ -n "$CMD" ] && CMD=$(printf '%s' "$CMD" | sed -e 's/\\u0026/\&/g' -e 's/\\u003c/</g' -e 's/\\u003e/>/g' -e 's/\\\\n/\n/g')
    fi
    if [ -z "$CMD" ]; then
      echo "  Could not parse command from message"
      echo "  Raw: $MSG"
      exit 1
    fi
    echo "  Command: $CMD"
    echo ""
    run_command "$CMD"
    ;;

  watch)
    echo "  Watching for commands (Ctrl+C to stop)..."
    LAST_ID=""
    while true; do
      MSG=$(ntfy_fetch "$CMD_TOPIC")
      if [ -n "$MSG" ]; then
        # Get message ID to avoid re-running
        MSG_ID=$(echo "$MSG" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
        if [ -z "$MSG_ID" ] && command -v jq >/dev/null 2>&1; then
          MSG_ID=$(echo "$MSG" | jq -r '.id // empty' 2>/dev/null || echo "")
        fi
        if [ "$MSG_ID" != "$LAST_ID" ] && [ -n "$MSG_ID" ]; then
          LAST_ID="$MSG_ID"
          CMD=""
          if command -v jq >/dev/null 2>&1; then
            CMD=$(echo "$MSG" | jq -r '.message // empty' 2>/dev/null || echo "")
          elif command -v python3 >/dev/null 2>&1; then
            CMD=$(echo "$MSG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")
          else
            CMD=$(echo "$MSG" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
            [ -n "$CMD" ] && CMD=$(printf '%s' "$CMD" | sed -e 's/\\u0026/\&/g' -e 's/\\u003c/</g' -e 's/\\u003e/>/g' -e 's/\\\\n/\n/g')
          fi
          if [ -n "$CMD" ]; then
            echo ""
            echo "  [$(date '+%H:%M:%S')] New command received"
            run_command "$CMD"
          fi
        fi
      fi
      sleep 3
    done
    ;;

  post)
    shift
    _msg="${*:-$(hostname -s) webhook ready}"
    ntfy_post "$OUT_TOPIC" "${VM_NAME}: manual" "$_msg"
    echo "  Posted to ${OUT_TOPIC}: $_msg"
    ;;

  cmd)
    shift
    _target="${1:-}"
    shift 2>/dev/null || true
    _command="$*"
    if [ -z "$_target" ] || [ -z "$_command" ]; then
      echo "Usage: webhooks.sh cmd <target-host> <command...>"
      echo "  Sends <command> to dtk-cmd-<target-host>; receiver must run 'webhooks.sh once' or 'watch'."
      exit 1
    fi
    _remote_cmd_topic="dtk-cmd-${_target}"
    ntfy_post "$_remote_cmd_topic" "${VM_NAME} -> ${_target}" "$_command"
    echo "  Posted to ${_remote_cmd_topic}: $_command"
    echo "  Receiver ('${_target}') must run: webhooks.sh once   (or be in 'watch' mode)"
    echo "  Output will appear in: dtk-out-${_target}"
    ;;

  test)
    # Round-trip self-test. Marker is computed from random inputs so it can ONLY
    # appear in the OUT topic if the command actually executed (not just if it
    # was echoed in the captured "$ <cmd>" line).
    _a=$(awk 'BEGIN{srand(); print int(rand()*100000)}')
    _b=$(awk 'BEGIN{srand()+1; print int(rand()*100000)}')
    _expected=$(( _a + _b ))
    _verify="VERIFY=${_expected}"
    _cmd="echo VERIFY=\$((${_a}+${_b}))"
    echo "  Round-trip self-test on ${VM_NAME}"
    echo "    cmd: ${_cmd}"
    echo "    expected output: ${_verify}  (NOT present in cmd literal)"
    echo "  [1/2] Posting cmd to ${CMD_TOPIC}..."
    ntfy_post "$CMD_TOPIC" "self-test" "$_cmd"
    sleep 2
    echo "  [2/2] Fetching latest from ${CMD_TOPIC} and executing..."
    MSG=$(ntfy_fetch "$CMD_TOPIC")
    if [ -z "$MSG" ]; then
      echo "  FAIL: no message in ${CMD_TOPIC} after post (ntfy reachability or retention)"
      exit 1
    fi
    CMD=""
    if command -v jq >/dev/null 2>&1; then
      CMD=$(echo "$MSG" | jq -r '.message // empty' 2>/dev/null || echo "")
    elif command -v python3 >/dev/null 2>&1; then
      CMD=$(echo "$MSG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")
    fi
    if [ -z "$CMD" ]; then
      echo "  FAIL: could not parse command from message"
      echo "  Raw: $MSG"
      exit 1
    fi
    run_command "$CMD"
    sleep 1
    _out=$(ntfy_fetch "$OUT_TOPIC")
    case "$_out" in
      *"${_verify}"*) echo ""; echo "  PASS: '${_verify}' found in ${OUT_TOPIC} — execution verified"; exit 0 ;;
      *)              echo ""; echo "  FAIL: '${_verify}' not in ${OUT_TOPIC}"; echo "  Last OUT msg: $_out"; exit 1 ;;
    esac
    ;;

  *)
    echo "Usage: webhooks.sh [once|watch|post <msg>|cmd <target-host> <cmd...>|test]"
    exit 1
    ;;
esac
