#!/bin/sh
# Emergency memory cleanup — stop swap thrashing on E2 Micros
# Usage: 25-mem-emergency.sh          (clean only)
#        25-mem-emergency.sh --stop   (clean + stop containers)
set -eu

STOP_CONTAINERS=false
[ "${1:-}" = "--stop" ] && STOP_CONTAINERS=true

echo "=== MEMORY CLEANUP ==="
echo "Before:"
free -m

# 1. Drop kernel caches
echo ""
echo "[1/3] Dropping caches..."
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

# 2. Kill stuck pulls/builds (safe — these can be retried)
echo "[2/3] Killing stuck pulls/builds..."
sudo pkill -f 'docker pull' 2>/dev/null || true
sudo pkill -f 'nix-store --import' 2>/dev/null || true
sudo pkill -f 'nix-build' 2>/dev/null || true

# 3. Optionally stop containers
if [ "$STOP_CONTAINERS" = true ]; then
  echo "[3/3] Stopping all containers..."
  sudo docker stop $(sudo docker ps -q 2>/dev/null) 2>/dev/null || true
  sleep 3
else
  echo "[3/3] Containers untouched (use --stop to stop them)"
fi

echo ""
echo "After:"
free -m
