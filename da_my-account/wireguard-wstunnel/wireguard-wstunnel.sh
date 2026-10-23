# wg-tcp — toggle WireGuard-over-TCP/443 fallback (declarative wrapper)
#
# Extracted from wireguard-wstunnel.nix (home.file.".local/bin/wg-tcp").
# Runtime-data-driven: the systemd user unit name and the WG interface name
# are read from wireguard-wstunnel.json at RUNTIME via jq, not interpolated
# by Nix into this file. Real binary paths arrive through
# writeShellApplication's runtimeEnv (SYSTEMCTL_BIN / WG_QUICK_BIN / WG_BIN),
# never as ${pkgs.foo} strings in this body.
#
# Usage: wg-tcp [up|down|status|check|help]
#
# Fail-loud: this is an operator-invoked control command (up/down/status),
# not a transparent wrapper around another user binary, so a missing or
# unreadable runtime JSON is a hard error rather than a silent fall-through.
set -eu

cmd="${1:-status}"

SYSTEMCTL="${WG_TCP_SYSTEMCTL_BIN:?wg-tcp: WG_TCP_SYSTEMCTL_BIN not set by Nix module}"
WG_QUICK="${WG_TCP_WG_QUICK_BIN:?wg-tcp: WG_TCP_WG_QUICK_BIN not set by Nix module}"
WG_SHOW="${WG_TCP_WG_BIN:?wg-tcp: WG_TCP_WG_BIN not set by Nix module}"
CONFIG_JSON="${WG_TCP_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "[wg-tcp] ERROR: $CONFIG_JSON missing or unreadable" >&2
  exit 1
fi

UNIT="$(jq -r '.service_unit' "$CONFIG_JSON")"
IFACE="$(jq -r '.wg_tcp_interface' "$CONFIG_JSON")"

case "$cmd" in
  up)
    echo "[wg-tcp] starting ${UNIT} + bringing ${IFACE} up"
    "$SYSTEMCTL" --user start "$UNIT"
    sleep 1
    sudo "$WG_QUICK" up "$IFACE" || true
    echo "[wg-tcp] tunnel via TCP/443 active"
    ;;
  down)
    echo "[wg-tcp] tearing down ${IFACE} + ${UNIT}"
    sudo "$WG_QUICK" down "$IFACE" || true
    "$SYSTEMCTL" --user stop "$UNIT"
    ;;
  status)
    echo "── ${UNIT} systemd unit:"
    "$SYSTEMCTL" --user status "$UNIT" --no-pager 2>&1 | head -10
    echo "── wg interfaces up:"
    sudo "$WG_SHOW" show interfaces 2>/dev/null || echo "(none)"
    ;;
  check)
    # The Linux "Test fallbacks" (#932): every rung of the mesh ladder probed on
    # its own, PASS / FAIL / SKIP, in the order a connect walks them. Data from
    # the runtime JSON (relay host, pinned addresses, DoH endpoints, route), so
    # nothing here names a host or an address.
    host="$(jq -r '.relay_host' "$CONFIG_JSON")"
    port="$(jq -r '.relay_port' "$CONFIG_JSON")"
    remote="$(jq -r '.relay_remote' "$CONFIG_JSON")"
    pinned="$(jq -r '.relay_pinned[]?' "$CONFIG_JSON")"
    wg_if="$(jq -r '.wg_interface' "$CONFIG_JSON")"
    secret_file="$(jq -r '.secret_file' "$CONFIG_JSON")"
    fresh_s="$(jq -r '.handshake_fresh_s' "$CONFIG_JSON")"
    pass=0; fails=0
    say() { printf '  %-5s %-14s %s\n' "$1" "$2" "$3"; if [ "$1" = PASS ]; then pass=$((pass + 1)); elif [ "$1" = FAIL ]; then fails=$((fails + 1)); fi; }
    in_pin() { printf '%s\n' "$pinned" | grep -qxF "$1"; }
    b64u() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
    bracket() { case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac; }

    echo "── mesh fallbacks for ${host}:${port} (pinned: $(printf '%s' "$pinned" | tr '\n' ' '))"

    # 1. Direct UDP: only a WireGuard handshake proves it.
    now="$(date +%s)"; newest=0
    hs="$(sudo -n "$WG_SHOW" show "$wg_if" latest-handshakes 2>/dev/null || true)"
    for t in $(printf '%s\n' "$hs" | awk '{print $2}'); do [ "$t" -gt "$newest" ] && newest="$t"; done
    if [ -z "$hs" ]; then say SKIP "Direct UDP" "$wg_if is down or sudo -n is not allowed: connect, a handshake is the only proof"
    elif [ "$newest" -gt 0 ] && [ $((now - newest)) -le "$fresh_s" ]; then say PASS "Direct UDP" "$wg_if handshake $((now - newest)) s ago"
    else say FAIL "Direct UDP" "$wg_if has no handshake within ${fresh_s} s (UDP blocked?)"; fi

    # 2. System DNS, judged against the pin (a captive portal answers with its own address).
    sys="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    best=""
    private=1
    for a in $sys; do
      if in_pin "$a"; then best="$a"; break; fi
      case "$a" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|fc*|fd*) ;; *) private=0 ;; esac
    done
    if [ -z "$sys" ]; then say FAIL "System DNS" "$host does not resolve here"
    elif [ -n "$best" ]; then say PASS "System DNS" "$host -> $sys(as pinned)"
    elif [ "$private" = 1 ] && [ -n "$hs" ]; then say PASS "System DNS" "$host -> $sys: the mesh's split-horizon answer ($wg_if is up); off the mesh it is the pin"
    else say FAIL "System DNS" "$host -> $sys, but the fleet pins $(printf '%s' "$pinned" | tr '\n' ' ')(hijacked or stale)"; fi

    # 3. Pinned IP: real TLS to each pinned address, certificate checked against the relay's name.
    for ip in $pinned; do
      r="$(curl -sS -o /dev/null --max-time 8 --connect-to "$host:$port:$(bracket "$ip"):$port" \
            -w '%{ssl_verify_result} %{http_code}' "https://$host:$port/" 2>&1 || true)"
      case "$r" in
        "0 "*) say PASS "Pinned IP" "$ip:$port answers TLS with a certificate valid for $host"; [ -n "$best" ] || best="$ip" ;;
        *) case "$ip" in
             # No IPv6 route from here is the network, not the pin: the v4 line above decides.
             *:*) say SKIP "Pinned IP" "$ip:$port: ${r%%$'\n'*} (no IPv6 path from this network?)" ;;
             *)   say FAIL "Pinned IP" "$ip:$port: ${r%%$'\n'*}" ;;
           esac ;;
      esac
    done

    # 4. DNS-over-HTTPS by IP (no DNS needed to reach it).
    for url in $(jq -r '.doh[]?' "$CONFIG_JSON"); do
      ans="$(curl -fsS --max-time 6 -H 'accept: application/dns-json' "$url?name=$host&type=A" 2>/dev/null \
             | jq -r '[.Answer[]? | select(.type == 1) | .data] | join(" ")' 2>/dev/null || true)"
      hit=""; for a in $ans; do if in_pin "$a"; then hit="$a"; fi; done
      if [ -n "$hit" ]; then say PASS "DoH" "$url: $ans"; [ -n "$best" ] || best="$hit"
      elif [ -n "$ans" ]; then say FAIL "DoH" "$url: $ans (not the pinned address)"
      else say FAIL "DoH" "$url: no answer (DoH blocked too?)"; fi
    done

    # 5. TLS-443 relay: the full WebSocket upgrade wstunnel does, with the key.
    if [ ! -r "$secret_file" ]; then say FAIL "TLS-443 relay" "$secret_file missing: sops-decrypt WSTUNNEL_PATH_PREFIX first"
    elif [ -z "$best" ]; then say FAIL "TLS-443 relay" "no usable address for $host (every rung above failed)"
    else
      hdr="$(printf '{"typ":"JWT","alg":"HS256"}' | b64u)"
      cl="$(printf '{"id":"%s","p":{"Udp":{"timeout":null}},"r":"%s","rp":%s}' \
            "$(cat /proc/sys/kernel/random/uuid)" "${remote%:*}" "${remote##*:}" | b64u)"
      sig="$(printf '%s.%s' "$hdr" "$cl" | openssl dgst -sha256 -hmac "$(head -c 16 /dev/urandom | base64)" -binary | b64u)"
      code="$(curl -sS --http1.1 -o /dev/null --max-time 8 --connect-to "$host:$port:$(bracket "$best"):$port" -w '%{http_code}' \
              -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
              -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
              -H "Sec-WebSocket-Protocol: v1, authorization.bearer.$hdr.$cl.$sig" \
              "https://$host:$port/$(cat "$secret_file")/events" 2>/dev/null || true)"
      case "$code" in
        101) say PASS "TLS-443 relay" "wss://$host via $best: upgrade 101 (the relay takes the tunnel to $remote)" ;;
        400|404) say FAIL "TLS-443 relay" "wss://$host via $best: HTTP $code - the relay key is wrong" ;;
        *) say FAIL "TLS-443 relay" "wss://$host via $best: ${code:-no answer} (TCP 443 blocked?)" ;;
      esac
    fi
    echo "── ${pass} pass, ${fails} fail. On a hostile network: wg-tcp up (the relay), then wg-tcp status."
    [ "$fails" -eq 0 ]
    ;;
  help|-h|--help)
    cat <<'HELP'
wg-tcp [up|down|status|check]
  up      start the TCP/443 relay (wstunnel-client) and bring wg0-tcp up through it
  down    the reverse
  status  the relay unit and the WireGuard interfaces
  check   probe every fallback rung: Direct UDP, system DNS vs the pinned address,
          the pinned address over TLS, DoH by IP, the relay's WebSocket upgrade

Last resort, manual - SSH tunnel (UDP rides inside TCP 22 through socat).
Needs an SSH path to a host that can reach the hub's WireGuard port; the fleet
VMs take SSH over the mesh only, so this is for a host of your own with a public
sshd (a home box), or a hub-side sshd you open on purpose:
  ssh -N -L 51900:127.0.0.1:51900 you@your-host \
      "socat TCP-LISTEN:51900,fork,reuseaddr UDP:<hub-ip>:51820" &
  socat UDP-LISTEN:51822,fork,reuseaddr TCP:127.0.0.1:51900 &
  wg set wg0 peer <hub-public-key> endpoint 127.0.0.1:51822
UDP over a TCP stream reorders nothing but stalls under loss; prefer wg-tcp up.
HELP
    ;;
  *)
    echo "Usage: wg-tcp [up|down|status|check|help]"
    exit 1
    ;;
esac
