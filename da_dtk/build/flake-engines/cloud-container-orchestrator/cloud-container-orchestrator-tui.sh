#!/usr/bin/env bash
# cloud-container-orchestrator TUI — tmux split: fzf menu (left) + output (right)
# Mirrors the Konsole Quick Commands sidebar in a portable terminal interface.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/cloud-container-orchestrator.sh"
SESSION="cco-tui"
MENU_FILE="/tmp/cco-tui-menu.txt"
CMD_FILE="/tmp/cco-tui-cmd.txt"

# ── Menu definition ──────────────────────────────────────────────────
# Format: "category | label | engine-cmd arg1 arg2"
# The engine command is passed directly to cloud-container-orchestrator.sh
VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"

generate_menu() {
  cat <<'STATIC'
──────────── Mode ────────────
Mode             | SSH (default)              | mode-ssh
Mode             | Dropbear                   | mode-dropbear
Mode             | Serial                     | mode-serial
Mode             | status                     | mode-status
STATIC

  # Per-VM commands
  for vm in $VMS; do
    cat <<EOF
──────────── VM: $vm ────────────
VM: $vm          | ssh (port 22)              | vm-ssh $vm
VM: $vm          | ssh dropbear (port 2200)   | vm-ssh-dropbear $vm
VM: $vm          | htop                       | vm-htop $vm
VM: $vm          | journalctl -f              | vm-journalctl-f $vm
VM: $vm          | journal: docker            | vm-journal-docker $vm
VM: $vm          | journal: sshd              | vm-journal-sshd $vm
VM: $vm          | journal: wireguard         | vm-journal-wg $vm
VM: $vm          | journal: container-init    | vm-journal-cinit $vm
VM: $vm          | journal: kernel            | vm-journal-kernel $vm
VM: $vm          | journal: errors            | vm-journal-errors $vm
VM: $vm          | systemctl status           | vm-systemctl-status $vm
VM: $vm          | systemctl list-units       | vm-systemctl-list $vm
VM: $vm          | docker start               | vm-docker-start $vm
VM: $vm          | docker stop                | vm-docker-stop $vm
VM: $vm          | docker ps                  | vm-docker-ps $vm
VM: $vm          | docker stats               | vm-docker-stats $vm
VM: $vm          | docker exec                | vm-docker-exec $vm
VM: $vm          | dashboard                  | vm-dashboard $vm
EOF
    # Cloud control per provider
    case "$vm" in
      oci-*)
        cat <<EOF
VM: $vm          | oci start                  | vm-oci-start $vm
VM: $vm          | oci stop                   | vm-oci-stop $vm
VM: $vm          | oci reset                  | vm-oci-reset $vm
VM: $vm          | oci serial                 | vm-oci-serial $vm
EOF
        ;;
      gcp-proxy)
        cat <<EOF
VM: $vm          | gcloud start               | vm-gcloud-start arch-1
VM: $vm          | gcloud stop                | vm-gcloud-stop arch-1
VM: $vm          | gcloud reset               | vm-gcloud-reset arch-1
VM: $vm          | gcloud serial              | vm-gcloud-serial arch-1
EOF
        ;;
      gcp-t4)
        cat <<EOF
VM: $vm          | gcloud start               | vm-gcloud-start ollama-spot-gpu
VM: $vm          | gcloud stop                | vm-gcloud-stop ollama-spot-gpu
VM: $vm          | gcloud reset               | vm-gcloud-reset ollama-spot-gpu
VM: $vm          | gcloud serial              | vm-gcloud-serial ollama-spot-gpu
EOF
        ;;
    esac
  done

  cat <<'STATIC'
──────────── Orchestration (all VMs) ────────────
All VMs          | journal: docker            | all-journal-docker
All VMs          | journal: sshd              | all-journal-sshd
All VMs          | journal: wireguard         | all-journal-wg
All VMs          | journal: container-init    | all-journal-cinit
All VMs          | journal: kernel            | all-journal-kernel
All VMs          | journal: errors            | all-journal-errors
All VMs          | systemctl status           | all-systemctl-status
All VMs          | systemctl list-units       | all-systemctl-list
All VMs          | docker start               | all-docker-start
All VMs          | docker stop                | all-docker-stop
All VMs          | docker ps                  | all-docker-ps
All VMs          | docker stats               | all-docker-stats
All VMs          | dashboard-stats            | all-dashboard-stats
All VMs          | dashboard-journal          | all-dashboard-journal
All VMs          | script push                | all-script-push
──────────── Local ────────────
Local            | htop                       | local-htop
Local            | journalctl -f              | local-journalctl-f
Local            | journal: docker            | local-journal-docker
Local            | journal: sshd              | local-journal-sshd
Local            | journal: wireguard         | local-journal-wg
Local            | journal: container-init    | local-journal-cinit
Local            | journal: kernel            | local-journal-kernel
Local            | journal: errors            | local-journal-errors
Local            | systemctl status           | local-systemctl-status
Local            | systemctl list-units       | local-systemctl-list
Local            | docker start               | local-docker-start
Local            | docker stop                | local-docker-stop
Local            | docker ps                  | local-docker-ps
Local            | docker stats               | local-docker-stats
Local            | docker exec                | local-docker-exec
──────────── Desktop ────────────
Desktop          | dtk.sh (interactive)       | dtk
Desktop          | install dev toolchain      | dtk-install
Desktop          | docker-start (dev)         | dtk-docker
Desktop          | git-clone (all repos)      | dtk-git-clone
Desktop          | info (installed tools)     | dtk-info
Desktop          | commands (VM rescue)       | dtk-commands
Desktop          | ssh (gcloud serial)        | dtk-ssh
Desktop          | htop                       | desktop-htop
Desktop          | hm build switch            | hm-switch
Desktop          | nixos rebuild switch        | nixos-switch
Desktop          | git status (all repos)     | git-status-all
Desktop          | wg status                  | wg-status
Desktop          | docker ps (local)          | docker-ps-local
Desktop          | free memory                | free-mem
Desktop          | disk usage                 | disk-usage
──────────── Cloud ────────────
Cloud            | oci list instances         | oci-list
Cloud            | oci instance details       | oci-details
Cloud            | oci vnic/IP list           | oci-vnics
Cloud            | gcloud list instances      | gcloud-list
Cloud            | gcloud instance details    | gcloud-details
Cloud            | gcloud billing + costs     | gcloud-billing
──────────── GH Actions ────────────
GH Actions       | runs: cloud (recent)       | gha-runs-cloud
GH Actions       | runs: cloud (failed)       | gha-failed-cloud
GH Actions       | runs: cloud (latest log)   | gha-log-cloud
GH Actions       | workflows list             | gha-workflows
GH Actions       | runs: unix (recent)        | gha-runs-unix
GH Actions       | runs: front (recent)       | gha-runs-front
──────────── GH Repos ────────────
GH Repos         | status: all repos          | gh-repos-status
GH Repos         | list: all repos            | gh-repos-list
GH Repos         | PRs: open (cloud)          | gh-prs
GH Repos         | issues: open (cloud)       | gh-issues
GH Repos         | recent commits             | gh-commits
──────────── GH Registry ────────────
GH Registry      | list: all packages         | ghcr-list
GH Registry      | list: with versions        | ghcr-versions
GH Registry      | count: total               | ghcr-count
GH Registry      | versions: inspect          | ghcr-inspect
GH Registry      | latest: all images         | ghcr-latest
GH Registry      | visibility: all            | ghcr-visibility
STATIC
}

# ── Menu selector (runs in left pane loop) ───────────────────────────
run_menu() {
  local engine="$1"
  local output_pane="$2"

  while true; do
    # Generate menu, filter separator lines for fzf, keep them for display
    generate_menu > "$MENU_FILE"

    selected=$(
      grep -v '^─' "$MENU_FILE" \
      | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "\033[36m%-18s\033[0m %s\n", $1, $2 }' \
      | fzf --ansi --no-sort --reverse --cycle \
            --header="$(printf '\033[1;33m Cloud Container Orchestrator \033[0m  q=quit  enter=run')" \
            --prompt="cmd> " \
            --preview-window=hidden \
            --bind='ctrl-c:abort' \
      || true
    )

    # Quit on empty selection (ctrl-c / esc)
    [ -z "$selected" ] && break

    # Extract the label back to find the command
    label="$(echo "$selected" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*//' | sed 's/^[^ ]* *//')"
    cmd_line="$(grep -F "$label" "$MENU_FILE" | head -1 | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }')"

    [ -z "$cmd_line" ] && continue

    # Send command to output pane
    tmux send-keys -t "$output_pane" "clear" C-m
    tmux send-keys -t "$output_pane" "bash '$engine' $cmd_line" C-m
  done

  # User quit — kill session
  tmux kill-session -t "$SESSION" 2>/dev/null || true
}

# ── Main: launch tmux session ────────────────────────────────────────

# Kill existing session if any
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Export function + vars for the menu pane subprocess
export -f run_menu generate_menu
export VMS ENGINE MENU_FILE SESSION

# Create session with output pane (right, 70%)
tmux new-session -d -s "$SESSION" -n "cco" \
  -x "$(tput cols)" -y "$(tput lines)"

# Split: left = menu (30%), right = output (70%)
tmux split-window -t "$SESSION" -h -l "70%" \
  "echo -e '\033[1;33m Select a command from the left pane \033[0m'; exec bash"

# The right pane is now pane 1
OUTPUT_PANE="$SESSION:cco.1"

# Run menu in the left pane (pane 0)
tmux send-keys -t "$SESSION:cco.0" \
  "run_menu '$ENGINE' '$OUTPUT_PANE'; exit" C-m

# Style
tmux set-option -t "$SESSION" mouse on
tmux set-option -t "$SESSION" status-style "bg=#1a1a2e,fg=#e0e0e0"
tmux set-option -t "$SESSION" status-left "#[fg=#f7c948,bold] CCO TUI "
tmux set-option -t "$SESSION" status-right "#[fg=#888]mode: $(cat "$HOME/.cache/konsole-conn-mode" 2>/dev/null || echo ssh) "
tmux set-option -t "$SESSION" pane-border-style "fg=#333"
tmux set-option -t "$SESSION" pane-active-border-style "fg=#f7c948"

# Focus menu pane and attach
tmux select-pane -t "$SESSION:cco.0"
tmux attach-session -t "$SESSION"
