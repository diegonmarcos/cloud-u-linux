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
FLAKES=$(ls -d "$REPO"/?[ab]_flakes_* 2>/dev/null)

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

# ── both flakes actually READ the SoT, rather than a store copy ──────────────
for nix in "$REPO"/ba_flakes_desktop/src/claude/claude.nix \
           "$REPO"/bb_flakes_termux/src/claude/claude.nix; do
  check "$(basename "$(dirname "$(dirname "$(dirname "$nix")")")") no longer home.files an mcp template" \
    "$(grep -c 'mcp.json.tpl".source' "$nix" || true)" 0
done

# The template lands via an activation copy, so ~/.mcp.json must be templated
# strictly after that copy — otherwise a switch renders last switch's servers.
check "mcpSecrets runs after claudeAssets" \
  "$(grep -c 'entryAfter \["linkGeneration" "claudeAssets"\]' \
      "$REPO/ba_flakes_desktop/src/claude/claude.nix" || true)" 1

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

exit "$fail"
