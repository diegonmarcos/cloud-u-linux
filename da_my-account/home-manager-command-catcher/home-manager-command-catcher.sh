# home-manager-command-catcher.sh — generated from home-manager-command-catcher.nix, do not edit by hand.
#
# Fully runtime-data-driven: the heavy-verb allowlist is read from
# home-manager-command-catcher.json via jq at RUNTIME. Nothing is baked in
# by Nix interpolation. See home-manager-command-catcher.nix for how this
# script is wired (writeShellApplication + xdg.configFile deploy of the
# JSON) and home-manager-command-catcher.json for the verb list + rationale.
#
# REAL is supplied via $HM_REAL, an environment variable set by the Nix
# module (writeShellApplication's runtimeEnv) to the absolute store path of
# the real home-manager binary. It must never be resolved with `command -v`
# or a bare PATH lookup here: this wrapper shadows `home-manager` on PATH
# via lib.hiPrio, so a PATH lookup from inside the wrapper would recurse
# into itself instead of reaching the real binary.
set -u

REAL="${HM_REAL:?home-manager-command-catcher.sh: HM_REAL not set by Nix module}"

# Recursion guard: once inside a catcher-spawned invocation go straight
# to the real binary. Note this is also what nix-switch-progress-wrap
# sets for everything it spawns, so a home-manager run started BY the
# wrap window never re-enters here.
if [ -n "${NSP_ACTIVE:-}" ]; then
  exec "$REAL" "$@"
fi

CONFIG_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/home-manager-command-catcher.json"

# If the config is missing or unparseable, this wrapper must never break
# `home-manager` — fall through to the real binary bare rather than exiting
# non-zero.
HEAVY_VERBS=()
if [ -r "$CONFIG_JSON" ] && jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  while IFS= read -r v; do
    HEAVY_VERBS+=("$v")
  done < <(jq -r '.heavy_home_manager_verbs[]' "$CONFIG_JSON" 2>/dev/null)
else
  exec "$REAL" "$@"
fi

# First non-flag argument is the verb we gate on.
verb=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    *) verb="$arg"; break ;;
  esac
done

is_heavy=0
for v in "${HEAVY_VERBS[@]:-}"; do
  if [ "$verb" = "$v" ]; then
    is_heavy=1
    break
  fi
done

if [ "$is_heavy" -ne 1 ]; then
  exec "$REAL" "$@"
fi

# NSP_ACTIVE must stay UNSET across this exec. nix-switch-progress-wrap
# keys its whole mode off it: unset means "owner mode", open the
# progress window and drive it; already set means "nested mode", assume
# an outer wrap owns a window and just run bare. Exporting it here would
# make the wrap open nothing — the exact bug fixed in the system catcher
# (c0e7ab93). Recursion is impossible on this path anyway because we
# hand the wrap "$REAL", an absolute store path, never a PATH lookup.
if command -v nix-switch-progress-wrap >/dev/null 2>&1 \
  && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  exec nix-switch-progress-wrap "$REAL" "$@"
fi

# Headless or wrap not installed: no window, never block — same
# invariant as the system catcher, so CI and SSH sessions are unaffected.
# The guard IS needed here; nothing downstream sets it.
export NSP_ACTIVE=1
exec "$REAL" "$@"
