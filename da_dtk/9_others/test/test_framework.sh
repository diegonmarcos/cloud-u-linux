#!/bin/sh
# test_framework.sh — verify vault's declarative framework is wired correctly
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

echo "=== vault framework conformance ==="

# 1. .git/config contains [include] pointing to dist/gitconfig
git config --local --get include.path 2>/dev/null | grep -q '0_git/dist/gitconfig' \
    || fail ".git/config missing [include] for 0_git/dist/gitconfig"
pass ".git/config [include] wired"

# 2. hooksPath resolves to 0_git/dist/hooks
[ "$(git config core.hooksPath)" = "0_git/dist/hooks" ] \
    || fail "core.hooksPath != 0_git/dist/hooks (got: $(git config core.hooksPath))"
pass "hooksPath = 0_git/dist/hooks"

# 3. alias.sync is defined
git config alias.sync | grep -q 'cloud-git-sync.sh' \
    || fail "alias.sync missing or wrong"
pass "alias.sync defined"

# 4. pre-commit hook exists + executable
[ -x "0_git/dist/hooks/pre-commit" ] \
    || fail "dist/hooks/pre-commit missing or not executable"
pass "pre-commit hook deployed + executable"

# 5. No stale .githooks/ at repo root
[ ! -d "$REPO_ROOT/.githooks" ] || fail ".githooks/ still exists at repo root — should be removed"
pass "no stale .githooks/"

# 6. No stale .gitconfig tracked at repo root
git ls-files .gitconfig 2>/dev/null | grep -q '^.gitconfig$' \
    && fail ".gitconfig still tracked at repo root — should be removed"
pass "no stale .gitconfig tracked at root"

# 7. pre-commit blocks staged .env-like file (sanity — script-level check)
grep -q "P4.*env" "0_git/dist/hooks/pre-commit" \
    || fail "pre-commit doesn't include .env blocking pattern P4"
pass "pre-commit includes .env block rule"

# 8. pre-commit uses data-driven submodule discovery (no hardcoded names)
grep -q "git config --file .gitmodules" "0_git/dist/hooks/pre-commit" \
    || fail "pre-commit still uses hardcoded submodule paths (not data-driven)"
pass "pre-commit is data-driven for submodules"

echo "=== all checks passed ==="
