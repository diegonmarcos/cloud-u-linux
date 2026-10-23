# flakes.switch — pull every new flake change, then rebuild this device.
#
#   1. git sync local   inside ~/git/cloud-infra-desktop  (LOCAL wins on conflict, and the
#      engine pushes your own commits too — it is bidirectional)
#   2. bb_flakes_termux/build.sh switch
#
# Renamed from `up` (2026-08-08): `up` was a flake.nix sharedAliases entry
# that shadowed the managed function for months, and the name said nothing
# about what it did. The dotted name is a namespace, not syntax — fish
# accepts any function name without a slash.
#
# ONE implementation: the `sw` binary (src/scripts/sw.sh) does exactly these
# two steps and is on PATH for bash/zsh/cron too. This function is the
# fish-facing name for it, so every shell runs the same code.
if command -q sw
    sw $argv
    return $status
end

# Bootstrap path — `sw` only lands on PATH after the first successful switch.
echo "[flakes.switch] sw not on PATH yet — running the two steps directly"
set -l repo $HOME/git/cloud-infra-desktop
set -l engine $repo/1_cicd/dist/scripts/cloud-git-sync.sh
if test -x $engine
    $engine local; or echo "[flakes.switch] WARN: sync failed — switching with the tree as-is"
else
    git -C $repo pull --rebase; or echo "[flakes.switch] WARN: pull failed — switching with the tree as-is"
end
$repo/bb_flakes_termux/build.sh switch $argv
