#!/usr/bin/env bash
# ============================================================================
# gen-hooks-doc.sh — generate HOOKS.md from hooks-rules.json (single source).
# Deterministic (preserves array order) so a drift test can assert
# committed HOOKS.md == fresh output. Run from build.sh / manually:
#   bash gen-hooks-doc.sh > HOOKS.md
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RULES="${HOOK_RULES_FILE:-$HERE/hooks-rules.json}"
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

jq -e . "$RULES" >/dev/null || { echo "invalid hooks-rules.json" >&2; exit 1; }

emit_rows() { # $1=level — table rows: id | category | reversibility | event | pattern | reason | alt
    jq -r --arg lvl "$1" '.rules[] | select(.level==$lvl)
        | (.id)+"\t"+(.category // "—")+"\t"+(.reversibility // "—")+"\t"+(.event // "-")+"\t"
          +((.match.pattern // (if .handler then "handler:"+.handler else "-" end))|@base64)+"\t"
          +((.reason // "-")|@base64)+"\t"+((.alt // "")|@base64)' "$RULES" \
    | while IFS=$'\t' read -r id cat rev event pat_b reason_b alt_b; do
        pat="$(b64d "$pat_b")"; reason="$(b64d "$reason_b")"; alt="$(b64d "$alt_b")"
        printf '| `%s` | %s | %s | %s | `%s` | %s | %s |\n' \
          "$id" "$cat" "$rev" "$event" "$pat" "$reason" "${alt:-—}"
      done
}

section() { # $1=level $2=heading
    echo "## $2"
    echo
    echo "| id | category | reversibility | event | pattern / handler | reason | alt |"
    echo "|---|---|---|---|---|---|---|"
    emit_rows "$1"
    echo
}

cat <<'HDR'
# Claude Code Hooks — generated reference

> **GENERATED from `hooks-rules.json` by `gen-hooks-doc.sh` — do not hand-edit.**
> Edit the registry, then `build.sh switch` (a drift test asserts this file is current).

Three independent axes classify every rule:
- **Reinforcement level** — `allow` (tier-0 short-circuit) · `deny` (block, exit 2) ·
  `warn` (advisory, exit 0) · `nudge` (PostToolUse soft) · `inject` (context prose).
- **Category** (one question: *what asset/invariant does this protect?*) — `secrets` ·
  `data-loss` · `declarative-state` · `shell-safety` · `arch-guessing` · `read-only`.
- **Reversibility** (blast radius, orthogonal to level) — `irreversible` · `recoverable` · `advisory`.

Enforcement is **PreToolUse:Bash only**; SessionStart/UserPromptSubmit are injection-only;
the nudge is PostToolUse. The guard is **fail-closed** (unreadable registry ⇒ deny).

HDR

echo "## Summary"
echo
echo "| level | count | event |"
echo "|---|---|---|"
for lvl in allow deny warn nudge inject; do
    n="$(jq -r --arg l "$lvl" '[.rules[]|select(.level==$l)]|length' "$RULES")"
    ev="$(jq -r --arg l "$lvl" '[.rules[]|select(.level==$l)|.event // (.tiers|join(","))]|unique|join(", ")' "$RULES")"
    printf '| %s | %s | %s |\n' "$lvl" "$n" "$ev"
done
echo
echo "Irreversible rules (audit-first when relaxing anything):"
echo
jq -r '.rules[] | select(.reversibility=="irreversible") | "- `"+.id+"` ("+.level+", "+.category+")"' "$RULES"
echo

section allow "ALLOW — tier-0 short-circuit (read-only, silent)"
section deny  "DENY — hard block (exit 2)"
section warn  "WARN — advisory (exit 0, first match wins)"
section nudge "NUDGE — PostToolUse soft reminder"

echo "## INJECT — context prose by tier"
echo
echo "| id | fragment | tiers |"
echo "|---|---|---|"
jq -r '.rules[] | select(.level=="inject")
    | "| `"+.id+"` | `"+.fragment+"` | "+(.tiers|join(", "))+" |"' "$RULES"
