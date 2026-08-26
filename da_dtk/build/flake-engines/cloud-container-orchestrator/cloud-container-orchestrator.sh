#!/usr/bin/env bash
# Konsole Quick Commands — all commands live here, nix just calls: bash this.sh <id>
# No escaping hell. Pure bash.
# Every command prints itself (dimmed) so you can copy-paste and re-run.
set -euxo pipefail  # -x = verbose: print every command before execution
export BUILDSH_GUARDRAIL=1  # All commands here are intentional — bypass guardrail prompts

# Commands that need root use sudo inline — script runs as calling user

cmd="$1"; shift || true
vm="${1:-}"; shift || true

# Print the command being run (dimmed gray, copyable)
show() { printf '\033[0;90m$ %s\033[0m\n' "$*"; "$@"; }

# ── Connection mode: ssh (default), dropbear, serial ─────────────────
MODE_FILE="$HOME/.cache/konsole-conn-mode"
get_mode() { cat "$MODE_FILE" 2>/dev/null || echo "ssh"; }

# VM metadata: alias|user|provider|hasDropbear
VM_META="gcp-proxy|diego|gcp|1
oci-mail|ubuntu|oci|1
oci-analytics|ubuntu|oci|1
oci-apps|ubuntu|oci|1
gcp-t4|diego|gcp|0"

vm_field() { echo "$VM_META" | grep "^${1}|" | cut -d'|' -f"$2"; }

# Remote exec via current mode
rexec() {
  local _vm="$1"; shift
  local _mode; _mode="$(get_mode)"
  local _user; _user="$(vm_field "$_vm" 2)"
  case "$_mode" in
    ssh)
      printf '\033[0;90m[ssh] %s: %s\033[0m\n' "$_vm" "$*"
      ssh "$_vm" -t "$@" ;;
    dropbear)
      local _ip; _ip="$(vm_field "$_vm" 3)"
      # dropbear uses WG IP from ssh config, port 2200, no ControlMaster
      printf '\033[0;90m[dropbear:2200] %s: %s\033[0m\n' "$_vm" "$*"
      ssh -p 2200 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${_user}@${_vm}" -t "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; $*" ;;
    serial)
      local _provider; _provider="$(vm_field "$_vm" 3)"
      printf '\033[0;33m[serial] %s — interactive serial console (%s)\033[0m\n' "$_vm" "$_provider"
      if [ "$_provider" = "oci" ]; then
        bash "$0" "vm-oci-serial" "$_vm"
      else
        bash "$0" "vm-gcloud-serial" "$_vm"
      fi
      return 0 ;;
  esac
}

case "$cmd" in

  # ── Mode switcher ─────────────────────────────────────────────────
  mode-ssh)
    mkdir -p "$(dirname "$MODE_FILE")"
    echo "ssh" > "$MODE_FILE"
    printf '\033[1;32m✓ Mode set: SSH (port 22)\033[0m\n'
    ;;
  mode-dropbear)
    mkdir -p "$(dirname "$MODE_FILE")"
    echo "dropbear" > "$MODE_FILE"
    printf '\033[1;32m✓ Mode set: Dropbear (port 2200)\033[0m\n'
    ;;
  mode-serial)
    mkdir -p "$(dirname "$MODE_FILE")"
    echo "serial" > "$MODE_FILE"
    printf '\033[1;32m✓ Mode set: Serial console\033[0m\n'
    ;;
  mode-status)
    printf '\033[1;36mCurrent mode: %s\033[0m\n' "$(get_mode)"
    ;;

  # ── VM SSH connections (require $vm) ─────────────────────────────────
  vm-ssh)
    local _user; _user="$(vm_field "$vm" 2)"
    printf '\033[0;90m[ssh:22] %s@%s\033[0m\n' "$_user" "$vm"
    ssh "$vm"
    ;;
  vm-ssh-dropbear)
    local _user; _user="$(vm_field "$vm" 2)"
    printf '\033[0;90m[dropbear:2200] %s@%s\033[0m\n' "$_user" "$vm"
    ssh -p 2200 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${_user}@${vm}"
    ;;

  # ── VM commands (require $vm) ───────────────────────────────────────
  vm-htop)              rexec "$vm" htop ;;
  vm-journalctl-f)      rexec "$vm" sudo journalctl -f ;;
  vm-journal-docker)    rexec "$vm" sudo journalctl -u docker -n 15 --no-pager ;;
  vm-journal-sshd)      rexec "$vm" sudo journalctl -u sshd -u ssh -n 15 --no-pager ;;
  vm-journal-wg)        rexec "$vm" sudo journalctl -u wg-quick@wg0 -n 15 --no-pager ;;
  vm-journal-cinit)     rexec "$vm" sudo journalctl -u container-init -n 15 --no-pager ;;
  vm-journal-kernel)    rexec "$vm" sudo journalctl -k -n 15 --no-pager ;;
  vm-journal-errors)    rexec "$vm" sudo journalctl -p err -n 15 --no-pager ;;
  vm-systemctl-status)  rexec "$vm" sudo systemctl status ;;
  vm-systemctl-list)    rexec "$vm" sudo systemctl list-units --type=service --state=running ;;
  vm-docker-start)
    rexec "$vm" 'sudo systemctl start docker && systemctl status docker --no-pager -l'
    ;;
  vm-docker-stop)
    rexec "$vm" 'sudo systemctl stop docker && echo "Docker stopped" && systemctl is-active docker || true'
    ;;
  vm-docker-ps)
    rexec "$vm" 'sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
    ;;
  vm-docker-stats)      rexec "$vm" sudo docker stats ;;
  vm-docker-exec)
    rexec "$vm" 'sudo docker ps --format "{{.Names}}" && echo "---" && read -p "Container: " c && sudo docker exec -it "$c" sh'
    ;;
  vm-dashboard)
    SESSION="dash-${vm}"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    tmux new-session -d -s "$SESSION" -n "$vm" "ssh $vm -t sudo docker stats"
    tmux split-window -t "$SESSION" -v -p 30 "ssh $vm -t htop"
    tmux select-pane -t "$SESSION:0.0"
    tmux set-option -t "$SESSION" mouse on
    tmux attach-session -t "$SESSION"
    ;;

  # ── VM cloud control (oci/gcloud per-VM) ─────────────────────────────
  # OCI VM map: ssh_alias → instance_id from cloud-data (no API calls for lookup)
  vm-oci-start|vm-oci-stop|vm-oci-reset)
    ACTION="${cmd#vm-oci-}"
    ACTION_UPPER="$(echo "$ACTION" | tr '[:lower:]' '[:upper:]')"
    printf '\033[0;90m$ oci compute instance action --action %s (%s)\033[0m\n' "$ACTION_UPPER" "$vm"
    CLOUD_DATA="${CLOUD_DATA:-$HOME/git/cloud-infra/2_configs/dist/_cloud-data-consolidated.json}"
    OCID="$(jq -r ".vms | to_entries[] | select(.value.ssh_alias==\"$vm\") | .value.instance_id" "$CLOUD_DATA" 2>/dev/null)"
    [ -z "$OCID" ] && { echo "Instance not found in cloud-data for: $vm"; exit 1; }
    oci compute instance action --action "$ACTION_UPPER" --instance-id "$OCID" --output table
    ;;
  vm-oci-serial)
    printf '\033[0;90m$ oci serial console → %s\033[0m\n' "$vm"
    CLOUD_DATA="${CLOUD_DATA:-$HOME/git/cloud-infra/2_configs/dist/_cloud-data-consolidated.json}"
    OCID="$(jq -r ".vms | to_entries[] | select(.value.ssh_alias==\"$vm\") | .value.instance_id" "$CLOUD_DATA" 2>/dev/null)"
    [ -z "$OCID" ] && { echo "Instance not found in cloud-data for: $vm"; exit 1; }
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    # Find or create console connection
    CONN="$(oci compute instance-console-connection list --compartment-id "$CID" --instance-id "$OCID" --output json \
      | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | ."connection-string"' | head -1)"
    if [ -z "$CONN" ]; then
      echo "Creating console connection..."
      oci compute instance-console-connection create --instance-id "$OCID" --ssh-public-key-file ~/.ssh/id_rsa.pub --wait-for-state ACTIVE --output json >/dev/null
      CONN="$(oci compute instance-console-connection list --compartment-id "$CID" --instance-id "$OCID" --output json \
        | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | ."connection-string"' | head -1)"
    fi
    [ -z "$CONN" ] && { echo "Failed to get console connection"; exit 1; }
    echo "Connecting to serial console for $vm..."
    # OCI serial needs: ssh-rsa (legacy key), no ControlPath (OCID paths > 108 chars)
    # Both inner (ProxyCommand) and outer SSH must have these flags
    SSH_OPTS="-o ControlPath=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
    # The connection string looks like: ssh -o ProxyCommand='ssh -W %h:%p -p 443 <connid>@instance-console...' <instanceid>
    # Replace ALL 'ssh ' with 'ssh <opts> ' to cover both inner and outer
    FIXED_CONN="$(echo "$CONN" | sed "s|ssh -o |ssh $SSH_OPTS -o |g; s|ssh -W |ssh $SSH_OPTS -W |g")"
    eval "$FIXED_CONN"
    ;;
  # GCloud VM control
  vm-gcloud-start)  show gcloud compute instances start "$vm" --zone=us-central1-a ;;
  vm-gcloud-stop)   show gcloud compute instances stop "$vm" --zone=us-central1-a ;;
  vm-gcloud-reset)  show gcloud compute instances reset "$vm" --zone=us-central1-a ;;
  vm-gcloud-serial) show gcloud compute connect-to-serial-port "$vm" --zone=us-central1-a ;;

  # ── Orchestration commands (run on ALL VMs) ─────────────────────────
  # Interactive commands need special handling in orchestration
  all-docker-stats)
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    for v in $ALL_VMS; do
      printf '\033[1;36m══ %s ══\033[0m\n' "$v"
      rexec "$v" sudo docker stats --no-stream 2>&1 || printf '\033[0;31m  [FAILED]\033[0m\n'
      echo
    done
    ;;
  all-htop|all-journalctl-f)
    echo "ERROR: '$cmd' is interactive — use per-VM commands or vm-dashboard instead"
    exit 1
    ;;
  all-dashboard-stats)
    SESSION="dash-stats"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    CORE_VMS="gcp-proxy oci-mail oci-analytics oci-apps"
    # Tab 0: consolidated — 4 core VMs in quadrant layout
    FIRST_CORE=true
    for v in $CORE_VMS; do
      if $FIRST_CORE; then
        tmux new-session -d -s "$SESSION" -n "consolidated" "ssh $v -t 'watch -n2 sudo docker stats --no-stream || sleep 999'"
        FIRST_CORE=false
      else
        tmux split-window -t "$SESSION:consolidated" "ssh $v -t 'watch -n2 sudo docker stats --no-stream || sleep 999'"
      fi
    done
    tmux select-layout -t "$SESSION:consolidated" tiled
    # Per-VM tabs: docker stats + htop split
    for v in $ALL_VMS; do
      tmux new-window -t "$SESSION" -n "$v" "ssh $v -t 'sudo docker stats || echo No docker; sleep 999'"
      tmux split-window -t "$SESSION" -v -p 30 "ssh $v -t htop"
      tmux select-pane -t 0
    done
    tmux set-option -t "$SESSION" mouse on
    tmux select-window -t "$SESSION:consolidated"
    tmux attach-session -t "$SESSION"
    ;;
  all-dashboard-journal)
    SESSION="dash-journal"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    FIRST=true
    for v in $ALL_VMS; do
      if $FIRST; then
        tmux new-session -d -s "$SESSION" -n "$v" "ssh $v -t 'sudo journalctl -f'"
        FIRST=false
      else
        tmux new-window -t "$SESSION" -n "$v" "ssh $v -t 'sudo journalctl -f'"
      fi
      tmux split-window -t "$SESSION" -v -p 30 "ssh $v -t htop"
      tmux select-pane -t 0
    done
    tmux set-option -t "$SESSION" mouse on
    tmux select-window -t "$SESSION:gcp-proxy"
    tmux attach-session -t "$SESSION"
    ;;
  all-script-push)
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    RAW_URL="https://raw.githubusercontent.com/diegonmarcos/cloud-mykonsole-dtk/main/1-aliases/engines/cloud-container-orchestrator/cloud-container-orchestrator.sh"
    for v in $ALL_VMS; do
      printf '\033[1;36m══ %s ══\033[0m\n' "$v"
      ssh "$v" "mkdir -p ~/.local/share/konsole && curl -fsSL '$RAW_URL' -o ~/.local/share/konsole/cloud-container-orchestrator.sh && chmod +x ~/.local/share/konsole/cloud-container-orchestrator.sh && echo 'Done'" 2>&1 || printf '\033[0;31m  [FAILED]\033[0m\n'
      echo
    done
    ;;
  all-*)
    SUB="${cmd#all-}"
    ALL_VMS="gcp-proxy oci-mail oci-analytics oci-apps gcp-t4"
    for v in $ALL_VMS; do
      printf '\033[1;36m══ %s ══\033[0m\n' "$v"
      bash "$0" "vm-${SUB}" "$v" 2>&1 || printf '\033[0;31m  [FAILED]\033[0m\n'
      echo
    done
    ;;

  # ── Local commands (same as VM but run directly) ────────────────────
  local-htop)              show htop ;;
  local-journalctl-f)      show sudo journalctl -f ;;
  local-journal-docker)    show sudo journalctl -u docker -n 15 --no-pager ;;
  local-journal-sshd)      show sudo journalctl -u sshd -u ssh -n 15 --no-pager ;;
  local-journal-wg)        show sudo journalctl -u wg-quick@wg0 -n 15 --no-pager ;;
  local-journal-cinit)     show sudo journalctl -u container-init -n 15 --no-pager ;;
  local-journal-kernel)    show sudo journalctl -k -n 15 --no-pager ;;
  local-journal-errors)    show sudo journalctl -p err -n 15 --no-pager ;;
  local-systemctl-status)  show sudo systemctl status ;;
  local-systemctl-list)    show sudo systemctl list-units --type=service --state=running ;;
  local-docker-start)
    show sudo systemctl start docker
    sudo systemctl status docker --no-pager -l
    ;;
  local-docker-stop)
    show sudo systemctl stop docker
    echo "Docker stopped"
    sudo systemctl is-active docker || true
    ;;
  local-docker-ps)
    printf '\033[0;90m$ sudo docker ps --format "table {{.Names}}\\t{{.Status}}\\t{{.Ports}}"\033[0m\n'
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  local-docker-stats)      show sudo docker stats ;;
  local-docker-exec)
    printf '\033[0;90m$ sudo docker ps + exec\033[0m\n'
    sudo docker ps --format "{{.Names}}" && echo "---" && read -rp "Container: " c && sudo docker exec -it "$c" sh
    ;;

  # ── Desktop commands ────────────────────────────────────────────────
  dtk)              show bash ~/git/cloud-mykonsole-dtk/dtk.sh ;;
  dtk-install)      show bash ~/git/cloud-mykonsole-dtk/dtk.sh install ;;
  dtk-docker)       show bash ~/git/cloud-mykonsole-dtk/dtk.sh docker-start ;;
  dtk-git-clone)    show bash ~/git/cloud-mykonsole-dtk/dtk.sh git-clone ~/git ;;
  dtk-info)         show bash ~/git/cloud-mykonsole-dtk/dtk.sh info ;;
  dtk-commands)     show bash ~/git/cloud-mykonsole-dtk/dtk.sh commands ;;
  dtk-ssh)          show bash ~/git/cloud-mykonsole-dtk/dtk.sh ssh ;;
  desktop-htop)     show htop ;;
  hm-switch)        show ~/git/cloud-unix/ba_flakes_desktop/build.sh switch ;;
  nixos-switch)     show ~/git/cloud-unix/aa_nixos-surface_host/build.sh switch ;;
  git-status-all)
    printf '\033[0;90m$ for d in ~/git/*/; do git -C "$d" status -sb; done\033[0m\n'
    for d in ~/git/*/; do
      echo "=== $(basename "$d") ==="
      git -C "$d" status -sb
      echo
    done
    ;;
  wg-status)        show sudo wg show wg0 ;;
  docker-ps-local)
    printf '\033[0;90m$ sudo docker ps --format '\''table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'\''\033[0m\n'
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  free-mem)         show free -h ;;
  disk-usage)       show df -h / /home /nix /mnt/shared 2>/dev/null ;;

  # ── VPS - Cloud ─────────────────────────────────────────────────────
  oci-list)
    printf '\033[0;90m$ oci compute instance list --output table\033[0m\n'
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    oci compute instance list --compartment-id "$CID" --output table \
      --query 'data[*].{Name:"display-name",State:"lifecycle-state",Shape:shape}'
    ;;
  oci-details)
    printf '\033[0;90m$ oci compute instance list --output json | jq ...\033[0m\n'
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    oci compute instance list --compartment-id "$CID" --all --output json \
      | jq '.data[] | {name: ."display-name", state: ."lifecycle-state", shape: .shape, ocpus: ."shape-config".ocpus, memory: ."shape-config"."memory-in-gbs", created: ."time-created"}'
    ;;
  oci-vnics)
    printf '\033[0;90m$ oci compute vnic-attachment list\033[0m\n'
    CID="$(grep tenancy ~/.oci/config | head -1 | cut -d= -f2)"
    oci compute vnic-attachment list --compartment-id "$CID" --all --output json \
      | jq '.data[] | {instance: ."instance-id"[-12:], vnic: ."vnic-id"[-12:], state: ."lifecycle-state"}'
    ;;
  gcloud-list)
    printf '\033[0;90m$ gcloud compute instances list\033[0m\n'
    gcloud compute instances list \
      --format='table(name,zone,machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'
    ;;
  gcloud-details)
    printf '\033[0;90m$ gcloud compute instances list --format=json | jq ...\033[0m\n'
    gcloud compute instances list --format=json \
      | jq '.[] | {name: .name, zone: .zone, machine: .machineType, status: .status, ip: .networkInterfaces[0].accessConfigs[0].natIP, disks: [.disks[].diskSizeGb]}'
    ;;
  gcloud-billing)
    printf '\033[0;90m$ gcloud billing accounts list + instances + budgets + disks\033[0m\n'
    echo "=== Billing Account ==="
    gcloud billing accounts list --format='table(name,displayName,open)'
    echo
    echo "=== Running Instances ==="
    gcloud compute instances list --format='table(name,zone,machineType.basename(),status)'
    echo
    echo "=== Budgets ==="
    ACCT="$(gcloud billing accounts list --format='value(name)' | head -1)"
    gcloud billing budgets list --billing-account="$ACCT" \
      --format='table(displayName,amount.specifiedAmount.currencyCode,amount.specifiedAmount.units,budgetFilter.calendarPeriod)' \
      2>/dev/null || echo "No budgets or alpha API not enabled"
    echo
    echo "=== Disks ==="
    gcloud compute disks list --format='table(name,zone.basename(),sizeGb,type.basename(),status)'
    ;;

  # ── VPS - GH Actions ───────────────────────────────────────────────
  gha-runs-cloud)     show gh run list --repo diegonmarcos/cloud-infra --limit 15 ;;
  gha-failed-cloud)   show gh run list --repo diegonmarcos/cloud-infra --status failure --limit 10 ;;
  gha-log-cloud)
    printf '\033[0;90m$ gh run view --repo diegonmarcos/cloud-infra --log <latest> | tail -50\033[0m\n'
    RUN_ID="$(gh run list --repo diegonmarcos/cloud-infra --limit 1 --json databaseId --jq '.[0].databaseId')"
    gh run view --repo diegonmarcos/cloud-infra --log "$RUN_ID" 2>/dev/null | tail -50
    ;;
  gha-workflows)      show gh workflow list --repo diegonmarcos/cloud-infra ;;
  gha-runs-unix)      show gh run list --repo diegonmarcos/cloud-unix --limit 10 ;;
  gha-runs-front)     show gh run list --repo diegonmarcos/front --limit 10 ;;

  # ── VPS - GH Repos ─────────────────────────────────────────────────
  gh-repos-status)
    printf '\033[0;90m$ gh repo list diegonmarcos --limit 50 | jq ... | column -t\033[0m\n'
    gh repo list diegonmarcos --limit 50 --json name,visibility,pushedAt \
      | jq -r '.[] | [.name, .visibility, .pushedAt[:10]] | @tsv' | sort | column -t
    ;;
  gh-repos-list)      show gh repo list diegonmarcos --limit 50 ;;
  gh-prs)             show gh pr list --repo diegonmarcos/cloud-infra ;;
  gh-issues)          show gh issue list --repo diegonmarcos/cloud-infra ;;
  gh-commits)
    printf '\033[0;90m$ gh api repos/diegonmarcos/{cloud,unix,...}/commits?per_page=3\033[0m\n'
    for r in cloud cloud-data unix vault front-data octocode; do
      echo "=== $r ==="
      gh api "repos/diegonmarcos/$r/commits?per_page=3" \
        --jq '.[] | "  " + .commit.message[:60] + " (" + .commit.author.date[:10] + ")"' \
        2>/dev/null || echo "  NOT FOUND"
      echo
    done
    ;;

  # ── VPS - GH Registry ──────────────────────────────────────────────
  ghcr-list)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq .[].name\033[0m\n'
    gh api 'user/packages?package_type=container' --jq '.[].name' | sort
    ;;
  ghcr-versions)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq ...\033[0m\n'
    gh api 'user/packages?package_type=container' \
      --jq '.[] | .name + " (" + .package_type + ") updated: " + .updated_at[:10]' | sort
    ;;
  ghcr-count)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq ". | length"\033[0m\n'
    echo "Total GHCR packages: $(gh api 'user/packages?package_type=container' --jq '. | length')"
    ;;
  ghcr-inspect)
    printf '\033[0;90m$ gh api user/packages/container/<name>/versions\033[0m\n'
    echo "Package name:"
    read -r pkg
    gh api "user/packages/container/$pkg/versions" \
      --jq '.[] | (.metadata.container.tags // ["untagged"])[0] + " (" + .updated_at[:10] + ")"' \
      2>/dev/null || echo "Not found: $pkg"
    ;;
  ghcr-latest)
    printf '\033[0;90m$ gh api user/packages?package_type=container → versions for each\033[0m\n'
    gh api 'user/packages?package_type=container' --jq '.[].name' | while read -r pkg; do
      latest="$(gh api "user/packages/container/$pkg/versions" --jq '.[0].name // "?"' 2>/dev/null)"
      echo "$pkg: $latest"
    done | sort
    ;;
  ghcr-visibility)
    printf '\033[0;90m$ gh api user/packages?package_type=container --jq ".[] | .name + .visibility"\033[0m\n'
    gh api 'user/packages?package_type=container' \
      --jq '.[] | .name + ": " + .visibility' | sort
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Usage: $0 <command-id> [vm-alias]"
    exit 1
    ;;
esac
