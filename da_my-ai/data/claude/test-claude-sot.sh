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
         settings.project.json mcp.desktop.json.tpl mcp.termux.json.tpl \
         mcp-local-launch.sh mcp-auth-headers.sh; do
  check "the SoT holds $f" "$([ -f "$SOT/$f" ] && echo yes || echo no)" yes
done

for f in settings.base.json settings.desktop.json settings.termux.json \
         settings.project.json mcp.desktop.json.tpl mcp.termux.json.tpl \
         claude-plugins.json; do
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

# ── cloud-infra's repo-scoped copy is GENERATED, and has been regenerated ────
# 0_apps/src/claude/ is what deploy-dotfiles.sh copies into every repo's
# .claude/. It used to be a second hand-kept copy of agents/ plus its own
# settings.json whose _doc read "edit there, then re-copy here" — and the two
# agents/README.md had already diverged, each describing itself as the same
# file. deploy-dotfiles.sh now refreshes that directory from this one, so the
# committed copy must be byte-identical or the refresh was never run.
#
# Byte-identical, not key-sampled like the seventeen-mirror check below: this
# is the ONE copy that is machine-generated, so anything less than equality
# means a hand edit landed in the generated tree and will be silently reverted.
INFRA_CLAUDE="$REPO/../cloud-infra/0_apps/src/claude"
if [ -d "$INFRA_CLAUDE" ]; then
  check "cloud-infra's generated agents/ matches the SoT" \
    "$(diff -rq "$SOT/agents" "$INFRA_CLAUDE/agents" >/dev/null 2>&1 && echo yes || echo no)" yes
  check "cloud-infra's generated settings.json is settings.project.json verbatim" \
    "$(cmp -s "$SOT/settings.project.json" "$INFRA_CLAUDE/settings.json" && echo yes || echo no)" yes
  check "cloud-infra's generated mcp-auth-headers.sh matches the SoT" \
    "$(cmp -s "$SOT/mcp-auth-headers.sh" "$INFRA_CLAUDE/mcp-auth-headers.sh" && echo yes || echo no)" yes
else
  echo "skip — cloud-infra 0_apps/src/claude not found at $INFRA_CLAUDE"
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
#
# A mirror is a copy some repo OWNS. The bare path walk also matched three
# kinds of file that no repo owns, and they held eighteen drifts nobody could
# act on — a permanently red gate is a gate that gets ignored, which is how the
# real drift below stayed unnoticed:
#   $GITBASE/.claude/           an abandoned CLAUDE_CONFIG_DIR, littered with
#                               .hm-bak-2026* files, whose own settings.json
#                               points at $HOME/.claude — these keys are never
#                               read by anything.
#   _legacy-*/…                 a pre-move archive, same story.
#   <repo>/cloud, <repo>/IV_cloud-configs, <repo>/V_front-configs
#                               untracked, gitignored STALE CLONES of OTHER
#                               repos (cloud pinned at c307b98 / d8a0dde55,
#                               diegonmarcos.github.io at b3111d73) sitting
#                               inside a repo that does not track them. Their
#                               "drift" is their upstream's content from weeks
#                               ago; ~/git/cloud and ~/git/front are green at
#                               HEAD, so `git pull` in the clone is the fix and
#                               an edit here would be fiction.
# Keep only files whose OWN git toplevel is a direct child of $GITBASE: a real
# checkout, editable, and the copy a commit here would actually change. The
# first two resolve to $HOME (a repo of its own, one level too high) and the
# clones resolve to themselves at depth two, so all five drop out.
GITBASE="$(cd "$REPO/.." && pwd)"
mirrors=$(find "$GITBASE" -maxdepth 4 \
  \( -path '*/.claude/settings.json' -o -path '*/0_apps/src/claude/settings.json' \) \
  -not -path '*/.git/*' -not -path '*z_archive*' -not -path '*/I_cloud/*' 2>/dev/null |
  while read -r m; do
    top=$(git -C "$(dirname "$m")" rev-parse --show-toplevel 2>/dev/null) || continue
    if [ "$(dirname "$top")" = "$GITBASE" ]; then printf '%s\n' "$m"; fi
  done | sort)
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

# ── retired MCPs stay retired ────────────────────────────────────────────────
# da_dtk ships two MCP products (products/mcp-dtk, products/mcp-unix-api) and
# neither is used any more. They are not declared in either template, not in
# ~/.mcp.json and not among cloud-infra's eleven build-*mcp*.json services — so
# today they are off by ABSENCE, which is a decision nothing is holding.
#
# The check above ("every cloud-infra MCP is declared in the desktop template")
# pushes in the opposite direction by design: anything cloud-infra declares
# must appear client-side. This is the counterweight. A retired server that
# quietly reappears in a template costs a tool-list slot and some eager context
# on every session, and the reason it went away is not written anywhere the
# next edit would look.
for retired in mcp-dtk mcp-unix-api dtk-mcp; do
  check "retired MCP '$retired' is not declared in either template" \
    "$(grep -l "\"$retired\"" "$SOT/mcp.desktop.json.tpl" "$SOT/mcp.termux.json.tpl" 2>/dev/null | wc -l | tr -d ' ')" 0
done

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

# ── the deployed statusline assets match the SoT ─────────────────────────────
# The status line is owned by the my-ai BINARY: statusline_assets.rs embeds
# data/statusline/ and install() writes it into ~/.claude on every daemon start,
# which is what makes the dependency self-healing. That guarantee is only as
# good as the daemon actually running, and on termux nothing runs it — no
# systemd, no service, so install() never fires. The deployed copy froze a month
# behind the SoT and quietly lost the 7d reset countdown; the settings were
# identical the whole time, so every settings-level check stayed green.
#
# Content-compare the deployed copy against the SoT. Absent = skip (CI and the
# container have no ~/.claude); present-and-different = the installer has not
# run here, and `my-ai usage --daemon` is what repairs it.
STATUSLINE_SOT="$SOT/../statusline"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -d "$STATUSLINE_SOT" ] && [ -d "$CLAUDE_DIR" ]; then
  stale=""
  for f in "$STATUSLINE_SOT"/*.sh; do
    n=$(basename "$f")
    [ -f "$CLAUDE_DIR/$n" ] || continue
    cmp -s "$f" "$CLAUDE_DIR/$n" || stale="$stale $n"
  done
  check "every deployed statusline asset matches the SoT" \
    "$(printf '%s' "$stale" | wc -w | tr -d ' ')" 0
  [ -n "$stale" ] && echo "     stale in $CLAUDE_DIR:$stale — run 'my-ai usage --daemon' to reinstall"
else
  echo "skip — no deployed statusline to compare at $CLAUDE_DIR"
fi

# ── the DEPLOYED mcp client list matches the platform template ───────────────
# gen-mcp-tpl.sh --check compares the two templates against the derivation and
# stops there. Nothing compared them against what a session actually LOADS, and
# that is exactly the gap: today both templates were correct while ~/.mcp.json
# was a month old, so a restart bound the stale server list and --check still
# printed OK.
#
# NOT byte equality, deliberately. ~/.mcp.json legitimately differs from the
# tpl: the live file carries headersHelper (a script that mints a bearer per
# session) where the tpl carries a static ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}
# that NIX renders at switch time. Writing the tpl through verbatim would leave
# that literal string in place and break auth on every gated server. So compare
# the axis that goes stale — which servers exist, where they point, and how they
# are reached. Auth delivery is the deployer's business; wiring is the SoT's.
AXIS='.mcpServers | with_entries(.value |= {type: (.type // "http"), url: .url, command: .command})'
case "$(uname -o 2>/dev/null)/${PREFIX:-}" in
  *[Aa]ndroid*|*com.termux*) PLAT=termux ;;
  *)                         PLAT=desktop ;;
esac
if [ -f "$HOME/.mcp.json" ]; then
  live=$(jq -S "$AXIS" "$HOME/.mcp.json" 2>/dev/null || echo '"UNREADABLE"')
  want=$(jq -S "$AXIS" "$SOT/mcp.$PLAT.json.tpl")
  check "deployed ~/.mcp.json matches mcp.$PLAT.json.tpl (servers, urls, transport)" \
    "$([ "$live" = "$want" ] && echo yes || echo no)" yes
  if [ "$live" != "$want" ]; then
    echo "     want (tpl) vs got (~/.mcp.json) — re-run the home-manager switch:"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$live") | sed 's/^/     /' || true
  fi
else
  echo "skip — no deployed ~/.mcp.json to compare"
fi

# ── every repo's committed .mcp.json carries the derived HTTP set ────────────
# A different deploy path from ~/.mcp.json: deploy-dotfiles.sh copies
# cloud-infra's derive output (1_cloud-configs/dist/mcp.json) to <repo>/.mcp.json
# so a clone with no home-manager still gets servers. Same rot, one tier down —
# front-data and git-repos-master were still shipping the seven PRE-RENAME
# server names, which is the failure the header of this file describes.
#
# Presence, url and transport of the derived set, not equality: a repo may
# legitimately carry MORE (cloud-infra-desktop ships the desktop tpl, stdio
# extras and the mesh-direct endpoint included). What must never happen is a
# derived server going missing or pointing somewhere else.
DERIVE="$REPO/../cloud-infra/1_cloud-configs/dist/mcp.json"
if [ -f "$DERIVE" ]; then
  behind=""; nrepo=0
  for f in "$GITBASE"/*/.mcp.json; do
    [ -f "$f" ] || continue
    nrepo=$((nrepo + 1))
    miss=$(jq -r -n --slurpfile want "$DERIVE" --slurpfile got "$f" '
      ($got[0].mcpServers // {}) as $g
      | [ $want[0].mcpServers | to_entries[]
          | select(($g[.key] | not)
                   or $g[.key].url != .value.url
                   or ($g[.key].type // "http") != (.value.type // "http"))
          | .key ] | join(",")' 2>/dev/null) || miss="UNREADABLE"
    [ -n "$miss" ] && behind="$behind ${f#"$GITBASE"/}[$miss]"
  done
  check "every repo .mcp.json carries the derived HTTP set ($nrepo checked)" \
    "$(printf '%s' "$behind" | wc -w | tr -d ' ')" 0
  [ -n "$behind" ] && for b in $behind; do echo "     stale: $b"; done
else
  echo "skip — cloud-infra derive output not found at $DERIVE"
fi

# ── the enforced ~/.claude.json keys are actually enforced ───────────────────
# ~/.claude.json is Claude Code's OTHER config file, and claude-json.json
# declares the keys the SoT owns in it. The applier is `my-ai build.sh assets`,
# which runs on desktop and never on termux — so remoteControlAtStartup was
# declared true here and simply ABSENT from the live file, indefinitely.
#
# That is the third instance of one pattern (statusline assets, ~/.mcp.json,
# now this): the SoT declares correctly, the applier only runs on one platform,
# and the other silently freezes. Declaring without checking is what makes the
# freeze silent, so each declared key is compared to the deployed value.
CJ="$SOT/claude-json.json"
if [ -f "$CJ" ] && [ -f "$HOME/.claude.json" ]; then
  unapplied=0
  for k in $(jq -r '.keys | keys[]' "$CJ"); do
    want=$(jq -c --arg k "$k" '.keys[$k]' "$CJ")
    got=$(jq -c --arg k "$k" '.[$k]' "$HOME/.claude.json" 2>/dev/null || echo null)
    if [ "$want" != "$got" ]; then
      unapplied=$((unapplied + 1))
      echo "     unapplied: $k — want $want, deployed $got"
    fi
  done
  check "every enforced ~/.claude.json key is applied" "$unapplied" 0
  [ "$unapplied" -gt 0 ] && echo "     run 'MY_AI_CLAUDE_OVERLAY=<platform> my-ai/build.sh assets' to apply"
else
  echo "skip — no deployed ~/.claude.json to compare"
fi

exit "$fail"
