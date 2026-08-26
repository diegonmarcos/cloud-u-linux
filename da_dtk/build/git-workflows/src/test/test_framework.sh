#!/bin/sh
# test_framework.sh — verify this repo's declarative framework is wired correctly
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

echo "=== $REPO_NAME framework conformance ==="

git config --local --get include.path 2>/dev/null | grep -q '0_git/dist/gitconfig' \
    || fail ".git/config missing [include]"
pass ".git/config [include] wired"

[ "$(git config core.hooksPath)" = "0_git/dist/hooks" ] \
    || fail "core.hooksPath != 0_git/dist/hooks (got: $(git config core.hooksPath))"
pass "hooksPath = 0_git/dist/hooks"

git config alias.sync | grep -q 'cloud-git-sync.sh' || fail "alias.sync missing"
pass "alias.sync defined"

[ -x "0_git/dist/hooks/pre-commit" ] || fail "pre-commit missing or not executable"
pass "pre-commit hook deployed + executable"

[ ! -d "$REPO_ROOT/.githooks" ] || fail ".githooks/ still exists at root"
pass "no stale .githooks/"

git ls-files .gitconfig 2>/dev/null | grep -q '^.gitconfig$' \
    && fail ".gitconfig still tracked at root"
pass "no stale .gitconfig tracked at root"

grep -q "git config --file .gitmodules" "0_git/dist/hooks/pre-commit" \
    || fail "pre-commit not data-driven for submodules"
pass "pre-commit data-driven for submodules"

echo "=== all checks passed ==="
