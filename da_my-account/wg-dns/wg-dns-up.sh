# wg-dns-up — route .app queries to Hickory DNS once wg0 comes up
#
# Extracted from cloud-network-wg-dns.nix
# (systemd.user.services.wg-dns-config.Service.ExecStart). Runtime-data-driven:
# the Hickory DNS IP, the WG interface and the private-domain list are read
# from cloud-network-wg-dns.json via jq at RUNTIME rather than being
# Nix-interpolated into this body.
#
# Fall-through, not fail-loud: this is a best-effort DNS convenience layer
# on top of a working WireGuard mesh, not something the mesh itself depends
# on — every original failure path already `echo`s and falls through
# (missing wg0, resolvectl unavailable, hickory unreachable) rather than
# aborting, and this preserves that exactly (no new exit 1 introduced).
set -u

JQ="${WG_DNS_JQ_BIN:?wg-dns-up: WG_DNS_JQ_BIN not set}"
IP="${WG_DNS_IP_BIN:?wg-dns-up: WG_DNS_IP_BIN not set}"
DIG="${WG_DNS_DIG_BIN:?wg-dns-up: WG_DNS_DIG_BIN not set}"

CONFIG_JSON="${WG_DNS_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/cloud-network-wg-dns.json}"

if [ ! -r "$CONFIG_JSON" ] || ! "$JQ" -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "[wg-dns] $CONFIG_JSON missing or unreadable — skipping DNS config"
  exit 0
fi

HICKORY_DNS="$("$JQ" -r '.hickory_dns' "$CONFIG_JSON")"
WG_IFACE="$("$JQ" -r '.wg_interface' "$CONFIG_JSON")"
# Accepts a list (current shape) or a bare string (legacy). Flattened to a
# space-separated word list because `resolvectl domain <if> ...` takes each
# domain as its own argv entry and REPLACES the interface's list wholesale —
# passing all of them quoted as one word registers a single bogus domain.
WG_DOMAINS="$("$JQ" -r '.wg_domains | if type == "array" then join(" ") else . end' "$CONFIG_JSON")"

# Wait for wg0 interface to exist (max 10s)
for _ in {1..10}; do
  if "$IP" link show "$WG_IFACE" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! "$IP" link show "$WG_IFACE" >/dev/null 2>&1; then
  echo "[wg-dns] $WG_IFACE not found — skipping DNS config"
  exit 0
fi

echo "[wg-dns] Adding $HICKORY_DNS to resolv.conf for .app names"

# Method 1: systemd-resolved (if available)
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
  echo "[wg-dns] Using systemd-resolved split DNS"
  sudo resolvectl dns "$WG_IFACE" "$HICKORY_DNS"
  # Deliberate word splitting: one argv per domain.
  #
  # The rationale must NOT share the line with the directive. ShellCheck parses
  # everything after `shellcheck` as key=value pairs, so a trailing
  # "-- explanation" is read as a key `--` with no `=` and the whole file fails
  # to parse: SC1072 "Expected '=' after directive key", SC1073, SC1009. That
  # broke the derivation, and with it every home-manager CI build from
  # 2026-08-21 12:14 onward — five consecutive red runs, none of which
  # mentioned this file in the summary.
  # shellcheck disable=SC2086
  sudo resolvectl domain "$WG_IFACE" $WG_DOMAINS
  sudo resolvectl default-route "$WG_IFACE" false
else
  # Method 2: Direct resolv.conf prepend (resolvconf/NetworkManager systems)
  echo "[wg-dns] Using resolv.conf prepend (no systemd-resolved)"
  if ! grep -q "$HICKORY_DNS" /etc/resolv.conf 2>/dev/null; then
    # Prepend Hickory as first nameserver
    sudo sed -i "1s/^/nameserver $HICKORY_DNS\n/" /etc/resolv.conf
    echo "[wg-dns] Added nameserver $HICKORY_DNS to /etc/resolv.conf"
  else
    echo "[wg-dns] $HICKORY_DNS already in resolv.conf"
  fi
fi

echo "[wg-dns] Verifying: dig @$HICKORY_DNS authelia.app"
"$DIG" "@$HICKORY_DNS" +short authelia.app 2>/dev/null || echo "(hickory not reachable — wg0 may need time)"
echo "[wg-dns] Done"
