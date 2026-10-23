# git.push — sync-then-push in ONE command, no stale ref, no second push.
#
# A pre-push hook cannot do this: git compare-and-swaps refs/heads/<branch>
# against the sha it read BEFORE the hook ran, so if the hook's rebase moves
# HEAD the in-flight push is doomed no matter what the hook does (verified
# 2026-08-09). The fix is to run the sync engine BEFORE git resolves the refs
# to push at all — this function does exactly that, in `ask` mode, which
# already fetches, rebases and pushes (step 4), so it's a complete push.
set -l root (git rev-parse --show-toplevel 2>/dev/null)
if test -z "$root"
    echo "git.push: not inside a git repo" >&2
    return 1
end

set -l engine $root/1_workflows/dist/scripts/cloud-git-sync.sh
if not test -x $engine
    set engine $HOME/git/cloud-infra-desktop/1_workflows/dist/scripts/cloud-git-sync.sh
end

if not test -x $engine
    echo "git.push: sync engine not found — falling back to plain git push" >&2
    git push $argv
    return $status
end

$engine ask $argv
return $status
