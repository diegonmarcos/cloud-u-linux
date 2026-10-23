### ------------------- ###
### --- FISH CONFIG --- ###
### ------------------- ###

# ~/.config/fish/config.fish







### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
### --- CUSTOM ALIAS --- #
### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# --- Aliases ---

# ============================================================================
# Python Aliases
# ============================================================================
alias py='python3'
alias python='python3'
alias pip='pip3'

# ============================================================================
# Directory Navigation
# ============================================================================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

# ============================================================================
# List Directory Contents
# ============================================================================
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias lh='ls -lh'
alias lt='ls -ltr'

# ============================================================================
# Git Aliases
# ============================================================================
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'
alias gla='git log --oneline --graph --decorate --all'
alias gd='git diff'
alias gds='git diff --staged'
alias gco='git checkout'
alias gb='git branch'
alias gba='git branch -a'
alias gpl='git pull'
alias gcl='git clone'
alias gst='git stash'
alias gstp='git stash pop'

# ============================================================================
# Grep with Colors
# ============================================================================
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# ============================================================================
# Safety Aliases (prompt before overwrite/delete)
# ============================================================================
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# ============================================================================
# System Information
# ============================================================================
alias df='df -h'
alias du='du -h'
alias free='free -h'

# ============================================================================
# Networking
# ============================================================================
alias ports='netstat -tulanp'
alias myip='curl -s ifconfig.me'
alias ping='ping -c 5'

# ============================================================================
# Misc Utilities
# ============================================================================
alias c='clear'
alias h='history'
alias reload='source ~/.config/fish/config.fish'

# ============================================================================
# Quick Edit Config Files
# ============================================================================
alias editfish='$EDITOR ~/.config/fish/config.fish'
alias sourcefish='source ~/.config/fish/config.fish'

# ============================================================================
# Development Shortcuts
# ============================================================================
alias serve='python3 -m http.server'
alias jn='jupyter notebook'
alias dcu='docker-compose up'
alias dcd='docker-compose down'
alias dps='docker ps'
alias dpsa='docker ps -a'

# ============================================================================
# Functions
# ============================================================================

# Create directory and cd into it
function mkcd
    mkdir -p $argv[1]; and cd $argv[1]
end

# Extract any archive
function extract
    if test -f $argv[1]
        switch $argv[1]
            case '*.tar.bz2'
                tar xjf $argv[1]
            case '*.tar.gz'
                tar xzf $argv[1]
            case '*.bz2'
                bunzip2 $argv[1]
            case '*.rar'
                unrar x $argv[1]
            case '*.gz'
                gunzip $argv[1]
            case '*.tar'
                tar xf $argv[1]
            case '*.tbz2'
                tar xjf $argv[1]
            case '*.tgz'
                tar xzf $argv[1]
            case '*.zip'
                unzip $argv[1]
            case '*.Z'
                uncompress $argv[1]
            case '*.7z'
                7z x $argv[1]
            case '*.deb'
                ar x $argv[1]
            case '*.tar.xz'
                tar xf $argv[1]
            case '*.tar.zst'
                unzstd $argv[1]
            case '*'
                echo "'$argv[1]' cannot be extracted via extract()"
        end
    else
        echo "'$argv[1]' is not a valid file"
    end
end

# Quick find
function qfind
    find . -name "*$argv[1]*"
end

# Backup file with timestamp
function backup
    if test -f $argv[1]
        set timestamp (date +%Y%m%d_%H%M%S)
        cp $argv[1] "$argv[1].backup.$timestamp"
        echo "Backup created: $argv[1].backup.$timestamp"
    else
        echo "File not found: $argv[1]"
    end
end

# Create a new directory and enter it
function mkd
    mkdir -p $argv; and cd $argv[-1]
end

# Get current git branch
function git_current_branch
    git branch 2>/dev/null | sed -n '/\* /s///p'
end

# Quick git commit with message
function gcam
    git add --all; and git commit -m $argv[1]
end

# Quick git push to current branch
function gpsh
    git push origin (git_current_branch)
end

# Print path with newlines
function path
    echo $PATH | tr ' ' '\n'
end

echo "Fish aliases loaded successfully!"

alias gcl 'git clone'
alias push 'git add . && git commit -m "update" && git push'

alias mem_recover /home/diego/Documents/Git/mylibs/mytools/0_unix/kill_halt.sh
alias mem_usage /home/diego/Documents/Git/mylibs/mytools/0_unix/mem_usage.sh


alias ll 'ls -alF'
alias la 'ls -A'
alias l 'ls -CF'

alias gdrive 'bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh '
alias gdrive_reset 'bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh b2'
alias gdrive_mount 'bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh b1'
alias gdrive_umount 'fusermount -u /home/diego/Documents/Gdrive'

alias python python3
alias py python3
alias pip pip3
fish_add_path "/home/diego/.local/bin"








### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
### --- CUSTOM FUNCTIONS --- #
### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function pyp --description 'Install/Run package with optional sudo path fix'
    # 1. Check for minimum arguments
    if test (count $argv) -lt 1
        echo "Error: Need at least one argument: [Package_Name] or [sudo Package_Name]."
        return 1
    end

    # Variables
    set -l is_sudo_mode false
    set -l target_package ""
    set -l extra_args ""

    # --- Mode Detection ---
    if test $argv[1] = "sudo"
        # MODE: SUDO (e.g., pyp sudo ps_mem)
        if test (count $argv) -lt 2
            echo "Error: 'pyp sudo' requires a package name: pyp sudo [package]."
            return 1
        end
        set is_sudo_mode true
        set target_package $argv[2]
        # Any arguments coming AFTER the package name (e.g., -p 1234)
        set extra_args $argv[3..-1]
    else
        # MODE: STANDARD (e.g., pyp ps_mem)
        set target_package $argv[1]
        # Any arguments coming AFTER the package name
        set extra_args $argv[2..-1]
    end

    # 2. Change Directory
    cd ~/poetry_venv_1

    # 3. INSTALL the package (Always runs)
    echo "Installing package: $target_package..."
    poetry add "$target_package"

    # 4. RUN the command
    echo "Running command..."

    if test $is_sudo_mode = "true"
        # --- SUDO PATH FIX ---

        # Get the absolute path dynamically from the Venv
        set -l abs_path (poetry run which $target_package 2>/dev/null)

        if test -z "$abs_path"
            echo "Error: Could not find executable '$target_package' in Venv."
            return 1
        end

        # Join any extra arguments into a single string with spaces
        set -l args_string (string join " " $extra_args)

        # Build the final command string: sudo "/path/to/exe" arg1 arg2
        set -l command_string "sudo \"$abs_path\" $args_string"

        echo "Executing with SUDO path fix: sh -c '$command_string'"

        # Execute via sh -c to handle sudo correctly
        poetry run sh -c "$command_string"
    else
        # --- STANDARD EXECUTION ---
        poetry run $target_package $extra_args
    end
end
funcsave pyp

# --- Claude Code Usage Stats ---
function ccusage-models --description 'Display Claude Code token usage per model in current session'
    ccusage session --json -b | jq -r '.sessions[0].modelBreakdowns[] | [.modelName, (.inputTokens | tostring), (.outputTokens | tostring), ((.inputTokens + .outputTokens) | tostring), ("$" + (.cost | round | tostring))] | @csv' | sed 's/"//g' | awk -F',' 'BEGIN {printf "%-30s %15s %15s %15s %15s\n", "MODEL", "INPUT", "OUTPUT", "TOTAL", "COST"; print "---------------------------------------------------------------"} {printf "%-30s %15s %15s %15s %15s\n", $1, sprintf("%'\''d", $2), sprintf("%'\''d", $3), sprintf("%'\''d", $4), $5}'
end





### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
### --- SETS --- #
### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# --- Sets ---
#set -Ux GEMINI_API_KEY "YOUR_API_KEY"
# --- Variables ---
set -g path_to_my_git "/home/diego/Documents/Git/"





### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
### --- STARTUP SERVICES --- #
### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# --- Login Script ---
## Rclone mount check
if not mount | grep -q "/home/diego/Documents/Gdrive"
    bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh a2
end



### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
### --- STARTER SCREEN --- #
### # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# --- NVM (Node Version Manager) ---
# To use nvm with fish, you can use a wrapper like bass.
# Install bass with Oh My Fish:
# omf install bass
# Then add the following to your config.fish:
# function nvm
#   bass source ~/.nvm/nvm.sh --no-use \; nvm $argv
# end
# set -x NVM_DIR ~/.nvm

# --- Custom Functions ---
# The following file needs to be translated from zsh to fish syntax.
# source $path_to_my_git/mylibs/mytools/0_zsh/my_functions.zsh

# --- Dashboard Functions ---
function get_system_info
    set os_name (uname -s)
    set kernel_version (uname -r)
    set current_hostname (hostname)
    set uptime (uptime | awk '{print $3, $4}' | sed 's/,//')
    set cpu_model (lscpu | grep "Model name:" | awk '{print $3,$4,$5,$6,$7,$8}')
    set memory_usage (free -h | awk '/Mem:/ {printf "%.1f GB / %.1f GB", $3/1024/1024, $2/1024/1024}')

    echo -e "\n1.System Information:"
    echo -e "------------------"
    echo -e "OS:\t\t$os_name"
    echo -e "Kernel:\t\t$kernel_version"
    echo -e "Hostname:\t$current_hostname"
    echo -e "Uptime:\t\t$uptime"
    echo -e "CPU:\t\t$cpu_model"
    echo -e "Memory:\t\t$memory_usage"
end

function get_network_info
    set ip_address (ip route get 1.1.1.1 | awk '{print $7}')
    set gateway (ip route | grep default | awk '{print $3}')

    echo -e "\n2.Network Information:"
    echo -e "-------------------"
    echo -e "IP Address:\t$ip_address"
    echo -e "Gateway:\t$gateway"
end

function get_disk_usage
    set disk_usage (df -h / | awk 'NR==2 {printf "%s / %s (%.1f%%)", $3, $2, $5}')

    echo -e "\n3.Disk Usage:"
    echo -e "-----------"
    echo -e "Root:\t\t$disk_usage"
end

function echo_with_art
    # Print the ASCII art
    echo '

           _               _
        _ /\ \           /\ \
      / \_\\ \ \         /  \ \
     / / / \ \ \       / /\ \ \
    / / /   \ \ \      \/_/\ \ \
    \ \ \____\ \ \         / / /
     \ \________\ \       / / /
      \/________/\ \     / / /  _
                \ \ \   / / /_/\_\
                 \ \_\ / /_____/ /
                  \/_/ \________/ 


'

    # Print the arguments passed to the function
    echo $argv
end

# --- Starship Prompt ---
starship init fish | source

# --- Startup Items ---
# Clear the screen
clear

# Header
printf "\x1b[1;34mWelcome to your shell, %s!\x1b[0m\n" (whoami)

date "+%A, %B %d, %Y - %I:%M %p"

# System, Network, and Disk Info
get_system_info
get_network_info
get_disk_usage

# Optional: Add more sections for other data (e.g., weather, calendar, news)
echo -e "\n4.Rclone - Mounted Drives"
echo -e "-----------------------"
mount | grep rclone

# Footer
printf "\n\x1b[32mHave a productive day!\x1b[0m\n"  # Green color

# Call the function
echo_with_art

alias ppy="poetry run python3 $argv"
fish_add_path /home/diego/.local/bin
set -gx DBX_CONTAINER_MANAGER docker
