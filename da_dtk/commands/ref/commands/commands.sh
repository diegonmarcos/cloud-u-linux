#!/bin/sh
# Commands module — run quick system commands by filename prefix index
set -eu

CMDS_DIR="$(cd "$(dirname "$0")" && pwd)"

_idx="${1:-}"
if [ -z "$_idx" ]; then
  echo "Commands (runs locally on this machine):"
  for _f in "$CMDS_DIR"/[0-9]*.sh; do
    [ "$(basename "$_f")" = "commands.sh" ] && continue
    _prefix=$(basename "$_f" .sh | grep -oP '^\d+')
    _name=$(basename "$_f" .sh | sed 's/^[0-9]*-//')
    printf "  %2s) %s\n" "$_prefix" "$_name"
  done
  printf "> "
  read -r _idx
fi
[ -z "$_idx" ] && exit 0

# Find the script by filename prefix (00, 01, 02, ...)
_padded=$(printf '%02d' "$_idx" 2>/dev/null || echo "$_idx")
_script=$(ls "$CMDS_DIR"/${_padded}-*.sh 2>/dev/null | head -1)
if [ -n "$_script" ] && [ -f "$_script" ]; then
  sh "$_script"
else
  echo "Invalid command: $_idx"
fi
