#!/bin/sh
# Termux SSHD rescue — start openssh sshd via the nix-on-droid recipe
# from upstream issue #32: https://github.com/nix-community/nix-on-droid/issues/32
#
# - Uses $HOME/.nix-profile/bin/sshd (the profile path proot resolves correctly)
# - Generates a real sshd_config file (inline -o HostKey=... fails under proot)
# - No flake rebuild needed — only requires that openssh is already in the profile
#
# Usage on termux:
#   sh ~/git/cloud-unix/bb_flakes_termux/rescue-sshd.sh
#   curl -fsSL https://raw.githubusercontent.com/diegonmarcos/cloud-unix/main/bb_flakes_termux/rescue-sshd.sh | sh
set -eu

# Port — sourced from build.json defaults.ssh_port, fallback 8023.
# Note: 8022 is reserved/broken on some Android+nix-on-droid combos
# (kernel TIME_WAIT or app sandbox lock that doesn't show in /proc/net/tcp).
# 8023 is verified working; change build.json to override.
PORT=""
_PORT_BJ="$HOME/git/cloud-unix/bb_flakes_termux/build.json"
[ -f "$_PORT_BJ" ] && PORT=$(awk -F'[":, ]+' '/"ssh_port"/{print $3; exit}' "$_PORT_BJ" 2>/dev/null)
[ -z "$PORT" ] && PORT=8023
KEY_DIR="$HOME/.ssh"
HOST_KEY="$KEY_DIR/ssh_host_rsa_key"
SSHD_CONFIG="$KEY_DIR/sshd_config"
PID_FILE="$HOME/.cache/sshd.pid"
LOG_FILE="$HOME/.cache/sshd.log"
AUTH_KEYS="$KEY_DIR/authorized_keys"

SSHD_BIN="$HOME/.nix-profile/bin/sshd"
SSH_KEYGEN_BIN="$HOME/.nix-profile/bin/ssh-keygen"

# Bind ONLY to the WG IP — no public exposure. Source order:
#   1. build.json defaults.wg_ip (data-driven, declarative)
#   2. live wg0 interface (in case build.json missing or outdated)
LISTEN_IP=""
_BUILD_JSON="$HOME/git/cloud-unix/bb_flakes_termux/build.json"
if [ -f "$_BUILD_JSON" ]; then
  LISTEN_IP=$(awk -F'"' '/"wg_ip"/{print $4; exit}' "$_BUILD_JSON" 2>/dev/null)
fi
[ -z "$LISTEN_IP" ] && LISTEN_IP=$(ip -4 addr show wg0 2>/dev/null | awk '/inet / {sub(/\/.*/,"",$2); print $2; exit}')

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_BLU='\033[0;36m'; C_RST='\033[0m'
ok()   { printf "${C_GREEN}[OK]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YEL}[WARN]${C_RST} %s\n" "$*"; }
fail() { printf "${C_RED}[FAIL]${C_RST} %s\n" "$*"; exit 1; }
step() { printf "\n${C_BLU}>>>${C_RST} %s\n" "$*"; }

# ── 1. Preflight: ensure openssh is in the profile ────────────────────
step "1/5  Preflight"
mkdir -p "$KEY_DIR" "$(dirname "$PID_FILE")"
chmod 700 "$KEY_DIR"

if [ ! -x "$SSHD_BIN" ]; then
  warn "sshd not in profile yet, installing openssh via nix-env..."
  nix-env -iA nixpkgs.openssh 2>&1 | tail -5 || fail "nix-env install failed"
fi
[ -x "$SSHD_BIN" ]       || fail "sshd still missing at $SSHD_BIN after install"
[ -x "$SSH_KEYGEN_BIN" ] || fail "ssh-keygen missing at $SSH_KEYGEN_BIN"
ok "sshd=$SSHD_BIN"

# Bootstrap authorized_keys from repo if missing
if [ ! -s "$AUTH_KEYS" ]; then
  REPO_KEYS="$HOME/git/cloud-unix/bb_flakes_termux/src/modules/data/authorized-keys.json"
  if [ -f "$REPO_KEYS" ]; then
    awk '/"ssh-/ { gsub(/^[[:space:]]*"|",?$/, ""); print }' "$REPO_KEYS" > "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    ok "wrote authorized_keys from repo ($(wc -l < "$AUTH_KEYS") keys)"
  else
    warn "no authorized_keys and repo file missing — pubkey auth will fail"
  fi
else
  ok "authorized_keys present ($(wc -l < "$AUTH_KEYS") lines)"
fi

# ── 2. Stop any existing sshd ─────────────────────────────────────────
step "2/5  Stop existing"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
fi
pkill -f 'dropbear|sshd' 2>/dev/null || true
rm -f "$PID_FILE"
sleep 0.3
ok "cleaned"

# ── 3. Host key ───────────────────────────────────────────────────────
step "3/5  Host key"
if [ ! -f "$HOST_KEY" ]; then
  "$SSH_KEYGEN_BIN" -t rsa -b 4096 -f "$HOST_KEY" -N "" -q || fail "ssh-keygen failed"
  ok "generated $HOST_KEY"
else
  ok "$HOST_KEY exists"
fi

# ── 4. sshd_config (a REAL file, not -o flags — see issue #32) ────────
step "4/5  Write sshd_config"
# ListenAddress: bind ONLY to WG IP if known — no public exposure. If we
# couldn't determine the WG IP (script #1 scan failed), fall back to
# 127.0.0.1 only (still no public exposure) — the user can ssh via WG once
# the wg interface comes up + they restart sshd.
_listen="${LISTEN_IP:-127.0.0.1}"
cat > "$SSHD_CONFIG" <<EOF
HostKey $HOST_KEY
ListenAddress $_listen
Port $PORT
PidFile $PID_FILE
AuthorizedKeysFile $AUTH_KEYS
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
EOF
chmod 600 "$SSHD_CONFIG"
ok "wrote $SSHD_CONFIG (listen=$_listen)"

# ── 5. Start sshd ─────────────────────────────────────────────────────
step "5/5  Start sshd"
: > "$LOG_FILE"
"$SSHD_BIN" -f "$SSHD_CONFIG" >> "$LOG_FILE" 2>&1
sleep 0.5

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  ok "sshd running (PID $(cat "$PID_FILE"))"
else
  fail "sshd failed to start. Last 20 log lines:
$(tail -20 "$LOG_FILE" 2>/dev/null | sed 's/^/    /')"
fi

# ── Report ────────────────────────────────────────────────────────────
echo
LAN_IP=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2!~/^127\./ {sub(/\/.*/,"",$2); print $2; exit}')
WG_IP=$(ip -4 addr show wg0 2>/dev/null | awk '/inet / {sub(/\/.*/,"",$2); print $2}')
LISTEN=$(ss -tln 2>/dev/null | awk -v p=":$PORT" '$0 ~ p {print; exit}')

printf "${C_GREEN}════════════ SSHD UP ════════════${C_RST}\n"
[ -n "$LISTEN" ] && echo "  $LISTEN"
echo "  PID:       $(cat "$PID_FILE" 2>/dev/null)"
[ -n "$LAN_IP" ] && echo "  LAN ssh:   ssh -p $PORT nix-on-droid@$LAN_IP"
[ -n "$WG_IP" ]  && echo "  WG  ssh:   ssh -p $PORT nix-on-droid@$WG_IP"
echo "  config:    $SSHD_CONFIG"
echo "  hostkey:   $HOST_KEY"
echo "  log:       $LOG_FILE"
