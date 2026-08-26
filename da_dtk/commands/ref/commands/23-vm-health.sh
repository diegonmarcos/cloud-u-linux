#!/bin/sh
# Full VM health check — WG, SSH, Docker, containers, memory, systemd
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

echo "══════════════════════════════════════════════"
echo "  VM Health Check — $(hostname -s 2>/dev/null)"
echo "══════════════════════════════════════════════"

echo ""
echo "── System ──"
uptime 2>/dev/null
free -m 2>/dev/null | head -3
df -h / 2>/dev/null | tail -1

echo ""
echo "── WireGuard ──"
WG_IP=$(ip -4 addr show wg0 2>/dev/null | grep -oP 'inet \K[0-9./]+' || echo "NO IP")
WG_STATE=$($SUDO systemctl is-active wg-quick@wg0 2>/dev/null || echo "inactive")
echo "  wg0 IP: $WG_IP"
echo "  Service: $WG_STATE"
$SUDO wg show wg0 2>/dev/null | grep -E 'peer|endpoint|latest' | head -6 || true

echo ""
echo "── SSH ──"
for svc in sshd ssh; do
  STATE=$($SUDO systemctl is-active "$svc" 2>/dev/null || echo "inactive")
  [ "$STATE" != "inactive" ] && echo "  $svc: $STATE"
done
echo "  Port 22: $($SUDO ss -tlnp 2>/dev/null | grep ':22 ' | head -1 || echo 'NOT LISTENING')"
echo "  D-state: $(ps aux 2>/dev/null | awk '$8 ~ /^D/' | wc -l) processes"

echo ""
echo "── Dropbear ──"
DB_STATE=$($SUDO systemctl is-active dropbear 2>/dev/null || echo "inactive")
echo "  Service: $DB_STATE"
echo "  Port 2200: $($SUDO ss -tlnp 2>/dev/null | grep ':2200 ' | head -1 || echo 'NOT LISTENING')"

echo ""
echo "── Docker ──"
DOCKER_STATE=$($SUDO systemctl is-active docker 2>/dev/null || echo "inactive")
echo "  Service: $DOCKER_STATE"
if [ "$DOCKER_STATE" = "active" ]; then
  TOTAL=$($SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l)
  RUNNING=$($SUDO docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
  echo "  Containers: $RUNNING/$TOTAL running"
  # Show non-running
  $SUDO docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -v "Up " | while read -r line; do
    echo "    STOPPED: $line"
  done
fi

echo ""
echo "── container-init ──"
CI_STATE=$($SUDO systemctl is-active container-init 2>/dev/null || echo "inactive")
echo "  Service: $CI_STATE"
[ -f /opt/scripts/container-init.json ] && echo "  JSON: $(cat /opt/scripts/container-init.json | head -1)" || echo "  JSON: MISSING"

echo ""
echo "── Protection Drop-ins ──"
for svc in sshd ssh wg-quick@wg0 docker container-init; do
  DDIR="/etc/systemd/system/${svc}.service.d"
  [ -d "$DDIR" ] || continue
  FILES=$(ls "$DDIR"/*.conf 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')
  echo "  $svc: $FILES"
done

echo ""
echo "── Failed Units ──"
$SUDO systemctl --failed --no-pager 2>/dev/null | grep -v "^$" | head -10

echo ""
echo "── Systemd Slices (cgroup) ──"
$SUDO systemctl status connectivity.slice --no-pager 2>&1 | head -5 || echo "  connectivity.slice: not found"
$SUDO systemctl status docker.slice --no-pager 2>&1 | head -5 || echo "  docker.slice: not found"
