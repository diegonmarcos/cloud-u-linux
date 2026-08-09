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

## Summary

| level | count | event |
|---|---|---|
| allow | 0 |  |
| deny | 0 |  |
| warn | 0 |  |
| nudge | 0 |  |
| inject | 1 | UserPromptSubmit,PreToolUse:Bash |

Irreversible rules (audit-first when relaxing anything):


## ALLOW — tier-0 short-circuit (read-only, silent)

| id | category | reversibility | event | pattern / handler | reason | alt |
|---|---|---|---|---|---|---|

## DENY — hard block (exit 2)

| id | category | reversibility | event | pattern / handler | reason | alt |
|---|---|---|---|---|---|---|

## WARN — advisory (exit 0, first match wins)

| id | category | reversibility | event | pattern / handler | reason | alt |
|---|---|---|---|---|---|---|

## NUDGE — PostToolUse soft reminder

| id | category | reversibility | event | pattern / handler | reason | alt |
|---|---|---|---|---|---|---|

## INJECT — context prose by tier

| id | fragment | tiers |
|---|---|---|
| `inject-principles-oneline` | `hooks-fragments/principles-oneline.md` | UserPromptSubmit, PreToolUse:Bash |
