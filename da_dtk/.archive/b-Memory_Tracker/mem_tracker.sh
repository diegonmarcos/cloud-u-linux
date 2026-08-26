#!/bin/sh

#=====================================
# MEMORY USAGE REPORT
#=====================================
# Displays consolidated memory usage by application
# Usage: ./mem_usage_report.sh [option]

# Force C locale for consistent number formatting (period as decimal separator)
LC_NUMERIC=C
export LC_NUMERIC

# Temp file for kill commands
CMD_FILE="/tmp/gemini_mem_tracker_cmds_$$"
touch "$CMD_FILE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# Box drawing characters
BOX_H="─"
BOX_V="│"
BOX_TL="┌"
BOX_TR="┐"
BOX_BL="└"
BOX_BR="┘"
BOX_LT="├"
BOX_RT="┤"
BOX_TT="┬"
BOX_BT="┴"
BOX_X="┼"

# Help function
show_help() {
    printf "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  ${WHITE}Memory Usage Report${NC}                                        ${CYAN}║${NC}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${YELLOW}USAGE:${NC}  $0 [option]\n"
    printf "\n"
    printf "${YELLOW}OPTIONS:${NC}\n"
    printf "  ${GREEN}(none)${NC}     Display memory usage statistics (Interactive TUI)\n"
    printf "  ${GREEN}print${NC}      Print memory usage statistics to stdout\n"
    printf "  ${GREEN}kill${NC}       Trigger the OOM killer manually\n"
    printf "  ${GREEN}help${NC}       Display this help message\n"
    printf "\n"
}

# Core Logic Function
generate_report() {
    # Clear cmd file
    : > "$CMD_FILE"

    # Get total and used memory in MiB from `free`
    mem_info=$(free -m | awk '/^Mem:/ { print $2, $3, $4, $6, $7 }')
    total_mem=$(echo "$mem_info" | cut -d' ' -f1)
    used_mem=$(echo "$mem_info" | cut -d' ' -f2)
    free_mem=$(echo "$mem_info" | cut -d' ' -f3)
    buff_cache=$(echo "$mem_info" | cut -d' ' -f4)
    available_mem=$(echo "$mem_info" | cut -d' ' -f5)

    # Get swap info
    swap_info=$(free -m | awk '/^Swap:/ { print $2, $3 }')
    swap_total=$(echo "$swap_info" | cut -d' ' -f1)
    swap_used=$(echo "$swap_info" | cut -d' ' -f2)

    # Get process information and consolidate memory usage
    app_data=$(ps -e -o pmem=,args= | awk '
    {
        usage = $1
        cmd = $0
        sub(/^[0-9.-]+ +/, "", cmd)

        split(cmd, parts, " ")
        app_path = parts[1]
        sub(/.*\\/, "", app_path)
        app_name = app_path
        
        # Default pkill pattern (basic heuristic)
        pkill_pattern = app_name

        # Heuristics to group related processes under a common name
        if (cmd ~ /brave/) {
            app_name = "Brave Browser"
            pkill_pattern = "brave"
        } else if (cmd ~ /claude/) {
            app_name = "Claude Code"
            pkill_pattern = "claude"
        } else if (cmd ~ /code/ || cmd ~ /Code/) {
            app_name = "VS Code"
            pkill_pattern = "code"
        } else if (cmd ~ /gemini/) {
            app_name = "Gemini CLI"
            pkill_pattern = "gemini"
        } else if (cmd ~ /plasmashell/) {
            app_name = "KDE Plasma Shell"
            pkill_pattern = "plasmashell"
        } else if (cmd ~ /kwin/) {
            app_name = "KWin (Window Manager)"
            pkill_pattern = "kwin_x11"
        } else if (cmd ~ /kded/) {
            app_name = "KDE Services (kded)"
            pkill_pattern = "kded5"
        } else if (cmd ~ /krunner/) {
            app_name = "KRunner"
            pkill_pattern = "krunner"
        } else if (cmd ~ /Xorg/ || cmd ~ /xorg/) {
            app_name = "Xorg (Display Server)"
            pkill_pattern = "Xorg"
        } else if (cmd ~ /konsole/) {
            app_name = "Konsole"
            pkill_pattern = "konsole"
        } else if (cmd ~ /dolphin/) {
            app_name = "Dolphin"
            pkill_pattern = "dolphin"
        } else if (cmd ~ /live-server/) {
            app_name = "Live Server"
            pkill_pattern = "live-server"
        } else if (cmd ~ /firefox/) {
            app_name = "Firefox"
            pkill_pattern = "firefox"
        } else if (cmd ~ /chrome/ || cmd ~ /chromium/) {
            app_name = "Chrome/Chromium"
            pkill_pattern = "chrome"
        } else if (cmd ~ /electron/) {
            app_name = "Electron App"
            pkill_pattern = "electron"
        } else if (cmd ~ /obsidian/) {
            app_name = "Obsidian"
            pkill_pattern = "obsidian"
        } else if (cmd ~ /slack/) {
            app_name = "Slack"
            pkill_pattern = "slack"
        } else if (cmd ~ /discord/) {
            app_name = "Discord"
            pkill_pattern = "Discord"
        } else if (cmd ~ /spotify/) {
            app_name = "Spotify"
            pkill_pattern = "spotify"
        } else if (cmd ~ /docker/) {
            app_name = "Docker"
            pkill_pattern = "dockerd"
        } else if (cmd ~ /mysql/ || cmd ~ /mariadb/) {
            app_name = "MySQL/MariaDB"
            pkill_pattern = "mysqld"
        } else if (cmd ~ /postgres/) {
            app_name = "PostgreSQL"
            pkill_pattern = "postgres"
        } else if (cmd ~ /mongo/) {
            app_name = "MongoDB"
            pkill_pattern = "mongod"
        } else if (cmd ~ /redis/) {
            app_name = "Redis"
            pkill_pattern = "redis-server"
        } else if (cmd ~ /nginx/) {
            app_name = "Nginx"
            pkill_pattern = "nginx"
        } else if (cmd ~ /apache/) {
            app_name = "Apache"
            pkill_pattern = "apache2"
        } else if (cmd ~ /node/) {
            app_name = "Node.js"
            pkill_pattern = "node"
        } else if (cmd ~ /python/) {
            app_name = "Python"
            pkill_pattern = "python"
        } else if (cmd ~ /java/) {
            app_name = "Java"
            pkill_pattern = "java"
        } else if (cmd ~ /rust/) {
            app_name = "Rust"
            pkill_pattern = "rust"
        } else if (cmd ~ /go/) {
            app_name = "Go"
            pkill_pattern = "go"
        }

        app[app_name] += usage
        count[app_name] += 1
        kill_map[app_name] = pkill_pattern
    }
    END {
        for (a in app) {
            print app[a], count[a], a "|" kill_map[a]
        }
    }')

    # Calculate totals
    total_app_usage=$(echo "$app_data" | awk -F'|' '{split($1, a, " "); sum += a[1]} END {print sum}')
    total_used_percent=$(awk -v used="$used_mem" -v total="$total_mem" 'BEGIN {printf "%.2f", (used/total)*100}')
    system_usage=$(awk -v total_used="$total_used_percent" -v app_used="$total_app_usage" 'BEGIN {printf "%.2f", total_used - app_used}')

    # Combine data and sort - filter out unnamed entries and those with <0.5% usage
    combined_data=$( (echo "$app_data"; echo "$system_usage 1 System (Kernel, Buffers, Cache)|") | sort -rn | awk '$1 >= 0.5 && $3 !~ /^[0-9.]+$/ {print}')

    # Count total processes
    total_procs=$(echo "$app_data" | awk '{sum += $2} END {print sum}')

    # Print header (Total width 80)
    printf "\n"
    printf "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║  ${WHITE}MEMORY USAGE REPORT                                                         ${CYAN}║${NC}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"

    # Memory overview bar (Total width 80)
    used_percent_int=$(printf "%.0f" "$total_used_percent")
    bar_width=55
    filled=$((used_percent_int * bar_width / 100))
    empty=$((bar_width - filled))

    printf "${WHITE}  RAM Usage:${NC} "
    printf "${BLUE}["
    i=0
    while [ $i -lt $filled ]; do
        if [ $i -lt $((filled / 3)) ]; then
            printf "${GREEN}█"
        elif [ $i -lt $((filled * 2 / 3)) ]; then
            printf "${YELLOW}█"
        else
            printf "${RED}█"
        fi
        i=$((i + 1))
    done
    i=0
    while [ $i -lt $empty ]; do
        printf "${GRAY}░"
        i=$((i + 1))
    done
    printf "${BLUE}]${NC} "
    printf "${WHITE}%.1f%%${NC}\n" "$total_used_percent"

    # Swap bar (if swap exists)
    if [ "$swap_total" -gt 0 ]; then
        swap_percent=$(awk -v used="$swap_used" -v total="$swap_total" 'BEGIN {printf "%.1f", (used/total)*100}')
        swap_percent_int=$(printf "%.0f" "$swap_percent")
        filled=$((swap_percent_int * bar_width / 100))
        empty=$((bar_width - filled))

        printf "${WHITE}  Swap:${NC}      "
        printf "${BLUE}["
        i=0
        while [ $i -lt $filled ]; do
            printf "${MAGENTA}█"
            i=$((i + 1))
        done
        i=0
        while [ $i -lt $empty ]; do
            printf "${GRAY}░"
            i=$((i + 1))
        done
        printf "${BLUE}]${NC} "
        printf "${WHITE}%.1f%%${NC}\n" "$swap_percent"
    fi

    printf "\n"

    # Memory stats box (Total width 80)
    # Inner width 78
    printf "${BLUE}┌──────────────────────────────────────────────────────────────────────────────┐${NC}\n"
    printf "${BLUE}│${NC} ${CYAN}Total RAM:${NC} ${WHITE}%6d MiB${NC}  ${GRAY}│${NC}  ${CYAN}Used:${NC} ${YELLOW}%6d MiB${NC}  ${GRAY}│${NC}  ${CYAN}Available:${NC} ${GREEN}%6d MiB${NC}         ${BLUE}│${NC}\n" "$total_mem" "$used_mem" "$available_mem"
    printf "${BLUE}│${NC} ${CYAN}Buff/Cache:${NC} ${WHITE}%5d MiB${NC}  ${GRAY}│${NC}  ${CYAN}Free:${NC} ${WHITE}%6d MiB${NC}  ${GRAY}│${NC}  ${CYAN}Swap:${NC} ${WHITE}%6d${NC}/${WHITE}%d MiB${NC}         ${BLUE}│${NC}\n" "$buff_cache" "$free_mem" "$swap_used" "$swap_total"
    printf "${BLUE}└──────────────────────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"

    # Usage breakdown
    printf "${WHITE}  System:${NC} ${MAGENTA}%.1f%%${NC}  ${GRAY}+${NC}  ${WHITE}User Apps:${NC} ${CYAN}%.1f%%${NC}  ${GRAY}=${NC}  ${WHITE}Total:${NC} ${YELLOW}%.1f%%${NC}  ${GRAY}(%d processes)${NC}\n\n" "$system_usage" "$total_app_usage" "$total_used_percent" "$total_procs"

    # Table header (Total width 80)
    # 4(#)+1+22(App)+1+6(Use)+1+9(Mem)+1+8(Cum)+1+6(Proc)+1+17(Kill) = 78 inner chars
    printf "${BLUE}┌────┬──────────────────────┬──────┬─────────┬────────┬──────┬─────────────────┐${NC}\n"
    printf "${BLUE}│${NC} ${WHITE}#${NC}  ${BLUE}│${NC} ${WHITE}%-20s${NC} ${BLUE}│${NC} ${WHITE}%-4s${NC} ${BLUE}│${NC} ${WHITE}%-7s${NC} ${BLUE}│${NC} ${WHITE}%-6s${NC} ${BLUE}│${NC} ${WHITE}%-4s${NC} ${BLUE}│${NC} ${WHITE}%-15s${NC} ${BLUE}│${NC}\n" "Application" "Use%" "Memory" "Cumul." "Proc" "Pkill Pattern"
    printf "${BLUE}├────┼──────────────────────┼──────┼─────────┼────────┼──────┼─────────────────┤${NC}\n"

    # Table rows
    echo "$combined_data" | awk \
    -v total_mem="$total_mem" \
    -v cmd_file="$CMD_FILE" \
    -v BLUE="\033[0;34m" \
    -v GREEN="\033[0;32m" \
    -v YELLOW="\033[1;33m" \
    -v RED="\033[0;31m" \
    -v CYAN="\033[0;36m" \
    -v MAGENTA="\033[0;35m" \
    -v WHITE="\033[1;37m" \
    -v GRAY="\033[0;90m" \
    -v NC="\033[0m" ' 
    BEGIN {
        cumulative = 0
        rank = 1
    }
    {
        usage = $1
        proc_count = $2
        
        # Reconstruct remainder
        remainder = ""
        for (i = 3; i <= NF; i++) {
            remainder = remainder $i " "
        }
        sub(/ $/, "", remainder)
        
        split(remainder, parts, "|")
        app_name = parts[1]
        kill_cmd = parts[2]

        # Clean up trailing space in app_name
        sub(/ $/, "", app_name)

        cumulative += usage
        mem_mib = (usage / 100) * total_mem

        if (mem_mib >= 1024) {
            mem_str = sprintf("%.1f GiB", mem_mib / 1024)
        } else {
            mem_str = sprintf("%.0f MiB", mem_mib)
        }

        # Color based on usage
        if (usage >= 10) {
            color = RED
        } else if (usage >= 5) {
            color = YELLOW
        } else if (usage >= 1) {
            color = CYAN
        } else {
            color = GRAY
        }

        # Highlight system row
        if (app_name ~ /System/) {
            color = MAGENTA
        }

        # Truncate app name if too long
        if (length(app_name) > 20) {
            app_name = substr(app_name, 1, 17) "..."
        }
        
        # Truncate pkill pattern if too long
        if (length(kill_cmd) > 15) {
            kill_cmd = substr(kill_cmd, 1, 12) "..."
        }
        
        # Calculate index
        idx = rank - 1
        
        # Save to cmd file
        print idx ":" kill_cmd >> cmd_file

        printf "%s│%s %-2d %s│%s %-20s %s│%s %4.1f %s│%s %7s %s│%s %6.1f %s│%s %4d %s│%s %-15s %s│%s\n", \
            BLUE, WHITE, idx, BLUE, color, app_name, BLUE, color, usage, BLUE, WHITE, mem_str, BLUE, WHITE, cumulative, BLUE, GRAY, proc_count, BLUE, GRAY, kill_cmd, BLUE, NC

        rank++
    }'

    printf "${BLUE}└────┴──────────────────────┴──────┴─────────┴────────┴──────┴─────────────────┘${NC}\n"
    printf "\n"

    # OOM Status section (Total width 80)
    printf "${CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${NC}\n"
    printf "${CYAN}│${NC}  ${WHITE}🛡️  OOM Protection Status${NC}%51s${CYAN}│${NC}\n" ""
    printf "${CYAN}├──────────────────────────────────────────────────────────────────────────────┤${NC}\n"

    # Check panic_on_oom
    panic_oom=$(cat /proc/sys/vm/panic_on_oom 2>/dev/null)
    if [ "$panic_oom" = "0" ]; then
        printf "${CYAN}│${NC}  ${GREEN}●${NC} panic_on_oom: ${WHITE}%-3s${NC} (OOM killer enabled)%33s${CYAN}│${NC}\n" "$panic_oom" ""
    else
        printf "${CYAN}│${NC}  ${RED}●${NC} panic_on_oom: ${WHITE}%-3s${NC} (System will panic on OOM)%27s${CYAN}│${NC}\n" "$panic_oom" ""
    fi

    # Check systemd-oomd
    oomd_status=$(systemctl is-active systemd-oomd 2>/dev/null)
    if [ "$oomd_status" = "active" ]; then
        printf "${CYAN}│${NC}  ${GREEN}●${NC} systemd-oomd: ${GREEN}%-8s${NC}%53s${CYAN}│${NC}\n" "active" ""
    else
        printf "${CYAN}│${NC}  ${YELLOW}●${NC} systemd-oomd: ${GRAY}%-8s${NC}%51s${CYAN}│${NC}\n" "${oomd_status:-inactive}" ""
    fi

    printf "${CYAN}└──────────────────────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"

    # Funny message about mouseless terminal/Vim
    printf "${GRAY}  Pure power, no clicks needed (cat certainly agrees).${NC}\n"
    printf "\n"
    # Using standard cat for ASCII art to avoid printf expansion issues
    cat << "EOF_CAT"
               ·◎◎○··
                ○●◉◉◎◎·
                ·◉●●●●◉
                ○●●●●●○
              ·◎●●●●●◎·                 ·· ···○◎○○·
             ○●●●●●◉○                ○○○○◎◉◉●●◎◎◎·
           ·◎●●◉●●◉○             ·◎◉◎◎◎○◉●●◉◎◎○◎  ··
          ○◉●●●●◉◎·             ○◉◎◎◎○○◎◉◎◉◎○○○◎···
        ·◎●●●◉●◉○·            ·◎◉◎○○◎◎◎◎○○◎◎◎○○○◎·  ·
       ○◉◉◉●●●◉○             ◎◉◎○○○○◎◎◎○◎◎◎◎○◎◎◎○○○··
      ·●●●●●●◉○             ○◎◎◎◎◎○◎○◎◎◎◎◎◎○◎●●◎◎
     ·◉●●●●●◉○           ·○○◎○○◎◎◎◎◎◎◎○○◎◎○○○○○○◎
    ·◉●◉●●●◎··    ···◎◎○○◎◎◎◎◎○◎◎◎◎◎◉◉◎◉●●◉◎◎◎◎◎◎·
    ○●●●●●◉·    ○◉◎◎◎◎◎◎◎○◎◎○◎◎◎◎◎◎◎◎◎◉◎◎◎◎◎◎◎◎○ ·○○
   ·◉●●●●●○   ○◎◉◎◎◎◎◎○○◎◎◎◎○○◎◎◎◎◎◎◎◎○○·      ◎○  · ·
   ○◉●●●●◎·  ◎◉◎○○◎◎◎◎◎◎◎◎◎◎◎◎◎◎○◎◎◎◎◎◎○◎○     ◎·○   ··
   ◉●●●●●◎ ·◉◉◎◎◎◎◎◎◎○◎◎◎○◎◎◎◎◎◎◎◎◎◎○◎○◎◉·     ·
   ◉●●●◉●○ ◎●◎◎◎◎◎◎◉◎◎◎◎◎◎◎○◎◎◎◎◎◎◎◎◎○◎●◎·
   ◉●●●●●◎◎◉◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎○◎◎◎◎◎◎○◎◉◉●·
   ◉●●●●●◉◎◎◎◎◎◎◎◎◎◎◎◎◎◎○○◎○◎◎◎◎◎◎◎◎◉●●◉◎○○○○○○○
   ◎◉●●●●◉◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◉◎◎◎◎◎◎◎○◎●●●◉●●●●●●●●◎·
   ·◉●●●●◉◎◎◎◎◎◎◎◎◎◎◎◎○○◉◉◉◎○○◎◎◎◎◎●●●●●◉◉●●●●●●◎◎○○·
    ◉◉●●●◉○◎◎◎◎◎◎◎◎◎◎○◎◎◎○◉◉◎○○◎◎◎◎◎◎··········◉◎◉◉◉○·
    ○●●●●◉◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◉●●◎○◎◎○○◎·            ○○○·
     ◎●●●●◉◎○◎○◎○◎◎○◎◉◎◎◎○◎○◉●◎○◎○◎◎○
      ◉◉●●●◎○○○◎○◎◎◎◎○○○◎◎○○◎●●○○◎◎◎◎·             ···  ·○○·
      ·◎◉●●●◎○○◎○◎◎◎◎○◎◎◎◎○◎◉●●●○○◎◎◎○               ◎●◉◉○◉●○◎◉●◉●◎○○
        ◎◉◎◎○◎◎○○◎◎◎◎◎◎◎○○◎◎●●●●●○○◎◎◎·            ···◎●●◉◉●●●●●●●●●●◉·
        ·◉◉◎○○○◎○○◎◎◎◎◎○◎◉◉●●●●●●●◎○○○○·                ◎●●●●●●●●●●●●●●◎○○◎·
         ○◎●◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◎◉◉◉◎◎◎◎◉○              ·◉◉●●●●●●●●●●●◉···○◎○·
      ·····○○○○○○○○○○◎○○○○○○○○○○○○○◎◎○○○◎·· ··         ·◎· ·○◎◎◎◎◎◎◎◎◎···· ○◉○
                                                           ··○○○○○○○○○○○○○○·
EOF_CAT
    printf "\n"
}

# TUI Loop Function
tui_mode() {
    # Hide cursor
    printf "\033[?25l"
    
    # Restore cursor on exit
    trap 'rm -f "$CMD_FILE"; printf "\033[?25h"; exit 0' INT TERM EXIT

    while true; do
        clear
        generate_report
        
        # Footer Controls
        printf "${CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${NC}\n"
        printf "${CYAN}│${NC}  ${WHITE}CONTROLS:${NC}   ${GREEN}[ r ]${NC} Refresh    ${RED}[ k ]${NC} Kill Process    ${RED}[ q ]${NC} Quit               ${CYAN}│${NC}\n"
        printf "${CYAN}└──────────────────────────────────────────────────────────────────────────────┘${NC}\n"
        
        # Read single key
        old_tty=$(stty -g)
        stty -icanon -echo min 1 time 0
        key=$(dd bs=1 count=1 2>/dev/null)
        stty "$old_tty"

        case "$key" in
            q|Q)
                break
                ;; 
            r|R)
                continue
                ;; 
            k|K)
                # Restore cursor
                printf "\033[?25h"
                printf "\n"
                printf "${YELLOW}Enter process # to kill: ${NC}"
                read pid_idx
                
                # Find command in temp file
                # Format in file is: index:command
                if [ -n "$pid_idx" ]; then
                    cmd_entry=$(grep "^${pid_idx}:" "$CMD_FILE")
                    if [ -n "$cmd_entry" ]; then
                        kill_pattern=$(echo "$cmd_entry" | cut -d':' -f2-)
                        
                        if [ -z "$kill_pattern" ] || [ "$kill_pattern" = " " ]; then
                            printf "${RED}Error: No pattern found for index $pid_idx${NC}\n"
                        else
                            printf "${RED}Executing: pkill %s${NC}\n" "$kill_pattern"
                            pkill "$kill_pattern"
                            printf "${GREEN}Done.${NC}\n"
                        fi
                    else
                        printf "${RED}Invalid index: $pid_idx${NC}\n"
                    fi
                fi
                
                printf "${GRAY}Press Enter to continue...${NC}"
                read dummy
                printf "\033[?25l"
                ;; 
        esac
    done
}

# Main execution
case "$1" in
    help|-h|--help)
        show_help
        ;; 
    print)
        # Use a temp file for print mode too just to avoid errors, though we wont read it
        generate_report
        rm -f "$CMD_FILE"
        ;; 
    kill)
        printf "${RED}⚠ Triggering OOM killer...${NC}\n"
        echo f | sudo tee /proc/sysrq-trigger
        ;; 
    *)
        tui_mode
        ;; 
esac