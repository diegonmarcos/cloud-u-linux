#!/usr/bin/env bash
# ============================================================================
# hook-engine.sh — data-driven Claude Code hook engine
#
# ONE engine, ONE source of truth (hooks-rules.json beside this script).
# Dispatched by mode (arg $1); settings.json wires each event to a mode:
#   inject <SessionStart|UserPromptSubmit|PreToolUse>  — context injection
#   guard                                              — PreToolUse:Bash allow/deny/warn
#   nudge                                              — PostToolUse soft graph nudge
#
# Resolution: files are found beside the *invoked* path (this script's own
# dir), NOT via readlink — Claude Code copies the whole plugin dir into its
# cache on marketplace install, so $HERE co-locates hooks-rules.json and
# hooks-fragments/ regardless of whether we're running from the nix-store
# source or the installed plugin cache.
#
# Fail policy (deliberate, per mode):
#   guard  → FAIL-CLOSED: unreadable/invalid registry ⇒ DENY (never silent-allow).
#   inject → fail-open: emit a minimal static reminder.
#   nudge  → fail-open: exit 0.
#
# Source: ~/git/cloud-unix/ba_flakes_desktop/src/modules/dotfiles/claude/cloud-marketplace/cloud-principles-ai-plugin/scripts/
# Deployed via: home.file ".claude/cloud-marketplace" + `claude plugin marketplace add`
#   (see common.nix claudeMarketplace activation) — installed copy runs from
#   ~/.claude/plugins/cache/cloud-marketplace/cloud-principles-ai-plugin/<version>/scripts/
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RULES="${HOOK_RULES_FILE:-$HERE/hooks-rules.json}"

b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# ── registry health ────────────────────────────────────────────────────────
rules_ok() { [ -f "$RULES" ] && jq -e . "$RULES" >/dev/null 2>&1; }

MODE="${1:-}"

# ════════════════════════════════════════════════════════════════════════════
# MODE: inject <tier>
# ════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "inject" ]; then
    TIER="${2:-}"
    INPUT="$(cat 2>/dev/null || true)"

    # PreToolUse fires on every Bash call — gate the injected fragment to
    # once per session via a sentinel file, keyed by session_id (falls back
    # to PPID if session_id is unavailable), instead of repeating every turn.
    if [ "$TIER" = "PreToolUse" ]; then
        SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
        [ -n "$SID" ] || SID="ppid-$PPID"
        PLUGIN_NS="$(basename "$(dirname "$HERE")")"
        SENTINEL="${TMPDIR:-/tmp}/claude-${SID}.${PLUGIN_NS}.principles-shown"
        [ -f "$SENTINEL" ] && exit 0   # already shown once this session
    fi

    emit_fallback() {
        printf '## CORE PRINCIPLES (fallback)\n\n1. FULLY DECLARATIVE. 2. DATA-DRIVEN. 5. FIX THE ENGINE, NO HACKS. 7. USE SOPS. 8. ASK, DONT ASSUME. 9. USE cloud-cgc-mcp — never guess architecture.\n'
    }

    if ! rules_ok; then
        body="$(emit_fallback)"
    else
        body=""
        while IFS= read -r frag; do
            [ -n "$frag" ] || continue
            path="$HERE/$frag"
            # PreToolUse prefers a -compact.md variant to keep per-call cost low.
            if [ "$TIER" = "PreToolUse" ]; then
                compact="$HERE/${frag%.md}-compact.md"
                [ -f "$compact" ] && path="$compact"
            fi
            [ -f "$path" ] || continue
            body="${body}$(cat "$path")"$'\n\n'
        done < <(jq -r --arg t "$TIER" \
            '.rules[] | select(.level=="inject") | select(any(.tiers[]?; startswith($t))) | .fragment' "$RULES")
        # No matching rules for this tier is a normal, valid state (e.g. a
        # plugin intentionally has zero UserPromptSubmit rules) — NOT a
        # failure, so don't fall back to the CORE PRINCIPLES blurb here.
        # The fallback is reserved for an unreadable/invalid registry only.
    fi

    if [ "$TIER" = "PreToolUse" ]; then
        touch "$SENTINEL" 2>/dev/null || true
        # Must be JSON additionalContext to reach the model on PreToolUse.
        jq -nc --arg ctx "$body" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}' 2>/dev/null \
          || true
    else
        printf '%s' "$body"
    fi
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# MODE: guard  (PreToolUse:Bash)
# ════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "guard" ]; then
    INPUT="$(cat 2>/dev/null || true)"

    # jq MISSING is an environment problem, not a corrupt registry — denying
    # every Bash call because the interpreter isn't on the hook PATH bricked
    # the whole session (2026-08-08 audit). Warn + fail OPEN for that case only.
    if ! command -v jq >/dev/null 2>&1; then
        echo "⚠️  hook-engine: jq not on hook PATH — guard DISABLED this call (fail-open for missing interpreter)" >&2
        exit 0
    fi
    # FAIL-CLOSED: no usable registry ⇒ deny. A data-driven guard that fails
    # open is worse than the hardcoded one.
    if ! rules_ok; then
        echo "🛑 BLOCKED: hook-engine.sh cannot read hooks-rules.json (fail-closed)." >&2
        echo "   Fix the registry; do not bypass the guard." >&2
        exit 2
    fi

    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
    [ "$TOOL" = "Bash" ] || exit 0
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$CMD" ] || exit 0

    matches() { # $1=pattern_b64 $2=ci  → 0 if CMD matches
        local pat ci gi=""
        pat="$(b64d "$1")"; ci="$2"
        [ "$ci" = "true" ] && gi="i"
        printf '%s' "$CMD" | grep -q${gi}E -- "$pat"
    }

    # ── procedural carve-out handlers (imperative logic stays in shell) ──
    # Return 0 to DENY, 1 to ALLOW.
    check_git_add_secret() {
        case "$PWD" in "$HOME"/git/cloud-vault*) return 1 ;; esac
        local tokens tok
        tokens="$(printf '%s' "$CMD" | grep -oE '[^[:space:]]+\.(env|key|pem|age|p12|pfx)\b|[^[:space:]]*(^|/)\.secrets\b|[^[:space:]]*secrets\.ya?ml\b' 2>/dev/null || true)"
        for tok in $tokens; do
            [ ! -e "$tok" ] && continue                       # deletion → safe
            case "$tok" in
                *secrets.yaml|*secrets.yml)
                    if grep -qE '^sops:|ENC\[AES256_GCM' "$tok" 2>/dev/null; then continue; fi ;;
            esac
            return 0                                          # unsafe token → deny
        done
        return 1
    }

    # PREFILTER (2026-08-08): one combined-alternation grep per ci-class.
    # If NO rule pattern matches at all (the overwhelmingly common case),
    # exit now — the per-rule walk below cost ~100 forks per Bash call on
    # proot, flirting with the 5s hook timeout.
    _pre_cs=$(jq -r '[.rules[] | select(.event=="PreToolUse:Bash" and (.match.ci!=true)) | "(" + .match.pattern + ")"] | join("|")' "$RULES")
    _pre_ci=$(jq -r '[.rules[] | select(.event=="PreToolUse:Bash" and (.match.ci==true))  | "(" + .match.pattern + ")"] | join("|")' "$RULES")
    _hit=0
    [ -n "$_pre_cs" ] && printf '%s' "$CMD" | grep -qE  -- "$_pre_cs" && _hit=1
    [ "$_hit" = 0 ] && [ -n "$_pre_ci" ] && printf '%s' "$CMD" | grep -qiE -- "$_pre_ci" && _hit=1
    [ "$_hit" = 0 ] && exit 0

    # ALLOW (tier-0 short-circuit) — evaluated first, in array order.
    while IFS=' ' read -r pat ci; do
        [ -n "$pat" ] || continue
        if matches "$pat" "$ci"; then exit 0; fi
    done < <(jq -r '.rules[] | select(.level=="allow" and .event=="PreToolUse:Bash")
                    | (.match.pattern|@base64)+" "+(.match.ci|tostring)' "$RULES")

    # DENY — exit 2 on first match (pattern, then optional handler carve-out).
    while IFS=' ' read -r pat ci handler reason_b alt_b; do
        [ -n "$pat" ] || continue
        matches "$pat" "$ci" || continue
        if [ "$handler" != "-" ]; then
            # unknown handler must NOT count as a carve-out (a typo used to
            # fail OPEN via rc=127 — 2026-08-08 audit)
            if declare -F "$handler" >/dev/null 2>&1; then
                "$handler" || continue      # handler says ALLOW → skip this rule
            fi
        fi
        echo "🛑 BLOCKED by hook-engine.sh: $(b64d "$reason_b")" >&2
        alt="$(b64d "$alt_b")"; [ -n "$alt" ] && echo "   Use instead: $alt" >&2
        exit 2
    done < <(jq -r '.rules[] | select(.level=="deny" and .event=="PreToolUse:Bash")
                    | (.match.pattern|@base64)+" "+(.match.ci|tostring)+" "+(.handler // "-")+" "+(.reason|@base64)+" "+((.alt // "")|@base64)' "$RULES")

    # WARN — advisory, first match wins, exit 0.
    while IFS=' ' read -r pat ci reason_b alt_b; do
        [ -n "$pat" ] || continue
        if matches "$pat" "$ci"; then
            echo "⚠️  hook-engine WARNING (non-blocking): $(b64d "$reason_b"). Better: $(b64d "$alt_b")" >&2
            exit 0
        fi
    done < <(jq -r '.rules[] | select(.level=="warn" and .event=="PreToolUse:Bash")
                    | (.match.pattern|@base64)+" "+(.match.ci|tostring)+" "+(.reason|@base64)+" "+((.alt // "")|@base64)' "$RULES")

    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# MODE: nudge  (PostToolUse) — stateful, fail-open
# ════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "nudge" ]; then
    INPUT="$(cat 2>/dev/null || true)"
    rules_ok || exit 0
    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
    SID="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null || true)"
    [ -n "$TOOL" ] || exit 0

    THRESHOLD="$(jq -r '.meta.nudge_threshold // 5' "$RULES" 2>/dev/null)"
    RESET_PREFIX="$(jq -r '.meta.nudge_reset_prefix // "mcp__cloud-cgc"' "$RULES" 2>/dev/null)"
    STATE="${TMPDIR:-/tmp}/claude-graph-nudge-${SID}"

    case "$TOOL" in
        "$RESET_PREFIX"*) printf '0' > "$STATE" 2>/dev/null || true; exit 0 ;;
    esac
    # Only tools in meta.nudge_count_tools advance the counter.
    if ! jq -e --arg t "$TOOL" '.meta.nudge_count_tools | index($t)' "$RULES" >/dev/null 2>&1; then
        exit 0
    fi

    count=0
    [ -f "$STATE" ] && count="$(cat "$STATE" 2>/dev/null || echo 0)"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    count=$((count + 1))

    if [ "$count" -ge "$THRESHOLD" ]; then
        printf '0' > "$STATE" 2>/dev/null || true
        jq -nc --arg ctx "REMINDER (FIRE rule 6): ${THRESHOLD} file reads/searches with no cloud-cgc-mcp query. Before reasoning about architecture, use octocode_graphrag / octocode_search / knowledge_* / c3_* — don't read-5-files-and-guess-the-6th." \
          '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
    else
        printf '%s' "$count" > "$STATE" 2>/dev/null || true
    fi
    exit 0
fi

# Unknown mode → no-op (don't break the tool flow).
exit 0
