# wg-tcp — WireGuard-over-TCP/443 fallback (Termux foreground variant)
#
# Extracted from wireguard-wstunnel.nix (home.file.".local/bin/wg-tcp").
# Fully runtime-data-driven: endpoint/port values are read from
# wireguard-wstunnel.json (${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/
# wireguard-wstunnel.json) via jq at RUNTIME. The JSON itself is generated
# by Nix (builtins.toJSON) from the same cloud build.json source of truth
# the module always used (fire-rule 4 + 6) — only the *reading* of it moved
# from Nix-eval-time interpolation into this script to runtime.
#
# WSTUNNEL binary path is supplied via $WG_TCP_WSTUNNEL_BIN, set by the Nix
# module (writeShellApplication's runtimeEnv) to the absolute store path —
# never resolved via `command -v` here.
#
# Secrets: WSTUNNEL_PATH_PREFIX is read from $HOME/.config/wireguard/
# .wstunnel-secret at run time (path comes from the JSON, contents never do).
#
# Usage: wg-tcp [up|down|status]
#   up      starts wstunnel client in the background, writes PID + log
#   down    SIGTERM the recorded PID
#   status  shows whether the PID is alive + tail of log
#
# Termux-specific: requires `termux-wake-lock` running so Android doesn't
# kill the wstunnel process when the screen sleeps. The helper warns if
# the lock is not held.
set -eu

cmd="${1:-status}"

WSTUNNEL="${WG_TCP_WSTUNNEL_BIN:?wg-tcp: WG_TCP_WSTUNNEL_BIN not set by Nix module}"
CONFIG_JSON="${WG_TCP_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "[wg-tcp] ERROR: $CONFIG_JSON missing or unreadable" >&2
  exit 1
fi

LOCAL_UDP="$(jq -r '.local_udp_port' "$CONFIG_JSON")"
REMOTE_WG="$(jq -r '.remote_wg_port' "$CONFIG_JSON")"
WS_ENDPOINT="$(jq -r '.ws_endpoint' "$CONFIG_JSON")"
PIDFILE="$(jq -r '.pid_file' "$CONFIG_JSON")"
LOGFILE="$(jq -r '.log_file' "$CONFIG_JSON")"
SECRET="$(jq -r '.secret_file' "$CONFIG_JSON")"

pid_alive() {
  [ -f "$PIDFILE" ] || return 1
  local p
  p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

case "$cmd" in
  up)
    if pid_alive; then echo "[wg-tcp] wstunnel-client already running (pid=$(cat "$PIDFILE"))"; exit 0; fi
    if [ ! -r "$SECRET" ]; then
      echo "[wg-tcp] ERROR: $SECRET not found." >&2
      echo "[wg-tcp] Put 64-char hex (sops -d <secrets.yaml>) into that file, chmod 600." >&2
      exit 1
    fi
    PATH_PREFIX="$(cat "$SECRET")"
    : >"$LOGFILE"
    "$WSTUNNEL" client \
      --local-to-remote "udp://${LOCAL_UDP}:127.0.0.1:${REMOTE_WG}" \
      --http-upgrade-path-prefix "$PATH_PREFIX" \
      "$WS_ENDPOINT" >>"$LOGFILE" 2>&1 &
    echo "$!" > "$PIDFILE"
    sleep 1
    if pid_alive; then
      echo "[wg-tcp] wstunnel-client up (pid=$(cat "$PIDFILE")) — endpoint=${WS_ENDPOINT}"
      echo "[wg-tcp] log: $LOGFILE"
    else
      echo "[wg-tcp] FAILED to start — see $LOGFILE" >&2
      tail -5 "$LOGFILE" >&2 || true
      exit 1
    fi
    # Wake-lock advisory (Android kills bg processes without it)
    if ! pgrep -f termux-wake-lock >/dev/null 2>&1; then
      echo "[wg-tcp] WARNING: termux-wake-lock not held — Android may kill wstunnel when screen sleeps."
      echo "[wg-tcp] Run: termux-wake-lock"
    fi
    ;;
  down)
    if ! pid_alive; then
      echo "[wg-tcp] not running"
      rm -f "$PIDFILE"
      exit 0
    fi
    p=$(cat "$PIDFILE")
    kill -TERM "$p" 2>/dev/null || true
    sleep 1
    if pid_alive; then kill -KILL "$p" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
    echo "[wg-tcp] wstunnel-client down"
    ;;
  status)
    if pid_alive; then
      echo "[wg-tcp] UP — pid=$(cat "$PIDFILE")"
      echo "── log tail (${LOGFILE}) ──"
      tail -5 "$LOGFILE" 2>/dev/null || echo "(no log)"
    else
      echo "[wg-tcp] DOWN"
    fi
    ;;
  *)
    echo "Usage: wg-tcp [up|down|status]"
    exit 1
    ;;
esac
