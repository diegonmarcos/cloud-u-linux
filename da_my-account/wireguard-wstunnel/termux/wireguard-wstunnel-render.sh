# wireguard-wstunnel-render.sh — renders wg0-tcp.conf from wg0.conf.
#
# Extracted from wireguard-wstunnel.nix (home.activation.installWg0TcpConf).
# Identical render rule as desktop — only the Endpoint line is rewritten.
# Termux WG is managed by the Termux:WireGuard app, so the user imports
# this file as a separate profile and toggles between wg0 and wg0-tcp.
#
# Runtime-data-driven: source/dest paths and the local UDP port are read
# from wireguard-wstunnel.json via jq at RUNTIME.
#
# This runs from home-manager activation (entryAfter "linkGeneration"), not
# as a user-facing wrapped command — fail loud on genuine errors so a
# broken render is visible, but a missing source wg0.conf is a normal,
# expected first-run state (no WG profile imported yet), not an error.
set -eu

CONFIG_JSON="${WG_TCP_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t wireguard-wstunnel-render -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

LOCAL_UDP="$(jq -r '.local_udp_port' "$CONFIG_JSON")"
WG0_CONF="$(jq -r '.wg0_conf' "$CONFIG_JSON")"
WG_TCP_CONF="$(jq -r '.wg_tcp_conf' "$CONFIG_JSON")"

mkdir -p "$(dirname "$WG_TCP_CONF")"

if [ -r "$WG0_CONF" ]; then
  awk -v port="$LOCAL_UDP" '
    BEGIN  { in_peer = 0 }
    /^\[Peer\]/ { in_peer = 1 }
    /^\[/      { if ($0 != "[Peer]") in_peer = 0 }
    in_peer && /^Endpoint[[:space:]]*=/ { print "Endpoint = 127.0.0.1:" port; next }
    { print }
  ' "$WG0_CONF" > "${WG_TCP_CONF}.tmp"
  mv "${WG_TCP_CONF}.tmp" "$WG_TCP_CONF"
  chmod 600 "$WG_TCP_CONF"
  echo "[wireguard-wstunnel] rendered $WG_TCP_CONF (Endpoint=127.0.0.1:${LOCAL_UDP})"
else
  echo "[wireguard-wstunnel] $WG0_CONF not found — skipping wg0-tcp.conf render"
fi
