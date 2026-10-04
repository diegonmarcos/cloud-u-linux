#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ <repo>/9_others/build.sh — build + deploy this repo's config     ║
# ║                                                                  ║
# ║ Usage: ./9_others/build.sh [all|git|apps|sops|cicd|clean]        ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# The portable builder: every repo under cloud EXCEPT cloud itself.
#
# cloud has a 367-line engine because it also renders workflows through
# inject-header, drives nix flakes and reconciles submodules. The other repos
# need none of that — they need their config tiers compiled and installed —
# so this is the whole thing.
#
# Tiers (see the repo root; prefix says what a directory IS):
#   0_git/     gitconfig, gitattributes, gitignore, gitmodules, LICENSE, hooks/
#   0_apps/    claude, vscode, obsidian dotfiles + root/mcp.json
#   2_sops/    sops.yaml
#   1_cicd/    workflows (only where a repo has them)
#   9_others/  shared libs + this script
#
# Each tier owns its own dist/: a source and its compiled form sit together.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GIT_SRC="$REPO_ROOT/0_git/src";   GIT_DIST="$REPO_ROOT/0_git/dist"
APPS_SRC="$REPO_ROOT/0_apps/src"; APPS_DIST="$REPO_ROOT/0_apps/dist"
CICD_SRC="$REPO_ROOT/1_cicd/src"; CICD_DIST="$REPO_ROOT/1_cicd/dist"
SOPS_SRC="$REPO_ROOT/2_sops"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── 0_git ────────────────────────────────────────────────────────────────────
# gitconfig/attributes/ignore/modules deploy to the root as dotfiles; hooks are
# consumed in place via core.hooksPath. LICENSE is copied VERBATIM — it is the
# one artifact that must never carry a generated-file banner, because GitHub's
# licence detector and SPDX scanners match on its text.
do_git() {
    [ -d "$GIT_SRC" ] || { log "no 0_git/src — skipping"; return 0; }
    rm -rf "$GIT_DIST"; mkdir -p "$GIT_DIST/hooks"
    # gitconfig is NOT a root dotfile. A .gitconfig at a repo root means nothing
    # to git — that filename is user-level. The repo consumes it by including
    # 0_git/dist/gitconfig from .git/config, so it is written WITHOUT a dot and
    # never copied to the root.
    if [ -f "$GIT_SRC/gitconfig" ]; then
        cp -f "$GIT_SRC/gitconfig" "$GIT_DIST/gitconfig"
        log "  git: gitconfig -> 0_git/dist/gitconfig (included from .git/config)"
    fi
    # These three ARE root dotfiles — git reads them from the working tree.
    for f in gitattributes gitignore gitmodules; do
        [ -f "$GIT_SRC/$f" ] || continue
        cp -f "$GIT_SRC/$f" "$GIT_DIST/.$f"
        cp -f "$GIT_DIST/.$f" "$REPO_ROOT/.$f"
        log "  git: $f -> .$f"
    done
    if [ -f "$GIT_SRC/LICENSE" ]; then
        cp -f "$GIT_SRC/LICENSE" "$GIT_DIST/LICENSE"
        cp -f "$GIT_SRC/LICENSE" "$REPO_ROOT/LICENSE"
        log "  git: LICENSE (verbatim)"
    fi
    if [ -d "$GIT_SRC/hooks" ]; then
        cp -f "$GIT_SRC/hooks/"* "$GIT_DIST/hooks/" 2>/dev/null || true
        chmod +x "$GIT_DIST/hooks/"* 2>/dev/null || true
        log "  git: hooks -> 0_git/dist/hooks ($(ls -1 "$GIT_DIST/hooks" 2>/dev/null | wc -l | tr -d ' '))"
    fi
    # Wire the include so core.hooksPath and the aliases take effect. Relative
    # to the .git directory, which is why it is ../0_git/... and not a path
    # from the repo root.
    git -C "$REPO_ROOT" config --local include.path ../0_git/dist/gitconfig 2>/dev/null || true
}

# ── 0_apps + 2_sops ─────────────────────────────────────────────────────────
# One shared implementation: 9_others/src/deploy-dotfiles.sh, the same script
# cloud uses. It reads manifest.json for the tool->target map, honours
# never_manage (machine state such as settings.local.json), and handles
# root_targets (.mcp.json, .sops.yaml).
do_apps() {
    [ -d "$APPS_SRC" ] || { log "no 0_apps/src — skipping"; return 0; }
    rm -rf "$APPS_DIST"; mkdir -p "$APPS_DIST"
    sh "$SCRIPT_DIR/src/deploy-dotfiles.sh" "$APPS_SRC" "$APPS_DIST/dotfiles" "$REPO_ROOT"
}

# ── 1_cicd ───────────────────────────────────────────────────────────────────
# Only repos that actually ship workflows have this tier populated.
do_cicd() {
    [ -d "$CICD_SRC/cicd" ] || { log "no 1_cicd/src/cicd — skipping"; return 0; }
    rm -rf "$CICD_DIST"; mkdir -p "$CICD_DIST" "$REPO_ROOT/.github/workflows"
    n=0
    for f in "$CICD_SRC"/cicd/*.yml; do
        [ -f "$f" ] || continue
        cp -f "$f" "$CICD_DIST/$(basename "$f")"
        cp -f "$f" "$REPO_ROOT/.github/workflows/$(basename "$f")"
        n=$((n+1))
    done
    [ -d "$CICD_SRC/scripts" ] && { mkdir -p "$CICD_DIST/scripts"; cp -f "$CICD_SRC/scripts/"* "$CICD_DIST/scripts/" 2>/dev/null || true; }
    log "  cicd: $n workflow(s) -> .github/workflows/"
}

do_clean() { rm -rf "$GIT_DIST" "$APPS_DIST" "$CICD_DIST" "$SCRIPT_DIR/dist"; log "cleaned tier dists"; }

case "${1:-all}" in
    git)   do_git ;;
    apps)  do_apps ;;
    sops)  do_apps ;;   # sops.yaml rides the apps root_targets path
    cicd)  do_cicd ;;
    clean) do_clean ;;
    all|"") do_git; do_apps; do_cicd; log "FINISHED — tiers compiled and installed" ;;
    *) echo "Usage: $0 [all|git|apps|sops|cicd|clean]" >&2; exit 1 ;;
esac
