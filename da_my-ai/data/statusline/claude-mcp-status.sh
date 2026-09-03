#!/usr/bin/env bash
# claude-mcp-status.sh — per-MCP online/offline icons for the statusline.
#
# `claude mcp list` no longer health-checks anything when run non-interactively
# (this script's whole original premise) — every server now unconditionally
# reports "⏸ Pending approval (run `claude` to approve)" outside a live TTY
# session, REGARDLESS of whether it's actually reachable. That text is an
# auth-approval gate, not a liveness signal, so trusting it made every server
# render identically (all "pending" — the "all half-circles" bug). Real fix:
# use `claude mcp list` only to discover each server's declared transport
# (URL for HTTP, command/path for stdio), then probe THAT directly — curl the
# URL for HTTP servers, check the target file/command exists for stdio ones.
# Still cached (15-min TTL, lazy background refresh) since the probe fan-out
# is not free either.
#
# Output (ansi): MCP[●○…]  — one dot per CONFIGURED server, stable sorted
# order. ● green = reachable, ○ grey = unreachable/unknown. Emits nothing if
# no servers are configured; the statusline falls back to the count.
#
# Arg 1 (optional): project cwd, to also read its ./.mcp.json. Defaults to $PWD.
set -u

TTL=900                                            # 15 min
LOCK_TTL=120                                        # a refresh can't outlive timeout 60 + overhead
CACHE="${TMPDIR:-/tmp}/claude-mcp-status.cache"    # "name<TAB>on|off" per line
LOCK="${TMPDIR:-/tmp}/claude-mcp-status.refresh.lock"

# --- Hidden mode: the detached refresher (`$0 --refresh`) -------------------
# `claude mcp list` health-checks every server and takes ~15s. It MUST run
# detached (setsid, below) — an attached background child is reaped together
# with the statusline's process group the instant the render returns, killing
# the probe mid-flight and leaving a 0-byte cache. This mode blocks on the
# probe, writes the cache atomically, then frees the lock.
if [ "${1:-}" = "--refresh" ]; then
  run="claude mcp list"
  command -v timeout >/dev/null 2>&1 && run="timeout 60 $run"
  tmp="$CACHE.$$"
  $run 2>/dev/null | while IFS= read -r line; do
    case "$line" in *:*) ;; *) continue ;; esac
    name=${line%%:*}; name=$(printf '%s' "$name" | tr -d '[:space:]')
    [ -z "$name" ] && continue
    # Line shape: "name: <target> - <status text>" — target is either an
    # "https://... (HTTP)" URL or a local stdio command/path. Probe the
    # target itself; the trailing status text is an approval gate, not a
    # liveness signal (see header comment).
    target=${line#*: }; target=${target%% - *}
    case "$target" in
      https://*|http://*)
        # ANY http response code proves the server is up and answering —
        # MCP streamable-HTTP endpoints reject a bare GET (wrong method/
        # headers for the protocol) with 4xx, which is still "reachable",
        # not "down". Only a genuine connection failure (curl emits no
        # code at all, or "000") means actually unreachable.
        url=$(printf '%s' "$target" | sed -E 's/ \(HTTP\)$//')
        code=$(timeout 5 curl -o /dev/null -s -w '%{http_code}' -L "$url" 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
          printf '%s\ton\n' "$name"
        else
          printf '%s\toff\n' "$name"
        fi ;;
      *)
        # stdio server: last whitespace-separated token is usually the
        # script/entry path; first token is the launcher command. "on" if
        # either resolves — best-effort (no full JSON-RPC handshake here).
        path=$(printf '%s' "$target" | awk '{print $NF}')
        cmd=$(printf '%s' "$target" | awk '{print $1}')
        if [ -e "$path" ] || command -v "$cmd" >/dev/null 2>&1; then
          printf '%s\ton\n' "$name"
        else
          printf '%s\toff\n' "$name"
        fi ;;
    esac
  done > "$tmp" 2>/dev/null
  [ -s "$tmp" ] && mv -f "$tmp" "$CACHE" || rm -f "$tmp"
  rmdir "$LOCK" 2>/dev/null
  exit 0
fi

cwd="${1:-$PWD}"
command -v jq >/dev/null 2>&1 || exit 0

# Configured server names (global + project), stable + de-duplicated.
servers=""
for f in "$HOME/.mcp.json" "$cwd/.mcp.json"; do
  [ -f "$f" ] && servers="$servers"$'\n'"$(jq -r '.mcpServers // {} | keys[]' "$f" 2>/dev/null)"
done
servers=$(printf '%s\n' "$servers" | sed '/^$/d' | sort -u)
[ -z "$servers" ] && exit 0

# --- Lazy refresh: fire at most one background `claude mcp list` when stale ---
need=false
if [ ! -f "$CACHE" ]; then
  need=true
else
  now=$(date +%s 2>/dev/null || echo 0)
  mtime=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  [ $((now - mtime)) -ge "$TTL" ] && need=true
fi
if [ "$need" = true ] && command -v claude >/dev/null 2>&1; then
  # Reclaim a dead lock: a refresher that died before rmdir (statusline reaps the
  # backgrounded subshell, timeout kills it, session exits) would otherwise wedge
  # the lock forever and freeze the cache. A live refresh can't outlive LOCK_TTL.
  if [ -d "$LOCK" ]; then
    lmtime=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    [ $(( $(date +%s 2>/dev/null || echo 0) - lmtime )) -ge "$LOCK_TTL" ] && rmdir "$LOCK" 2>/dev/null
  fi
  # mkdir is atomic → exactly one refresher at a time (no stampede).
  if mkdir "$LOCK" 2>/dev/null; then
    # Detach into a new session so the ~15s probe survives this render's exit.
    # `setsid` (no -f, portable) execs the refresher into its own session/pgrp;
    # `&` lets us return instantly. The detached child writes the cache + frees
    # the lock when done; a child that dies anyway leaves a lock the LOCK_TTL
    # reclaim above clears on the next render.
    # Invoke through `bash` — $0 is a non-executable source path / read-only
    # nix-store symlink, so exec'ing it directly (bare setsid "$0") fails.
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$0" --refresh </dev/null >/dev/null 2>&1 &
    else
      bash "$0" --refresh </dev/null >/dev/null 2>&1 &   # fallback: attached (may be reaped)
    fi
  fi
fi

# Short label for a server id: strip noise words (cloud/mcp/local — the
# project-wide prefix/suffix clutter), then abbreviate what's left to exactly
# 3 chars — fixed width keeps the MCP[...] segment scannable/aligned.
# 1 word  -> first 3 chars, capitalized  (mail-mcp -> Mai, cloud-cgc-mcp -> Cgc)
# 2+ words -> first 2 of word1 + first 1 of word2 (google-workspace -> Gow)
abbrev() {
  local id="$1" w cleaned=""
  IFS='-' read -ra parts <<<"$id"
  for w in "${parts[@]}"; do
    case "$w" in mcp|local|cloud|"") continue ;; esac
    cleaned="$cleaned $w"
  done
  cleaned="${cleaned# }"
  [ -z "$cleaned" ] && cleaned="$id"
  read -ra words <<<"$cleaned"
  if [ "${#words[@]}" -ge 2 ]; then
    printf '%s%s' "$(printf '%s' "${words[0]}" | cut -c1-2)" "$(printf '%s' "${words[1]}" | cut -c1-1)" | sed 's/.*/\u&/'
  else
    printf '%s' "${words[0]}" | cut -c1-3 | sed 's/.*/\u&/'
  fi
}

# --- Render from cache (stale OK); uncached/unknown server → off ---
# ● full = reachable, ○ empty = unreachable/unknown — no shape distinction
# by locality. Each server gets its abbreviated label before the dot.
out=""
while IFS= read -r s; do
  [ -z "$s" ] && continue
  state="off"
  [ -f "$CACHE" ] && { c=$(awk -F'\t' -v n="$s" '$1==n {print $2; exit}' "$CACHE" 2>/dev/null); [ -n "$c" ] && state="$c"; }
  label=$(abbrev "$s")
  case "$state" in
    on) out="$out $label\033[32m●\033[0m" ;;   # green, reachable
    *)  out="$out $label\033[90m○\033[0m" ;;   # grey, unreachable/unknown
  esac
done <<EOF
$servers
EOF
out="${out# }"

printf '%s' "MCP[$out]"
