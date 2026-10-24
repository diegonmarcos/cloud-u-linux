#!/usr/bin/env bash
# Tester (#1151): hooks/ai-usage-post.sh (installed as ~/.claude/claude-ai-usage-post.sh) posts Claude usage to
# c3-infra-api throttled, fire-and-forget, mesh first then public with a bearer that never reaches argv.
#   bash test-claude-ai-usage-post.sh
set -u
D="$(cd "$(dirname "$0")" && pwd)"
P="$D/../claude/cloud-marketplace/c3-infra/hooks/ai-usage-post.sh"
fail=0; n=0
ok()  { n=$((n+1)); }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL: $1" >&2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
# curl stub: logs argv (one line), the -K - stdin config, and the @file body; answers MESH_CODE for the mesh URL, 204 otherwise.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"; echo "ARGV $args" >> "$STUB_LOG"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
case " $args " in *" -K - "*) echo "STDIN $(cat)" >> "$STUB_LOG";; esac
for a in "$@"; do case "$a" in @*) echo "BODY $(cat "${a#@}")" >> "$STUB_LOG";; esac; done
case "$args" in *mesh.example*) printf '%s' "${MESH_CODE:-204}";; *) printf '204';; esac
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" STUB_LOG="$T/log" AI_USAGE_STATE="$T/state" AI_USAGE_SYNC=1 AI_USAGE_HOST=test-host
export C3_AI_USAGE_MESH_URL=https://mesh.example C3_AI_USAGE_URL=https://pub.example/c3-infra-api
unset C3_AI_USAGE_TOKEN C3_AI_USAGE_TOKEN_FILE AUTHELIA_TOKEN_URL AUTHELIA_OIDC_CLIENT_ID AUTHELIA_OIDC_CLIENT_SECRET
reset() { : > "$T/log"; rm -f "$T"/state/*; }
calls() { grep -c '^ARGV' "$T/log"; }

# 1 statusline: both windows, mesh first, body is exactly the validated numbers
reset; bash "$P" statusline 23.5 1738425600 41.2 1738857600 sess-1 >/dev/null 2>&1
[ "$(calls)" = 1 ] && ok || bad "mesh answered 2xx: exactly one call (got $(calls))"
grep -q 'ARGV .*https://mesh.example/ai/usage/claude' "$T/log" && ok || bad "mesh URL is the first leg"
grep -q 'BODY {"source":"statusline","host":"test-host","session_id":"sess-1","five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}' "$T/log" && ok || bad "body shape"

# 2 throttle: a second post inside the interval is dropped, outside it goes through
bash "$P" statusline 24 1738425600 41.2 1738857600 >/dev/null 2>&1
[ "$(calls)" = 1 ] && ok || bad "throttled within 60 s (calls=$(calls))"
AI_USAGE_MIN_INTERVAL=0 bash "$P" statusline 25 1738425600 41.2 1738857600 >/dev/null 2>&1
[ "$(calls)" = 2 ] && ok || bad "MIN_INTERVAL=0 posts again"
echo $(( $(date +%s) - 61 )) > "$T/state/claude-ai-usage-post.statusline.stamp"
bash "$P" statusline 26 1738425600 41.2 1738857600 >/dev/null 2>&1
[ "$(calls)" = 3 ] && ok || bad "an old stamp lets the next post through"

# 3 nothing to post, or hostile values: no call at all
reset
bash "$P" statusline "" "" "" "" >/dev/null 2>&1
bash "$P" statusline '1;"}' 1738425600 "" "" >/dev/null 2>&1
bash "$P" statusline 50 'x"y' "" "" >/dev/null 2>&1
[ "$(calls)" = 0 ] && ok || bad "empty / hostile values post nothing (calls=$(calls))"
reset; bash "$P" statusline 50 1738425600 '' '' 'a"b$(id)' >/dev/null 2>&1
grep -q 'BODY {"source":"statusline","host":"test-host","session_id":"a_b__id_",' "$T/log" && ok || bad "session id is sanitised"

# 4 mesh down -> public leg; the bearer is on stdin config, never in argv
reset; MESH_CODE=000 C3_AI_USAGE_TOKEN=ft_SECRET123 bash "$P" statusline 10 1738425600 20 1738857600 >/dev/null 2>&1
[ "$(calls)" = 2 ] && ok || bad "mesh down: mesh then public (calls=$(calls))"
grep -q 'ARGV .*https://pub.example/c3-infra-api/ai/usage/claude' "$T/log" && ok || bad "public URL on the second leg"
grep -q 'STDIN header = "Authorization: Bearer ft_SECRET123"' "$T/log" && ok || bad "bearer travels on the stdin config"
grep '^ARGV' "$T/log" | grep -q 'ft_SECRET123' && bad "the bearer leaked into argv" || ok
reset; MESH_CODE=000 bash "$P" statusline 10 1738425600 20 1738857600 >/dev/null 2>&1
[ "$(calls)" = 1 ] && ok || bad "no token: only the mesh leg is tried (calls=$(calls))"
printf 'ft_FILETOKEN\n' > "$T/tokfile"; reset
MESH_CODE=000 C3_AI_USAGE_TOKEN_FILE="$T/tokfile" bash "$P" statusline 10 1738425600 20 1738857600 >/dev/null 2>&1
grep -q 'STDIN header = "Authorization: Bearer ft_FILETOKEN"' "$T/log" && ok || bad "token file is read"

# 5 hook mode (cloud sessions): only StopFailure/rate_limit posts, as rate_limited
reset; printf '%s' '{"session_id":"abc123","hook_event_name":"StopFailure","error":"rate_limit"}' | bash "$P" >/dev/null 2>&1
grep -q 'BODY {"source":"cloud-hook","host":"test-host","session_id":"abc123","rate_limited":true}' "$T/log" && ok || bad "StopFailure rate_limit posts rate_limited"
reset; printf '%s' '{"hook_event_name":"StopFailure","error":"overloaded"}' | bash "$P" >/dev/null 2>&1
printf '%s' '{"hook_event_name":"Stop"}' | bash "$P" >/dev/null 2>&1
printf '%s' 'not json' | bash "$P" >/dev/null 2>&1
[ "$(calls)" = 0 ] && ok || bad "other events post nothing (calls=$(calls))"

# 6 never blocks: with a slow network the default (detached) mode returns at once, and always exits 0
reset; unset AI_USAGE_SYNC
s=$(date +%s%N); STUB_SLEEP=3 bash "$P" statusline 10 1738425600 "" "" >/dev/null 2>&1; rc=$?; e=$(date +%s%N)
[ "$rc" = 0 ] && [ $(( (e - s) / 1000000 )) -lt 1500 ] && ok || bad "detached: rc=$rc took $(( (e - s) / 1000000 )) ms"
export AI_USAGE_SYNC=1
PATH="/usr/bin:/bin" bash "$P" statusline 10 1738425600 "" "" >/dev/null 2>&1; [ $? = 0 ] && ok || bad "exit 0 even without curl on PATH"

# 7 wiring: the statusline refresher calls it; the engine embeds and installs it; the cloud hook is declared
grep -q 'claude-ai-usage-post.sh' "$D/statusline-command.sh" && ok || bad "statusline-command.sh does not call the poster"
grep -q 'claude-ai-usage-post.sh", include_str!("../../data/claude/cloud-marketplace/c3-infra/hooks/ai-usage-post.sh"), true' "$D/../../engines/statusline-assets/statusline_assets.rs" && ok || bad "statusline-assets does not embed the poster"
[ "$(jq -r '[.hooks.StopFailure[]?.hooks[]?.command] | map(select(test("ai-usage-post.sh"))) | length' "$D/../claude/settings.project.json")" = 1 ] && ok || bad "settings.project.json lacks the StopFailure hook"
[ -x "$P" ] && ok || bad "poster not executable"

echo "claude-ai-usage-post: $((n - fail)) passed, $fail failed"
[ "$fail" = 0 ]
