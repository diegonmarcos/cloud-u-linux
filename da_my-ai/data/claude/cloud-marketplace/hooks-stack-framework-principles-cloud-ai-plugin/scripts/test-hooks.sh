#!/usr/bin/env bash
# ============================================================================
# test-hooks.sh — proves hook-engine.sh against the fixtures in hooks-rules.json.
# MUST be fully green before deploy: it is the behavior-preservation contract.
# Run: bash test-hooks.sh
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/hook-engine.sh"
RULES="$HERE/hooks-rules.json"
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }

# Run guard in a clean dir so file-existence carve-outs are deterministic.
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

guard() { # $1=command → sets G_EXIT, G_ERR
    G_ERR="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
        | (cd "$SANDBOX" && bash "$ENGINE" guard) 2>&1 >/dev/null)"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
        | (cd "$SANDBOX" && bash "$ENGINE" guard) >/dev/null 2>&1
    G_EXIT=$?
}

echo "## per-rule fixtures ##"
while IFS=$'\t' read -r level kind samp_b; do
    samp="$(b64d "$samp_b")"
    guard "$samp"
    case "$level:$kind" in
      deny:trigger)
        [ "$G_EXIT" = 2 ] && ok || bad "deny should BLOCK (exit2, got $G_EXIT): $samp" ;;
      deny:pass)
        [ "$G_EXIT" = 0 ] && ok || bad "deny pass should allow (exit0, got $G_EXIT): $samp" ;;
      warn:trigger)
        if [ "$G_EXIT" = 0 ] && printf '%s' "$G_ERR" | grep -q WARNING; then ok
        else bad "warn should warn (exit0+WARNING, got $G_EXIT/$G_ERR): $samp"; fi ;;
      warn:pass)
        if [ "$G_EXIT" = 0 ] && ! printf '%s' "$G_ERR" | grep -qE 'WARNING|BLOCKED'; then ok
        else bad "warn pass should be silent (got $G_EXIT/$G_ERR): $samp"; fi ;;
      allow:pass)
        if [ "$G_EXIT" = 0 ] && ! printf '%s' "$G_ERR" | grep -qE 'WARNING|BLOCKED'; then ok
        else bad "allow should be silent exit0 (got $G_EXIT/$G_ERR): $samp"; fi ;;
    esac
done < <(jq -r '
    .rules[] | . as $r
    | ( (($r.tests.deny  // [])[]? | [$r.level,"trigger",(.|@base64)])
      , (($r.tests.allow // [])[]? | [$r.level,"pass",   (.|@base64)]) )
    | @tsv' "$RULES")

echo "## fail-closed: missing registry ⇒ deny ##"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | HOOK_RULES_FILE=/nonexistent.json bash "$ENGINE" guard >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "fail-closed: missing registry did NOT deny"

echo "## inject: SessionStart non-empty, PreToolUse valid JSON ##"
out="$(printf '{}' | bash "$ENGINE" inject SessionStart)"
[ -n "$out" ] && printf '%s' "$out" | grep -q 'CORE PRINCIPLES' && ok || bad "inject SessionStart empty/missing principles"
out="$(printf '{}' | bash "$ENGINE" inject PreToolUse)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext|length>0' >/dev/null 2>&1 && ok || bad "inject PreToolUse not valid JSON additionalContext"
out="$(printf '{}' | bash "$ENGINE" inject UserPromptSubmit)"
printf '%s' "$out" | grep -q 'PRINCIPLES' && ok || bad "inject UserPromptSubmit missing one-line PRINCIPLES pointer"

echo "## nudge: 5th read fires, mcp resets ##"
SID="t-$$"; ST="${TMPDIR:-/tmp}/claude-graph-nudge-$SID"; rm -f "$ST"
nfire() { printf '{"tool_name":"%s","session_id":"%s"}' "$1" "$SID" | bash "$ENGINE" nudge 2>/dev/null; }
for i in 1 2 3 4; do
    [ -z "$(nfire Read | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)" ] && ok || bad "nudge fired early on read $i"
done
[ -n "$(nfire Read | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)" ] && ok || bad "nudge did not fire on 5th read"
nfire Read >/dev/null; nfire Read >/dev/null
nfire mcp__cloud-cgc-pub-mcp__cgc_octocode_search >/dev/null
[ -z "$(nfire Read | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)" ] && ok || bad "nudge not reset by cloud-cgc call"
rm -f "$ST"

echo "## CLAUDE.md stub: no duplication, plugin owns all injected content ##"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    sz=$(wc -c < "$CLAUDE_MD" 2>/dev/null || echo 999999)
    [ "$sz" -le 10 ] && ok || bad "~/.claude/CLAUDE.md should be a ~1-char stub (got ${sz} bytes) — content belongs in hooks-fragments/*.md, not duplicated here"
else
    echo "  (~/.claude/CLAUDE.md not deployed on this host — skipping)"
fi

echo "## SessionStart injection budget: <=5k tokens (~20k chars, 4 chars/tok heuristic) ##"
sso="$(printf '{}' | bash "$ENGINE" inject SessionStart)"
sso_chars=${#sso}
sso_budget=20000
[ "$sso_chars" -le "$sso_budget" ] && ok \
    || bad "SessionStart injection is ${sso_chars} chars (budget ${sso_budget} ~= 5k tokens) — trim hooks-fragments/*.md"

echo "## doc drift: gen-hooks-doc.sh == HOOKS.md ##"
if [ -f "$HERE/HOOKS.md" ]; then
    if diff -q <(bash "$HERE/gen-hooks-doc.sh") "$HERE/HOOKS.md" >/dev/null 2>&1; then ok
    else bad "HOOKS.md is stale — run: bash gen-hooks-doc.sh > HOOKS.md"; fi
else
    echo "  (HOOKS.md not generated yet — skipping drift check)"
fi

echo "## every mcp__ reference names a server in the generated MCP list ##"
# The one assertion here that keeps catching this class of bug rather than the
# single instance of it. The server list is DERIVED, not hand-kept: the service
# declarations feed cloud-infra/1_cloud-configs/src/derive/derive-mcp-json.ts ->
# dist/mcp.json -> gen-mcp-tpl.sh -> the mcp.*.json.tpl files sitting beside this
# marketplace. Comparing against that is what would have caught the split of
# cloud-cgc-mcp into cloud-cgc-pub-mcp/cloud-cgc-pvt-mcp the day it happened; the
# dead name matched no tool, raised no error, and simply stopped hooking.
#
# A reference is legitimately either a full tool name (mcp__<server>__<tool>) or a
# bare server PREFIX (mcp__cloud-cgc, which spans both cgc servers on purpose), so
# a reference passes when its server part is a prefix of at least one known name.
#
# A failure naming a server that IS live but is keyed differently in some other
# client list is a TRUE positive, not a gap in this check. It used to happen with
# the container list, which was hand-written and keyed the same servers
# cloud-infra / cloud-services / mattermost; that list is now generated too (see
# the assertion below), so every list keys a server exactly one way. Fix a drift,
# never widen this check to hide it.
SOT_DIR="$(cd "$HERE/../../.." 2>/dev/null && pwd)"
known=""
for tpl in "$SOT_DIR/mcp.termux.json.tpl" "$SOT_DIR/mcp.desktop.json.tpl"; do
    [ -f "$tpl" ] || continue
    known="$known$(jq -r '.mcpServers|keys[]' "$tpl" 2>/dev/null)
"
done
known="$(printf '%s' "$known" | grep -v '^$' | sort -u)"
if [ -n "$known" ]; then
    unknown=""
    for ref in $(grep -rhoE 'mcp__[A-Za-z0-9_-]+' "$HERE/../.." | sed -e 's/^mcp__//' -e 's/__.*//' | sort -u); do
        printf '%s\n' "$known" | grep -q -- "^$ref" || unknown="$unknown $ref"
    done
    if [ -z "$unknown" ]; then ok
    else bad "mcp__ reference(s) name no server in the generated list:$unknown (known: $(printf '%s' "$known" | tr '\n' ' '))"; fi
else
    echo "  (mcp.*.json.tpl not beside this marketplace — skipping)"
fi

echo "## every client MCP list carries the same servers, modulo declared overrides ##"
# The complement of the assertion above. That one asks whether an mcp__ name in
# this marketplace matches SOME live server; this one asks whether every client
# gets the same servers in the first place. The container list failed only the
# second question and it was the expensive failure: it named seven servers where
# the canonical set has eleven, so every headless agent was ordered by these very
# hooks to consult the PRIVATE code graph over a server its client had never been
# offered. Nothing errored — an unoffered server is indistinguishable from a tool
# the model simply did not reach for — so agents grepped and guessed for weeks.
#
# Compared on the axis that goes stale: which servers exist, where they point,
# and how they are reached. Headers are excluded because they are the ONE thing a
# platform is allowed to differ on, and only by declaring auth_header in
# mcp-policy.json — a difference nobody declared would show up as a different url
# or a missing key, which this does catch. A platform whose list lives outside
# this repository is skipped when that checkout is absent (cloud-infra's
# lint-pipeline clones only cloud-u-linux); its own repo asserts the same
# equality from the other side.
POLICY="$SOT_DIR/mcp-policy.json"
AXIS='.mcpServers | with_entries(.value |= {type: (.type // "http"), url: .url})'
if [ -f "$POLICY" ] && [ -f "$SOT_DIR/mcp.desktop.json.tpl" ]; then
    want="$(jq -S "$AXIS" "$SOT_DIR/mcp.desktop.json.tpl")"
    for plat in $(jq -r '.platforms | keys[]' "$POLICY"); do
        out="$(jq -r --arg p "$plat" '.platforms[$p].output // ""' "$POLICY")"
        if [ -n "$out" ]; then
            list="${GIT_BASE:-$HOME/git}/$out"
        else
            list="$SOT_DIR/mcp.$plat.json.tpl"
        fi
        if [ ! -f "$list" ]; then
            echo "  ($plat list not present at $list — skipping)"
            continue
        fi
        got="$(jq -S "$AXIS" "$list" 2>/dev/null || echo '"UNREADABLE"')"
        if [ "$got" = "$want" ]; then ok
        else
            bad "$plat MCP list disagrees with the canonical one ($list)"
            diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/       /' || true
        fi
        # An undeclared auth header is the other half of the same drift: it renders
        # as a literal ${...} the platform's renderer does not recognise, so the
        # server loads and 403s rather than being absent, which reads as an outage.
        hdr="$(jq -S '[.mcpServers[]?.headers // empty] | unique' "$list" 2>/dev/null || echo '"UNREADABLE"')"
        declared="$(jq -S --arg p "$plat" '[.platforms[$p].auth_header // .auth_header]' "$POLICY")"
        if [ "$hdr" = "[]" ] || [ "$hdr" = "$declared" ]; then ok
        else bad "$plat auth header is not the one mcp-policy.json declares for it"; fi
    done
else
    echo "  (mcp-policy.json not beside this marketplace — skipping)"
fi

echo
echo "RESULT pass=$pass fail=$fail"
exit "$fail"
