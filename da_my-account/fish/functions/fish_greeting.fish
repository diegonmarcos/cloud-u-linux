# Gather system info
set -l user (whoami)
set -l host (hostname -s)
set -l hostname_full (hostname)
set -l profile "$HM_PROFILE"; test -z "$profile" && set profile "unknown"
set -l os "NixOS"
set -l kernel (uname -r)
set -l kernel_short (uname -r | cut -d'-' -f1)
set -l arch (uname -m)
set -l shell "Fish $FISH_VERSION"
set -l de "$XDG_CURRENT_DESKTOP"
set -l uptime_secs (command cat /proc/uptime | cut -d. -f1)
set -l uptime_days (math -s0 "$uptime_secs / 86400")
set -l uptime_hours (math -s0 "($uptime_secs % 86400) / 3600")
set -l uptime_mins (math -s0 "($uptime_secs % 3600) / 60")
set -l uptime_str "$uptime_days"d" ""$uptime_hours"h" ""$uptime_mins"m
set -l cpu_name (command grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //' | sed 's/(R)//g' | sed 's/(TM)//g' | string sub -l 25)
set -l cpu_cores (nproc)
set -l cpu_freq (math -s0 (command cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)" / 1000")
set -l mem_info (command free -h | awk '/Mem:/ {print $3"/"$2}')
set -l mem_perc (command free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
set -l disk_info (command df -h /nix | awk 'NR==2 {print $3"/"$2}')
set -l disk_perc (command df /nix | awk 'NR==2 {gsub(/%/,""); print $5}')
set -l ip_addr (curl -sf --max-time 2 ifconfig.me 2>/dev/null; or echo "offline")
set -l ip_priv (ip -4 addr show scope global 2>/dev/null | awk '/inet / {gsub(/\/.*/, "", $2); iface=$NF; if (iface !~ /docker|br-|veth/) printf "%s(%s) ", $2, iface}' | string trim)
set -l dns_servers (command awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | string trim)
set -l load_avg (command cat /proc/loadavg | awk '{print $1" "$2" "$3}')
set -l pkgs (command ls /nix/store 2>/dev/null | wc -l | string trim)
set -l procs (command ls /proc 2>/dev/null | grep -c '^[0-9]')
set -l datetime (date '+%d-%m-%Y %H:%M')
set -l gpu (lspci 2>/dev/null | grep -i vga | sed 's/.*: //' | string sub -l 25)

# Security info
set -l ssh_status (systemctl is-active sshd 2>/dev/null); test -z "$ssh_status" && set ssh_status "n/a"
set -l fw_status (systemctl is-active firewalld 2>/dev/null); test -z "$fw_status" && set fw_status "n/a"
set -l fail2ban (systemctl is-active fail2ban 2>/dev/null); test -z "$fail2ban" && set fail2ban "n/a"
set -l open_ports (ss -tuln 2>/dev/null | grep LISTEN | wc -l | string trim)
set -l last_login (last -1 -R $user 2>/dev/null | head -1 | awk '{print $4" "$5" "$6}')
test -z "$last_login" && set last_login "n/a"

# ASCII Art Banner
echo
set_color --bold cyan
echo "    ███████╗██╗███████╗██╗  ██╗"
echo "    ██╔════╝██║██╔════╝██║  ██║"
echo "    █████╗  ██║███████╗███████║"
echo "    ██╔══╝  ██║╚════██║██╔══██║"
echo "    ██║     ██║███████║██║  ██║"
echo "    ╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝"
set_color normal
echo

# Header bar with profile name
set_color --bold blue
printf "  ╭───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮\n"
printf "  │ "; set_color --bold white; printf "%s" $user; set_color brblack; printf "@"; set_color --bold green; printf "%-18s" $host
set_color brblack; printf "│ "; set_color cyan; printf "%-17s" $datetime
set_color brblack; printf "│ "; set_color yellow; printf "Profile: %-12s" $profile
set_color brblack; printf "│ "; set_color magenta; printf "%-18s" "$os $kernel_short"; set_color --bold blue; printf "│\n"
printf "  ╰───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
set_color normal
echo

# ROW 1: HARDWARE | OS (MAGENTA)
set_color --bold magenta
printf "  ┌─ HARDWARE ─────────────────────────────────────┐ ┌─ SYSTEM ──────────────────────────────────────┐\n"
set_color normal
printf "  │ "; set_color magenta; printf "CPU    "; set_color normal; printf "%-40s" "$cpu_name"; printf "│ │ "; set_color magenta; printf "OS     "; set_color normal; printf "%-39s" "$os $kernel_short"; printf "│\n"
printf "  │ "; set_color magenta; printf "Cores  "; set_color normal; printf "%-40s" "$cpu_cores @ $cpu_freq MHz"; printf "│ │ "; set_color magenta; printf "Host   "; set_color normal; printf "%-39s" (string sub -l 39 "$hostname_full"); printf "│\n"
printf "  │ "; set_color magenta; printf "GPU    "; set_color normal; printf "%-40s" "$gpu"; printf "│ │ "; set_color magenta; printf "Kernel "; set_color normal; printf "%-39s" "$kernel"; printf "│\n"
printf "  │ "; set_color magenta; printf "RAM    "; set_color normal; printf "%-40s" "$mem_info ($mem_perc%)"; printf "│ │ "; set_color magenta; printf "DE     "; set_color normal; printf "%-39s" "$de"; printf "│\n"
printf "  │ "; set_color magenta; printf "Disk   "; set_color normal; printf "%-40s" "$disk_info ($disk_perc%)"; printf "│ │ "; set_color magenta; printf "Shell  "; set_color normal; printf "%-39s" "$shell"; printf "│\n"
set_color --bold magenta
printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
set_color normal
echo

# ROW 2: NETWORK | SECURITY (YELLOW)
set_color --bold yellow
printf "  ┌─ NETWORK ──────────────────────────────────────┐ ┌─ SECURITY STATUS ────────────────────────────┐\n"
set_color normal
printf "  │ "; set_color yellow; printf "IP-Pub "; set_color normal; printf "%-40s" "$ip_addr"; printf "│ │ "; set_color yellow; printf "SSH      "; set_color normal; printf "%-37s" "$ssh_status"; printf "│\n"
printf "  │ "; set_color yellow; printf "IP-Priv"; set_color normal; printf " %-39s" "$ip_priv"; printf "│ │ "; set_color yellow; printf "Firewall "; set_color normal; printf "%-37s" "$fw_status"; printf "│\n"
printf "  │ "; set_color yellow; printf "DNS    "; set_color normal; printf "%-40s" "$dns_servers"; printf "│ │ "; set_color yellow; printf "Fail2ban "; set_color normal; printf "%-37s" "$fail2ban"; printf "│\n"
printf "  │ "; set_color yellow; printf "Load   "; set_color normal; printf "%-40s" "$load_avg"; printf "│ │ "; set_color yellow; printf "Ports    "; set_color normal; printf "%-37s" "$open_ports listening"; printf "│\n"
printf "  │ "; set_color yellow; printf "Uptime "; set_color normal; printf "%-40s" "$uptime_str"; printf "│ │ "; set_color yellow; printf "Last     "; set_color normal; printf "%-37s" "$last_login"; printf "│\n"
set_color --bold yellow
printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
set_color normal
echo

# ══════════════════ Tree ══════════════════
set_color --bold blue; echo "── Tree ───────────────────────────────────────────────────────────────────────────────────────"
set_color normal
set_color blue; echo -n "  ~/git/"; set_color normal
echo ""
printf "    "
for d in front cloud vault unix tools cloud-data front-data
  if test -d "$HOME/git/$d"
    set_color green; printf "%-14s" "$d/"
  else
    set_color red; printf "%-14s" "$d/"
  end
end
set_color normal; echo ""
set_color blue; echo -n "  ~/Mounts/Storage/"; set_color normal
echo ""
printf "    "
for d in Gdrive_dnm Gdrive_me
  if test -d "$HOME/Mounts/Storage/$d"
    set_color green; printf "%-14s" "$d/"
  else
    set_color red; printf "%-14s" "$d/"
  end
end
set_color normal; echo ""; echo ""


# ══════════════════ Configuration ══════════════════
set_color --bold magenta; echo "── Configuration ──────────────────────────────────────────────────────────────────────────────"
set_color normal
# Flakes
set_color cyan; echo "  Flakes:"
set_color normal
set_color magenta; echo -n "    NixOS            "; set_color normal; echo "~/git/cloud-infra-desktop/aa_desk-usr_x86_surface-linux_nixos/"
set_color magenta; echo -n "    OS Modules       "; set_color normal; echo "~/git/cloud-infra-desktop/aa_desk-usr_x86_surface-linux_nixos/src/modules/"
set_color magenta; echo -n "    Home-Manager     "; set_color normal; echo "~/git/cloud-infra-desktop/ba_flakes_desktop/"
set_color magenta; echo -n "    HM Modules       "; set_color normal; echo "~/git/cloud-infra-desktop/ba_flakes_desktop/src/modules/"
# Wrappers - Guardrails
set_color cyan; echo "  Wrappers - Guardrails:"
set_color normal
set_color red; echo -n "    BLOCKED          "; set_color normal; echo "rm -rf /, mkfs, dd (always denied)"
set_color yellow; echo -n "    CONFIRM          "; set_color normal; echo "npm npx docker nix pip apt pkg (ask before run)"
set_color blue; echo -n "    WARNING          "; set_color normal; echo "bun cargo go (warn on write ops)"
# Wrappers - Custom
set_color cyan; echo "  Wrappers - Custom:"
set_color normal
set_color green; echo -n "    curl/wget        "; set_color normal; echo "Auto-inject Authelia token for *.diegonmarcos.com"
set_color --dim; echo "    ('hhelp config' — cat flake.nix)"; set_color normal
echo ""

# ══════════════════ Tools ══════════════════
set_color --bold green; echo "── Tools ──────────────────────────────────────────────────────────────────────────────────────"
set_color normal
# Nix Flakes
set_color cyan; echo "  Nix Flakes:"
set_color normal
set_color magenta; echo -n "    up               "; set_color normal; echo "Rebuild Nix config"
set_color magenta; echo -n "    conf             "; set_color normal; echo "Edit flake.nix"
set_color magenta; echo -n "    dtk              "; set_color normal; echo "Diego's Toolkit (cloud ops, dashboards, webhooks)"
# Dev
set -l _claude_ver (claude --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
set -l _goose_ver (goose --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
set -l _ant_ver (command -q ant && ant --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
set_color cyan; echo "  Dev:"
set_color normal
set_color green; echo -n "    claude           "; set_color normal; echo "Native Anthropic binary (v$_claude_ver)"
set_color green; echo -n "    claude-superset  "; set_color normal; echo -n "claude via Headroom proxy "; set_color --dim; echo "(token compression over WG · falls back to direct)"; set_color normal
set_color green; echo -n "    claude-superset-tui  "; set_color normal; echo -n "helper TUI "; set_color --dim; echo "(live savings · health · dashboard · launch) · tray applet autostarts"; set_color normal
set_color green; echo -n "    claude-termux    "; set_color normal; echo "Android-safe (io_uring fix + 1GB cap)"
set_color green; echo -n "    claude-malloc    "; set_color normal; echo "Max memory (2GB) + TMPDIR isolation"
set_color green; echo -n "    claude-rescue    "; set_color normal; echo "Fallback chain: podman → npx → nix → node"
set_color green; echo -n "    ant              "; set_color normal; echo "Anthropic Claude Platform CLI (v$_ant_ver) · Messages, Managed Agents, Files"
set_color green; echo -n "    ai-cli           "; set_color normal; echo -n "Goose AI (v$_goose_ver) "; set_color --dim; echo "default: Haiku 4.5 · ai-cli -h for models"; set_color normal
set_color green; echo -n "    code             "; set_color normal; echo "VS Code Server (local/lan/stop)"
# Cloud
set_color cyan; echo "  Cloud:"
set_color normal
set_color red; echo -n "    connect          "; set_color normal; echo "Cloud Connect Unified dashboard (git/mounts/sync/servers)"
set_color red; echo -n "    sync             "; set_color normal; echo "File sync & serve (WebDAV SFTP HTTP+Eruda)"
# http-dev status
if systemctl --user is-active http-dev.service >/dev/null 2>&1
  set -l _httpd_pid (systemctl --user show http-dev.service -p MainPID --value 2>/dev/null)
  set_color green; echo -n "    http-dev         "; set_color normal; echo -n "● Web+MD+Eruda "; set_color cyan; echo -n "http://127.0.0.1:$__httpd_port"; set_color normal; echo " (PID: $_httpd_pid)"
else
  set_color red; echo -n "    http-dev         "; set_color normal; echo "○ Not running"
end
# System
set_color cyan; echo "  System:"
set_color normal
set_color magenta; echo -n "    tree             "; set_color normal; echo "Directory tree"
set_color magenta; echo -n "    yazi             "; set_color normal; echo "Terminal file manager"
set_color magenta; echo -n "    tldr             "; set_color normal; echo "Simplified man pages (tealdeer)"
set_color magenta; echo -n "    tmux             "; set_color normal; echo "Terminal multiplexer (sessions, splits, detach)"
set_color magenta; echo -n "    browsh           "; set_color normal; echo "Web browser in terminal (headless Firefox)"
set_color magenta; echo -n "    nmtui            "; set_color normal; echo "Network Manager TUI (WiFi, VPN, connections)"
# Search (fzf)
set_color cyan; echo "  Search (fzf + atuin):"
set_color normal
set_color blue; echo -n "    ↑                "; set_color normal; echo "Classic per-command history recall"
set_color blue; echo -n "    Ctrl+R           "; set_color normal; echo "Atuin fuzzy history search"
set_color blue; echo -n "    Ctrl+T           "; set_color normal; echo "Find file (fzf)"
set_color blue; echo -n "    Alt+C            "; set_color normal; echo "Cd to folder (fzf)"
set_color cyan; echo "  Clipboard (cliphist):"
set_color normal
set_color blue; echo -n "    cliphist list    "; set_color normal; echo "Show clipboard history"
set_color blue; echo -n "    cliphist list | fzf | cliphist decode | wl-copy"; set_color normal; echo ""
echo ""
set_color --dim; echo "    ('hhelp tools' — all binaries declared in flake)"; set_color normal
echo ""

# ══════════════════ Env Vars ══════════════════
# GENERATED — __cloud_envvars_help, built by fish.nix from
# bb_flakes_termux/src/modules/data/fish-envvars.json (one shared copy).
# Names from that file, values read live, secrets shown as "set (hidden)".
__cloud_envvars_help
echo ""

# ══════════════════ Alias/Functions ══════════════════
# GENERATED — __cloud_commands_help, built by fish.nix from the very
# shellAbbrs/shellAliases attrsets that define them, so this can never
# advertise something that is not installed.
__cloud_commands_help
echo ""

set_color cyan; echo ""
echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
set_color normal
