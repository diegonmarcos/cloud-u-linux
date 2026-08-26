#!/bin/sh
# Restore nix binary paths — finds docker/docker-compose and other nix binaries
# and creates symlinks in ~/.local/bin/ pointing to the nix store
set -eu

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

# Nix profile paths to search
NIX_PATHS="
$HOME/nix-profile/bin
$HOME/.nix-profile/bin
/nix/var/nix/profiles/default/bin
"

# Critical binaries to ensure are in PATH
BINS="docker docker-compose jq git curl ssh rsync htop tmux ttyd sops age"

FIXED=0
for cmd in $BINS; do
  # Skip if already works
  if command -v "$cmd" >/dev/null 2>&1; then
    continue
  fi

  # Search nix profiles
  FOUND=""
  for p in $NIX_PATHS; do
    if [ -x "$p/$cmd" ]; then
      FOUND="$p/$cmd"
      break
    fi
  done

  # Search nix store directly
  if [ -z "$FOUND" ]; then
    FOUND=$(find /nix/store -maxdepth 2 -name "$cmd" -type f -executable 2>/dev/null | tail -1)
  fi

  if [ -n "$FOUND" ]; then
    ln -sf "$FOUND" "$BIN_DIR/$cmd"
    echo "  linked: $cmd → $FOUND"
    FIXED=$((FIXED + 1))
  else
    echo "  MISSING: $cmd (not in nix store)"
  fi
done

if [ "$FIXED" -eq 0 ]; then
  echo "All binaries already in PATH — nothing to fix"
else
  echo "Fixed $FIXED binary path(s) in $BIN_DIR"
fi

# Also export PATH for current session
echo ""
echo "Run this to update current shell:"
echo "  export PATH=\"$BIN_DIR:\$HOME/nix-profile/bin:\$HOME/.nix-profile/bin:\$PATH\""
echo "  hash -r"
