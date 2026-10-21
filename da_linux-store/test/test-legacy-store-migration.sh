#!/bin/sh
# test-legacy-store-migration.sh — the store's old name is migrated, never linked or read.
#   1. linux-store, linux-account and bootstrap.sh carry the SAME migration text.
#   2. EXECUTED: old dir merged into the store, a differing file kept in .legacy-backup-<date>,
#      duplicates dropped, old dir removed; a second run changes nothing; an old symlink with no
#      store is renamed into place.
#   3. The old name appears in no tracked file except on lines marked legacy_store_migration.
# Usage: sh da_linux-store/test/test-legacy-store-migration.sh
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"; ROOT="$(cd "$D/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/legacy-store-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "  ok   $1"; }; no() { echo "  FAIL $1"; fails=$((fails + 1)); }
OLD="cloud-drive-""shared-store"
blk() { sed -n '/^# legacy_store_migration begin/,/^# legacy_store_migration end/p' "$1" | sed 's/ *#.*$//' | grep -v '^$'; }
blk "$D/linux-store" > "$T/a"; blk "$ROOT/da_linux-account/linux-account" > "$T/b"; blk "$D/bootstrap.sh" > "$T/c"
if [ -s "$T/a" ] && cmp -s "$T/a" "$T/b" && cmp -s "$T/a" "$T/c"; then ok "the three scripts carry the same migration text"; else no "migration text differs between linux-store, linux-account and bootstrap.sh"; fi
sed -n '/^# legacy_store_migration begin/,/^# legacy_store_migration end/p' "$D/linux-store" > "$T/mig.sh"
H="$T/home"; N=cloud-shared-store
mig() { ( HOME="$H" sh -c ". '$T/mig.sh'; legacy_store_migrate \"\$HOME/$OLD\" \"\$HOME/$N\"" ) 2>&1; }
mkdir -p "$H/$OLD/git/a" "$H/$OLD/git/b" "$H/$OLD/.hid" "$H/$N/git/a"
echo o > "$H/$OLD/only.txt"; echo s > "$H/$OLD/same.txt"; echo s > "$H/$N/same.txt"; echo old > "$H/$OLD/clash.txt"; echo new > "$H/$N/clash.txt"
echo h > "$H/$OLD/.hid/h"; echo ao > "$H/$OLD/git/a/f"; echo an > "$H/$N/git/a/f"; echo b > "$H/$OLD/git/b/f"
out="$(mig)"; BK="$(ls -d "$H/$N"/.legacy-backup-* 2>/dev/null | head -1)"
if [ ! -e "$H/$OLD" ] && [ ! -L "$H/$OLD" ] && [ "$(cat "$H/$N/only.txt")" = o ] && [ "$(cat "$H/$N/.hid/h")" = h ] && [ "$(cat "$H/$N/git/b/f")" = b ] \
   && [ "$(cat "$H/$N/clash.txt")" = new ] && [ "$(cat "$BK/clash.txt")" = old ] && [ "$(cat "$H/$N/git/a/f")" = an ] && [ "$(cat "$BK/git/a/f")" = ao ] \
   && [ "$(cat "$H/$N/same.txt")" = s ] && [ ! -e "$BK/same.txt" ]; then ok "merged into the store; conflicts kept in .legacy-backup-<date>; old dir removed"; else no "migration result wrong: $out"; fi
snap="$(cd "$H" && find . | sort)"; out="$(mig)"
if [ "$snap" = "$(cd "$H" && find . | sort)" ] && [ -z "$out" ]; then ok "second run is a no-op"; else no "not idempotent"; fi
rm -rf "$H"; mkdir -p "$H/real"; echo k > "$H/real/k"; ln -s real "$H/$OLD"; mig >/dev/null
if [ ! -L "$H/$OLD" ] && [ "$(cat "$H/$N/k" 2>/dev/null)" = k ]; then ok "an old symlink with no store is renamed into place"; else no "old symlink handling wrong"; fi
hits="$(cd "$ROOT" && git ls-files -z | xargs -0 grep -nI -- "$OLD" 2>/dev/null | grep -v legacy_store_migration | grep -v 'test-legacy-store-migration.sh' || true)"
if [ -z "$hits" ]; then ok "the old name appears only in migration code"; else no "the old name is still used:"; echo "$hits" | head -20; fi
[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }; echo "all passed"
