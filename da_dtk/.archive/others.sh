#!/bin/sh
# Others module — submenu dispatcher for 5-help-others/*
set -eu

OTHERS_DIR="$(cd "$(dirname "$0")" && pwd)"

_sub="${1:-}"
if [ -z "$_sub" ]; then
  echo "Others:"
  echo "  1) ssh"
  echo "  2) git-clone"
  echo "  3) install"
  echo "  4) commands"
  echo "  5) info"
  echo "  6) engines"
  echo "  7) webhooks"
  printf "> "
  read -r _si
  case "$_si" in
    1) _sub="ssh" ;; 2) _sub="git-clone" ;; 3) _sub="install" ;;
    4) _sub="commands" ;; 5) _sub="info" ;; 6) _sub="engines" ;;
    7) _sub="webhooks" ;;
    b|B) exit 0 ;; *) echo "Invalid"; exit 1 ;;
  esac
fi

shift 2>/dev/null || true

case "$_sub" in
  ssh)        sh "$OTHERS_DIR/ssh/ssh.sh" "$@" ;;
  git-clone)  sh "$OTHERS_DIR/git-clone/git-clone.sh" "$@" ;;
  install)    sh "$OTHERS_DIR/install/install.sh" "$@" ;;
  commands)   sh "$OTHERS_DIR/commands/commands.sh" "$@" ;;
  info)       sh "$(dirname "$OTHERS_DIR")/1-aliases/info/info.sh" "$@" ;;
  engines)    sh "$(dirname "$OTHERS_DIR")/1-aliases/engines/engines.sh" "$@" ;;
  webhooks)   sh "$OTHERS_DIR/webhooks/webhooks.sh" "$@" ;;
  *) echo "Unknown: $_sub"; exit 1 ;;
esac
