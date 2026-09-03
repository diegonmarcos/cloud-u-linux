#!/usr/bin/env bash
# claude-plugins-status.sh — on/off status of registered Claude Code PLUGINS
# (NOT MCP servers). Data-driven: reads ~/.claude/claude-plugins.json; add a
# plugin by appending a JSON entry — no edits here.
#
# Usage: claude-plugins-status.sh [--format ansi|plain] [--part skl|sys|all]
#   --part picks which bucket to render (statusline interleaves Skl/Rul/Sys,
#   Rul coming from claude-hooks-status.sh in between) — default: all.
#   ansi  (default): compact segment  → Skl[Ag●●●●]  /  Sys[H● P●:full M:Rem]
#                    ● green = on / ○ grey = off; flag_file plugins append mode.
#   plain          : uncolored, for the claude-superset banner.
#
# detect.type:
#   env_set    → env var detect.env is non-empty
#   flag_file  → file detect.path (relative to config dir) exists;
#                detect.show_content=true appends its content (e.g. ponytail mode)
#   env_value  → renders as icon:Value (superset mode), folded into Sys
#
# Detection is deliberately spawn-free (env var + stat) so it is safe to call on
# every statusline render. One jq call parses the whole manifest.
set -u

fmt="ansi"; part="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) fmt="${2:-ansi}"; shift 2 ;;
    --part)   part="${2:-all}"; shift 2 ;;
    *) shift ;;
  esac
done
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAN="$CFG/claude-plugins.json"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$MAN" ] || exit 0

# One jq call → TSV: label \t icon \t type \t env \t path \t show_content \t group.
# Absent optional fields get a "-" sentinel (not ""): tab is IFS-whitespace, so
# `read` would coalesce an empty middle column and shift every field left.
rows=$(jq -r '.plugins[] | [.label, .icon, .detect.type, (.detect.env // "-"), (.detect.path // "-"), (.detect.show_content // false), (.group // "-")] | @tsv' "$MAN" 2>/dev/null) || exit 0
[ -z "$rows" ] && exit 0

# Bucket rendered "icon:detail"/"icon●" tokens by .group; ungrouped entries
# (e.g. superset-mode) fold into Sys — it's system/runtime state, same as
# Headroom/Ponytail/RTK/Caveman.
sys=""; sys_plain=""
while IFS=$'\t' read -r label icon dtype env path show group; do
  [ -z "$label" ] && continue
  [ "$env" = "-" ] && env=""
  [ "$path" = "-" ] && path=""
  [ "$group" = "-" ] && group=""
  on=false; detail=""; tok=""
  case "$dtype" in
    env_set)
      [ -n "${!env:-}" ] && on=true ;;
    flag_file)
      if [ -f "$CFG/$path" ]; then
        on=true
        [ "$show" = "true" ] && detail=$(tr -d '[:space:]' < "$CFG/$path" 2>/dev/null)
      fi ;;
    env_value)
      # Value indicator (superset face from CLAUDE_SUPERSET_MODE: remote/local/
      # claude -> Rem/Loc/Cla), no on/off dot. Absent => nothing shown.
      _v="${!env:-}"
      if [ -n "$_v" ]; then
        _v3=$(printf '%s' "$_v" | cut -c1-3)
        detail="$(tr '[:lower:]' '[:upper:]' <<<"${_v3:0:1}")${_v3:1}"
        sys="$sys ${icon}\033[32m:${detail}\033[0m"
        sys_plain="$sys_plain ${label}:${detail}"
      fi
      continue ;;
  esac
  if [ "$on" = true ]; then
    tok="${icon}\033[32m●\033[0m"
    [ -n "$detail" ] && tok="${tok}\033[32m:${detail}\033[0m"
    sys_plain="$sys_plain ${label}:${detail:-on}"
  else
    tok="${icon}\033[90m○\033[0m"
    sys_plain="$sys_plain ${label}:off"
  fi
  sys="$sys $tok"
done <<EOF
$rows
EOF

# Skl: one dot per registered custom agent (~/.claude/agents, excluding
# README) — the count IS the dot-run length, matching the MCP/Sys dot style.
_ag_dir="$CFG/agents"; _ag_c=0
if [ -d "$_ag_dir" ]; then
  for _f in "$_ag_dir"/*.md; do
    [ -f "$_f" ] || continue
    _n="${_f##*/}"; _n="${_n%.md}"
    case "$_n" in README*|readme*) continue ;; esac
    _ag_c=$((_ag_c + 1))
  done
fi
skl=""
if [ "$_ag_c" -gt 0 ]; then
  dots=""
  for _ in $(seq 1 "$_ag_c"); do dots="${dots}\033[32m●\033[0m"; done
  skl="Ag:${dots}"
fi

sys="${sys# }"; sys_plain="${sys_plain# }"

render() {
  local label="$1" body="$2"
  [ -z "$body" ] && return
  printf '%s[%s] ' "$label" "$body"
}

if [ "$fmt" = "plain" ]; then
  case "$part" in
    skl) out=$(render "Skl" "Ag:${_ag_c}") ;;
    sys) out=$(render "Sys" "$sys_plain") ;;
    *)   out="$(render "Skl" "Ag:${_ag_c}")$(render "Sys" "$sys_plain")" ;;
  esac
else
  case "$part" in
    skl) out=$(render "Skl" "$skl") ;;
    sys) out=$(render "Sys" "$sys") ;;
    *)   out="$(render "Skl" "$skl")$(render "Sys" "$sys")" ;;
  esac
fi
printf '%s' "${out% }"
