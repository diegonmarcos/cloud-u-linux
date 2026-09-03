#!/usr/bin/env bash
# claude-hooks-status.sh — per-plugin rule-count summary, for the statusline
# Rul[…] segment (mirrors claude-plugins-status.sh Skl[…]/Sys[…]).
#
# Every installed plugin that ships a hooks-rules.json gets its own Cl<N>
# entry (Cl = "cloud principles", the shared rule schema across plugins) —
# earlier versions only read ONE plugin's file, silently ignoring the rest.
#
# Output (ansi):  Rul[Cl1:52⛔9 Cl2:18⛔0 Cl3:9⛔0 Cl4:5⛔0]
#   red count only appears on a Cl entry that actually has deny>0.
#   plain:  Rul:Cl1(52,deny9) Cl2(18,deny0) Cl3(9,deny0) Cl4(5,deny0)
#
# No installed plugin has hooks-rules.json / no jq → emits nothing.
#
# Usage: claude-hooks-status.sh [--format ansi|plain]
set -u

fmt="ansi"; [ "${1:-}" = "--format" ] && fmt="${2:-ansi}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

command -v jq >/dev/null 2>&1 || exit 0

# Newest installed version of each plugin under plugins/cache/cloud-marketplace,
# falling back to the source-tree copy (mirrors the old single-file lookup).
files=$(find "$CFG/plugins/cache/cloud-marketplace" -maxdepth 3 -name hooks-rules.json 2>/dev/null | sort)
[ -z "$files" ] && files=$(find "$CFG/cloud-marketplace" -maxdepth 3 -name hooks-rules.json 2>/dev/null | sort)
[ -z "$files" ] && exit 0

ansi=""; plain=""; i=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  i=$((i + 1))
  line=$(jq -r '
    (.rules // []) as $r |
    [ ($r|length), ([$r[]|select(.level=="deny")]|length) ] | @tsv' "$f" 2>/dev/null)
  [ -z "$line" ] && continue
  IFS=$'\t' read -r total deny <<<"$line"
  if [ "${deny:-0}" -gt 0 ]; then deny_color=31; else deny_color=90; fi
  ansi="$ansi Cl${i}:\033[32m${total}\033[0m\033[${deny_color}m⛔${deny}\033[0m"
  plain="$plain Cl${i}(${total},deny${deny})"
done <<EOF
$files
EOF

ansi="${ansi# }"; plain="${plain# }"
[ -z "$ansi" ] && exit 0

if [ "$fmt" = plain ]; then
  printf 'Rul:%s' "$plain"
else
  printf 'Rul[%s]' "$ansi"
fi
