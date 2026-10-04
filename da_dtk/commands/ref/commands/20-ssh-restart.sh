#!/bin/sh
# Full SSH debug + fix — diagnoses and repairs SSH on any VM
# Handles: zombie sshd, MemoryMin deadlocks, filled MaxStartups, firewall blocks
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

echo "══════════════════════════════════════════════"
echo "  SSH Debug + Fix"
echo "══════════════════════════════════════════════"

# ── Phase 1: Diagnose ──────────────────────────────────────────
echo ""
echo "── Phase 1: Diagnose ──"

# Check sshd status
SSHD_SVC=""
for svc in sshd ssh; do
  if $SUDO systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc.service"; then
    SSHD_SVC="$svc"
    break
  fi
done
echo "  SSH service: ${SSHD_SVC:-NOT FOUND}"

if [ -n "$SSHD_SVC" ]; then
  STATE=$($SUDO systemctl show "$SSHD_SVC" --property=ActiveState --value 2>/dev/null || echo "unknown")
  RESULT=$($SUDO systemctl show "$SSHD_SVC" --property=Result --value 2>/dev/null || echo "unknown")
  echo "  State: $STATE (result: $RESULT)"
fi

# Check for zombie/unkillable sshd processes
SSHD_PIDS=$(pgrep -x sshd 2>/dev/null || true)
SSHD_COUNT=$(echo "$SSHD_PIDS" | grep -c . 2>/dev/null || echo 0)
echo "  sshd PIDs: $SSHD_COUNT processes"

# Check port 22
PORT22=$($SUDO ss -tlnp 2>/dev/null | grep ":22 " || echo "")
echo "  Port 22: ${PORT22:-NOT LISTENING}"

# Check Dropbear
PORT2200=$($SUDO ss -tlnp 2>/dev/null | grep ":2200 " || echo "")
echo "  Port 2200: ${PORT2200:-NOT LISTENING}"

# Check protection drop-ins
DROPIN_DIR="/etc/systemd/system/${SSHD_SVC}.service.d"
if [ -d "$DROPIN_DIR" ]; then
  echo "  Drop-ins: $(ls "$DROPIN_DIR" 2>/dev/null | tr '\n' ' ')"
  for f in "$DROPIN_DIR"/*.conf; do
    [ -f "$f" ] && echo "    $(basename "$f"): $(grep -E 'Memory|CPU|OOM' "$f" 2>/dev/null | tr '\n' ' ')"
  done
fi

# Check iptables for SSH
echo "  Firewall SSH rules:"
$SUDO iptables -L INPUT -n 2>/dev/null | grep -E "dpt:22|ACCEPT.*0.0.0.0/0.*0.0.0.0/0" | head -3 | while read -r line; do echo "    $line"; done
POLICY=$($SUDO iptables -L INPUT 2>/dev/null | head -1 | grep -oP '\(policy \K\w+' || echo "unknown")
echo "  INPUT policy: $POLICY"

# ── Phase 2: Fix ──────────────────────────────────────────────
echo ""
echo "── Phase 2: Fix ──"

# Kill ALL sshd processes (including zombies)
if [ -n "$SSHD_PIDS" ]; then
  echo "  Killing $SSHD_COUNT sshd processes..."
  echo "$SSHD_PIDS" | xargs $SUDO kill -9 2>/dev/null || true
  sleep 2
  # Check if they died
  REMAINING=$(pgrep -x sshd 2>/dev/null | wc -l || echo 0)
  if [ "$REMAINING" -gt 0 ]; then
    echo "  WARNING: $REMAINING processes survived SIGKILL (D-state zombie)"
    echo "  Removing protection drop-in + rebooting (only way to clear D-state)..."
    # Remove the protection.conf that causes MemoryMin deadlock
    for svc in sshd ssh; do
      DDIR="/etc/systemd/system/${svc}.service.d"
      [ -f "$DDIR/protection.conf" ] && $SUDO rm -f "$DDIR/protection.conf" && echo "  Removed $DDIR/protection.conf"
    done
    $SUDO systemctl daemon-reload
    echo "  Rebooting in 3 seconds..."
    sleep 3
    $SUDO reboot
    exit 0
  else
    echo "  All sshd processes killed"
  fi
fi

# Remove protection drop-in temporarily if it has MemoryMin (causes unkillable state)
if [ -f "$DROPIN_DIR/protection.conf" ] && grep -q "MemoryMin" "$DROPIN_DIR/protection.conf" 2>/dev/null; then
  echo "  Disabling MemoryMin protection (causes zombie sshd on low-RAM VMs)..."
  $SUDO sed -i 's/^MemoryMin=/#MemoryMin=/' "$DROPIN_DIR/protection.conf" 2>/dev/null || true
  $SUDO systemctl daemon-reload
fi

# Flush iptables
echo "  Flushing iptables..."
$SUDO iptables -F INPUT 2>/dev/null || true
$SUDO iptables -P INPUT ACCEPT 2>/dev/null || true

# Reset + start SSH
if [ -n "$SSHD_SVC" ]; then
  $SUDO systemctl reset-failed "$SSHD_SVC" 2>/dev/null || true
  echo "  Starting $SSHD_SVC..."
  if $SUDO systemctl start "$SSHD_SVC" 2>/dev/null; then
    echo "  $SSHD_SVC started"
  else
    echo "  ERROR: $SSHD_SVC failed to start"
    $SUDO journalctl -u "$SSHD_SVC" --since "30 sec ago" --no-pager 2>/dev/null | tail -5
  fi
fi

# Restart Dropbear
$SUDO systemctl restart dropbear 2>/dev/null && echo "  Dropbear restarted" || echo "  Dropbear not installed (skip)"

# ── Phase 3: Verify ──────────────────────────────────────────
echo ""
echo "── Phase 3: Verify ──"
echo "  Listening:"
$SUDO ss -tlnp 2>/dev/null | grep -E ":22 |:2200 " || echo "  (none!)"
echo "  sshd PIDs: $(pgrep -x sshd 2>/dev/null | wc -l || echo 0)"
echo ""

# Test
if $SUDO ss -tlnp 2>/dev/null | grep -q ":22 "; then
  echo "  ✓ SSH is listening on port 22"
else
  echo "  ✗ SSH is NOT listening — reboot may be required"
fi
