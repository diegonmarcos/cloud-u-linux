#!/usr/bin/env bash
# The gate for "ONE SoT for claude settings". Runs offline — no nix, no HM.
#
# It lives IN the SoT dir on purpose: the thing being guarded is "this
# directory is the only place claude settings live", so the guard travels with
# it and both flakes get the same check.
#
# What actually went wrong, twice:
#   - mcp.json.tpl was a home.file in EACH flake. cloud-infra declared
#     cloud-cgc-pvt-mcp on 2026-08-23; neither client list ever heard about it,
#     because nothing pointed at the SoT to notice the gap.
#   - assets/mcp.json (no .tpl) sat in ba_flakes_desktop for months holding
#     seven pre-rename server names that nothing read.
# Both are the same failure: a settings file owned outside this directory.
set -euo pipefail

SOT="${1:-$(cd "$(dirname "$0")" && pwd)}"
# From the SCRIPT location, not $SOT: $SOT is overridable so the gate can be
# pointed at a candidate tree, and REPO must stay the real checkout either way.
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   — $1"; else echo "FAIL — $1: got '$2', want '$3'"; fail=1; fi; }

# ── the SoT holds what it claims to hold ─────────────────────────────────────
for f in settings.base.json settings.desktop.json settings.termux.json \
         mcp.desktop.json.tpl mcp.termux.json.tpl mcp-local-launch.sh; do
  check "the SoT holds $f" "$([ -f "$SOT/$f" ] && echo yes || echo no)" yes
done

for f in settings.base.json settings.desktop.json settings.termux.json \
         mcp.desktop.json.tpl mcp.termux.json.tpl claude-plugins.json; do
  check "$f is valid JSON" "$(jq -e . "$SOT/$f" >/dev/null 2>&1 && echo yes || echo no)" yes
done

# ── nothing outside the SoT owns a claude settings file ──────────────────────
# A flake may own secrets.yaml (sops ciphertext keyed to its own age
# recipients, un-shareable by construction) and nothing else.
# Scoped to the flake trees: they are the only places that can vendor a second
# copy, and a whole-monorepo walk took minutes on node_modules and .archive.
# The flakes are NOT in this repo. my-ai and the other d* apps split out into
# cloud-u-linux; ba_/bb_flakes_* stayed behind in cloud-infra-desktop. So the
# gate reaches them as a sibling checkout, the same way it reaches cloud-infra
# below. An absent sibling must SKIP, never pass: an empty $FLAKES fed to find
# counts zero hits and every check below would read as green.
DESKTOP="${CLOUD_DESKTOP_REPO:-$REPO/../cloud-infra-desktop}"
FLAKES=$(ls -d "$DESKTOP"/?[ab]_flakes_* 2>/dev/null || true)

if [ -n "$FLAKES" ]; then
  check "no flake vendors an mcp template of its own" \
    "$(find $FLAKES -name 'mcp*.json.tpl' -print 2>/dev/null | wc -l | tr -d ' ')" 0

  check "no flake vendors a settings.*.json of its own" \
    "$(find $FLAKES \( -name 'settings.*.json' ! -name 'settings.local.json' \) -print 2>/dev/null | wc -l | tr -d ' ')" 0

  # scripts/ and .sops.yaml are ENGINE, not settings — deploy/merge/debug shell
  # and the sops recipient list. Ownership follows what a file IS, not where it
  # happens to sit: data is the SoT's, code is the flake's.
  check "no settings DATA left beside a flake, only secrets.yaml" \
    "$(find $FLAKES -path '*/src/claude/assets/*' -maxdepth 5 -type f \
        ! -name secrets.yaml ! -name .sops.yaml ! -path '*/assets/scripts/*' \
        2>/dev/null | wc -l | tr -d ' ')" 0

  # ── both flakes actually READ the SoT, rather than a store copy ────────────
  for nix in "$DESKTOP"/ba_flakes_desktop/src/claude/claude.nix \
             "$DESKTOP"/bb_flakes_termux/src/claude/claude.nix; do
    check "$(basename "$(dirname "$(dirname "$(dirname "$nix")")")") no longer home.files an mcp template" \
      "$(grep -c 'mcp.json.tpl".source' "$nix" || true)" 0
  done

  # The template lands via an activation copy, so ~/.mcp.json must be templated
  # strictly after that copy — otherwise a switch renders last switch's servers.
  check "mcpSecrets runs after claudeAssets" \
    "$(grep -c 'entryAfter \["linkGeneration" "claudeAssets"\]' \
        "$DESKTOP/ba_flakes_desktop/src/claude/claude.nix" || true)" 1
else
  echo "skip — cloud-infra-desktop checkout not found at $DESKTOP"
fi

# ── the client list has not drifted from the server list ─────────────────────
# cloud-infra is the server-side SoT. Every MCP it declares public=true with a
# dns entry should be reachable from the desktop template; this is the check
# that was missing when cloud-cgc-pvt-mcp went undeclared for four days.
INFRA="$REPO/../cloud-infra/1_cloud-configs/dist"
if [ -d "$INFRA" ]; then
  missing=$(
    for b in "$INFRA"/build-*mcp*.json; do
      n=$(jq -r '.name // (input_filename | sub(".*/build-"; "") | sub("\\.json$"; ""))' "$b" 2>/dev/null) || continue
      case "$n" in null|"") continue;; esac
      jq -e --arg n "$n" '.mcpServers | has($n)' "$SOT/mcp.desktop.json.tpl" >/dev/null 2>&1 || echo "$n"
    done
  )
  check "every cloud-infra MCP is declared in the desktop template" \
    "$(printf '%s' "$missing" | grep -c . || true)" 0
  [ -n "$missing" ] && echo "     undeclared: $missing"
else
  echo "skip — cloud-infra checkout not found at $INFRA"
fi

# ── the repo-scoped mirror agrees with the SoT ───────────────────────────────
# 0_apps/src/claude/settings.json is committed into every repo under cloud so a
# fresh clone — CI, a container, someone else's checkout — gets more than
# Claude's stock defaults. It is a HAND-KEPT MIRROR of the machine-independent
# half of settings.base.json, and its own _doc says why that is dangerous:
# project settings merge OVER user settings, so a key that drifts here silently
# overrides the SoT inside every repo. It was correct when this check was
# written; nothing was making it stay correct.
#
# Only the keys the mirror deliberately carries. Everything with an @HOME@ path
# is deliberately absent from it (a committed file has no substitution step),
# and so is enabledPlugins — those are per-machine.
# EVERY copy, not one. This checked only cloud-infra's, and there are
# seventeen: one .claude/settings.json per repo, plus the 0_apps source they
# are generated from. Three had drifted the first time it looked — da_dtk and
# ac_cloud-vault were forcing ENABLE_TOOL_SEARCH to "true", which defers every
# MCP tool behind Tool Search unconditionally instead of past the 10% mark, for
# anyone working in those repos. Checking one copy of a file that exists
# seventeen times is not a gate.
#
# I_cloud is skipped: it is the `cloud` repo vendored as a submodule inside two
# others, pinned to a commit by design, so it lags on purpose and its parent's
# pre-push hook rebases it. Failing on a pinned submodule would make this
# permanently red for something that is not a bug.
GITBASE="$(cd "$REPO/.." && pwd)"
mirrors=$(find "$GITBASE" -maxdepth 4 \
  \( -path '*/.claude/settings.json' -o -path '*/0_apps/src/claude/settings.json' \) \
  -not -path '*/.git/*' -not -path '*z_archive*' -not -path '*/I_cloud/*' 2>/dev/null | sort)
drifted=""
for m in $mirrors; do
  for k in .alwaysThinkingEnabled .env.ENABLE_TOOL_SEARCH .disabledMcpjsonServers; do
    if [ "$(jq -c "$k" "$m" 2>/dev/null)" != "$(jq -c "$k" "$SOT/settings.base.json" 2>/dev/null)" ]; then
      drifted="$drifted ${m#"$GITBASE"/}:$k"
    fi
  done
done
check "every repo-scoped mirror agrees with the SoT ($(printf '%s' "$mirrors" | grep -c . ) checked)" \
  "$(printf '%s' "$drifted" | wc -w | tr -d ' ')" 0
[ -n "$drifted" ] && for d in $drifted; do echo "     drift: $d"; done

# ── the container's fork is declared, and its provenance is not a dead path ──
# a_solutions/user-ai_claude-superset-api ships its own claude-config: it has
# no working checkout to read the SoT from and no home-manager to deploy it, so
# it COPIES. That fork is legitimate and it is also how config rots — its five
# hook scripts each carried a "# Source:" header naming
# .../src/modules/dotfiles/claude/, a directory that no longer exists anywhere,
# because those hooks were superseded by the cloud-marketplace plugins in this
# SoT and nobody told the copy.
#
# Two things are checked. The inventory, so a hook appearing or vanishing in
# the fork is a visible diff rather than a surprise. And the provenance, so no
# file may cite a Source: path that is not there — the specific way this one
# went quiet.
FORK="$REPO/../cloud-infra/a_solutions/user-ai_claude-superset-api/src/code/claude-config"
if [ -d "$FORK" ]; then
  check "the container fork holds the declared hook inventory" \
    "$(ls "$FORK/hooks" 2>/dev/null | tr '\n' ' ')" \
    "a-context-inject-memory.sh b-context-inject-prompt.sh c-context-inject-pretool.sh c-pretool-guard-blockers.sh c-pretool-guard-warning.sh "

  dead=$(
    grep -rhoE '^# Source: [^ ]+' "$FORK" 2>/dev/null | awk '{print $3}' | sort -u |
      while read -r path; do
        expanded=$(printf '%s' "$path" | sed "s|^~|$HOME|")
        case "$expanded" in
          *"{"*) expanded_a=$(printf '%s' "$expanded" | sed 's|{\([^,}]*\),[^}]*}|\1|')
                 [ -e "$expanded_a" ] || echo "$path" ;;
          *) [ -e "$expanded" ] || echo "$path" ;;
        esac
      done
  )
  check "no file in the container fork cites a Source: path that is gone" \
    "$(printf '%s' "$dead" | grep -c . || true)" 0
  [ -n "$dead" ] && echo "     dead provenance: $dead"
else
  echo "skip — container fork not found at $FORK"
fi

exit "$fail"
