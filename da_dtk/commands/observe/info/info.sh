#!/bin/sh
# Info module — show installed tools and repos
set -eu

REPOS="cloud:https://github.com/diegonmarcos/cloud-infra.git
cloud-data:https://github.com/diegonmarcos/cloud-data.git
unix:https://github.com/diegonmarcos/cloud-unix.git
front:https://github.com/diegonmarcos/front.git
vault:https://github.com/diegonmarcos/cloud-vault.git"

echo "=== Installed Tools ==="
for t in fish git node npm python3 rust cargo go docker podman gcloud oci aws \
         terraform claude wrangler gh jq yq rg fd bat eza fzf zoxide tmux ttyd \
         starship sops age nix rsync curl wget; do
  if command -v "$t" >/dev/null 2>&1; then
    _ver=$("$t" --version 2>/dev/null | head -1 || echo "ok")
    printf "  + %-12s %s\n" "$t" "$_ver"
  else
    printf "  - %-12s not installed\n" "$t"
  fi
done
echo ""
echo "=== Repos ==="
echo "$REPOS" | while read -r _line; do echo "  ${_line%%:*}"; done
