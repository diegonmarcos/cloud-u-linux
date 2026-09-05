#!/usr/bin/env bash
# The gate for da_c3-watchdog's published data.
#
# It lives IN data/ for the same reason da_my-ai's does: the thing being
# guarded is "this directory is the only place this file lives", so the guard
# travels with it.
#
# watchdog-policy.json is the one document this app publishes. It is installed
# to ~/.config/c3-watchdog/ by build.sh, to /etc/c3-watchdog/ by the dist
# tarball, and shipped inside that tarball — three destinations, one file, and
# nothing was checking that it stays one file.
set -euo pipefail

DATA="${1:-$(cd "$(dirname "$0")" && pwd)}"
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
POLICY="$DATA/watchdog-policy.json"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   — $1"; else echo "FAIL — $1: got '$2', want '$3'"; fail=1; fi; }

check "the data dir holds watchdog-policy.json" "$([ -f "$POLICY" ] && echo yes || echo no)" yes
check "it is valid JSON" "$(jq -e . "$POLICY" >/dev/null 2>&1 && echo yes || echo no)" yes

# ── one file, not three ──────────────────────────────────────────────────────
# A second copy anywhere in this repo is a second source of truth: the app
# resolves whichever of its three search paths exists first, so a stale copy
# does not conflict with the real one, it SILENTLY WINS on some machines.
check "no second copy of the policy in this repo" \
  "$(find "$REPO" -name watchdog-policy.json -not -path '*/.git/*' -not -path '*/target/*' 2>/dev/null | wc -l | tr -d ' ')" 1

# ── the daemon reads ONE key, and it reads it by scanning text ───────────────
# watchdog.rs's json_array() is not a parser: it finds the FIRST occurrence of
# "slices" in the file body, then the first '[' after it, then the first ']'.
# That is deliberate — the daemon is std+libc with no JSON crate, which is what
# lets it be a 828K static binary — but it means the file's ORDER is load
# bearing in a way JSON never is. Move protected_slices below anything else
# containing the word, or add a "slices" key above it, and the daemon silently
# protects a different list. Nothing in the JSON schema can express that; this
# check can.
want="$(jq -r '.defaults.protected_slices.slices | join(",")' "$POLICY" 2>/dev/null)"
got="$(
  python3 - "$POLICY" <<'PY'
import sys
body = open(sys.argv[1]).read()
i = body.find('"slices"')
if i < 0: print(""); raise SystemExit
o = body.find('[', i); c = body.find(']', o)
print(",".join(t.strip().strip('"').strip() for t in body[o+1:c].split(',') if t.strip()))
PY
)"
check "the daemon's text scan finds defaults.protected_slices.slices" "$got" "$want"

# ── how much of this file is actually read ───────────────────────────────────
# Not a failure — a number worth seeing. The daemon consumes exactly one key
# and the rest is documentation that reads like configuration, which is how
# someone ends up tuning a threshold that nothing has ever loaded.
total="$(jq '[paths | join(".")] | length' "$POLICY" 2>/dev/null || echo '?')"
echo "note — the daemon reads 1 of $total keys (defaults.protected_slices.slices); the rest is inert"

exit "$fail"
