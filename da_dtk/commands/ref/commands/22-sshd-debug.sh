#!/bin/sh
# SSH full diagnostic — D-state detection, drop-ins, connections, zombie check
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

echo "══════════════════════════════════════════════"
echo "  SSHD Debug"
echo "══════════════════════════════════════════════"

# Detect sshd service name
SSHD_SVC=""
for svc in sshd ssh; do
  if $SUDO systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc.service"; then
    SSHD_SVC="$svc"; break
  fi
done

echo ""
echo "── Service: ${SSHD_SVC:-NOT FOUND} ──"
[ -n "$SSHD_SVC" ] && $SUDO systemctl status "$SSHD_SVC" --no-pager 2>&1 | head -20

echo ""
echo "── D-State Processes (unkillable zombies) ──"
ps aux 2>/dev/null | awk '$8 ~ /^D/ {print}' | head -10 || echo "  (none)"

echo ""
echo "── SSHD Process Tree ──"
pstree -p $(pgrep -x sshd 2>/dev/null | head -1) 2>/dev/null || echo "  (no sshd running)"

echo ""
echo "── Active SSH Connections ──"
$SUDO ss -tnp 2>/dev/null | grep ":22 " || echo "  (none)"

echo ""
echo "── Listening Ports (SSH/Dropbear) ──"
$SUDO ss -tlnp 2>/dev/null | grep -E ":22 |:2200 " || echo "  (none!)"

echo ""
echo "── Drop-ins ──"
for svc in sshd ssh; do
  DDIR="/etc/systemd/system/${svc}.service.d"
  [ -d "$DDIR" ] || continue
  echo "  $DDIR/:"
  for f in "$DDIR"/*.conf; do
    [ -f "$f" ] || continue
    echo "    --- $(basename "$f") ---"
    cat "$f" | sed 's/^/    /'
  done
done

echo ""
echo "── Dropbear Status ──"
$SUDO systemctl status dropbear --no-pager 2>&1 | head -10 || echo "  (not installed)"

echo ""
echo "── Journal (last 20 lines) ──"
[ -n "$SSHD_SVC" ] && $SUDO journalctl -u "$SSHD_SVC" --no-pager -n 20 2>/dev/null

echo ""
echo "── Memory Pressure ──"
free -m 2>/dev/null | head -3
echo "  Swap:"
swapon --show 2>/dev/null || echo "  (no swap)"
