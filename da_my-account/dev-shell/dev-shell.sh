# dev — the USERSPACE<->DEV boundary launcher (Design B, 2026-06-19).
#
# `dev`            → interactive shell inside the dev userspace ([dev] prompt).
# `dev -- <cmd…>`  → run one command inside it (e.g. `dev -- rustc --version`).
#
# Mechanism: bubblewrap enters a mount namespace that is the FULL host
# (--dev-bind / / : HOME, Wayland/X, network, /dev) with exactly ONE change — the
# p5 dev-store (storeDir=/nix/store, physical root /mnt/shared-lib/dev-store) is
# overlaid on /nix/store, masking the pool store. So inside `dev` ONLY the heavy
# toolchain (built by bc_flakes_dev-store) resolves; outside, none of it is on
# PATH. The dev profile is self-complete (carries its own bash/coreutils — the
# pool's are masked). Boot-independent: fails closed if p5 is absent.
#
# Extracted from programs/dev-shell.nix (devLauncher). Runtime-data-driven:
# the dev-store root, marker env var name and prompt marker are read from
# dev-shell.json via jq at RUNTIME instead of being baked in by
# builtins.fromJSON + Nix interpolation. Real binary paths (bwrap, basename,
# readlink, mktemp, rm) arrive via writeShellApplication's runtimeEnv, never
# as ${pkgs.foo} strings here.
#
# Fall-through vs fail-loud: `dev` is a user-facing command wrapping a whole
# dev toolchain, but there is no sane "real" fallback if the dev-store isn't
# mounted or built — running the command would just fail deep inside bwrap
# with a confusing error. So this preserves the original's fail-loud
# pre-checks (clear message + exit 1) rather than falling through.
set -u

BWRAP="${DEV_SHELL_BWRAP_BIN:?dev: DEV_SHELL_BWRAP_BIN not set}"
BN="${DEV_SHELL_BASENAME_BIN:?dev: DEV_SHELL_BASENAME_BIN not set}"
RL="${DEV_SHELL_READLINK_BIN:?dev: DEV_SHELL_READLINK_BIN not set}"
MKTEMP="${DEV_SHELL_MKTEMP_BIN:?dev: DEV_SHELL_MKTEMP_BIN not set}"
RM="${DEV_SHELL_RM_BIN:?dev: DEV_SHELL_RM_BIN not set}"
JQ="${DEV_SHELL_JQ_BIN:?dev: DEV_SHELL_JQ_BIN not set}"

CONFIG_JSON="${DEV_SHELL_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/dev-shell.json}"

if [ ! -r "$CONFIG_JSON" ] || ! "$JQ" -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "dev: $CONFIG_JSON missing or unreadable" >&2
  exit 1
fi

NAME="$("$JQ" -r '.name' "$CONFIG_JSON")"
P5="$("$JQ" -r '.p5_store_root' "$CONFIG_JSON")"
PROMPT_MARKER="$("$JQ" -r '.prompt_marker' "$CONFIG_JSON")"
MARKER_ENV="$("$JQ" -r '.marker_env' "$CONFIG_JSON")"

if [ ! -d "$P5/nix/store" ]; then
  echo "$NAME: dev-store not present at $P5 — is p5 (/mnt/shared-lib) mounted?" >&2
  exit 1
fi
# The profile gcroot ($P5/profile) points to a LOGICAL /nix/store path that
# only resolves INSIDE the namespace. Resolve the PHYSICAL p5 path so the
# pre-check works outside AND the binaries' interpreter (/nix/store/…-glibc)
# still resolves inside (where /nix/store == the p5 store).
PHYS="$P5/nix/store/$("$BN" "$("$RL" "$P5/profile" 2>/dev/null)" 2>/dev/null)"
if [ ! -x "$PHYS/bin/bash" ]; then
  echo "$NAME: dev profile not built yet — run:  ~/git/cloud-infra-desktop/bc_flakes_dev-store/build.sh ship" >&2
  exit 1
fi

# Host env passes through (no --clearenv) so DISPLAY/WAYLAND_DISPLAY/HOME/TERM
# just work; we only override PATH (→ the p5 profile) and set the marker.
base=( "$BWRAP"
  --dev-bind / /
  --bind "$P5/nix/store" /nix/store
  --setenv "$MARKER_ENV" 1
  --setenv CARGO_HOME "$HOME/.cargo"
  --setenv CARGO_TARGET_DIR "$HOME/.cargo/target"
  --setenv PATH "$PHYS/bin:$HOME/.cargo/bin" )

if [ "${1:-}" = "--" ]; then
  shift
  exec "${base[@]}" "$PHYS/bin/bash" -c 'exec "$@"' _ "$@"
fi

# Interactive: a throwaway rcfile (host /tmp is bound in) sets the [dev] prompt.
RC="$("$MKTEMP" /tmp/dev-rc.XXXXXX)"
printf 'PS1="%s\\w \\$ "\n' "$PROMPT_MARKER" > "$RC"
"${base[@]}" "$PHYS/bin/bash" --rcfile "$RC" -i
rc=$?
"$RM" -f "$RC"
exit $rc
