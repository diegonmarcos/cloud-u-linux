#!/usr/bin/env bash
# hm-auto-update-check.sh — generated from programs/hm-auto-update.nix, do not
# edit by hand.
#
# GHA (ship_nix-flakes_desktop_hm.yaml) pushes a layered incremental closure
# image to GHCR on every push (hm-cache-image, consumed by build.sh's
# ghcr_incremental_switch → ghcr_pull_layered — only changed layers transfer,
# NO 6GB download). This script closes the loop on the DESKTOP side: a
# systemd user timer runs this, which polls the GHCR registry directly for
# that image's digest (no ntfy/webhook — direct registry query) and, on
# change, pops a CANCELLABLE countdown, then launches `build.sh switch`
# detached via systemd-run (survives the triggering process/session dying —
# the safe-launch pattern documented after the 2026-07-08 HM activation
# incidents). The switch itself opens the nix-switch-progress Konsole window
# (verbosity/progress surface).
#
# Fully runtime-data-driven: image/tag/build.sh path/countdown delay/dialog
# + notify channels/RAM-headroom floor/switch cgroup bounds are ALL read at
# RUNTIME from CONFIG_JSON via jq — nothing is baked in by Nix interpolation.
# See programs/hm-auto-update.nix (xdg.configFile deploy) and
# hm-auto-update.json (the values + rationale, also consumed by build.sh).
# errexit is deliberately OFF, and must be turned off EXPLICITLY: this script
# is compiled by pkgs.writeShellApplication, which prepends `set -o errexit`
# ahead of this line. The body is written throughout in check-explicitly style
# (`cmd || { log; exit 0; }`, `${VAR:-default}` after a command substitution
# that may fail), which errexit silently converts into "die on the first
# non-zero exit" — including exits that are the NORMAL path, like yad
# returning 70 when its countdown lapses.
#
# A bare `set -uo pipefail` does not clear an already-set errexit; only `+e`
# does. Without this the countdown gate below killed the script mid-flight,
# after the digest had been recorded, so the update was dropped and never
# retried. Keep the `+e`.
set +e -uo pipefail

CONFIG_JSON="${HAU_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/hm-auto-update.json}"

# This is a user-facing auto-update helper, same spirit as the "skopeo
# missing" / "gh missing" guards below: if the config can't be read, log and
# skip THIS check rather than fail the timer unit outright.
if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "hm-auto-update: config missing/unreadable/unparseable at $CONFIG_JSON, skipping check" >&2
  exit 0
fi

_boolsh() { if [ "$1" = "true" ]; then echo 1; else echo 0; fi; }

# HAU_* env overrides let test-hm-auto-update.sh exercise this exact
# generated script with stub gh/skopeo/yad/systemd-run + an isolated
# state dir, instead of testing a hand-copied duplicate of the logic.
IMAGE="${HAU_IMAGE:-$(jq -r '.image' "$CONFIG_JSON")}"
TAG="${HAU_TAG:-$(jq -r '.tag' "$CONFIG_JSON")}"
BUILD_SH="${HAU_BUILD_SH:-$(jq -r '.repo_build_sh' "$CONFIG_JSON")}"
DELAY="${HAU_DELAY:-$(jq -r '.countdown.delay_seconds' "$CONFIG_JSON")}"
DIALOG_RAW="$(jq -r '.countdown.channels.dialog_center' "$CONFIG_JSON")"
NOTIFY_RAW="$(jq -r '.countdown.channels.notify_send' "$CONFIG_JSON")"
DIALOG_ENABLED="${HAU_DIALOG:-$(_boolsh "$DIALOG_RAW")}"
NOTIFY_ENABLED="$(_boolsh "$NOTIFY_RAW")"
MIN_FREE_MB="${HAU_MIN_FREE_MB:-$(jq -r '.safety.min_free_mb' "$CONFIG_JSON")}"
SW_MEM_MAX="$(jq -r '.safety.switch_memory_max' "$CONFIG_JSON")"
SW_SWAP_MAX="$(jq -r '.safety.switch_swap_max' "$CONFIG_JSON")"

command -v skopeo >/dev/null 2>&1 || { echo "hm-auto-update: skopeo missing, skipping check" >&2; exit 0; }
command -v gh >/dev/null 2>&1 || { echo "hm-auto-update: gh CLI missing, skipping check" >&2; exit 0; }

STATE_DIR="${HAU_STATE_DIR:-$HOME/.cache/hm-auto-update}"
mkdir -p "$STATE_DIR"
DIGEST_FILE="$STATE_DIR/last-digest"

TOKEN="$(gh auth token 2>/dev/null)" || { echo "hm-auto-update: gh not authenticated, skipping check" >&2; exit 0; }

NEW_DIGEST="$(skopeo inspect --format '{{.Digest}}' --creds "x:$TOKEN" "docker://$IMAGE:$TAG" 2>/dev/null)"
if [ -z "$NEW_DIGEST" ]; then
  echo "hm-auto-update: could not inspect $IMAGE:$TAG (unavailable or not yet pushed), skipping check" >&2
  exit 0
fi

if [ ! -f "$DIGEST_FILE" ]; then
  # First run — seed the baseline, don't trigger a switch for a digest
  # that (for all we know) is already what's active.
  echo "$NEW_DIGEST" > "$DIGEST_FILE"
  echo "hm-auto-update: seeded baseline digest $NEW_DIGEST" >&2
  exit 0
fi

OLD_DIGEST="$(cat "$DIGEST_FILE" 2>/dev/null || true)"
if [ "$NEW_DIGEST" = "$OLD_DIGEST" ]; then
  exit 0
fi

# ── RAM-headroom guard (2026-07-10) ─────────────────────────────────
# A new generation exists — but if the desktop is already memory-full,
# firing a ~GB pull now tips user-1000.slice into reclaim-thrash and
# freezes the box (exactly the 13:41 bootstrap freeze). DEFER: do NOT
# record the digest, so the very next poll retries once the box has
# headroom. This is the difference between "auto-update waits politely"
# and "auto-update freezes your desktop".
AVAIL_MB=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
AVAIL_MB="${AVAIL_MB:-0}"
if [ "$AVAIL_MB" -lt "$MIN_FREE_MB" ]; then
  echo "hm-auto-update: DEFERRING switch — only ${AVAIL_MB}MB free < ${MIN_FREE_MB}MB safe floor; will retry next poll (digest NOT recorded)" >&2
  exit 0
fi

# Record the new digest NOW: whether the user proceeds or skips, we must
# not re-prompt every poll for the SAME digest. A later, different digest
# will prompt afresh.
#
# But recording it early means any failure between here and the systemd-run
# below burns the digest for good — the next poll sees "no change" and the
# update is lost silently, with nothing in the log to say a switch was ever
# due. That is what the errexit bug at the gate did for months. Roll the
# digest back on any abnormal exit so the failure mode is "retries next
# poll" instead of "never again"; DIGEST_COMMITTED is set once the outcome
# is deliberate (switch launched, or user chose Skip).
DIGEST_COMMITTED=0
rollback_digest() {
  _rc=$?
  if [ "$_rc" -ne 0 ] && [ "$DIGEST_COMMITTED" -eq 0 ]; then
    printf '%s' "$OLD_DIGEST" > "$DIGEST_FILE" 2>/dev/null || true
    echo "hm-auto-update: aborted (exit $_rc) before switching — digest rolled back, will retry next poll" >&2
  fi
}
trap rollback_digest EXIT

echo "$NEW_DIGEST" > "$DIGEST_FILE"
SHORT="${NEW_DIGEST#sha256:}"; SHORT="${SHORT:0:12}"

if [ "$NOTIFY_ENABLED" = "1" ] && command -v notify-send >/dev/null 2>&1; then
  notify-send -i software-update-available "Home-manager auto-update" \
    "New generation ($SHORT) — activating in ${DELAY}s. To stop mid-switch: hm-auto-update-cancel" || true
fi

# ── Cancellable countdown gate ──────────────────────────────────────
# yad with --timeout draws a visible shrinking bar and auto-exits (70)
# when it lapses = "proceed by default". Buttons: Switch now (0) /
# Skip this build (1). Only an explicit Skip aborts; timeout, close, or
# "Switch now" all proceed (honours the fully-automatic intent, with an
# explicit opt-out). Headless (no DISPLAY/WAYLAND, no yad, or dialog
# disabled) proceeds after the countdown — NEVER blocks unattended.
DECISION="proceed"
if [ "$DIALOG_ENABLED" = "1" ] && command -v yad >/dev/null 2>&1 \
   && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  # Hard backstop (DELAY+5) in case yad itself hangs; yad's own --timeout
  # drives the visible countdown and exits 70 when it lapses.
  #
  # MUST stay wrapped in `if`. writeShellApplication compiles this with
  # `set -o errexit`, and every outcome this gate cares about EXCEPT the
  # "Switch now" button is a non-zero exit — 70 on timeout, 252 on close,
  # 1 on Skip. As a bare command, errexit killed the script on that line,
  # before `rc=$?` ever ran. The digest is recorded above, so the next poll
  # saw "no change" and never retried: the unattended path — the whole
  # point of the timer — could never switch. Only clicking "Switch now"
  # (exit 0) worked, which is why this looked fine every time it was
  # tested by hand. `if` puts the command in a condition context, where
  # errexit does not apply.
  if timeout $((DELAY + 5)) \
    yad --title="Home-manager auto-update" --window-icon=software-update-available \
        --width=460 --center --on-top --borders=12 \
        --image=software-update-available \
        --text="<b>New home-manager generation available</b>\ndigest $SHORT\n\nActivating automatically in $DELAY second(s).\nThe switch runs incrementally (only changed layers) and\nshows a live progress window." \
        --timeout="$DELAY" --timeout-indicator=bottom \
        --button="Skip this build!process-stop:1" \
        --button="Switch now!system-software-update:0"
  then rc=0; else rc=$?; fi
  case "$rc" in
    1) DECISION="skip" ;;   # explicit Skip only
    *) DECISION="proceed" ;; # 0 (now), 70 (timeout), 252 (closed), etc.
  esac
else
  echo "hm-auto-update: no graphical dialog (headless/disabled) — proceeding after ${DELAY}s" >&2
  sleep "$DELAY"
fi

if [ "$DECISION" = "skip" ]; then
  DIGEST_COMMITTED=1
  echo "hm-auto-update: user skipped generation $SHORT (digest recorded; next change re-prompts)" >&2
  if [ "$NOTIFY_ENABLED" = "1" ] && command -v notify-send >/dev/null 2>&1; then
    notify-send -i process-stop "Home-manager auto-update" "Skipped generation $SHORT." || true
  fi
  exit 0
fi

echo "hm-auto-update: activating generation $SHORT via build.sh switch (bounded: mem<=$SW_MEM_MAX swap<=$SW_SWAP_MAX)" >&2
# Detached — survives this oneshot service's own lifetime. build.sh's
# own .switch.lock flock (cmd_switch_runner) makes this safe even if a
# manual switch is already in flight. `switch` is incremental-first.
# MEMORY-BOUNDED: the switch's own footprint (build.sh, zstd, nix-store
# import) is capped so it can't pile onto the full desktop; if it
# balloons, oomd/OOM sacrifices the SWITCH, never the compositor.
systemd-run --user --unit=hm-auto-switch --collect \
  -p MemoryHigh="$SW_MEM_MAX" -p MemoryMax="$SW_MEM_MAX" -p MemorySwapMax="$SW_SWAP_MAX" \
  "$BUILD_SH" switch
