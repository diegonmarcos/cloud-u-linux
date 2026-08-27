#!/bin/sh
# Git clone module — clone/pull all repos
set -eu

REPOS="cloud:https://github.com/diegonmarcos/cloud-infra.git
cloud-data:https://github.com/diegonmarcos/cloud-data.git
unix:https://github.com/diegonmarcos/cloud-unix.git
front:https://github.com/diegonmarcos/front.git
vault:https://github.com/diegonmarcos/cloud-vault.git"

_target="${1:-$HOME/git}"
mkdir -p "$_target"
echo "=== Cloning all repos to $_target ==="
echo "$REPOS" | while read -r _line; do
  _name="${_line%%:*}"
  _url="${_line#*:}"
  if [ -d "$_target/$_name" ]; then
    echo "  $_name — exists, pulling..."
    git -C "$_target/$_name" pull --ff-only 2>&1 | head -1
  else
    echo "  $_name — cloning..."
    git clone "$_url" "$_target/$_name" 2>&1 | tail -1
  fi
done
echo "=== Done ==="
