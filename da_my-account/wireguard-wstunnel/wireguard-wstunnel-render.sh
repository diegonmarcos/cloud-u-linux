# wireguard-wstunnel-render — render wg0-tcp.conf + import into NetworkManager
#
# Extracted from wireguard-wstunnel.nix (home.activation.installWg0TcpConf).
# Two-step activation:
#   1. Render ~/.config/wireguard/wg0-tcp.conf from existing wg0.conf
#      (rewrite Endpoint → 127.0.0.1:<local_udp_port>)
#   2. Import into NetworkManager so the wg0-tcp profile appears in the
#      KDE Plasma network applet alongside wg0 — idempotent (skip if a
#      connection named "wg0-tcp" already exists).
#
# `nmcli connection import` needs root; we go through `sudo -n` so the
# activation succeeds when the user has passwordless sudo for nmcli (the
# standard NixOS surface-plasma profile). If sudo prompts, the import is
# skipped with a one-line hint instead of failing activation.
#
# Runtime-data-driven: paths, the local UDP port, the WG interface/profile
# name are read from wireguard-wstunnel.json via jq at RUNTIME. Real binary
# paths arrive via writeShellApplication runtimeEnv (NMCLI_BIN), never as
# ${pkgs.foo} strings in this body.
#
# Exit-code contract: the original inline block ran inside a `( ... ) || echo`
# subshell precisely so its several `exit 0` early-returns could not abort the
# whole home-manager activation chain. As a separate executable that isolation
# is now structural — every early return here is `exit 0`, and the caller in
# the .nix keeps the same `|| echo ...` guard so a non-zero exit still lets
# the HM chain continue.
#
# Fail-loud only for a genuinely broken deploy (missing/corrupt runtime JSON);
# a missing source wg0.conf stays a normal first-run skip, exactly as before.
set -eu

NMCLI="${WG_RENDER_NMCLI_BIN:?wireguard-wstunnel-render: WG_RENDER_NMCLI_BIN not set by Nix module}"
CONFIG_JSON="${WG_TCP_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t wireguard-wstunnel-render -p user.err "$CONFIG_JSON missing or unreadable"
  echo "[wireguard-wstunnel] ERROR: $CONFIG_JSON missing or unreadable" >&2
  exit 1
fi

LOCAL_UDP="$(jq -r '.local_udp_port' "$CONFIG_JSON")"
WG0_CONF="$(jq -r '.wg0_conf' "$CONFIG_JSON")"
WG_TCP_CONF="$(jq -r '.wg_tcp_conf' "$CONFIG_JSON")"
IFACE="$(jq -r '.wg_tcp_interface' "$CONFIG_JSON")"

mkdir -p "$(dirname "$WG_TCP_CONF")"

# ── (1) Render wg0-tcp.conf ───────────────────────────────────────
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
  echo "[wireguard-wstunnel] rendered ${WG_TCP_CONF} (Endpoint=127.0.0.1:${LOCAL_UDP})"
else
  echo "[wireguard-wstunnel] $WG0_CONF not found — skipping wg0-tcp.conf render"
  exit 0
fi

# ── (2) NetworkManager import (so KDE applet sees wg0-tcp) ────────
# Skip when nmcli is unavailable (server/CI builds).
if [ ! -x "$NMCLI" ]; then
  exit 0
fi

# If a profile named "wg0-tcp" already exists, leave it alone (user
# may have edited it). Idempotent re-runs are fast no-ops.
if "$NMCLI" -t -f NAME connection show 2>/dev/null | grep -qx "$IFACE"; then
  echo "[wireguard-wstunnel] NetworkManager profile '${IFACE}' already present — skipping import"
  exit 0
fi

# Import requires root (system-connections live in /etc/NetworkManager/).
# Try passwordless sudo; if not allowed, surface a one-line hint and exit
# cleanly so home-manager activation doesn't fail.
if sudo -n "$NMCLI" connection import type wireguard file "$WG_TCP_CONF" >/dev/null 2>&1; then
  echo "[wireguard-wstunnel] imported ${IFACE} into NetworkManager — visible in KDE applet"
  sudo -n "$NMCLI" connection modify "$IFACE" connection.autoconnect no >/dev/null 2>&1 || true
else
  echo "[wireguard-wstunnel] NM import needs root — run once manually:"
  echo "    sudo nmcli connection import type wireguard file ${WG_TCP_CONF}"
  echo "    sudo nmcli connection modify ${IFACE} connection.autoconnect no"
fi
