#!/bin/bash
# CI guard: skill index lists every rules file, every rule has a Why, JSON valid, agents pinned, hook tests pass.
cd "$(dirname "$0")/.."; M=.; A=../../agents; S=$M/skills/c3-infra; fail=0
bad(){ echo "GUARD FAIL: $*"; fail=$((fail+1)); }
[ "$(wc -l < $S/SKILL.md)" -le 150 ] || bad "SKILL.md over 150 lines"
for f in $S/rules/*.md; do b=$(basename $f); grep -q "rules/$b" $S/SKILL.md || bad "$b not in SKILL.md index"; done
for b in $(grep -o 'rules/[a-z-]*\.md' $S/SKILL.md | sort -u); do [ -f $S/$b ] || bad "index lists missing $b"; done
for f in $S/rules/*.md; do grep -E '^- ' $f | grep -vq 'Why:' && bad "$(basename $f): rule without Why"; grep -E '^- ' $f | grep -v 'Guard:' | grep -q . && bad "$(basename $f): rule without Guard"; done
grep -E '^[0-9]+\. ' $S/SKILL.md | grep -v 'Why:' | grep -q . && bad "SKILL.md hard rule without Why"
for j in ../.claude-plugin/marketplace.json $M/.claude-plugin/plugin.json $M/hooks/hooks.json; do node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' $j 2>/dev/null || bad "invalid JSON $j"; done
for a in $(ls $A/*.md | grep -v README); do grep -q '^model: sonnet' $a && grep -q '^tools:' $a || bad "$a: needs model: sonnet and tools:"; done
for a in build general-purpose explore review; do grep -q '^tools:.*mcp__' $A/$a.md && bad "lean agent $a lists an mcp__ tool"; done
for h in $(grep -o 'hooks/[a-z-]*\.sh' $M/hooks/hooks.json | sort -u); do [ -x $M/$h ] || bad "hook $h missing or not executable"; done
bash $M/hooks/tests/run.sh || bad "hook tests"
[ $fail = 0 ] && echo "guard OK"; [ $fail = 0 ]
