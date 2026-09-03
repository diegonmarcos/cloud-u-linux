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

echo "## inject: SessionStart non-empty (memory-system rule), no other tiers wired ##"
out="$(printf '{}' | bash "$ENGINE" inject SessionStart)"
[ -n "$out" ] && printf '%s' "$out" | grep -q 'Memory System' && ok || bad "inject SessionStart empty/missing memory-system rule"

echo "## nudge: this plugin wires no PostToolUse/nudge rule — skipping ##"

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

echo
echo "RESULT pass=$pass fail=$fail"
exit "$fail"
