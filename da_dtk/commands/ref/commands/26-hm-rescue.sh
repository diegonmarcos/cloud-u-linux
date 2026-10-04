#!/bin/sh
# 1226 hm-rescue — Pull latest HM source from git, copy to ~/.config/home-manager, re-apply
# Use when GHA can't reach this VM (broken WG, SSH down, etc.)
# This is the escape hatch to bootstrap the declarative pipeline from serial console.
set -e

_log "══════════════════════════════════════════════════════════════════"
_log "  HM RESCUE: Pull latest source + re-apply home-manager"
_log "══════════════════════════════════════════════════════════════════"

# Find cloud repo
CLOUD_REPO=""
for p in "$HOME/git/cloud-infra" "/home/diego/git/cloud-infra" "/home/diego/Mounts/Git/cloud"; do
  [ -d "$p/.git" ] && CLOUD_REPO="$p" && break
done

if [ -z "$CLOUD_REPO" ]; then
  _log "ERROR: cloud repo not found"
  exit 1
fi

# Detect VM name from hostname
HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
case "$HOSTNAME" in
  *proxy*|gcp-proxy*)    VM_NAME="gcp-proxy" ;;
  *mail*|oci-mail*)      VM_NAME="oci-mail" ;;
  *analytics*|services-server*) VM_NAME="oci-analytics" ;;
  *arm*|arm-server*)     VM_NAME="oci-apps" ;;
  *t4*|gcp-t4*)          VM_NAME="gcp-t4" ;;
  *) _log "ERROR: Cannot determine VM name from hostname '$HOSTNAME'"; exit 1 ;;
esac

HM_USER=$(whoami)
HM_CONFIG="${HM_USER}@${VM_NAME}"
HM_DIR="$HOME/.config/home-manager"
SRC_DIR="$CLOUD_REPO/b_infra/nixhm-sudo-${VM_NAME}/src"

_log "VM: $VM_NAME  User: $HM_USER  Config: $HM_CONFIG"
_log "Cloud repo: $CLOUD_REPO"
_log "HM source: $SRC_DIR"

# Phase 1: Pull latest from git
_log ""
_log "── Phase 1: Git pull ──"
git -C "$CLOUD_REPO" pull --ff-only 2>&1 || {
  _log "WARNING: git pull failed — using current local state"
}

# Phase 2: Copy updated modules to HM dir
_log ""
_log "── Phase 2: Copy source → ~/.config/home-manager ──"
if [ ! -d "$SRC_DIR" ]; then
  _log "ERROR: Source dir not found: $SRC_DIR"
  exit 1
fi

# Copy all .nix files and modules/ from source
for f in "$SRC_DIR"/*.nix; do
  [ -f "$f" ] && cp -f "$f" "$HM_DIR/" && _log "  Copied: $(basename "$f")"
done
if [ -d "$SRC_DIR/modules" ]; then
  cp -rf "$SRC_DIR/modules/"* "$HM_DIR/modules/" 2>/dev/null && _log "  Copied: modules/"
fi

# Phase 3: Re-apply home-manager
_log ""
_log "── Phase 3: home-manager switch ──"
home-manager switch --flake "${HM_DIR}#${HM_CONFIG}" 2>&1

_log ""
_log "── Done ──"
_log "HM rescue complete. Verify WG: sudo wg show"
