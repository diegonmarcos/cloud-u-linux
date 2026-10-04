#!/bin/sh
# Emergency fix-all for gcp-proxy — fixes sshd zombies, protection drop-ins, WG IP, stale sessions
# Run as root from serial console when SSH is dead
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

echo "══════════════════════════════════════════════"
echo "  FIX-ALL: $(hostname -s 2>/dev/null)"
echo "══════════════════════════════════════════════"

# ── Phase 1: Kill stale SSH sessions ──────────────────────────────
echo ""
echo "── Phase 1: Kill stale SSH sessions ──"
# Find docker/buildx/compose processes hanging under sshd
STALE_PIDS=$($SUDO pstree -p 2>/dev/null | grep -oP 'sshd-session\(\K[0-9]+' || true)
DOCKER_PIDS=$($SUDO pstree -p 2>/dev/null | grep -oP '(?:docker|buildx|compose)\(\K[0-9]+' || true)
if [ -n "$DOCKER_PIDS" ]; then
  echo "  Killing stale docker processes under sshd: $DOCKER_PIDS"
  echo "$DOCKER_PIDS" | xargs $SUDO kill -9 2>/dev/null || true
  sleep 2
fi
# Kill CLOSE-WAIT sshd sessions
CLOSE_WAIT=$($SUDO ss -tnp 2>/dev/null | grep ":22 " | grep "CLOSE-WAIT" | grep -oP 'pid=\K[0-9]+' | sort -u || true)
if [ -n "$CLOSE_WAIT" ]; then
  echo "  Killing CLOSE-WAIT sshd sessions: $CLOSE_WAIT"
  echo "$CLOSE_WAIT" | xargs $SUDO kill -9 2>/dev/null || true
fi
echo "  Done"

# ── Phase 2: Fix protection drop-ins ─────────────────────────────
echo ""
echo "── Phase 2: Fix protection drop-ins (MemoryMin + OOMScoreAdjust) ──"
for svc in sshd ssh; do
  DDIR="/etc/systemd/system/${svc}.service.d"
  [ -d "$DDIR" ] || continue
  for f in "$DDIR"/protection.conf "$DDIR"/scheduler.conf; do
    [ -f "$f" ] || continue
    echo "  Fixing $(basename "$f") for $svc..."
    # Fix MemoryMin: 50M → 10M, 30M → 10M
    $SUDO sed -i 's/MemoryMin=50M/MemoryMin=10M/g; s/MemoryMin=30M/MemoryMin=10M/g' "$f"
    # Fix MemoryLow: 80M → 20M, 50M → 20M
    $SUDO sed -i 's/MemoryLow=80M/MemoryLow=20M/g; s/MemoryLow=50M/MemoryLow=20M/g' "$f"
    # Fix OOMScoreAdjust: -1000 → -900
    $SUDO sed -i 's/OOMScoreAdjust=-1000/OOMScoreAdjust=-900/g' "$f"
    echo "  Fixed: $(grep -E 'Memory|OOM' "$f" 2>/dev/null | tr '\n' ' ')"
  done
done
# Same for WG
for svc in wg-quick@wg0; do
  DDIR="/etc/systemd/system/${svc}.service.d"
  [ -d "$DDIR" ] || continue
  for f in "$DDIR"/*.conf; do
    [ -f "$f" ] || continue
    $SUDO sed -i 's/MemoryMin=50M/MemoryMin=10M/g; s/MemoryMin=30M/MemoryMin=10M/g' "$f"
    $SUDO sed -i 's/MemoryLow=80M/MemoryLow=20M/g; s/MemoryLow=50M/MemoryLow=20M/g' "$f"
    $SUDO sed -i 's/OOMScoreAdjust=-1000/OOMScoreAdjust=-900/g' "$f"
    echo "  WG $(basename "$f"): $(grep -E 'Memory|OOM' "$f" 2>/dev/null | tr '\n' ' ')"
  done
done
$SUDO systemctl daemon-reload
echo "  systemd reloaded"

# ── Phase 2b: Remove ALL docker wrappers ─────────────────────────
echo ""
echo "── Phase 2b: Remove docker wrappers ──"
for _w in /usr/local/bin/docker /usr/local/bin/docker-real /usr/local/bin/docker-capped /usr/local/bin/docker-compose-capped /usr/local/bin/docker-buildx-capped; do
  [ -f "$_w" ] && $SUDO rm -f "$_w" && echo "  Removed: $_w"
done
# Remove stale FIFO/RR/protection drop-ins
for svc_dir in /etc/systemd/system/*.service.d; do
  [ -d "$svc_dir" ] || continue
  for stale in "$svc_dir/protection.conf" "$svc_dir/bouncer.conf" "$svc_dir/slice-assignment.conf" "$svc_dir/cpu-cap.conf" "$svc_dir/memory-cap.conf"; do
    [ -f "$stale" ] && $SUDO rm -f "$stale" && echo "  Removed: $stale"
  done
done
# Remove stale container-init.service
[ -f /etc/systemd/system/container-init.service ] && $SUDO rm -f /etc/systemd/system/container-init.service && echo "  Removed: container-init.service"
# Clear shell hash table
hash -r 2>/dev/null || true
echo "  Done"

# ── Phase 3: Fix WG IP ───────────────────────────────────────────
echo ""
echo "── Phase 3: Fix WireGuard IP ──"
WG_IP=""
# Read from wg0.conf Address line
WG_IP=$($SUDO grep -oP 'Address\s*=\s*\K[0-9.]+' /etc/wireguard/wg0.conf 2>/dev/null || true)
if [ -z "$WG_IP" ]; then
  # Read from cloud-data
  for DIR in /opt/cloud-data /home/*/git/cloud-data; do
    [ -f "$DIR/_cloud-data-consolidated.json" ] || continue
    if command -v jq >/dev/null 2>&1; then
      VM_ALIAS=$(hostname -s 2>/dev/null || echo "")
      # Try direct hostname match, then alias match
      WG_IP=$(jq -r ".vms | to_entries[] | select(.value.ssh_alias==\"$VM_ALIAS\" or .key==\"$VM_ALIAS\") | .value.wg_ip" "$DIR/_cloud-data-consolidated.json" 2>/dev/null || true)
      [ -n "$WG_IP" ] && break
    fi
  done
fi
# Hardcoded fallback for known VMs
if [ -z "$WG_IP" ]; then
  case "$(hostname -s 2>/dev/null)" in
    *proxy*|arch-1) WG_IP="10.0.0.1" ;;
    *mail*|web-server) WG_IP="10.0.0.3" ;;
    *analytics*) WG_IP="10.0.0.4" ;;
    *apps*) WG_IP="10.0.0.6" ;;
  esac
fi
if [ -z "$WG_IP" ]; then
  echo "  ERROR: Cannot determine WG IP"
else
  CURRENT=$(ip -4 addr show wg0 2>/dev/null | grep -oP 'inet \K[0-9.]+' || true)
  if [ "$CURRENT" = "$WG_IP" ]; then
    echo "  WG IP already assigned: $WG_IP"
  else
    # Add Address to wg0.conf if missing
    if ! $SUDO grep -q "^Address" /etc/wireguard/wg0.conf 2>/dev/null; then
      echo "  Adding Address = ${WG_IP}/24 to wg0.conf"
      $SUDO sed -i "1a Address = ${WG_IP}/24" /etc/wireguard/wg0.conf
    fi
    # Restart WG to pick up Address
    $SUDO systemctl restart wg-quick@wg0 2>/dev/null || {
      # Manual fallback
      $SUDO ip addr add "${WG_IP}/24" dev wg0 2>/dev/null || true
      $SUDO ip link set wg0 mtu 1280 2>/dev/null || true
    }
    echo "  WG IP assigned: $WG_IP"
  fi
fi
# Fix MTU
$SUDO ip link set wg0 mtu 1280 2>/dev/null || true

# ── Phase 4: Restart sshd ────────────────────────────────────────
echo ""
echo "── Phase 4: Restart sshd ──"
$SUDO systemctl reset-failed sshd 2>/dev/null || true
$SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || true
echo "  sshd restarted"

# ── Phase 5: Fix Dropbear bind address ────────────────────────────
echo ""
echo "── Phase 5: Fix Dropbear ──"
# Check if dropbear exists
if command -v dropbear >/dev/null 2>&1; then
  # Check if listening on 0.0.0.0
  DB_LISTEN=$($SUDO ss -tlnp 2>/dev/null | grep dropbear | grep -oP '[\d.]+:' | head -1 || true)
  if echo "$DB_LISTEN" | grep -q "127.0.0.1"; then
    echo "  Dropbear bound to localhost only — need to fix in HM source"
    echo "  (Declarative fix needed: watchdog-petter-dropbear module)"
  else
    echo "  Dropbear OK: $DB_LISTEN"
  fi
else
  echo "  Dropbear not installed"
fi

# ── Phase 6: Start Docker + all containers ──────────────────────
echo ""
echo "── Phase 6: Start Docker + containers ──"
if ! $SUDO docker info >/dev/null 2>&1; then
  echo "  Starting Docker daemon..."
  $SUDO systemctl start docker 2>/dev/null || true
  sleep 5
  if $SUDO docker info >/dev/null 2>&1; then
    echo "  Docker started"
  else
    echo "  ERROR: Docker failed to start"
  fi
else
  echo "  Docker already running"
fi
# Start all existing containers (lightweight docker start, no compose Go binary)
STOPPED=$($SUDO docker ps -aq --filter "status=exited" --filter "status=created" 2>/dev/null || true)
if [ -n "$STOPPED" ]; then
  echo "  Starting $(echo "$STOPPED" | wc -l) stopped containers..."
  echo "$STOPPED" | xargs $SUDO docker start 2>/dev/null || true
  sleep 3
fi
RUNNING=$($SUDO docker ps --format '{{.Names}}' 2>/dev/null | wc -l || echo 0)
TOTAL=$($SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l || echo 0)
echo "  Containers: $RUNNING/$TOTAL running"

# ── Phase 7: Verify ──────────────────────────────────────────────
echo ""
echo "── Phase 6: Verify ──"
echo "  WG:"
ip -4 addr show wg0 2>/dev/null | grep -E "inet|mtu" || echo "    NO WG IP!"
echo "  SSH:"
$SUDO ss -tlnp 2>/dev/null | grep -E ":22 |:2200 " || echo "    NOT LISTENING!"
echo "  sshd PIDs: $(pgrep -x sshd 2>/dev/null | wc -l)"
echo "  D-state: $(ps aux 2>/dev/null | awk '$8 ~ /^D/' | wc -l) processes"
echo "  Protection:"
grep -E 'Memory|OOM' /etc/systemd/system/sshd.service.d/*.conf 2>/dev/null | head -5
echo "  Memory:"
free -m 2>/dev/null | head -2
echo ""
echo "── Phase 7: Verify ──"
