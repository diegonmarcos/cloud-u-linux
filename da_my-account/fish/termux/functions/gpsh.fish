# Delegate to git.push — sync-then-push in one command, no stale ref.
# No $argv pass-through on purpose: the old body was
# `git push origin (git_current_branch)`, which ignored arguments, and the
# sync engine's parser only accepts {ask|local|remote|--no-push|-q}, so
# forwarding a stray word here would turn a typo into a usage error.
git.push
