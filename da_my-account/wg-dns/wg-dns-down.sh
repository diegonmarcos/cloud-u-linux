# wg-dns-down — revert the .app -> Hickory DNS routing set up by wg-dns-up
#
# Extracted from cloud-network-wg-dns.nix
# (systemd.user.services.wg-dns-config.Service.ExecStop). Same runtime JSON
# as wg-dns-up.sh (cloud-network-wg-dns.json), read via jq at RUNTIME.
#
# Fall-through, not fail-loud: teardown-on-stop must never block the unit
# from stopping — every original line already ends in `|| true` or is
# inherently best-effort, preserved as-is.
set -u

JQ="${WG_DNS_JQ_BIN:?wg-dns-down: WG_DNS_JQ_BIN not set}"

CONFIG_JSON="${WG_DNS_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/cloud-network-wg-dns.json}"

if [ ! -r "$CONFIG_JSON" ] || ! "$JQ" -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "[wg-dns] $CONFIG_JSON missing or unreadable — skipping DNS teardown"
  exit 0
fi

HICKORY_DNS="$("$JQ" -r '.hickory_dns' "$CONFIG_JSON")"
WG_IFACE="$("$JQ" -r '.wg_interface' "$CONFIG_JSON")"

echo "[wg-dns] Removing $HICKORY_DNS from resolv.conf"
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
  sudo resolvectl revert "$WG_IFACE" 2>/dev/null || true
else
  sudo sed -i "/^nameserver $HICKORY_DNS\$/d" /etc/resolv.conf 2>/dev/null || true
fi
