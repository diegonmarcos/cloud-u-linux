#!/bin/sh
# Remove stale guardrail wrapper scripts from ~/.local/bin/
# These were deployed by an old HM generation (system-protection-guardrails.nix)
# that had a syntax error in the docker case statement.
# The module is now DISABLED but the wrapper files persist on disk.
set -eu

BIN_DIR="$HOME/.local/bin"
WRAPPERS="docker docker-compose npm npx nix nix-env nix-shell systemctl"
REMOVED=0

echo "Checking for stale guardrail wrappers in $BIN_DIR..."

for cmd in $WRAPPERS; do
  FILE="$BIN_DIR/$cmd"
  if [ -f "$FILE" ] && grep -q "guardrail\|_log_guardrail\|BUILDSH_GUARDRAIL" "$FILE" 2>/dev/null; then
    rm -f "$FILE"
    echo "  removed: $FILE"
    REMOVED=$((REMOVED + 1))
  fi
done

if [ "$REMOVED" -eq 0 ]; then
  echo "  No stale wrappers found — clean"
else
  echo "  Removed $REMOVED wrapper(s)"
  echo "  Reload shell: hash -r (bash) or exec fish (fish)"
fi
