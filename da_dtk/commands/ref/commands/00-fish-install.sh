#!/bin/sh
# Install Fish shell + set as default — works on any OS
set -eu

SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

if command -v fish >/dev/null 2>&1; then
  echo "Fish already installed: $(fish --version)"
else
  echo "Installing Fish shell..."
  if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y fish
  elif command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update && $SUDO apt-get install -y fish
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -S --noconfirm fish
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add fish
  elif command -v nix-env >/dev/null 2>&1; then
    nix-env -iA nixpkgs.fish
  else
    echo "ERROR: no supported package manager found"
    exit 1
  fi
  echo "Fish installed: $(fish --version 2>/dev/null || echo 'OK')"
fi

# Add to /etc/shells if missing
FISH_PATH=$(command -v fish)
if ! grep -q "$FISH_PATH" /etc/shells 2>/dev/null; then
  echo "$FISH_PATH" | $SUDO tee -a /etc/shells >/dev/null
  echo "Added $FISH_PATH to /etc/shells"
fi

# Set as default shell
CURRENT_SHELL=$(getent passwd "$(whoami)" | cut -d: -f7)
if [ "$CURRENT_SHELL" != "$FISH_PATH" ]; then
  printf "Set Fish as default shell? [y/N] "
  read -r ans
  case "$ans" in y|Y)
    $SUDO chsh -s "$FISH_PATH" "$(whoami)"
    echo "Default shell changed to Fish — logout and back in to use it"
    ;;
  *)
    echo "Skipped — run 'chsh -s $FISH_PATH' later to switch"
    ;;
  esac
else
  echo "Fish is already the default shell"
fi
