#!/usr/bin/env sh
# core/dispatch.sh — resolve a token to a registry command and execute it.
# Replaces the old _resolve_shortcode_inner case-tree: routing is now DATA
# (registry.json), this is the generic executor. Requires registry.sh sourced,
# DTK_ROOT set, and (for exec.kind=core) the do_* handler functions in scope.

# dtk_dispatch <token> [extra args...]
#   token forms:  <id>            e.g. observe.btop
#                 <shortcode>     e.g. 30a   (legacy accelerator)
#                 <domain> <name> e.g. observe btop
#                 <name>          e.g. btop  (first match)
dtk_dispatch() {
  [ $# -eq 0 ] && return 1
  _tok="$1"; shift

  _obj="$(reg_resolve "$_tok")"
  # try "<domain> <name>" form if first token is a domain and a 2nd arg exists
  if [ -z "$_obj" ] && [ $# -ge 1 ]; then
    _try="$(reg_resolve_domain_name "$_tok" "$1")"
    if [ -n "$_try" ]; then _obj="$_try"; shift; fi
  fi
  # 127 = unresolved (caller shows help); other codes = the command's own status.
  [ -z "$_obj" ] && { echo "dtk: unknown command '$_tok'" >&2; return 127; }

  _kind="$(reg_field "$_obj" '.exec.kind')"
  # exec.args (declared) joined; runtime "$@" appended after
  _dargs="$(reg_field "$_obj" '.exec.args | join(" ")')"

  case "$_kind" in
    core)
      _fn="$(reg_field "$_obj" '.exec.fn')"
      command -v "$_fn" >/dev/null 2>&1 || { echo "dtk: handler '$_fn' not found"; return 1; }
      # shellcheck disable=SC2086
      "$_fn" $_dargs "$@" ;;
    module)
      _run="$(reg_field "$_obj" '.exec.run')"
      # shellcheck disable=SC2086
      sh "$DTK_ROOT/$_run" $_dargs "$@" ;;
    raw)
      _run="$(reg_field "$_obj" '.exec.run')"
      sh -c "$_run" ;;
    orchestrator)
      _run="$(reg_field "$_obj" '.exec.run')"
      # $_QC is the cloud-container-orchestrator invocation, set by bin/dtk
      # shellcheck disable=SC2086
      ${_QC:-sh "$DTK_ROOT/build/flake-engines/cloud-container-orchestrator/cloud-container-orchestrator.sh"} "$_run" ;;
    *)
      echo "dtk: unknown exec.kind '$_kind' for '$_tok'"; return 1 ;;
  esac
}
