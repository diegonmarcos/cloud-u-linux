#!/usr/bin/env bash
# claude-flags-status.sh — Full vs Lean context-profile segment, sourced from
# da_my-ai's claude_profiles (src/data/endpoints.json). Data-driven: add a
# profile there, it shows up here — no edits needed in this script.
#
# Active profile is inferred from env (DISABLE_WORKFLOWS is lean's marker,
# absent in full) since `my-ai claude <profile>` only sets env vars — there's
# no other on-disk signal at render time.
#
# Output (ansi):  Flags[Full(72k) vs \033[32mLean(56k)\033[0m]   (active bolded green)
#   plain:         Flags:Full(72k)/Lean(56k)*
set -u

fmt="ansi"; [ "${1:-}" = "--format" ] && fmt="${2:-ansi}"
JSON="$HOME/git/cloud-unix/da_my-ai/src/data/endpoints.json"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$JSON" ] || exit 0

full_k=$(jq -r '.claude_profiles.full.tokens // empty' "$JSON" 2>/dev/null)
lean_k=$(jq -r '.claude_profiles.lean.tokens // empty' "$JSON" 2>/dev/null)
[ -z "$full_k" ] || [ -z "$lean_k" ] && exit 0
full_k=$((full_k / 1000)); lean_k=$((lean_k / 1000))

active="full"
[ -n "${DISABLE_WORKFLOWS:-}" ] && active="lean"

if [ "$fmt" = "plain" ]; then
  full_tag="Full(${full_k}k)"; lean_tag="Lean(${lean_k}k)"
  [ "$active" = "full" ] && full_tag="${full_tag}*" || lean_tag="${lean_tag}*"
  printf 'Flags:%s/%s' "$full_tag" "$lean_tag"
else
  if [ "$active" = "full" ]; then
    printf 'Flags[\033[32mFull(%sk)\033[0m vs Lean(%sk)]' "$full_k" "$lean_k"
  else
    printf 'Flags[Full(%sk) vs \033[32mLean(%sk)\033[0m]' "$full_k" "$lean_k"
  fi
fi
