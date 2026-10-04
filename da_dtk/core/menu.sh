#!/usr/bin/env sh
# core/menu.sh — render the DTK menu FROM the registry (replaces the old
# hand-maintained printf grid). Grouped by domain, in declaration order.
# Requires registry.sh sourced.

dtk_menu() {
  _R='\033[0m'; _C='\033[1;36m'; _Y='\033[1;33m'; _D='\033[0;90m'; _W='\033[1;37m'
  printf "\n${_C}Diego's Toolkit (DTK)${_R} — unified CLI\n"
  printf "${_D}  dtk <domain> <command> | dtk <id> | dtk <shortcode>${_R}\n"
  reg_domains | while IFS= read -r _dom; do
    _title="$(reg_domain_title "$_dom")"
    printf "\n  ${_Y}%s${_R} ${_D}(%s)${_R}\n" "$_title" "$_dom"
    reg_commands_in "$_dom" | while IFS="$(printf '\t')" read -r _sc _name _sum; do
      if [ -n "$_sc" ]; then
        printf "    ${_W}%-22s${_R} ${_D}%-6s${_R} %s\n" "$_dom $_name" "$_sc" "$_sum"
      else
        printf "    ${_W}%-22s${_R} ${_D}%-6s${_R} %s\n" "$_dom $_name" "" "$_sum"
      fi
    done
  done
  printf "\n  ${_D}aliases: any shortcode (30a) or id (observe.btop) still works${_R}\n\n"
}
