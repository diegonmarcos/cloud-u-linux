#!/bin/sh
# SSH module — GCP serial/ssh/rescue for cloud VMs
set -eu

PROJECT="diego-cloud"

resolve_vm() {
  case "$1" in
    gcp-proxy) INSTANCE="arch-1";          ZONE="us-central1-a" ;;
    gcp-t4)    INSTANCE="ollama-spot-gpu"; ZONE="us-central1-a" ;;
    *) echo "Unknown VM: $1 (available: gcp-proxy gcp-t4)"; exit 1 ;;
  esac
}

_mode="${1:-}"
_vm="${2:-}"

if [ -z "$_mode" ] || [ -z "$_vm" ]; then
  echo "SSH Mode:"
  echo "  1) serial"
  echo "  2) ssh"
  echo "  3) rescue"
  echo "  4) reset"
  echo "  5) kill-watchdog"
  printf "> "
  read -r _mi
  case "$_mi" in
    1) _mode="serial" ;; 2) _mode="ssh" ;; 3) _mode="rescue" ;;
    4) _mode="reset" ;; 5) _mode="kill-watchdog" ;;
    b|B) exit 0 ;; *) echo "Invalid"; exit 1 ;;
  esac

  echo "VM:"
  echo "  1) gcp-proxy"
  echo "  2) gcp-t4"
  printf "> "
  read -r _vi
  case "$_vi" in
    1) _vm="gcp-proxy" ;; 2) _vm="gcp-t4" ;;
    b|B) exit 0 ;; *) echo "Invalid"; exit 1 ;;
  esac
fi

resolve_vm "$_vm"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found — install first (dtk.sh install)"
  exit 1
fi

case "$_mode" in
  serial)        gcloud compute connect-to-serial-port "$INSTANCE" --zone="$ZONE" --project="$PROJECT" ;;
  ssh)           gcloud compute ssh root@"$INSTANCE" --zone="$ZONE" --project="$PROJECT" ;;
  rescue)        gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command='sudo iptables -F INPUT; sudo iptables -P INPUT ACCEPT; sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; echo done' ;;
  reset)         gcloud compute instances reset "$INSTANCE" --zone="$ZONE" --project="$PROJECT" ;;
  kill-watchdog) gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command='sudo systemctl stop watchdog-petter.timer watchdog-petter.service 2>/dev/null; sudo systemctl disable watchdog-petter.timer 2>/dev/null; echo done' ;;
  *) echo "Unknown mode: $_mode"; exit 1 ;;
esac
