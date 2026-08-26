#!/usr/bin/env sh
# core/registry.sh — load + query the DTK command registry (registry.json).
# The registry is THE single source of truth for the command catalog. This module
# exposes pure query helpers (no side effects) used by dispatch.sh and menu.sh.
# Requires: jq. Requires DTK_ROOT to be set by the caller (bin/dtk).

DTK_REGISTRY="${DTK_REGISTRY:-$DTK_ROOT/registry.json}"

# reg_resolve <token> — token is an id (observe.btop), a shortcode (30a), or a
# bare command name (btop). Prints the single matching command object (compact
# JSON) or nothing. id/shortcode are unique; bare name returns the first match.
reg_resolve() {
  jq -c --arg t "$1" '
    ( .commands[] | select(.id==$t or .shortcode==$t) ),
    ( .commands[] | select(.name==$t) )
  ' "$DTK_REGISTRY" 2>/dev/null | head -1
}

# reg_resolve_domain_name <domain> <name> — for `dtk observe btop` invocation.
reg_resolve_domain_name() {
  jq -c --arg d "$1" --arg n "$2" \
    '.commands[] | select(.domain==$d and .name==$n)' "$DTK_REGISTRY" 2>/dev/null | head -1
}

# reg_domains — list domain keys in declaration order.
reg_domains() { jq -r '.domains | keys_unsorted[]' "$DTK_REGISTRY"; }

# reg_domain_title <domain>
reg_domain_title() { jq -r --arg d "$1" '.domains[$d].title // $d' "$DTK_REGISTRY"; }

# reg_commands_in <domain> — "shortcode<TAB>name<TAB>summary" per command.
reg_commands_in() {
  jq -r --arg d "$1" '.commands[] | select(.domain==$d)
    | "\(.shortcode // "")\t\(.name)\t\(.summary)"' "$DTK_REGISTRY"
}

# reg_field <command-json> <jq-filter> — read a field from a resolved object.
reg_field() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null; }
