#!/bin/sh
# Kill stuck docker/docker-compose processes (E2 Micro emergency)
# When docker-compose hangs on 1GB VMs, it eats 100% CPU on all cores,
# starving sshd and making the VM unreachable via SSH.
set -eu

echo "=== KILL STUCK DOCKER-COMPOSE ==="
echo "Before:"
ps aux | grep -E 'docker-compose|docker compose' | grep -v grep || echo "  (none running)"
echo ""

# 1. Graceful kill
echo "[1/3] Sending TERM to docker-compose..."
sudo pkill -f 'docker-compose' 2>/dev/null || true
sudo pkill -f 'docker compose' 2>/dev/null || true
sleep 2

# 2. Check if still alive, force kill
ALIVE=$(pgrep -f 'docker-compose|docker compose' 2>/dev/null || true)
if [ -n "$ALIVE" ]; then
  echo "[2/3] Still alive — sending KILL..."
  sudo pkill -9 -f 'docker-compose' 2>/dev/null || true
  sudo pkill -9 -f 'docker compose' 2>/dev/null || true
  sleep 1
else
  echo "[2/3] Processes terminated gracefully"
fi

# 3. Also kill orphaned docker CLI processes (stuck pulls, builds)
echo "[3/3] Killing orphaned docker CLI processes..."
sudo pkill -f 'docker pull' 2>/dev/null || true
sudo pkill -f 'docker build' 2>/dev/null || true

echo ""
echo "After:"
ps aux | grep -E 'docker-compose|docker compose' | grep -v grep || echo "  (none running)"
echo ""
free -m
echo ""
echo "SSH should recover within seconds."
