#!/usr/bin/env bash
# flakes-switch-progress-logs.sh
#
# Extracted from programs/flakes-switch-progress-logs/default.nix
# (wrapperScript). Installed under BOTH `flakes-switch-progress-logs` and
# the compat alias `nix-switch-progress-wrap` — identical text, so the two
# entry points can never drift out of sync with each other.
#
# Runtime-data-driven: title/icon/notify_on_finish/cap_pct_until_done/
# psi_refresh_seconds/spinner_frames/konsole_geometry/colors are read from
# flakes-switch-progress-logs.json at RUNTIME via jq, not interpolated by
# Nix into this file. The progress.mjs helper's store path arrives via
# writeShellApplication's runtimeEnv (NSP_MJS_BIN), never as a ${pkgs.foo}
# / ${mjs} string in this body. node itself comes in via runtimeInputs.
#
# Generated from programs/flakes-switch-progress-logs/default.nix — do
# not edit by hand.
set -uo pipefail

# ── Nested mode: NSP_ACTIVE was already set when we started, so an
#    outer flakes-switch-progress-logs invocation already owns the ONE
#    window (build.sh's own global re-exec at the bottom of build.sh,
#    or a bare direct invocation reached through the cross-repo
#    nix-command-catcher shim). We are one of that outer command's own
#    internal nix/home-manager calls (nix_switch()'s wrap, the pull
#    path's wrap, or a nested `nix`/`nixos-rebuild` call reached
#    through the catcher shim) — open NOTHING (no window, no header, no
#    PSI loop, no final banner, no notify-send). Just feed the SAME
#    status file the owner is already tailing, so byte-level nix build
#    bars still show up — inside the one already-open window instead of
#    opening a second one.
NSP_MJS="${NSP_MJS_BIN:?flakes-switch-progress-logs.sh: NSP_MJS_BIN not set by Nix module}"

if [ -n "${NSP_ACTIVE:-}" ]; then
  case "$1" in
    nix|home-manager) set -- "$@" --log-format internal-json ;;
  esac
  if [ -n "${NSP_STATUS_FILE:-}" ] && [ -w "${NSP_STATUS_FILE}" ]; then
    set -o pipefail
    "$@" 2>&1 | node "$NSP_MJS" | tee -a "$NSP_STATUS_FILE" >/dev/null
    exit "${PIPESTATUS[0]}"
  fi
  exec "$@"
fi

# ── Owner mode (NSP_ACTIVE unset on entry — the outermost invocation):
#    exactly the original single-window behaviour below. ─────────────

# Composability with the global nix/nixos-rebuild PATH shim
# (aa_desk-usr configuration_nix-command-catcher.nix, 2026-07-26): that
# shim shadows `nix`/`nixos-rebuild` and routes heavy verbs through THIS
# wrapper. Mark this whole process tree as already inside the catcher so
# any inner `nix`/`nixos-rebuild` call — the shim's own recursive call,
# or build.sh's own nix_switch()/pull re-wrap — takes the nested-mode
# branch above instead of opening a SECOND progress window / recursing.
export NSP_ACTIVE=1

# Passthrough (no popup/window) when there's no graphical session or
# konsole is missing — must never block a headless/CI/SSH nix
# invocation. This runs before any state is created, so owner mode
# costs nothing extra over a bare `exec "$@"` on SSH/CI/headless.
if { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; } || ! command -v konsole >/dev/null 2>&1; then
  exec "$@"
fi

# Config problem of any kind (missing/unreadable/unparseable JSON) must
# never block a switch — fall through to a bare exec exactly like the
# no-display/no-konsole passthrough above, before any state is created.
CONFIG_JSON="${NSP_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/flakes-switch-progress-logs.json}"
if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  exec "$@"
fi

TITLE="$(jq -r '.title' "$CONFIG_JSON")"
ICON="$(jq -r '.icon' "$CONFIG_JSON")"
NOTIFY_ON_FINISH="$(jq -r '.notify_on_finish' "$CONFIG_JSON")"
CAP_PCT="$(jq -r '.cap_pct_until_done' "$CONFIG_JSON")"
PSI_REFRESH="$(jq -r '.psi_refresh_seconds' "$CONFIG_JSON")"
KONSOLE_GEOMETRY="$(jq -r '.konsole_geometry' "$CONFIG_JSON")"

SPINNER=()
while IFS= read -r f; do
  SPINNER+=("$f")
done < <(jq -r '.spinner_frames[]' "$CONFIG_JSON")

COL_BANNER="$(jq -r '.colors.banner' "$CONFIG_JSON")"
COL_OK="$(jq -r '.colors.ok' "$CONFIG_JSON")"
COL_FAIL="$(jq -r '.colors.fail' "$CONFIG_JSON")"
COL_DIM="$(jq -r '.colors.dim' "$CONFIG_JSON")"
COL_WARN="$(jq -r '.colors.warn' "$CONFIG_JSON")"
COL_VALUE="$(jq -r '.colors.value' "$CONFIG_JSON")"

C_BANNER="$(printf '\033[%sm' "$COL_BANNER")"
C_OK="$(printf '\033[%sm' "$COL_OK")"
C_FAIL="$(printf '\033[%sm' "$COL_FAIL")"
C_DIM="$(printf '\033[%sm' "$COL_DIM")"
C_WARN="$(printf '\033[%sm' "$COL_WARN")"
C_VAL="$(printf '\033[%sm' "$COL_VALUE")"
C_0=$'\033[0m'

STATE_DIR="$HOME/.cache/nix-switch-progress"
mkdir -p "$STATE_DIR"
LAST_COMMIT_FILE="$STATE_DIR/last-commit"
STATUS_FILE="$(mktemp --tmpdir nsp-status.XXXXXX)"
# Nested invocations (see the branch above) tail into this SAME file
# instead of opening their own window.
export NSP_STATUS_FILE="$STATUS_FILE"
START_MS=$(( $(date +%s%N) / 1000000 ))

# ── Repo state: clean/dirty, commit being applied vs the previously
#    applied one (recorded by THIS wrapper on its last success), diffstat.
SRC_DIR="${NSP_SRC_DIR:-}"
DIRTY="" CUR_HASH="" CUR_SUBJ="" PREV_HASH="" PREV_SUBJ="" DIFFSTAT=""
if [ -n "$SRC_DIR" ] && git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  DIRTY="$(git -C "$SRC_DIR" status --porcelain)"
  CUR_HASH="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null)"
  CUR_SUBJ="$(git -C "$SRC_DIR" log -1 --format=%s 2>/dev/null)"
  PREV_HASH="$(cat "$LAST_COMMIT_FILE" 2>/dev/null || true)"
  if [ -n "$PREV_HASH" ] && git -C "$SRC_DIR" cat-file -e "$PREV_HASH" 2>/dev/null; then
    PREV_SUBJ="$(git -C "$SRC_DIR" log -1 --format=%s "$PREV_HASH" 2>/dev/null)"
    DIFFSTAT="$(git -C "$SRC_DIR" diff --stat "$PREV_HASH"..HEAD 2>/dev/null | tail -1)"
  fi
fi

# ── Closure/tarball size — best-effort, computed in the background
#    (nix path-info -S can take a few seconds) and appended when ready.
if [ -n "${NSP_FLAKE_ATTR:-}" ]; then
  (
    _sz="$(nix path-info -S "$NSP_FLAKE_ATTR" 2>/dev/null | awk '{print $2}')"
    if [ -n "$_sz" ]; then
      _human="$(numfmt --to=iec "$_sz" 2>/dev/null || echo "$_sz bytes")"
      printf '\n%bClosure size:%b %s\n' "$C_VAL" "$C_0" "$_human" >> "$STATUS_FILE"
    fi
  ) &
fi

# ── Header ────────────────────────────────────────────────────────
{
  printf '%b╔══════════════════════════════════════════════════════════╗%b\n' "$C_BANNER" "$C_0"
  printf '%b║              %s                    ║%b\n' "$C_BANNER" "$TITLE" "$C_0"
  printf '%b╚══════════════════════════════════════════════════════════╝%b\n' "$C_BANNER" "$C_0"
  echo ""
  if [ -n "$SRC_DIR" ]; then
    printf 'Repo:      %b%s%b\n' "$C_VAL" "$(basename "$SRC_DIR")" "$C_0"
    if [ -z "$DIRTY" ]; then
      printf 'Status:    %b✓ clean%b\n' "$C_OK" "$C_0"
    else
      printf 'Status:    %b✗ %s dirty file(s)%b\n' "$C_FAIL" "$(echo "$DIRTY" | wc -l)" "$C_0"
      # Indent each dirty path. Not `sed 's/^/.../'`: shellcheck rejects
      # echo|sed as SC2001 (style, still fatal under writeShellApplication),
      # and ${var//} cannot anchor per-line.
      printf '%s\n' "$DIRTY" | while IFS= read -r _dirty_line; do
        printf '             %s\n' "$_dirty_line"
      done
    fi
    printf 'Commit:    %b%s%b  %s\n' "$C_VAL" "$CUR_HASH" "$C_0" "$CUR_SUBJ"
    [ -n "$PREV_HASH" ] && printf 'Previous:  %b%s%b  %s\n' "$C_VAL" "$PREV_HASH" "$C_0" "$PREV_SUBJ"
    [ -n "$DIFFSTAT" ] && printf 'Diff:      %s\n' "$DIFFSTAT"
  fi
  printf 'Closure:   (calculating…)\n'
  echo ""
  printf '%b▶▶▶ PHASE: Preparing%b\n' "$C_WARN" "$C_0"
} > "$STATUS_FILE"

# ── PSI (/proc/pressure) panel — relative avg10/60/300 % AND absolute
#    cumulative stall µs (both in the raw kernel line), refreshed on an
#    interval with a rotating spinner. Killed in the EXIT trap. ──────
_psi_loop() {
  local i=0
  while :; do
    local f="${SPINNER[$((i % ${#SPINNER[@]}))]}"
    {
      echo ""
      printf '%b── PSI %s %s ──%b\n' "$C_DIM" "$f" "$(date +%H:%M:%S)" "$C_0"
      for r in cpu memory io; do
        [ -r "/proc/pressure/$r" ] && awk -v r="$r" '{print "  " r " " $0}' "/proc/pressure/$r"
      done
    } >> "$STATUS_FILE"
    i=$((i + 1))
    sleep "$PSI_REFRESH"
  done
}
_psi_loop &
PSI_PID=$!
export NSP_CAP="$CAP_PCT"

trap 'kill "$PSI_PID" 2>/dev/null || true' EXIT

# ── Companion copyable window — plain terminal text selection, never
#    auto-closed. Geometry/title data-driven from the json config. ──
konsole --geometry "$KONSOLE_GEOMETRY" -p "tabtitle=$TITLE" \
  -e bash -c "tail -n +1 -f '$STATUS_FILE'" >/dev/null 2>&1 &

# --log-format internal-json is only understood by `nix build ...` and
# `home-manager switch ...` (which wraps nix build internally) — only
# append it when the wrapped command actually IS one of those. Other
# callers (e.g. build.sh's `pull`/`switch` runner path: `gh run
# download`, `zstd`, `docker`, `nix-store --import`, the activation
# script itself) don't accept the flag at all — appending it
# unconditionally would break them outright. Those commands' plain-text
# output still flows through the same pipe into the .mjs, which already
# treats any non-`@nix` line as pass-through activation output (see
# progress.mjs) — so the one Konsole window still shows everything,
# just without the byte-level nix build bars (there's nothing to bar
# there — no local build/copy happens on that path). Owner mode reaches
# this when it IS the wrapped command (e.g. run directly via the
# nix-command-catcher shim); the nested-mode branch above has its own
# copy of this same case statement for when it isn't.
case "$1" in
  nix|home-manager) set -- "$@" --log-format internal-json ;;
esac
# The .mjs prints a colorized, phase-aware, data-dense progress line
# per update (both bars, sizes, ETA — plus passes through real
# activation output) to its own stdout — teed into BOTH the caller's
# log file (if any) and our STATUS_FILE for the one Konsole window.
set -o pipefail
export NSP_START_MS="$START_MS"
if [ -n "${NSP_LOG_FILE:-}" ]; then
  "$@" 2>&1 | tee -a "$NSP_LOG_FILE" | node "$NSP_MJS" | tee -a "$STATUS_FILE" >/dev/null
else
  "$@" 2>&1 | node "$NSP_MJS" | tee -a "$STATUS_FILE" >/dev/null
fi
_rc="${PIPESTATUS[0]}"

_elapsed_s=$(( ( $(date +%s%N) / 1000000 - START_MS ) / 1000 ))

if [ "$_rc" -eq 0 ]; then
  echo "$CUR_HASH" > "$LAST_COMMIT_FILE"
  {
    echo ""
    printf '%b✓ SWITCH SUCCEEDED%b  (total %ss)\n' "$C_OK" "$C_0" "$_elapsed_s"
  } >> "$STATUS_FILE"
  if [ "$NOTIFY_ON_FINISH" = "true" ]; then
    if command -v notify-send >/dev/null 2>&1; then
      notify-send -i "$ICON" "$TITLE" "Completed successfully in ${_elapsed_s}s." || true
    fi
  fi
else
  {
    echo ""
    printf '%b✗ SWITCH FAILED%b (exit %s)\n' "$C_FAIL" "$C_0" "$_rc"
  } >> "$STATUS_FILE"
  _clean="$(sed -r 's/\x1b\[[0-9;]*m//g' "$STATUS_FILE")"
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$_clean" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$_clean" | xclip -selection clipboard
  fi
  # STATUS_FILE must survive past this script's exit so the "Open Log"
  # notification action (below) has something to open — copy it into a
  # stable per-failure path instead of leaving it in mktemp limbo.
  FAIL_LOG="$STATE_DIR/last-failure.log"
  cp -f "$STATUS_FILE" "$FAIL_LOG" 2>/dev/null || true
  if [ "$NOTIFY_ON_FINISH" = "true" ]; then
    if command -v notify-send >/dev/null 2>&1; then
      _action="$(notify-send -u critical -i "$ICON" -A "open=Open Log" "$TITLE" "Failed (exit $_rc) — full log copied to clipboard." 2>/dev/null || true)"
      if [ "$_action" = "open" ]; then
        konsole -e less -R "$FAIL_LOG" >/dev/null 2>&1 &
      fi
    fi
  fi
fi

exit "$_rc"
