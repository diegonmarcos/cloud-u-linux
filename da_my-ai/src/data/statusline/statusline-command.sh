#!/usr/bin/env bash

input=$(cat)

# ── PAINT PATH: zero forks, zero renders ─────────────────────────────────────
# Everything below this block is the REFRESHER. A paint must not even run jq:
# with 10 sessions asking every second, one jq per paint is 10 processes/second
# before any real work starts. session_id is pulled out with bash pattern
# matching instead — no subshell, no pipe, no external command. A paint is then
# a read, a match, and a `cat`.
#
# The paint NEVER renders. It prints the last published line and, if that line
# is stale, starts a DETACHED refresh it does not wait for.
#
# A plain in-process time floor was not enough, and the reason matters: Claude
# Code kills a status line that takes too long. A cold render costs ~1.5s under
# load, so it was killed before it could write its cache; the next tick found no
# cache, rendered from scratch, and was killed too. Six sessions sat in that
# loop permanently — the tell was six sessions with a timestamp file and exactly
# ONE with cached output, 8-10 concurrent copies of this script, 465% of 8
# cores. A detached child is not killed with us, so the cache always lands.
#
# ponytail: 15s floor. That is what keeps N sessions cheap — refresher cost is
# N × render / interval, so 10 sessions cost ~1 core at 15s and ~3 at 5s.
STATUSLINE_MIN_INTERVAL="${STATUSLINE_MIN_INTERVAL:-15}"
if [ "${STATUSLINE_RENDER:-0}" != "1" ]; then
    _sid=""
    case "$input" in
        *'"session_id":"'*) _sid="${input#*\"session_id\":\"}"; _sid="${_sid%%\"*}" ;;
    esac
    if [ -z "$_sid" ]; then
        case "$input" in
            *'"transcript_path":"'*)
                _sid="${input#*\"transcript_path\":\"}"; _sid="${_sid%%\"*}"
                _sid="${_sid##*/}"; _sid="${_sid%.jsonl}" ;;
        esac
    fi
    _throttle="/tmp/statusline_out_${_sid:0:8}.cache"
    _stamp="$_throttle.key"

    printf -v _now '%(%s)T' -1          # bash builtin: no `date` fork
    _prev_at=0
    [ -f "$_stamp" ] && read -r _prev_at < "$_stamp" 2>/dev/null
    case "$_prev_at" in ""|*[!0-9]*) _prev_at=0;; esac

    if [ $(( _now - _prev_at )) -ge "$STATUSLINE_MIN_INTERVAL" ]; then
        # mkdir is the atomic test-and-set: exactly one refresher per session,
        # so a slow render can never stack up behind itself.
        if mkdir "$_throttle.lock" 2>/dev/null; then
            echo "$_now" > "$_stamp" 2>/dev/null
            printf '%s' "$input" > "$_throttle.in" 2>/dev/null
            (
                trap 'rmdir "$_throttle.lock" 2>/dev/null' EXIT
                STATUSLINE_RENDER=1 bash "$0" < "$_throttle.in" > "$_throttle.tmp" 2>/dev/null &&
                    mv -f "$_throttle.tmp" "$_throttle" 2>/dev/null
            ) </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null || true
        elif [ $(( _now - _prev_at )) -gt 120 ]; then
            # Refresher died without releasing the lock — reclaim it.
            rmdir "$_throttle.lock" 2>/dev/null || true
        fi
    fi
    # Whatever we have. Empty on the very first tick; populated a moment later.
    [ -s "$_throttle" ] && cat "$_throttle"
    exit 0
fi

# ── REFRESHER ONLY from here down ────────────────────────────────────────────
eval "$(echo "$input" | jq -r '
    @sh "cwd=\(.workspace.current_dir)",
    @sh "model_id=\(.model.id)",
    @sh "transcript_path=\(.transcript_path)",
    @sh "exceeds_200k=\(.exceeds_200k_tokens // false)",
    @sh "ctx_input=\(.context_window.total_input_tokens // 0)",
    @sh "ctx_output=\(.context_window.total_output_tokens // 0)",
    @sh "ctx_window=\(.context_window.context_window_size // 200000)",
    @sh "ctx_used_pct=\(.context_window.used_percentage // -1)",
    @sh "cu_new=\(.context_window.current_usage.input_tokens // 0)",
    @sh "cu_cwrite=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
    @sh "cu_cread=\(.context_window.current_usage.cache_read_input_tokens // 0)",
    @sh "cu_out=\(.context_window.current_usage.output_tokens // 0)",
    @sh "session_cost=\(.cost.total_cost_usd // 0)",
    @sh "session_id=\(.session_id // empty)",
    @sh "effort_level=\(.effort.level // empty)",
    @sh "session_name=\(.session_name // empty)",
    @sh "rl_5h=\(.rate_limits.five_hour.used_percentage // empty)",
    @sh "rl_7d=\(.rate_limits.seven_day.used_percentage // empty)"
')"

# Fallback session ID from transcript path
[ -z "$session_id" ] && session_id=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
session_short="${session_id:0:8}"

# Custom session name capped to 13 display chars (ellipsis when longer)
session_name_disp="$session_name"
[ "${#session_name_disp}" -gt 13 ] && session_name_disp="${session_name:0:12}…"

# Model name (strip claude- prefix and date suffix)
model_name=$(echo "$model_id" | sed -E 's/^claude-//; s/-([0-9]{8})$//')
[ -z "$model_name" ] && model_name="unknown"

# Context window — size is model-dependent (200K, or 1M extended-context).
# current_ctx = total input in the live window (new + cache-write + cache-read).
ctx_window_size=${ctx_window:-200000}
current_ctx=${ctx_input:-0}
settings_json="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$settings_json" ] && command -v jq >/dev/null 2>&1; then
    compact_win=$(jq -r '.autoCompactWindow // empty' "$settings_json" 2>/dev/null)
fi
[ -z "$compact_win" ] || [ "$compact_win" = "null" ] && compact_win=$((ctx_window_size * 95 / 100))
if [ "$current_ctx" -gt 0 ] && [ "$compact_win" -gt 0 ]; then
    ctx_percent=$((current_ctx * 100 / compact_win))
else
    ctx_percent=0
fi
case "$ctx_percent" in ""|*[!0-9]*) ctx_percent=0;; esac

# Context color
if [ "$exceeds_200k" = "true" ] || [ "$ctx_percent" -ge 95 ]; then
    ctx_color="31"
elif [ "$ctx_percent" -ge 50 ]; then
    ctx_color="33"
else
    ctx_color="32"
fi

# === Context Reset Detection ===
ctx_state_file="/tmp/statusline_ctx_state_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"
ctx_reset_file="/tmp/statusline_ctx_reset_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"

now_epoch=$(date +%s)
# fmt_age: seconds -> compact live string that ticks every refreshInterval.
fmt_age() { local s=${1:-0}; [ "$s" -lt 0 ] && s=0
    if [ "$s" -lt 60 ]; then echo "0m"
    elif [ "$s" -lt 3600 ]; then echo "$((s/60))m"
    else echo "$((s/3600))h$(((s%3600)/60))m"; fi; }
prev_ctx=0; prev_exceeds="false"; prev_epoch=$now_epoch
[ -f "$ctx_state_file" ] && read prev_ctx prev_exceeds prev_epoch < "$ctx_state_file" 2>/dev/null
[ -z "$prev_ctx" ] && prev_ctx=0
[ -z "$prev_exceeds" ] && prev_exceeds="false"
[ -z "$prev_epoch" ] && prev_epoch=$now_epoch

ctx_reset_detected="false"
if [ "$prev_ctx" -gt 50000 ] && [ "$current_ctx" -gt 0 ]; then
    [ "$current_ctx" -lt $((prev_ctx / 2)) ] && ctx_reset_detected="true"
fi
[ "$prev_exceeds" = "true" ] && [ "$exceeds_200k" = "false" ] && ctx_reset_detected="true"

[ "$ctx_reset_detected" = "true" ] && echo "$(date -Iseconds) $prev_ctx $current_ctx" >> "$ctx_reset_file"
# "last cache hit" = last render where the context changed (= last API response).
# Idle re-renders keep the same epoch, so the minutes-since grows while you sit.
if [ "$current_ctx" != "$prev_ctx" ]; then last_epoch=$now_epoch; else last_epoch=$prev_epoch; fi
secs_since=$(( now_epoch - last_epoch ))
echo "$current_ctx $exceeds_200k $last_epoch" > "$ctx_state_file"

last_reset_ts="never"
if [ -f "$ctx_reset_file" ]; then
    last_reset_line=$(tail -1 "$ctx_reset_file" 2>/dev/null)
    [ -n "$last_reset_line" ] && last_reset_ts=$(date -d "$(echo "$last_reset_line" | cut -d' ' -f1)" "+%m-%d %H:%M" 2>/dev/null || echo "?")
fi

# === EVERYTHING BELOW THAT DESCRIBES TOKEN USAGE COMES FROM ONE FILE ==========
# `my-ai usage --daemon` parses every transcript once (incrementally — it reads
# only appended bytes) and publishes the result. The status line looks its own
# session up and draws it. It never opens a transcript: that work is O(session
# length), and doing it here meant paying it per render, per session.
usage_json="${XDG_RUNTIME_DIR:-/tmp}/my-ai-usage.json"
# The daemon keys sessions on the transcript file stem, which is the session id.
sid="${session_id:-}"
[ -z "$sid" ] && sid=$(basename "$transcript_path" .jsonl 2>/dev/null)

# === Prompt/action age timers — time since this session's last `user` and last
# `assistant` record. The daemon tracks both timestamps (epoch ms); the age is
# just a subtraction here, so the timers still tick every refreshInterval.
# Cached against transcript size so an idle render is a stat, not a jq call.
age_cache="/tmp/statusline_age_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"
prompt_age="?"; action_age="?"
if [ -f "$transcript_path" ]; then
    tsize=$(stat -c %s "$transcript_path" 2>/dev/null || echo 0)
    c_size=""; last_user_ms=0; last_asst_ms=0
    [ -f "$age_cache" ] && read -r c_size last_user_ms last_asst_ms < "$age_cache" 2>/dev/null
    if [ "$tsize" != "$c_size" ] && [ -s "$usage_json" ]; then
        read -r last_user_ms last_asst_ms < <(
            jq -r --arg id "$sid" '(.sessions[$id] // {})
                | [ (.last_user_ms // 0), (.last_assistant_ms // 0) ] | @tsv' \
                "$usage_json" 2>/dev/null)
        echo "$tsize ${last_user_ms:-0} ${last_asst_ms:-0}" > "$age_cache"
    fi
    case "${last_user_ms:-0}" in ""|*[!0-9]*) last_user_ms=0;; esac
    case "${last_asst_ms:-0}" in ""|*[!0-9]*) last_asst_ms=0;; esac
    [ "$last_user_ms" -gt 0 ] && prompt_age=$(fmt_age $(( now_epoch - last_user_ms / 1000 )))
    [ "$last_asst_ms" -gt 0 ] && action_age=$(fmt_age $(( now_epoch - last_asst_ms / 1000 )))
fi

# === Cumulative session token totals — sum of every assistant message's
# usage{} across the WHOLE transcript, not the live-window snapshot that
# context_window.current_usage gives (that one resets/shrinks on compaction,
# badly undercounting Out — the most expensive token category). Cached
# READ FROM THE DAEMON, not computed here.
#
# `my-ai usage --daemon` already parses every transcript to build the 5h block;
# it publishes $XDG_RUNTIME_DIR/my-ai-usage.json with the numbers for every
# session. The status line's job is to DRAW, so this is one jq read of one file
# — no transcript parsing, no cache of its own, nothing that grows with session
# length. (This script used to re-slurp the whole 62 MB transcript per render
# with `jq -rs`: ~4.6 s CPU and ~140 MB jq heap per turn, per session, which at
# refreshInterval 1 drove load to 16. A second incremental scanner living here
# was still the wrong shape — same work, done per render, per session.)
#
#   .sessions[$id]       all-time totals for this session  -> LINE 4 block 3
#   .block_sessions[$id] THIS session inside the 5h window -> LINE 4c (5h-S)
#   .block               all projects  inside the 5h window -> LINE 4b (5h-T)
sum_in=0; sum_out=0; sum_cread=0; sum_cwrite=0
b_in=0; b_out=0; b_cread=0; b_cwrite=0; has_bs=0
if [ -s "$usage_json" ] && command -v jq >/dev/null 2>&1; then
    read -r sum_in sum_out sum_cread sum_cwrite b_in b_out b_cread b_cwrite has_bs < <(
        jq -r --arg id "$sid" '
            (.sessions[$id]       // {}) as $s |
            (.block_sessions[$id] // {}) as $b |
            [ ($s.input//0), ($s.output//0), ($s.cache_read//0), ($s.cache_write//0),
              ($b.input//0), ($b.output//0), ($b.cache_read//0), ($b.cache_write//0),
              (if (.block_sessions[$id]) then 1 else 0 end) ] | @tsv' \
            "$usage_json" 2>/dev/null)
    [ -z "${sum_in:-}" ] && { sum_in=0; sum_out=0; sum_cread=0; sum_cwrite=0; }
    [ -z "${has_bs:-}" ] && has_bs=0
fi

# Cost color
cost_cents=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", ${session_cost:-0} * 100}")
[ -z "$cost_cents" ] && cost_cents=0
if [ "$cost_cents" -ge 1000 ]; then
    cost_color="31"
elif [ "$cost_cents" -ge 500 ]; then
    cost_color="33"
else
    cost_color="32"
fi

# MCP server count
mcp_configured=0
[ -f "$HOME/.mcp.json" ] && { n=$(jq '.mcpServers // {} | keys | length' "$HOME/.mcp.json" 2>/dev/null); [ -n "$n" ] && mcp_configured=$((mcp_configured + n)); }
[ -f "${cwd}/.mcp.json" ] && { n=$(jq '.mcpServers // {} | keys | length' "${cwd}/.mcp.json" 2>/dev/null); [ -n "$n" ] && mcp_configured=$((mcp_configured + n)); }
[ "$mcp_configured" -gt 0 ] && mcp_color="32" || mcp_color="90"

# Subagent (.md) count — user (~/.claude/agents) + plugin-provided agent defs.
# Mirrors the MCP count above (README.md is the dir's index, not an agent).
agents_configured=$(find "$HOME/.claude/agents" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l)
n=$(find "$HOME/.claude/plugins/cache" -path '*/agents/*.md' 2>/dev/null | wc -l)
agents_configured=$((agents_configured + n))
[ "$agents_configured" -gt 0 ] && agents_color="32" || agents_color="90"

# Per-MCP online/offline icons (lazy 15-min cache), Full/Lean context-profile
# indicator, and PL[ Skl[...] Rul[...] Sys[...] ] — Skl/Sys from the plugins
# helper, Rul (per-plugin rule counts) from the hooks helper, interleaved so
# Rul lands between the two plugin buckets as designed.
# All helpers emit literal \033 escapes; the final `printf %b` renders them.
#
# These five are properties of the MACHINE, not of a session: every session
# produced the identical five strings by spawning five shell scripts (~0.43s per
# render). At ten sessions that was fifty processes a second for five strings
# that are the same for all of them. The daemon runs them once per interval and
# publishes the output under .blocks, so this is one jq read of a file.
# Falls back to spawning only if no daemon has published yet.
mcp_seg=""; flags_seg=""; skl_seg=""; sys_seg=""; rul_seg=""
if [ -s "$usage_json" ]; then
    # One line per field. These strings contain spaces, tabs and \033 escapes,
    # so they must not be word-split — `IFS= read -r` per line, not one read
    # across a delimiter.
    { IFS= read -r mcp_seg; IFS= read -r flags_seg; IFS= read -r skl_seg
      IFS= read -r sys_seg; IFS= read -r rul_seg; } < <(
        jq -r '(.blocks // {}) | (.mcp//""), (.flags//""), (.skl//""), (.sys//""), (.rul//"")' \
            "$usage_json" 2>/dev/null)
fi
if [ -z "$mcp_seg" ]; then
    mcp_seg=$(bash "$HOME/.claude/claude-mcp-status.sh" "$cwd" 2>/dev/null)
    flags_seg=$(bash "$HOME/.claude/claude-flags-status.sh" --format ansi 2>/dev/null)
    skl_seg=$(bash "$HOME/.claude/claude-plugins-status.sh" --part skl --format ansi 2>/dev/null)
    sys_seg=$(bash "$HOME/.claude/claude-plugins-status.sh" --part sys --format ansi 2>/dev/null)
    rul_seg=$(bash "$HOME/.claude/claude-hooks-status.sh" --format ansi 2>/dev/null)
fi
plugins_seg="PL[ ${skl_seg}${skl_seg:+ }${rul_seg}${rul_seg:+ }${sys_seg} ]"

# user@host (date removed from LINE 1 per 2026-06-25 layout change)
user_host="$(whoami)@$(hostname -s)"

# Format token count (K/M)
fmt_tok() {
    local t=$1
    if [ "$t" -ge 1000000 ]; then echo "$((t / 1000000))M"
    elif [ "$t" -ge 1000 ]; then echo "$((t / 1000))K"
    else echo "$t"; fi
}

# Color by percentage threshold
get_color() {
    local p=$1
    if [ "$p" = "N/A" ]; then echo "90"
    elif [ "$p" -ge 80 ]; then echo "31"
    elif [ "$p" -ge 50 ]; then echo "33"
    else echo "32"; fi
}

# === Git info — repo name + branch for LINE 1 (cheap: ONE `git rev-parse`) ===
# Re-enabled 2026-06-25 for the "repo/folder @ branch" display. The 2026-04-28
# disable was about a 9-fork block — esp. `ls-files --others` walking rust
# target/ (~100k files) ×parallel sessions = ~9% of a core 24/7. This does ONE
# rev-parse (branch + toplevel, no tree walk, no status), cached 10s per cwd →
# negligible. To restore dirty/ahead/behind/stash icons, swap in the
# `git status -b --porcelain=v1` one-forker (see git history).
git_repo=""; git_branch=""
if command -v git >/dev/null 2>&1; then
    git_cache="/tmp/statusline_git_$(printf '%s' "$cwd" | md5sum | cut -c1-8).cache"
    git_cache_age=$(( $(date +%s) - $(stat -c %Y "$git_cache" 2>/dev/null || echo 0) ))
    if [ -f "$git_cache" ] && [ "$git_cache_age" -lt 10 ]; then
        IFS='|' read -r git_repo git_branch < "$git_cache" 2>/dev/null
    else
        # one fork: line 1 = branch (or "HEAD" when detached), line 2 = repo root
        git_info=$(git -C "$cwd" rev-parse --abbrev-ref HEAD --show-toplevel 2>/dev/null)
        if [ -n "$git_info" ]; then
            git_branch=$(printf '%s\n' "$git_info" | sed -n 1p)
            git_repo=$(basename "$(printf '%s\n' "$git_info" | sed -n 2p)")
        fi
        printf '%s|%s\n' "$git_repo" "$git_branch" > "$git_cache"
    fi
fi

# === Async system metrics — all slow commands run in parallel ===
_async="/tmp/statusline_async_$$"
mkdir -p "$_async"

# RAM + Disk (instant)
mem_info=$(free | grep Mem)
mem_total=$(echo "$mem_info" | awk '{print $2}')
mem_used=$(echo "$mem_info" | awk '{print $3}')
mem_percent=$(awk "BEGIN {printf \"%.0f\", ($mem_used/$mem_total)*100}")

if [ -d "/data/data/com.termux.nix" ]; then
    disk_percent=$(df /data | tail -n 1 | awk '{print $5}' | sed 's/%//')
else
    disk_percent=$(df / | tail -n 1 | awk '{print $5}' | sed 's/%//')
fi

# Find ip command once
IP_CMD=""
for p in /sbin/ip /usr/sbin/ip /bin/ip $HOME/.nix-profile/bin/ip /run/current-system/sw/bin/ip; do
    [ -x "$p" ] && IP_CMD="$p" && break
done

# --- Background: CPU (100ms) ---
(
    cpu=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f", (($2+$4-u1) * 100 / (t-t1))}' <(grep 'cpu ' /proc/stat) <(sleep 0.1; grep 'cpu ' /proc/stat))
    echo "${cpu:-0}" > "$_async/cpu"
) &

# === Expensive probes — STUBBED (mirrors termux statusline) ===
# Reason this is the desktop default: the mesh-status + public-IP curls fired
# on EVERY status render (external network calls per refresh), and VRAM via
# nvidia-smi is wasted on the Surface's Intel iGPU. The private-IP probe forks
# `ip route get` + reads /proc/net/fib_trie every render despite barely
# changing. Static stubs preserve the rendering contract; vars below are read
# by the render block unchanged. To make any of these live, replace the
# matching stub with its probe (restore from git history).
echo "N/A" > "$_async/vram"
# --- Background: WireGuard mesh probe (re-enabled 2026-06-25) ---
# Root-free, NO network: per WG interface, just admin-up state + address via `ip`
# (handshakes need root). The 2026-04 disable was about EXTERNAL public-IP / mesh
# curls firing per render — those stay gone. Interfaces are DATA-DRIVEN from
# `wg show interfaces`, so wg0 + wg-public (and any future wg iface) are covered.
(
    seg=""
    if command -v wg >/dev/null 2>&1; then
        for wif in $(wg show interfaces 2>/dev/null); do
            if ${IP_CMD:-ip} -o link show "$wif" 2>/dev/null | grep -qE "[<,]UP[,>]"; then
                wip=$(${IP_CMD:-ip} -4 -o addr show "$wif" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
                seg="$seg ${wif}:up:${wip:-?}"
            else
                seg="$seg ${wif}:down"
            fi
        done
    fi
    echo "${seg# }" > "$_async/mesh"
) &

# Wait for the only remaining background job (CPU sample, bounded by sleep 0.1)
wait 2>/dev/null

# Read async results
cpu_percent=$(cat "$_async/cpu" 2>/dev/null); [ -z "$cpu_percent" ] && cpu_percent=0
vram_percent=$(cat "$_async/vram" 2>/dev/null); [ -z "$vram_percent" ] && vram_percent="N/A"
mesh_seg=$(cat "$_async/mesh" 2>/dev/null)   # "wg0:up:10.0.0.5 wg-public:up:10.1.0.5"
rm -rf "$_async"

# CPU pressure-stall (PSI) — "some avg10" = % of time ANY task was stalled
# waiting on CPU in the last 10s. Distinct from CPU:% (raw utilization):
# PSI stays low under a busy-but-not-contended box, spikes under real
# scheduling pressure. Linux-only; absent on the termux/Android kernel.
cpu_psi="N/A"
if [ -r /proc/pressure/cpu ]; then
    cpu_psi=$(awk -F'avg10=' '/^some/{split($2,a," "); printf "%.0f", a[1]}' /proc/pressure/cpu 2>/dev/null)
    [ -z "$cpu_psi" ] && cpu_psi="N/A"
fi

# Colors
mem_color=$(get_color "$mem_percent")
cpu_color=$(get_color "$cpu_percent")
disk_color=$(get_color "$disk_percent")
vram_color=$(get_color "$vram_percent")
psi_color=$(get_color "$cpu_psi")

# Battery — instant sysfs read (no fork). BAT* = laptop, battery = fallback.
# Low %% is bad, so this is colored inverse of the load metrics above.
bat_percent="N/A"; bat_color="90"
for _b in /sys/class/power_supply/BAT*/capacity /sys/class/power_supply/battery/capacity; do
    [ -r "$_b" ] && { bat_percent=$(cat "$_b" 2>/dev/null); break; }
done
case "$bat_percent" in
    ""|*[!0-9]*) bat_percent="N/A"; bat_color="90" ;;
    *) if [ "$bat_percent" -le 15 ]; then bat_color="31"
       elif [ "$bat_percent" -le 40 ]; then bat_color="33"
       else bat_color="32"; fi ;;
esac

# === BUILD OUTPUT ===
OUT=""

# LINE 1: | model@effort | session@name | user@OS | folder@branch |
OUT+="\033[37m|\033[0m"
# model @ effort  (effort omitted when the model doesn't support the param)
OUT+=" \033[35m${model_name}\033[0m"
[ -n "$effort_level" ] && OUT+=" \033[90m@\033[0m \033[36m${effort_level}\033[0m"
# session id @ name  (name omitted when no /rename or --name set)
OUT+=" \033[37m|\033[0m"
OUT+=" \033[90m${session_short}\033[0m"
[ -n "$session_name" ] && OUT+=" \033[90m@\033[0m \033[37m${session_name_disp}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[36m${user_host}\033[0m"
# folder@branch cell (collapse repo/folder when folder == repo root, or no repo)
OUT+=" \033[37m|\033[0m"
folder=$(basename "$cwd")
if [ -n "$git_repo" ] && [ "$git_repo" != "$folder" ]; then
    OUT+=" \033[34m${git_repo}/${folder}\033[0m"
else
    OUT+=" \033[34m${folder}\033[0m"
fi
[ -n "$git_branch" ] && OUT+=" \033[90m@\033[0m \033[33m${git_branch}\033[0m"
OUT+=" \033[37m|\033[0m\n"

# LINE 2: | MCP[...] | Flags[Full vs Lean] |
OUT+="\033[37m|\033[0m"
if [ -n "$mcp_seg" ]; then OUT+=" ${mcp_seg}"; else OUT+=" \033[${mcp_color}mMCP:${mcp_configured}\033[0m"; fi
[ -n "$flags_seg" ] && OUT+=" \033[37m|\033[0m ${flags_seg}"
OUT+=" \033[37m|\033[0m\n"

# LINE 3 — PL[ Skl[...] Rul[...] Sys[...] ] (self-omitting when all buckets empty)
[ -n "$skl_seg$rul_seg$sys_seg" ] && OUT+=" \033[37m|\033[0m ${plugins_seg}\n"

# LINE 4 — ONE line, three blocks separated by │ (per spec):
#   <datetime> │ Tok In Cache Out Σ │ $ In Out Cache Σ │ Ctx:used/win(%) Cache:hit% <idle>m
# Tokens = LIVE context window (context_window.current_usage) from stdin (spawn-free).
# $ = THIS turn = tokens/1e6 × per-MTok price from claude-pricing.json (data-driven).
PRICING="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-pricing.json"
p_in=15; p_out=75; p_cr=1.50; p_cw=18.75            # fallback (Opus) if JSON/jq absent
if command -v jq >/dev/null 2>&1 && [ -f "$PRICING" ]; then
    read p_in p_out p_cr p_cw < <(jq -r --arg m "$model_id" '
        . as $root
        | (($root.models | to_entries
            | map(select(.key as $k | ($m | startswith($k))))
            | sort_by(.key | length) | last | .value) // $root.default)
        | "\(.input) \(.output) \(.cache_read) \(.cache_write)"' "$PRICING" 2>/dev/null)
    [ -z "$p_in" ] && { p_in=15; p_out=75; p_cr=1.50; p_cw=18.75; }
fi

# token counts — cumulative session totals (sum_in/out/cread/cwrite, see the
# transcript scan above), not the live context-window snapshot. New/CchW/
# CchR/Out are kept as four distinct fields, not folded into one Cch bucket:
# New (input_tokens) is nearly always ~0 once caching is on — your actual
# new content each turn goes into CchW (cache_creation), not New. Folding
# CchW into "Cch" alongside CchR made New look like "your input" when it's
# really "content that bypassed caching entirely" (rare).
new_fmt=$(fmt_tok "${sum_in:-0}")
cwrite_fmt=$(fmt_tok "${sum_cwrite:-0}")
cread_fmt=$(fmt_tok "${sum_cread:-0}")
cache_tok=$(( ${sum_cread:-0} + ${sum_cwrite:-0} ))
out_fmt=$(fmt_tok "${sum_out:-0}")
sum_tok=$(( ${sum_in:-0} + cache_tok + ${sum_out:-0} ))
sum_fmt=$(fmt_tok "$sum_tok")
win_fmt=$(fmt_tok "$compact_win")
ctx_fmt=$(fmt_tok "$current_ctx")

# per-category $ for the WHOLE SESSION (sum_* from the cumulative transcript
# scan above) — actual USD. Two bugs fixed here: (1) was mistakenly *100'd as
# if for a ¢ display, then relabeled $ without removing the scale factor: a
# 141K-tok cache read at $1.50/MTok read as "$22" instead of the real $0.21;
# (2) was sourced from context_window.current_usage, a live-window snapshot
# that shrinks on compaction — badly undercounting Out, the priciest category.
read d_in d_out d_cwrite d_cread d_tot < <(LC_NUMERIC=C awk \
    -v n="${sum_in:-0}" -v o="${sum_out:-0}" -v cr="${sum_cread:-0}" -v cw="${sum_cwrite:-0}" \
    -v pi="$p_in" -v po="$p_out" -v pcr="$p_cr" -v pcw="$p_cw" \
    'BEGIN{di=n/1e6*pi; dou=o/1e6*po; dcw=cw/1e6*pcw; dcr=cr/1e6*pcr; printf "%.2f %.2f %.2f %.2f %.2f", di, dou, dcw, dcr, di+dou+dcw+dcr}')

# cache hit rate + colors
total_in=$(( ${cu_new:-0} + cache_tok ))
if [ "$total_in" -gt 0 ]; then cache_hit=$(( ${cu_cread:-0} * 100 / total_in )); else cache_hit=0; fi
if [ "$cache_hit" -ge 80 ]; then cache_color="32"; elif [ "$cache_hit" -ge 40 ]; then cache_color="33"; else cache_color="90"; fi
if [ "$exceeds_200k" = "true" ] && [ "$ctx_window_size" -le 200000 ]; then pct_color="31"
elif [ "$ctx_percent" -ge 90 ]; then pct_color="31"; elif [ "$ctx_percent" -ge 50 ]; then pct_color="33"; else pct_color="32"; fi

# Block 1: Ctx% (quick tag, same value as the full Ctx:used/win(%) at the end)
# + rate limits — omitted when the field is absent from stdin.
OUT+="\033[37m|\033[0m"
OUT+=" \033[${pct_color}mCtx:${ctx_percent}%\033[0m"
if [ -n "$rl_5h" ] || [ -n "$rl_7d" ]; then
    rl_5h_disp="${rl_5h%.*}"; [ -z "$rl_5h_disp" ] && rl_5h_disp="N/A"
    rl_7d_disp="${rl_7d%.*}"; [ -z "$rl_7d_disp" ] && rl_7d_disp="N/A"
    OUT+=" \033[$(get_color "$rl_5h_disp")m5h:${rl_5h_disp}%\033[0m"
    OUT+=" \033[$(get_color "$rl_7d_disp")m7d:${rl_7d_disp}%\033[0m"
fi
# Block 2: cache hit % + idle ages
OUT+=" \033[37m│\033[0m"
OUT+=" \033[${cache_color}mCch:${cache_hit}%\033[0m"
OUT+=" \033[90mUsr:${prompt_age}\033[0m"
OUT+=" \033[90mAgt:${action_age}\033[0m"
# Block 3: full context window detail. The token/cost breakdown that used to sit
# here moved to its own `All-S` row below, so the three usage scopes read as a
# stack of directly comparable rows instead of one being buried in this line.
OUT+=" \033[37m│\033[0m"
OUT+=" \033[${pct_color}mCtx:${ctx_fmt}/${win_fmt}(${ctx_percent}%)\033[0m"
OUT+="\n"

# LINE 4a — All-S: this session id, ALL TIME (not capped to the 5h window).
# Same fields in the same order as the 5h-T / 5h-S rows beneath it, so the three
# scopes stack: all-time this session, 5h all sessions, 5h this session.
# New/CchW/CchR/Out stay four separate fields rather than one folded "Cch"
# bucket — New (input_tokens) is near-zero once caching is on, so folding CchW
# in with CchR made New look like "your input" when it is really "content that
# bypassed caching entirely".
# Σ leads each row: it is the number being compared across the three scopes, so
# it sits at a fixed left position instead of at the end of a variable-width
# list. Labels are padded to 5 chars (All-S / 05h-T / 05h-S) so the brackets and
# the totals line up vertically.
OUT+="\033[37m|\033[0m All-S \033[37m[\033[0m"
OUT+=" \033[1m\033[${cost_color}mΣ${sum_fmt}(\$${d_tot})\033[0m"
OUT+=" \033[36mNew:${new_fmt}(\$${d_in})\033[0m"
OUT+=" \033[33mCchW:${cwrite_fmt}(\$${d_cwrite})\033[0m"
OUT+=" \033[34mCchR:${cread_fmt}(\$${d_cread})\033[0m"
OUT+=" \033[36mOut:${out_fmt}(\$${d_out})\033[0m"
OUT+=" \033[37m]\033[0m\n"

# LINE 4b — 5h billing-window token/cost breakdown, ccusage-backed (see
# claude-usage-status.sh). Companion to LINE 4's per-SESSION breakdown, same
# New/CchW/CchR/Out/Σ shape, summed over the active 5h block across ALL
# projects. Self-cached/detached-refresh, so cheap on the hot path; emits
# nothing when idle or ccusage/jq unavailable — row is simply omitted.
# The ONLY source is the my-ai daemon's published segment: a plain file read, no
# process at all. The old `claude-usage-status.sh` fallback is deliberately gone
# — on a cache miss it paid an `npx ccusage` Node start ON THE PAINT PATH, which
# is exactly the shape that OOM-killed plasmashell. Daemon down => no row.
# ponytail: no fallback by design; the producer is the fix, not a second reader.
_seg="${XDG_RUNTIME_DIR:-/tmp}/my-ai-usage.seg"
if [ -s "$_seg" ]; then
    usage_seg=$(cat "$_seg" 2>/dev/null)
    [ -n "$usage_seg" ] && OUT+="\033[37m|\033[0m ${usage_seg}\n"
fi

# LINE 4c — 5h-S: the same fields as 5h-T above, for THIS session, inside the
# SAME 5h window. It must be window-scoped, not session-cumulative: a session
# that has run for days would otherwise print totals far LARGER than the 5h-T
# line directly above it, which reads as a bug. The daemon does that windowing
# (.block_sessions), so this row is a lookup, not a computation. Omitted when
# this session has no usage in the active block.
if [ "${has_bs:-0}" = "1" ]; then
    b_cache=$(( b_cread + b_cwrite ))
    b_total=$(( b_in + b_cache + b_out ))
    read s_in s_out s_cwrite s_cread s_tot < <(LC_NUMERIC=C awk \
        -v n="$b_in" -v o="$b_out" -v cr="$b_cread" -v cw="$b_cwrite" \
        -v pi="$p_in" -v po="$p_out" -v pcr="$p_cr" -v pcw="$p_cw" \
        'BEGIN{di=n/1e6*pi; dou=o/1e6*po; dcw=cw/1e6*pcw; dcr=cr/1e6*pcr; printf "%.2f %.2f %.2f %.2f %.2f", di, dou, dcw, dcr, di+dou+dcw+dcr}')
    OUT+="\033[37m|\033[0m 05h-S \033[37m[\033[0m"
    OUT+=" \033[1mΣ$(fmt_tok "$b_total")(\$${s_tot})\033[0m"
    OUT+=" \033[36mNew:$(fmt_tok "$b_in")(\$${s_in})\033[0m"
    OUT+=" \033[33mCchW:$(fmt_tok "$b_cwrite")(\$${s_cwrite})\033[0m"
    OUT+=" \033[34mCchR:$(fmt_tok "$b_cread")(\$${s_cread})\033[0m"
    OUT+=" \033[36mOut:$(fmt_tok "$b_out")(\$${s_out})\033[0m"
    OUT+=" \033[37m]\033[0m\n"
fi

# LINE 5: | CPUPSI CPU | RAM Disk VRAM | Battery | Mesh ●wg0:ip ●wg-public:ip |
OUT+="\033[37m|\033[0m"
OUT+=" \033[${psi_color}mCPUPSI:${cpu_psi}%\033[0m"
OUT+=" \033[${cpu_color}mCPU:${cpu_percent}%\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[${mem_color}mRAM:${mem_percent}%\033[0m"
OUT+=" \033[${disk_color}mDisk:${disk_percent}%\033[0m"
OUT+=" \033[${vram_color}mVRAM:${vram_percent}%\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[${bat_color}mBattery:${bat_percent}%\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[1;37mMesh\033[0m"
if [ -n "$mesh_seg" ]; then
    for tok in $mesh_seg; do
        wif=${tok%%:*}; rest=${tok#*:}
        if [ "${rest%%:*}" = "up" ]; then
            OUT+=" \033[32m●\033[0m\033[36m${wif}:${rest#up:}\033[0m"
        else
            OUT+=" \033[31m○${wif}\033[0m"
        fi
    done
else
    OUT+=" \033[90m—\033[0m"
fi
OUT+=" \033[37m|\033[0m\n"

# Only ever reached as the detached refresher (STATUSLINE_RENDER=1); the caller
# redirects this into the cache and renames it into place atomically.
printf "%b" "$OUT"
