#!/bin/sh
# Fix WireGuard IP assignment — assigns WG IP from cloud-data + sets MTU 1280
# Run this when SSH hangs after VM reboot (wg0 has no IP assigned)
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

# Try to read WG IP from container-init.json or cloud-data
WG_IP=""
CLOUD_DATA="/opt/scripts/container-init.json"
if [ -f "$CLOUD_DATA" ] && command -v jq >/dev/null 2>&1; then
  VM_ALIAS=$(jq -r '.vm_alias // ""' "$CLOUD_DATA")
  CLOUD_DIR=$(jq -r '.cloud_data_dir // ""' "$CLOUD_DATA")
  if [ -n "$CLOUD_DIR" ] && [ -f "$CLOUD_DIR/_cloud-data-consolidated.json" ]; then
    WG_IP=$(jq -r ".vms | to_entries[] | select(.value.ssh_alias==\"$VM_ALIAS\") | .value.wg_ip" "$CLOUD_DIR/_cloud-data-consolidated.json" 2>/dev/null || true)
  fi
fi

# Fallback: read from wg0.conf
if [ -z "$WG_IP" ]; then
  WG_IP=$($SUDO grep -oP 'Address\s*=\s*\K[0-9.]+' /etc/wireguard/wg0.conf 2>/dev/null || true)
fi

if [ -z "$WG_IP" ]; then
  echo "ERROR: Cannot determine WG IP — check container-init.json or wg0.conf"
  exit 1
fi

echo "WG IP: $WG_IP"

# Check if already assigned
CURRENT=$(ip -4 addr show wg0 2>/dev/null | grep -oP 'inet \K[0-9.]+' || true)
if [ "$CURRENT" = "$WG_IP" ]; then
  echo "Already assigned: $WG_IP on wg0"
else
  $SUDO ip addr add "${WG_IP}/24" dev wg0 2>/dev/null || echo "IP already exists (non-fatal)"
  echo "Assigned: $WG_IP/24 on wg0"
fi

# Fix MTU (1280 = safe minimum for WG)
$SUDO ip link set wg0 mtu 1280
echo "MTU: 1280"

# Verify
echo ""
ip addr show wg0 | grep -E "inet |mtu"
echo ""
echo "WG status:"
$SUDO wg show wg0 2>/dev/null | head -5 || echo "(wg not running)"
