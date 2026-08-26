#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ vault workflows — build + deploy (lightweight engine)            ║
# ║                                                                  ║
# ║ build:  src/ → dist/ (1:1 copy, no header injection)            ║
# ║ deploy: dist/ → runtime locations                                ║
# ║   · dist/gitconfig    → .git/config [include] (in-place)        ║
# ║   · dist/hooks/       → read via hooksPath (in-place)           ║
# ║   · dist/gitignore    → .gitignore at repo root (copy)          ║
# ║   · dist/modules/gitmodules → .gitmodules at repo root (copy)   ║
# ║                                                                  ║
# ║ Usage: ./build.sh [build|deploy|all|test]                        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

do_build() {
    rm -rf "$DIST_DIR"
    cp -a "$SRC_DIR" "$DIST_DIR"
    chmod +x "$DIST_DIR/hooks/"* 2>/dev/null || true
    chmod +x "$DIST_DIR/scripts/"* 2>/dev/null || true
    log "Built: src/ → dist/"
}

do_deploy() {
    [ -d "$DIST_DIR" ] || { log "No dist/ — run build first"; exit 1; }

    # gitignore → repo root .gitignore (physical file required by git)
    if [ -f "$DIST_DIR/gitignore" ]; then
        cp "$DIST_DIR/gitignore" "$REPO_ROOT/.gitignore"
        log "Deployed .gitignore → repo root"
    fi

    # gitmodules → repo root .gitmodules (physical file required by git)
    if [ -f "$DIST_DIR/modules/gitmodules" ]; then
        cp "$DIST_DIR/modules/gitmodules" "$REPO_ROOT/.gitmodules"
        log "Deployed .gitmodules → repo root"
    fi

    # Gitconfig → include in .git/config + reconcile shadow keys
    # Unset any local keys owned by dist/gitconfig so they cannot shadow
    # the declared config (last-wins makes post-include entries win).
    if [ -f "$DIST_DIR/gitconfig" ]; then
        _gc_section=""
        while IFS= read -r line; do
            case "$line" in
                \[*\])
                    _gc_section=$(printf '%s' "$line" | sed 's/^\[\([^]]*\)\]$/\1/' | tr '[:upper:]' '[:lower:]')
                    ;;
                *=*)
                    [ -z "$_gc_section" ] && continue
                    _gc_key=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\([a-zA-Z][a-zA-Z0-9]*\)[[:space:]]*=.*/\1/p' | tr '[:upper:]' '[:lower:]')
                    [ -n "$_gc_key" ] && git -C "$REPO_ROOT" config --local --unset "${_gc_section}.${_gc_key}" 2>/dev/null || true
                    ;;
            esac
        done < "$DIST_DIR/gitconfig"
        unset _gc_section _gc_key
        git -C "$REPO_ROOT" config --local include.path ../0_git/dist/gitconfig 2>/dev/null || true
        log "Deployed gitconfig (included in .git/config)"
    fi

    log "Done"
}

do_test() {
    # Auto-discover + run every src/test/test_*.sh
    [ -d "$SRC_DIR/test" ] || { log "No src/test/ — skipping"; return 0; }
    fails=0
    for t in "$SRC_DIR/test/"test_*.sh; do
        [ -f "$t" ] || continue
        log "TEST: $(basename "$t")"
        bash "$t" || fails=$((fails + 1))
    done
    [ $fails -eq 0 ] || { log "Tests failed: $fails"; exit 1; }
    log "All tests passed"
}

case "${1:-all}" in
    build)  do_build ;;
    deploy) do_deploy ;;
    test)   do_test ;;
    all|"") do_build; do_deploy; do_test ;;
    *)      echo "Usage: $0 [build|deploy|test|all]" ;;
esac
