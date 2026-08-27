#!/bin/sh
# WireGuard full diagnostic — status, IP, peers, journal, boot service
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

echo "══════════════════════════════════════════════"
echo "  WireGuard Debug"
echo "══════════════════════════════════════════════"

echo ""
echo "── Interface ──"
ip addr show wg0 2>/dev/null || echo "  wg0 interface DOES NOT EXIST"

echo ""
echo "── WG Show ──"
$SUDO wg show wg0 2>/dev/null || echo "  wg not running"

echo ""
echo "── Service Status ──"
$SUDO systemctl status wg-quick@wg0 --no-pager 2>&1 | head -20

echo ""
echo "── Drop-ins ──"
ls /etc/systemd/system/wg-quick@wg0.service.d/ 2>/dev/null || echo "  (none)"
for f in /etc/systemd/system/wg-quick@wg0.service.d/*.conf; do
  [ -f "$f" ] && echo "  --- $(basename "$f") ---" && cat "$f"
done 2>/dev/null

echo ""
echo "── Boot Journal (wg-quick) ──"
$SUDO journalctl -u wg-quick@wg0 --no-pager -n 30 2>/dev/null || echo "  (no journal)"

echo ""
echo "── wg0.conf (redacted) ──"
$SUDO grep -E 'Address|MTU|ListenPort|Endpoint|AllowedIPs|DNS' /etc/wireguard/wg0.conf 2>/dev/null || echo "  (no config)"

echo ""
echo "── Ping Hub (10.0.0.1) ──"
ping -c 2 -W 2 10.0.0.1 2>/dev/null && echo "  Hub reachable" || echo "  Hub UNREACHABLE"

echo ""
echo "── wg-quick binary ──"
command -v wg-quick 2>/dev/null || echo "  NOT IN PATH"
command -v wg 2>/dev/null || echo "  wg NOT IN PATH"
ls -la /nix/var/nix/profiles/default/bin/wg* 2>/dev/null || true
ls -la /usr/bin/wg* 2>/dev/null || true
