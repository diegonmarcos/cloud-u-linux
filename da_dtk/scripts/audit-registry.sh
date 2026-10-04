#!/usr/bin/env bash
# audit-registry.sh — golden test for registry.json (the DTK command catalog).
# Asserts: valid JSON; unique ids; unique shortcodes; every command's domain is
# declared; and every legacy menu shortcode is covered by some command. Run before
# AND after the reorg — the covered-shortcode set must not regress.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG="$ROOT/registry.json"
JQ="$(command -v jq)"
[ -z "$JQ" ] && { echo "FAIL: jq not found"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

# 1. valid JSON
"$JQ" -e . "$REG" >/dev/null 2>&1 || fail "registry.json is not valid JSON"

# 2. unique ids
dupe_ids=$("$JQ" -r '.commands[].id' "$REG" | sort | uniq -d)
[ -n "$dupe_ids" ] && fail "duplicate ids: $dupe_ids"

# 3. unique shortcodes (ignoring null)
dupe_sc=$("$JQ" -r '.commands[].shortcode // empty' "$REG" | sort | uniq -d)
[ -n "$dupe_sc" ] && fail "duplicate shortcodes: $dupe_sc"

# 4. every command.domain is declared in .domains
bad_dom=$("$JQ" -r '.domains as $d | .commands[] | select(($d[.domain]|not)) | .id' "$REG")
[ -n "$bad_dom" ] && fail "commands with undeclared domain: $bad_dom"

# 5. every id is "<domain>.<name>"
bad_id=$("$JQ" -r '.commands[] | select(.id != (.domain + "." + .name)) | .id' "$REG")
[ -n "$bad_id" ] && fail "ids not matching domain.name: $bad_id"

# 6. GOLDEN: every legacy menu shortcode resolves to a command.
#    This is the catalog the old dtk.sh menu advertised (the contract we must keep).
GOLDEN="10 11 11b 12 13 14 15 \
20 20a 20b 20c 20d 20e 20f 20g 20h 20i 20j 20k 20l \
21 21a 21b 21c 21d 21e 21f 22a 22b 22c 22d \
30a 30b 30c 31 31a 31b 31c 31d 31e 32 32a 32b 32c 32d 33 34a 34b 34c \
40 40a0 40a1 40a2 40b0 40b1 40b2 41a0 41a1 41a2 42a 42b 42c 43a 43b 44a 45a 45b 45c 46a 46b \
50 51a 51b 51c 51d 51e 51f 51g 52a 52b"
missing=""
for sc in $GOLDEN; do
  hit=$("$JQ" -r --arg s "$sc" '.commands[] | select(.shortcode==$s) | .id' "$REG")
  [ -z "$hit" ] && missing="$missing $sc"
done
[ -n "$missing" ] && fail "menu shortcodes not covered by registry:$missing"

count=$("$JQ" '.commands | length' "$REG")
echo "OK: registry.json valid — $count commands, all golden shortcodes covered."
