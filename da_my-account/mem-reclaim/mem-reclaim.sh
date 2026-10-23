#!/usr/bin/env bash
# ============================================================================
# mem-reclaim — data-driven memory panic button
# ============================================================================
# Frees RAM by killing user-LAUNCHED apps while leaving the desktop session and
# the active terminal/Claude tree untouched. The boundary is the systemd cgroup,
# NOT process names — the user manager already classifies:
#   user@<uid>.service/session.slice/*  → KDE session daemons (kwin, plasmashell,
#                                          kded, powerdevil, …)  → ESSENTIAL, spared
#   user@<uid>.service/app.slice/*       → launched apps (browser, electron, …) → killable
# We kill app.slice members EXCEPT the app scope that contains mem-reclaim itself
# (that scope holds the terminal + Claude + its MCP servers). Robust against
# nix-wrapped ".name-wrapped" comm names that a name allowlist can't match.
#
# Writes the kill set to $XDG_RUNTIME_DIR/mem-reclaim-killed.<ts>.json
# (symlinked mem-reclaim-killed.json) so `mem-reclaim restore` can relaunch them.
# NO sudo, user processes only. Usage:
#   mem-reclaim            # kill non-essential apps now
#   mem-reclaim --dry-run  # preview (kills nothing)
#   mem-reclaim restore    # best-effort relaunch of the last kill set
# ============================================================================
set -u

CFG="${MEM_RECLAIM_CFG:-$HOME/.config/mem-reclaim/essentials.json}"
[ -f "$CFG" ] || CFG="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/mem-reclaim-essentials.json"
[ -f "$CFG" ] || { echo "mem-reclaim: essentials.json not found ($CFG)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "mem-reclaim: jq required" >&2; exit 1; }

ONLY="$(jq -r '.protect.only_kill_under' "$CFG")"          # e.g. "/app.slice/"
KEEP="$(jq -r '.protect.keep_scope_regex // empty' "$CFG")" # extra app scopes to spare
TWAIT="$(jq -r '.signals.term_wait_s // 6' "$CFG")"
MYUID="$(id -u)"
RUNDIR="${XDG_RUNTIME_DIR:-/run/user/$MYUID}"
LATEST="$RUNDIR/mem-reclaim-killed.json"
# The app scope containing THIS process = terminal + Claude + MCP servers → never kill.
MYCG="$(sed 's/^0:://' "/proc/$$/cgroup" 2>/dev/null | head -n1)"

do_reclaim() {
    dry="$1"
    ts="$(date +%Y%m%d-%H%M%S)"
    out="$RUNDIR/mem-reclaim-killed.$ts.json"
    lines="$(mktemp)"
    ps -u "$MYUID" -o pid=,rss= --sort=-rss 2>/dev/null | while read -r pid rss; do
        [ "$pid" = "$$" ] && continue
        cg="$(sed 's/^0:://' "/proc/$pid/cgroup" 2>/dev/null | head -n1)"
        [ -n "$cg" ] || continue
        case "$cg" in *"$ONLY"*) : ;; *) continue ;; esac    # only app.slice; spares session.slice + init.scope
        [ "$cg" = "$MYCG" ] && continue                       # spare active terminal/Claude/MCP scope
        [ -n "$KEEP" ] && printf '%s' "$cg" | grep -Eq "$KEEP" && continue
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || continue
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "$HOME")"
        scope="${cg##*/}"
        jq -n --argjson pid "$pid" --argjson rss "${rss:-0}" \
              --arg comm "$(cat "/proc/$pid/comm" 2>/dev/null)" --arg cmd "$cmd" \
              --arg cwd "$cwd" --arg scope "$scope" \
              '{pid:$pid,rss_kb:$rss,comm:$comm,scope:$scope,cmdline:$cmd,cwd:$cwd}' >> "$lines"
        [ "$dry" = "0" ] && kill -TERM "$pid" 2>/dev/null || true
    done
    jq -s --arg ts "$ts" '{killed_at:$ts,count:length,freed_kb:(map(.rss_kb)|add // 0),procs:.}' "$lines" > "$out"
    rm -f "$lines"
    n="$(jq -r '.count' "$out")"; freed="$(jq -r '.freed_kb' "$out")"
    if [ "$dry" = "1" ]; then
        echo "[mem-reclaim] DRY-RUN — would kill $n app(s), ~$((freed/1024))MB:"
        jq -r '.procs[] | "  \(.rss_kb/1024|floor)MB  pid=\(.pid)  \(.comm)  [\(.scope)]"' "$out"
        echo "[mem-reclaim] (preview $out — nothing killed)"
    else
        ln -sf "$out" "$LATEST"
        sleep "$TWAIT"
        jq -r '.procs[].pid' "$out" | while read -r p; do
            kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
        done
        echo "[mem-reclaim] killed $n app(s), freed ~$((freed/1024))MB → $out"
        echo "[mem-reclaim] 'mem-reclaim restore' relaunches them"
    fi
}

do_restore() {
    [ -e "$LATEST" ] || { echo "mem-reclaim: no killed record at $LATEST"; exit 1; }
    jq -r '.procs[] | [.cwd, .cmdline] | @tsv' "$LATEST" | while IFS="$(printf '\t')" read -r cwd cmd; do
        [ -n "$cmd" ] || continue
        ( cd "$cwd" 2>/dev/null || cd "$HOME"; setsid sh -c "$cmd" >/dev/null 2>&1 & )
        echo "[mem-restore] relaunched (cwd=$cwd): $cmd"
    done
}

case "${1:-kill}" in
    kill|"")           do_reclaim 0 ;;
    -n|--dry-run|dry)  do_reclaim 1 ;;
    restore)           do_restore ;;
    *) echo "usage: mem-reclaim [kill|--dry-run|restore]"; exit 1 ;;
esac
