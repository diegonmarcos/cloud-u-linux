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

usage() {
  cat <<EOF
my-webserver — local file server (Markdown, JSON/YAML tables, Eruda DevTools)

USAGE
  my-webserver [COMMAND] [PORT] [DIR]

COMMANDS
  start           start if not already running; prints the PID   (default)
  stop            kill the running instance and clear the PID file
  status          report running state, PID, and URL
  restart         stop then start
  -h, --help      show this help

ARGUMENTS
  PORT            TCP port to bind          (default: 8000)
  DIR             directory to serve as /   (default: \$HOME)

  Both are positional and only read when a COMMAND is given first:
    my-webserver start 8001 ~/git

BINDING
  Listens on 127.0.0.1 only — not reachable from the network. Putting a
  reverse proxy in front of it publishes DIR to whoever can reach the proxy.

ROUTES
  /<path>              file, or <path>/index.html, else an SPA directory browse
  /__api__/ls?path=..  directory listing as JSON

  There is no route table: URL paths map straight onto the filesystem under
  DIR, so a directory or symlink IS the alias.
    ln -s ~/git/cloud-u-linux/da_watchdog/reports ~/watchdog   ->  :8000/watchdog/

WRITE API
  /__api__/write and /__api__/git are disabled here and fail closed. They are
  used on termux. Enabling needs all three of HTTPD_WRITE=1,
  HTTPD_WRITE_ROOTS, and HTTPD_WRITE_TOKEN_FILE — see bb_flakes_termux.

FILES
  \$HOME/.cache/my-webserver.pid   PID of the instance this wrapper started

ENVIRONMENT
  HTTPD_WEB_SERVER_BIN   path to the SEA binary (set by Nix; required)

NOTES
  A systemd user service already runs \`my-webserver 8000 \$HOME\` at login,
  so DIR defaults to serving your whole home directory — dotfiles included.
  Serve a narrower DIR for anything you would not want read.
EOF
}

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
  start)      do_start ;;
  stop)       do_stop ;;
  status)     do_status ;;
  restart)    do_stop; do_start ;;
  -h|--help)  usage ;;
  *)          usage >&2; exit 1 ;;
esac
