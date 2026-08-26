#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-git-nuke.sh — bulletproof reset-from-origin `git nuke`     ║
# ║                                                                  ║
# ║ Source: cloud/1_cicd/src/scripts/cloud-git-nuke.sh          ║
# ║ Wired : 0_git/src/gitconfig  →  [alias] nuke               ║
# ║                                                                  ║
# ║ Sibling of `git sync` — same fan-out, opposite contract:         ║
# ║   sync  → smart, non-destructive (stash → rebase → pop)          ║
# ║           preserves local work, may halt on conflicts            ║
# ║   nuke  → bulletproof, DESTRUCTIVE (fetch + reset --hard)        ║
# ║           discards EVERYTHING local, never halts, no recovery    ║
# ║                                                                  ║
# ║ Use case:                                                        ║
# ║   • ephemeral CI containers (cloud-builder-x, GHA runners)       ║
# ║     that just need "match origin/main exactly, right now"        ║
# ║   • scripted bulk re-syncs across many repos where halting       ║
# ║     on a single repo would block the whole batch                 ║
# ║                                                                  ║
# ║ DO NOT USE on a repo where you have local work you care about.   ║
# ║ Local commits, dirty files, untracked files: ALL WIPED.          ║
# ║ This is a feature, not a bug — predictability over forgiveness.  ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   git nuke              # reset to origin/<current-branch>       ║
# ║   git nuke main         # reset to origin/main explicitly        ║
# ║   git nuke -q|--quiet   # minimal output                         ║
# ║                                                                  ║
# ║ Flow:                                                            ║
# ║   1. fetch origin <ref>                                          ║
# ║   2. reset --hard origin/<ref>                                   ║
# ║   3. clean -fdx (untracked files + dirs, including ignored)      ║
# ║   4. submodule sync --recursive  (refresh URLs from .gitmodules) ║
# ║   5. submodule update --init --recursive --remote --rebase --force│
# ║   6. print summary (old→new SHA, files wiped, submodule bumps)   ║
# ║                                                                  ║
# ║ Survives: force-pushed origin, local divergent history,          ║
# ║           dirty work, untracked files, broken submodules.        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

# ── arg parse ───────────────────────────────────────────────────────
QUIET=0
REF=""
for arg in "$@"; do
  case "$arg" in
    -q|--quiet) QUIET=1 ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    -*) printf 'usage: git nuke [<branch>] [-q|--quiet]\n' >&2; exit 2 ;;
    *)  REF="$arg" ;;
  esac
done
REF="${REF:-$(git rev-parse --abbrev-ref HEAD)}"

# ── output helpers (same shape as cloud-git-sync.sh) ───────────────
if [ -t 1 ]; then
  C_RESET=$(printf '\033[0m')
  C_BOLD=$(printf '\033[1m')
  C_DIM=$(printf '\033[2m')
  C_CYAN=$(printf '\033[36m')
  C_YELLOW=$(printf '\033[33m')
  C_GREEN=$(printf '\033[32m')
  C_RED=$(printf '\033[31m')
else
  C_RESET= C_BOLD= C_DIM= C_CYAN= C_YELLOW= C_GREEN= C_RED=
fi

hr()      { printf '%s────────────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }
section() { [ "$QUIET" = 1 ] && return; printf '\n%s▸ %s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }
step()    { [ "$QUIET" = 1 ] && return; printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
ok()      { [ "$QUIET" = 1 ] && return; printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
err()     { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
kv()      { [ "$QUIET" = 1 ] && return; printf '  %-22s %s%s%s\n' "$1" "$C_BOLD" "$2" "$C_RESET"; }

T_START=$(date +%s)

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "0000000")
HEAD_BEFORE_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "0000000")

# ── 0. pre-nuke state (informational only — we wipe regardless) ────
N_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
N_UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
N_IGNORED=$(git ls-files --others --ignored --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

if [ "$QUIET" = 0 ]; then
  hr
  printf '%s git nuke %s%s%s — %sDESTRUCTIVE%s reset to origin/%s\n' \
    "$C_BOLD$C_RED" "$C_RESET$C_BOLD" "$REPO_NAME" "$C_RESET" "$C_RED" "$C_RESET" "$REF"
  hr
  kv "before HEAD"      "$HEAD_BEFORE_SHORT"
  kv "tracked dirty"    "$N_DIRTY file(s)"
  kv "untracked"        "$N_UNTRACKED file(s)"
  kv "ignored"          "$N_IGNORED file(s)"
fi

# ── 1. fetch ────────────────────────────────────────────────────────
section "1/5 fetch origin $REF"
if git fetch origin "$REF" 2>&1 | sed 's/^/  │ /'; then
  ok "fetched origin/$REF"
else
  err "fetch failed — origin unreachable or ref doesn't exist"
  exit 1
fi

# ── 2. reset --hard ─────────────────────────────────────────────────
section "2/5 reset --hard origin/$REF"
git reset --hard "origin/$REF" 2>&1 | sed 's/^/  │ /'
ok "tree matches origin/$REF"

# ── 3. clean untracked + ignored ────────────────────────────────────
section "3/5 clean untracked + ignored"
# -f = force (required), -d = dirs, -x = include ignored. Belt-and-braces:
# fresh containers shouldn't have ignored files anyway, but we want to
# wipe stale build artefacts (dist/, node_modules/, .result, etc.) too.
N_CLEANED=$(git clean -fdx -n 2>/dev/null | wc -l | tr -d ' ')
git clean -fdx 2>&1 >/dev/null
ok "cleaned $N_CLEANED file(s)/dir(s)"

# ── 4. submodule URL sync (in case .gitmodules changed remotes) ────
section "4/5 sync submodule URLs"
if [ -f .gitmodules ]; then
  git submodule sync --recursive 2>&1 | sed 's/^/  │ /' || true
  ok "submodule URLs synced from .gitmodules"
else
  step "no .gitmodules — skipped"
fi

# ── 5. submodule update --remote --rebase --force ──────────────────
section "5/5 update submodules to remote HEAD"
if [ -f .gitmodules ]; then
  step "git submodule update --init --recursive --remote --rebase --force"
  # --force ensures local submodule changes get overwritten
  if git submodule update --init --recursive --remote --rebase --force 2>&1 | sed 's/^/  │ /'; then
    ok "submodules at remote HEAD"
  else
    warn "submodule update reported errors — continuing (non-fatal)"
  fi
else
  step "no .gitmodules — skipped"
fi

# ── post-nuke summary ───────────────────────────────────────────────
HEAD_AFTER=$(git rev-parse HEAD)
HEAD_AFTER_SHORT=$(git rev-parse --short HEAD)
T_END=$(date +%s)
ELAPSED=$((T_END - T_START))

section "summary"
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
  kv "HEAD"                "$HEAD_AFTER_SHORT  (already at origin)"
else
  kv "HEAD"                "$HEAD_BEFORE_SHORT → $HEAD_AFTER_SHORT"
fi
kv "wiped"                "$N_DIRTY tracked-dirty + $N_UNTRACKED untracked + $N_CLEANED build/ignored"
if [ -f .gitmodules ]; then
  SM_DRIFTED=$(git submodule status --recursive 2>/dev/null | grep -c '^+' || true)
  SM_CLEAN=$(git submodule status --recursive 2>/dev/null | grep -c '^ ' || true)
  kv "submodules"          "clean=$SM_CLEAN  drifted=$SM_DRIFTED"
fi
kv "elapsed"              "${ELAPSED}s"
hr
[ "$QUIET" = 0 ] && printf '%s✓ nuke complete%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
exit 0
