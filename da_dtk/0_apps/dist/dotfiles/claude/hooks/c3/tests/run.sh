#!/bin/bash
# Planted cases per hook: BLOCK lines must exit 2, PASS lines must exit 0.
H="$(cd "$(dirname "$0")/.." && pwd)"; fail=0; n=0
t(){ # hook expect command
  local out rc; out="$(node -e 'process.stdout.write(JSON.stringify({tool_input:{command:process.argv[1]}}))' "$3" | "$H/$1.sh" 2>&1)"; rc=$?
  n=$((n+1)); [ "$rc" = "$2" ] || { echo "FAIL $1 expected $2 got $rc: $3"; fail=$((fail+1)); }
  if [ "$2" = 2 ] && ! printf '%s' "$out" | grep -q "BLOCKED by c3-infra hook $1"; then echo "FAIL $1 no message: $3"; fail=$((fail+1)); fi; }
# pkill / pgrep -f
t no-pkill-pgrep-f 2 'pkill -f GradleDaemon'; t no-pkill-pgrep-f 2 'x && pgrep -fl gradle'; t no-pkill-pgrep-f 2 'pkill -9 -f foo'
t no-pkill-pgrep-f 0 'pgrep GradleDaemon'; t no-pkill-pgrep-f 0 'kill 1234'; t no-pkill-pgrep-f 0 'ps aux | grep foo'
# glob rm
t no-glob-rm-tmp 2 'rm -rf /tmp/*'; t no-glob-rm-tmp 2 'rm -rf /tmp/tmp.*'; t no-glob-rm-tmp 2 'rm -f /dev/shm/a*'
t no-glob-rm-tmp 0 'rm -rf /tmp/claude-x/build'; t no-glob-rm-tmp 0 'rm -rf /home/user/wt/plg/pl'; t no-glob-rm-tmp 0 'rm foo*.txt'
# gradle
t no-local-gradle 2 './gradlew assembleDebug'; t no-local-gradle 2 'cd app && gradle test'; t no-local-gradle 2 'sudo gradle build'
t no-local-gradle 0 'gh workflow run ship.yml'; t no-local-gradle 0 'ls gradle/'; t no-local-gradle 0 'cat gradlew.bat'
# push
t main-only-push 2 'git push origin feature/x'; t main-only-push 2 'git push -u origin HEAD:dev'; t main-only-push 2 'git push --all'
t main-only-push 0 'git push origin main'; t main-only-push 0 'git -C . push origin main'; t main-only-push 0 'git push origin HEAD:main'; t main-only-push 0 'git push origin --delete old'
t main-only-push 0 'git push origin main 2>&1 | tail -1'; t main-only-push 0 'git status'
# branches
t no-branch-create 2 'git checkout -b feat'; t no-branch-create 2 'git switch -c feat'; t no-branch-create 2 'git branch feat'; t no-branch-create 2 'git worktree add -b x ../x'
t no-branch-create 0 'git checkout main'; t no-branch-create 0 'git branch -D old'; t no-branch-create 0 'git branch --show-current'; t no-branch-create 0 'git branch -r'
# secrets
T="$(mktemp -d)"; git -C "$T" init -q; echo 'aws=AKIAABCDEFGHIJKLMNOP' > "$T/a.txt"; git -C "$T" add a.txt
t no-secrets-commit 2 "git -C $T commit -m wip"
t no-secrets-commit 2 'git commit -m "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"'
git -C "$T" rm -qf --cached a.txt; echo hello > "$T/b.txt"; git -C "$T" add b.txt
t no-secrets-commit 0 "git -C $T commit -m wip"; t no-secrets-commit 0 'git commit -m "fix the thing"'; t no-secrets-commit 0 'git log'
rm -rf "$T"
echo "hook tests: $n cases, $fail failed"; [ "$fail" = 0 ]
