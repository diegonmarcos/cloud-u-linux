# curl-wget-wrapper.sh — generated from curl-wget-wrapper.nix, do not edit
# by hand. Shared by both the `curl` and `wget` wrappers.
#
# Extracted from curl-wget-wrapper.nix's `mkWrapperPkg` (a Nix function
# called twice — once per binary — to produce two near-identical
# Nix-interpolated shell bodies differing only in real-binary path and
# header flag). Now ONE runtime script; the real binary is supplied via
# $WRAP_REAL (writeShellApplication's runtimeEnv, same pattern as
# nix-command-catcher.sh's $CATCHER_REAL — never resolved via `command -v`
# or a bare PATH lookup, since this wrapper shadows its own name on PATH via
# lib.hiPrio). Which wrapper is running is selected by $WRAP_NAME, used to
# look up that wrapper's header flag (and the shared token_file path) at
# RUNTIME from curl-wget-wrapper.json via jq.
#
# HARD REQUIREMENT: this wraps user-facing `curl`/`wget`. On ANY config
# problem (missing/unreadable/corrupt JSON, no matching wrapper entry, jq
# failure) it MUST fall straight through to the real binary, and the
# caller's exit code MUST be exactly the real binary's — every fallback and
# the final call below is a plain `exec "$REAL" "$@"`, never a `exit`.
set -u

REAL="${WRAP_REAL:?curl-wget-wrapper.sh: WRAP_REAL not set by Nix module}"
NAME="${WRAP_NAME:?curl-wget-wrapper.sh: WRAP_NAME not set by Nix module}"

# Re-entry guard
if [ "${_CURL_WRAP:-}" = "1" ]; then
  exec "$REAL" "$@"
fi
export _CURL_WRAP=1

CONFIG_JSON="${WRAP_CONFIG_JSON:-$HOME/.config/cloud-data/curl-wget-wrapper.json}"

# Missing/unreadable/corrupt config => transparent passthrough, never break
# the caller's curl/wget invocation.
if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  exec "$REAL" "$@"
fi

header_flag="$(jq -r --arg n "$NAME" '.wrappers[] | select(.name == $n) | .header_flag' "$CONFIG_JSON" 2>/dev/null)" || header_flag=""
if [ -z "$header_flag" ]; then
  exec "$REAL" "$@"
fi

# token_file is stored in JSON with a literal "$HOME" prefix (matching the
# original Nix string, which was never Nix-interpolated, only left for the
# shell to expand) — expand it here rather than via `eval`.
token_file_raw="$(jq -r '.token_file' "$CONFIG_JSON" 2>/dev/null)" || token_file_raw=""
token_file="${token_file_raw//\$HOME/$HOME}"

# Check if any arg matches *.diegonmarcos.com*
# Skip injection if user already provides an Authorization header
_needs_token=0
_has_auth=0
for _arg in "$@"; do
  case "$_arg" in
    *diegonmarcos.com*) _needs_token=1 ;;
    Authorization:*) _has_auth=1 ;;
  esac
done

if [ "$_needs_token" = "1" ] && [ "$_has_auth" = "0" ] && [ -n "$token_file" ] && [ -f "$token_file" ]; then
  _token="$(jq -r .access_token "$token_file" 2>/dev/null)" || _token=""
  if [ -n "$_token" ] && [ "$_token" != "null" ]; then
    exec "$REAL" "$header_flag" "Authorization: Bearer $_token" "$@"
  fi
fi

exec "$REAL" "$@"
