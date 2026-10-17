function fish_greeting
    # Every probe below is guarded (`command -q`, readable-file tests) and silenced, and every
    # value may be empty: the greeting prints NOTHING to stderr on any host, including an
    # Android/proot session (no hostname/free/ip/ss/lspci/systemctl, /proc/uptime and
    # /proc/loadavg denied by SELinux). test-fish-greeting.sh asserts that.
    set -l android 0
    if set -q ANDROID_ROOT; or set -q TERMUX_VERSION; or test -e /system/build.prop
        set android 1
    end

    # Gather system info
    set -l user (command whoami 2>/dev/null)
    test -z "$user" && set user (command id -un 2>/dev/null)
    test -z "$user" && set user "$USER"
    test -z "$user" && set user (command id -u 2>/dev/null)
    set -l host ""
    set -l hostname_full ""
    if test $android = 1
        for g in getprop android-host-exec
            command -q $g; or continue
            set -l a ro.product.model
            test $g = android-host-exec && set a getprop ro.product.model
            set hostname_full (command $g $a 2>/dev/null | string trim)
            test -n "$hostname_full" && break
        end
    end
    if test -z "$hostname_full"; and command -q hostname
        set hostname_full (command hostname 2>/dev/null)
    end
    if test -z "$hostname_full"; and test -r /proc/sys/kernel/hostname
        set hostname_full (command cat /proc/sys/kernel/hostname 2>/dev/null)
    end
    test -z "$hostname_full" && set hostname_full "$HOSTNAME"
    set hostname_full "$hostname_full"
    set host (string split -m1 . -- "$hostname_full")[1]
    set -l profile "$HM_PROFILE"
    test -z "$profile" && set profile unknown
    set -l os NixOS
    test $android = 1 && set os Android
    set -l kernel (command uname -r 2>/dev/null)
    set -l kernel_short (string split -m1 - -- "$kernel")[1]
    set -l arch (command uname -m 2>/dev/null)
    set -l shell "Fish $FISH_VERSION"
    set -l de "$XDG_CURRENT_DESKTOP"
    set -l uptime_str n/a
    set -l uptime_secs ""
    test -r /proc/uptime && set uptime_secs (string split -m1 . -- (command cat /proc/uptime 2>/dev/null))[1]
    if string match -qr '^[0-9]+$' -- "$uptime_secs"
        set -l d (math -s0 "$uptime_secs / 86400")
        set -l h (math -s0 "($uptime_secs % 86400) / 3600")
        set -l m (math -s0 "($uptime_secs % 3600) / 60")
        set uptime_str "$d"d" ""$h"h" ""$m"m
    end
    set -l cpu_name ""
    test -r /proc/cpuinfo && set cpu_name (command awk -F': *' '/^(model name|Hardware|Processor)/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | string replace -a '(R)' '' | string replace -a '(TM)' '' | string sub -l 25)
    set -l cpu_cores (command nproc 2>/dev/null)
    set -l cpu_freq ""
    set -l _f ""
    test -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq && set _f (command cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    string match -qr '^[0-9]+$' -- "$_f" && set cpu_freq (math -s0 "$_f / 1000")
    set -l cores_str "$cpu_cores"
    test -n "$cpu_freq" && set cores_str "$cpu_cores @ $cpu_freq MHz"
    # RAM straight from /proc/meminfo (free is absent on Android; this works everywhere).
    set -l mem_info n/a
    set -l mem_t ""
    set -l mem_a ""
    if test -r /proc/meminfo
        set mem_t (command awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
        set mem_a (command awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    end
    if string match -qr '^[0-9]+$' -- "$mem_t"; and string match -qr '^[0-9]+$' -- "$mem_a"; and test "$mem_t" -gt 0
        set -l used (math -s1 "($mem_t - $mem_a) / 1048576")
        set -l tot (math -s1 "$mem_t / 1048576")
        set mem_info "$used"G/"$tot"G" ("(math -s0 "($mem_t - $mem_a) * 100 / $mem_t")"%)"
    end
    set -l disk_dir /nix
    test -d $disk_dir; or set disk_dir $HOME
    set -l disk_info (command df -hP $disk_dir 2>/dev/null | command awk 'NR==2 {print $3"/"$2" ("$5")"}')
    test -z "$disk_info" && set disk_info n/a
    set -l ip_addr offline
    if command -q curl
        set -l _ip (command curl -sf --max-time 2 ifconfig.me 2>/dev/null)
        test -n "$_ip" && set ip_addr "$_ip"
    end
    set -l ip_priv ""
    if command -q ip
        set ip_priv (command ip -4 addr show scope global 2>/dev/null | command awk '/inet / {gsub(/\/.*/, "", $2); iface=$NF; if (iface !~ /docker|br-|veth/) printf "%s(%s) ", $2, iface}' | string trim)
    end
    set -l dns_servers ""
    test -r /etc/resolv.conf && set dns_servers (command awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | string trim)
    set -l load_avg n/a
    if test -r /proc/loadavg
        set -l _l (command awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)
        test -n "$_l" && set load_avg "$_l"
    end
    set -l datetime (command date '+%d-%m-%Y %H:%M' 2>/dev/null)
    set -l gpu ""
    if test $android = 0; and command -q lspci
        set gpu (command lspci 2>/dev/null | command grep -i vga | command sed 's/.*: //' | string sub -l 25)
    end

    # Security info. Android: no systemd/firewalld/fail2ban; show the terminal's own sshd ports.
    set -l sec1_k "SSH      "
    set -l sec2_k "Firewall "
    set -l sec3_k "Fail2ban "
    set -l ssh_status n/a
    set -l fw_status n/a
    set -l fail2ban n/a
    set -l listen_hex ""
    for f in /proc/net/tcp /proc/net/tcp6
        test -r $f; or continue
        set -a listen_hex (command awk '$4 == "0A" {split($2, a, ":"); print a[2]}' $f 2>/dev/null)
    end
    if test $android = 1
        set sec1_k "SSH 8023 "
        set sec2_k "SSH 8024 "
        set sec3_k "Mode     "
        set fail2ban "android/proot"
        set ssh_status unknown
        set fw_status unknown
        if test -n "$listen_hex"
            set ssh_status down
            set fw_status down
            contains 1F57 $listen_hex && set ssh_status listening
            contains 1F58 $listen_hex && set fw_status listening
        end
    else if command -q systemctl
        set ssh_status (command systemctl is-active sshd 2>/dev/null)
        test -z "$ssh_status" && set ssh_status n/a
        set fw_status (command systemctl is-active firewalld 2>/dev/null)
        test -z "$fw_status" && set fw_status n/a
        set fail2ban (command systemctl is-active fail2ban 2>/dev/null)
        test -z "$fail2ban" && set fail2ban n/a
    end
    set -l open_ports n/a
    if command -q ss
        set open_ports (command ss -tuln 2>/dev/null | command grep -c LISTEN)
    else if test -n "$listen_hex"
        set open_ports (count (printf '%s\n' $listen_hex | command sort -u 2>/dev/null))
    end
    set -l last_login ""
    command -q last && set last_login (command last -1 -R $user 2>/dev/null | command head -1 | command awk '{print $4" "$5" "$6}')
    test -z "$last_login" && set last_login n/a

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
    printf "  │ "
    set_color --bold white
    printf "%s" $user
    set_color brblack
    printf "@"
    set_color --bold green
    printf "%-18s" $host
    set_color brblack
    printf "│ "
    set_color cyan
    printf "%-17s" $datetime
    set_color brblack
    printf "│ "
    set_color yellow
    printf "Profile: %-12s" $profile
    set_color brblack
    printf "│ "
    set_color magenta
    printf "%-18s" "$os $kernel_short"
    set_color --bold blue
    printf "│\n"
    printf "  ╰───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\n"
    set_color normal
    echo

    # ROW 1: HARDWARE | OS (MAGENTA)
    set_color --bold magenta
    printf "  ┌─ HARDWARE ─────────────────────────────────────┐ ┌─ SYSTEM ──────────────────────────────────────┐\n"
    set_color normal
    printf "  │ "
    set_color magenta
    printf "CPU    "
    set_color normal
    printf "%-40s" "$cpu_name"
    printf "│ │ "
    set_color magenta
    printf "OS     "
    set_color normal
    printf "%-39s" "$os $kernel_short"
    printf "│\n"
    printf "  │ "
    set_color magenta
    printf "Cores  "
    set_color normal
    printf "%-40s" "$cores_str"
    printf "│ │ "
    set_color magenta
    printf "Host   "
    set_color normal
    printf "%-39s" (string sub -l 39 "$hostname_full")
    printf "│\n"
    printf "  │ "
    set_color magenta
    printf "GPU    "
    set_color normal
    printf "%-40s" "$gpu"
    printf "│ │ "
    set_color magenta
    printf "Kernel "
    set_color normal
    printf "%-39s" "$kernel"
    printf "│\n"
    printf "  │ "
    set_color magenta
    printf "RAM    "
    set_color normal
    printf "%-40s" "$mem_info"
    printf "│ │ "
    set_color magenta
    printf "DE     "
    set_color normal
    printf "%-39s" "$de"
    printf "│\n"
    printf "  │ "
    set_color magenta
    printf "Disk   "
    set_color normal
    printf "%-40s" "$disk_info"
    printf "│ │ "
    set_color magenta
    printf "Shell  "
    set_color normal
    printf "%-39s" "$shell"
    printf "│\n"
    set_color --bold magenta
    printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
    set_color normal
    echo

    # ROW 2: NETWORK | SECURITY (YELLOW)
    set_color --bold yellow
    printf "  ┌─ NETWORK ──────────────────────────────────────┐ ┌─ SECURITY STATUS ────────────────────────────┐\n"
    set_color normal
    printf "  │ "
    set_color yellow
    printf "IP-Pub "
    set_color normal
    printf "%-40s" "$ip_addr"
    printf "│ │ "
    set_color yellow
    printf "%s" "$sec1_k"
    set_color normal
    printf "%-37s" "$ssh_status"
    printf "│\n"
    printf "  │ "
    set_color yellow
    printf IP-Priv
    set_color normal
    printf " %-39s" "$ip_priv"
    printf "│ │ "
    set_color yellow
    printf "%s" "$sec2_k"
    set_color normal
    printf "%-37s" "$fw_status"
    printf "│\n"
    printf "  │ "
    set_color yellow
    printf "DNS    "
    set_color normal
    printf "%-40s" "$dns_servers"
    printf "│ │ "
    set_color yellow
    printf "%s" "$sec3_k"
    set_color normal
    printf "%-37s" "$fail2ban"
    printf "│\n"
    printf "  │ "
    set_color yellow
    printf "Load   "
    set_color normal
    printf "%-40s" "$load_avg"
    printf "│ │ "
    set_color yellow
    printf "Ports    "
    set_color normal
    printf "%-37s" "$open_ports listening"
    printf "│\n"
    printf "  │ "
    set_color yellow
    printf "Uptime "
    set_color normal
    printf "%-40s" "$uptime_str"
    printf "│ │ "
    set_color yellow
    printf "Last     "
    set_color normal
    printf "%-37s" "$last_login"
    printf "│\n"
    set_color --bold yellow
    printf "  └─────────────────────────────────────────────────┘ └───────────────────────────────────────────────┘\n"
    set_color normal
    echo

    # ══════════════════ Tree ══════════════════
    set_color --bold blue
    echo "── Tree ───────────────────────────────────────────────────────────────────────────────────────"
    set_color normal
    if test $android = 1
        # Android: the desktop's ~/Mounts do not exist; the shared store is the tree.
        set_color blue
        echo -n "  ~/cloud-shared-store/"
        set_color normal
        echo ""
        printf "    "
        if test -d "$HOME/cloud-shared-store"
            set -l n 0
            for d in $HOME/cloud-shared-store/*/
                set n (math $n + 1)
                test $n -gt 7 && break
                set_color green
                printf "%-14s" (string sub -l 13 -- (string replace -r '.*/' '' -- (string trim -r -c / -- $d)))"/"
            end
            test $n = 0 && printf "(empty)"
        else
            set_color red
            printf "(not linked)"
        end
        set_color normal
        echo ""
        echo ""
    else
        set_color blue
        echo -n "  ~/Mounts/Git/"
        set_color normal
        echo ""
        printf "    "
        for d in front cloud vault unix tools cloud-data front-data
            if test -d "$HOME/Mounts/Git/$d"
                set_color green
                printf "%-14s" "$d/"
            else
                set_color red
                printf "%-14s" "$d/"
            end
        end
        set_color normal
        echo ""
        set_color blue
        echo -n "  ~/Mounts/Storage/"
        set_color normal
        echo ""
        printf "    "
        for d in Gdrive_dnm Gdrive_me
            if test -d "$HOME/Mounts/Storage/$d"
                set_color green
                printf "%-14s" "$d/"
            else
                set_color red
                printf "%-14s" "$d/"
            end
        end
        set_color normal
        echo ""
        echo ""
    end

    # ══════════════════ Env Vars ══════════════════
    set_color --bold yellow
    echo "── Env Vars ───────────────────────────────────────────────────────────────────────────────────"
    set_color normal
    set_color blue
    echo -n "  Shell:         "
    set_color normal
    for v in EDITOR VISUAL PAGER LANG LC_ALL MANPAGER
        if set -q $v
            set_color --dim green
        else
            set_color --dim red
        end
        printf "%-16s" "$v"
    end
    set_color normal
    echo ""
    set_color blue
    echo -n "  AI / LLM:      "
    set_color normal
    for v in ANTHROPIC_API_KEY OPENAI_BASE_URL OPENAI_API_KEY
        if set -q $v
            set_color --dim green
        else
            set_color --dim red
        end
        printf "%-22s" "$v"
    end
    set_color normal
    echo ""
    set_color blue
    echo -n "  Auth:          "
    set_color normal
    for v in AUTHELIA_OIDC_CLIENT_ID AUTHELIA_TOKEN_URL
        if set -q $v
            set_color --dim green
        else
            set_color --dim red
        end
        printf "%-26s" "$v"
    end
    set_color normal
    echo ""
    set_color blue
    echo -n "                 "
    set_color normal
    for v in AUTHELIA_OIDC_CREDENTIALS_DIR AUTHELIA_OIDC_TOKENS_DIR
        if set -q $v
            set_color --dim green
        else
            set_color --dim red
        end
        printf "%-34s" "$v"
    end
    set_color normal
    echo ""
    set_color blue
    echo -n "  Dev:           "
    set_color normal
    for v in CARGO_HOME GOPATH PIP_CACHE_DIR npm_config_cache npm_config_prefix
        if set -q $v
            set_color --dim green
        else
            set_color --dim red
        end
        printf "%-18s" "$v"
    end
    set_color normal
    echo ""
    set_color blue
    echo -n "  System:        "
    set_color normal
    for v in DEVICE HM_PROFILE BUILDSH_GUARDRAIL TF_PLUGIN_CACHE_DIR GNUPGHOME GIT_EDITOR
        if set -q $v
            set_color --dim green
        else
            set_color --dim red
        end
        printf "%-16s" "$v"
    end
    set_color normal
    echo ""
    set_color --dim
    echo "    ('hhelp envvar' — list all env vars with values)"
    set_color normal
    echo ""

    # ══════════════════ Configuration ══════════════════
    set_color --bold magenta
    echo "── Configuration ──────────────────────────────────────────────────────────────────────────────"
    set_color normal
    # Flakes
    set_color cyan
    echo "  Flakes:"
    set_color normal
    set_color magenta
    echo -n "    NixOS            "
    set_color normal
    echo "~/Mounts/Git/unix/aa_nixos-surface_host/"
    set_color magenta
    echo -n "    OS Modules       "
    set_color normal
    echo "~/Mounts/Git/unix/aa_nixos-surface_host/src/modules/"
    set_color magenta
    echo -n "    Home-Manager     "
    set_color normal
    echo "~/Mounts/Git/unix/ba_flakes_desktop/"
    set_color magenta
    echo -n "    HM Modules       "
    set_color normal
    echo "~/Mounts/Git/unix/ba_flakes_desktop/src/modules/"
    # Wrappers - Guardrails
    set_color cyan
    echo "  Wrappers - Guardrails:"
    set_color normal
    set_color red
    echo -n "    BLOCKED          "
    set_color normal
    echo "rm -rf /, mkfs, dd (always denied)"
    set_color yellow
    echo -n "    CONFIRM          "
    set_color normal
    echo "npm npx docker nix pip apt pkg (ask before run)"
    set_color blue
    echo -n "    WARNING          "
    set_color normal
    echo "bun cargo go (warn on write ops)"
    # Wrappers - Custom
    set_color cyan
    echo "  Wrappers - Custom:"
    set_color normal
    set_color green
    echo -n "    curl/wget        "
    set_color normal
    echo "Auto-inject Authelia token for *.diegonmarcos.com"
    set_color --dim
    echo "    ('hhelp config' — cat flake.nix)"
    set_color normal
    echo ""

    # ══════════════════ Tools ══════════════════
    set_color --bold green
    echo "── Tools ──────────────────────────────────────────────────────────────────────────────────────"
    set_color normal
    # Nix Flakes
    set_color cyan
    echo "  Nix Flakes:"
    set_color normal
    set_color magenta
    echo -n "    up               "
    set_color normal
    echo "Rebuild Nix config"
    set_color magenta
    echo -n "    conf             "
    set_color normal
    echo "Edit flake.nix"
    # Dev
    set -l _claude_ver (command -q claude; and command claude --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
    set -l _goose_ver (command -q goose; and command goose --version 2>/dev/null | string match -r '[\d.]+'; or echo "n/a")
    set_color cyan
    echo "  Dev:"
    set_color normal
    set_color green
    echo -n "    claude           "
    set_color normal
    echo "Launch Claude Code (v$_claude_ver)"
    set_color green
    echo -n "    ai-cli           "
    set_color normal
    echo -n "Goose AI (v$_goose_ver) "
    set_color --dim
    echo "default: Haiku 4.5 · ai-cli -h for models"
    set_color normal
    set_color green
    echo -n "    code             "
    set_color normal
    echo "VS Code Server (local/lan/stop)"
    # Cloud
    set_color cyan
    echo "  Cloud:"
    set_color normal
    set_color red
    echo -n "    connect          "
    set_color normal
    echo "Cloud Connect Unified dashboard (git/mounts/sync/servers)"
    set_color red
    echo -n "    sync             "
    set_color normal
    echo "File sync & serve (WebDAV SFTP HTTP+Eruda)"
    # http-dev status
    if command -q systemctl; and command systemctl --user is-active http-dev.service >/dev/null 2>&1
        set -l _httpd_pid (command systemctl --user show http-dev.service -p MainPID --value 2>/dev/null)
        set_color green
        echo -n "    http-dev         "
        set_color normal
        echo -n "● Web+MD+Eruda "
        set_color cyan
        echo -n "http://127.0.0.1:$__httpd_port"
        set_color normal
        echo " (PID: $_httpd_pid)"
    else
        set_color red
        echo -n "    http-dev         "
        set_color normal
        echo "○ Not running"
    end
    # System
    set_color cyan
    echo "  System:"
    set_color normal
    set_color magenta
    echo -n "    tree             "
    set_color normal
    echo "Directory tree"
    set_color magenta
    echo -n "    yazi             "
    set_color normal
    echo "Terminal file manager"
    set_color magenta
    echo -n "    carbonyl         "
    set_color normal
    echo "Chromium in terminal (npx carbonyl)"
    set_color magenta
    echo -n "    nmtui            "
    set_color normal
    echo "Network Manager TUI (WiFi, VPN, connections)"
    # Search (fzf)
    set_color cyan
    echo "  Search (fzf):"
    set_color normal
    set_color blue
    echo -n "    Ctrl+T           "
    set_color normal
    echo "Find file"
    set_color blue
    echo -n "    Ctrl+R           "
    set_color normal
    echo "Search history"
    set_color blue
    echo -n "    Alt+C            "
    set_color normal
    echo "Cd to folder"
    echo ""
    set_color --dim
    echo "    ('hhelp tools' — all binaries declared in flake)"
    set_color normal
    echo ""

    # ══════════════════ Alias/Functions ══════════════════
    set_color --bold yellow
    echo "── Alias/Functions ────────────────────────────────────────────────────────────────────────────"
    set_color normal
    # Git
    set_color cyan
    echo "  Git:"
    set_color normal
    set_color yellow
    echo -n "    gacp             "
    set_color normal
    echo "git add . && commit && push"
    set_color yellow
    echo -n "    gcl              "
    set_color normal
    echo "git clone <url>"
    # Others
    set_color cyan
    echo "  Others:"
    set_color normal
    set_color yellow
    echo -n "    dtk              "
    set_color normal
    echo "Tools TUI menu (~/git/cloud-mykonsole-dtk/dtk.sh)"
    set_color yellow
    echo -n "    hhelp            "
    set_color normal
    echo "Parse flake configs (config/tools/alias)"
    set_color yellow
    echo -n "    fish-e           "
    set_color normal
    echo "Web terminal + mobile keys (ttyd on WireGuard)"
    echo ""
    set_color --dim
    echo "    ('hhelp alias' — all functions and aliases in bash and fish)"
    set_color normal

    set_color cyan
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════════════════════"
    set_color normal
end
