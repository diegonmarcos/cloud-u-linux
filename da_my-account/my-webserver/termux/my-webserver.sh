# my-webserver — POSIX wrapper for the fetched SEA binary
#
# Extracted from default.nix (httpdWrapperScript). The only value the Nix
# side ever interpolated into this body was the fetched binary's store path,
# which now arrives via writeShellApplication's runtimeEnv
# (HTTPD_WEB_SERVER_BIN) instead of a baked-in ${httpdBin} string. Port and
# serve-dir were already runtime shell defaults (not Nix interpolation), so
# there is no cloud-data JSON for this script.
#
# Usage: my-webserver [start|stop|status|restart] [port] [dir]
#
# Fall-through, not fail-loud: this is an interactive/desktop-entry wrapper
# around a user-facing command. A bad subcommand prints usage and exits 1
# (matches prior behavior); start/stop/status never hard-fail so re-running
# the wrapper always leaves the user with a usable command.
set -eu

SERVER="${HTTPD_WEB_SERVER_BIN:?my-webserver: HTTPD_WEB_SERVER_BIN not set}"
PORT="${2:-8000}"
DIR="${3:-$HOME}"
PID_FILE="$HOME/.cache/my-webserver.pid"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

do_start() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "$pid"
    return 0
  fi
  mkdir -p "$(dirname "$PID_FILE")"
  chmod +x "$SERVER" 2>/dev/null || true
  "$SERVER" "$PORT" "$DIR" >/dev/null 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  echo "$pid"
}

do_stop() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    echo "stopped (was PID $pid)"
  else
    rm -f "$PID_FILE"
    echo "not running"
  fi
}

do_status() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "running (PID $pid) on http://127.0.0.1:$PORT"
  else
    rm -f "$PID_FILE"
    echo "not running"
  fi
}

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  restart) do_stop; do_start ;;
  *)       echo "Usage: my-webserver {start|stop|status|restart} [port] [dir]"; exit 1 ;;
esac
