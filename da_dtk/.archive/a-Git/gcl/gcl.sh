#!/bin/sh

# gcl.sh - A simple, POSIX-compliant git clone/pull/push manager with TUI and CLI modes.
# MODIFIED:
# - Added TUI-based repo status panel on the right.
# - Added 'r' key to refresh status panel.
# - Added 's' key to select only "not OK" repos.
# - FIXED: 's' key was selecting all repos.
# - MODIFIED: 'sync' action now adds+commits before pushing.
# - MODIFIED: 'Enter' key now triggers RUN from anywhere.
# - FIXED: "m" + "enter" auto-run bug.
# - ADDED: All-lowercase shortcuts as requested (l/e, s/p/c/t, k/r/a/u).
# - FIXED: "divergent branches" error by adding --no-rebase to pull command.
# - FIXED: TUI highlighting bug; highlight now fills the entire line.
# - MODIFIED: Changed shortcuts/labels per user request (Pull='l', Local='o', Remote='E')
# - FIXED: Corrected TUI labels (L O CAL, S T ATUS) per request.
# - FIXED: Removed yellow/orange from help text per request.
# - FIXED: TUI highlighting for Strategy/Action/Run reverted to text-only to fix render bugs.
# - FIXED: RUN button escape codes showing literally - removed embedded color codes.
# - FIXED: Blue highlight rectangle not filling whole line - removed embedded C_RESET codes.
# - FIXED: Only highlight selected option in Strategy/Action, not all options in the field.
# - ENHANCED: Made shortcut letters bold (O in LOCAL, E in REMOTE, S/P/L/T in actions).

# --- Configuration: Repository Lists ---
PUBLIC_REPOS="
front-Github_profile:git@github.com:diegonmarcos/diegonmarcos.git
front-Github_io:git@github.com:diegonmarcos/diegonmarcos.github.io.git
back-System:git@github.com:diegonmarcos/back-System.git
back-Algo:git@github.com:diegonmarcos/back-Algo.git
back-Graphic:git@github.com:diegonmarcos/back-Graphic.git
cyber-Cyberwarfare:git@github.com:diegonmarcos/cyber-Cyberwarfare.git
ops-Tooling:git@github.com:diegonmarcos/ops-Tooling.git
ops-Mylibs:git@github.com:diegonmarcos/ops-Mylibs.git
ml-MachineLearning:git@github.com:diegonmarcos/ml-MachineLearning.git
ml-DataScience:git@github.com:diegonmarcos/ml-DataScience.git
ml-Agentic:git@github.com:diegonmarcos/ml-Agentic.git
"
PRIVATE_REPOS="
front-Notes_md:git@github.com:diegonmarcos/front-Notes_md.git
z-lecole42:git@github.com:diegonmarcos/lecole42.git
z-dev:git@github.com:diegonmarcos/dev.git
"
ALL_REPOS="${PUBLIC_REPOS}${PRIVATE_REPOS}"

# --- TUI State Variables ---
_strategy_selected=1      # 0=LOCAL, 1=REMOTE (default)
_action_selected=0        # 0=SYNC (default), 1=PUSH, 2=PULL, 3=STATUS, 4=FETCH, 5=UNTRACKED, 6=IGNORED
_repo_cursor_index=0      # For scrolling through repos
_repo_selection=""        # A string of 'y'/'n' for each repo
_repo_list=""             # A newline-separated list of repo names
_repo_status_list=""      # A newline-separated list of repo statuses
_repo_fetch_status_list="" # A newline-separated list of fetch statuses (unpulled commits)
_repo_count=0
_current_field=0          # 0=working_dir, 1=strategy, 2=action, 3=repos, 4=run button
_total_fields=5
_workdir_selected=1       # 0=current dir, 1=custom path (default)
_workdir_path="/home/diego/Documents/Git"  # Default custom path
_workdir_edit_mode=0      # 0=not editing, 1=editing path
_workdir_cursor_pos=28    # Cursor position when editing (start at end)

# --- Color and Terminal Control ---
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_BOLD_OFF="\033[22m"; C_RED="\033[31m"; C_GREEN="\033[32m";
C_YELLOW="\033[33m"; C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_ORANGE="\033[38;5;208m"; C_GRAY="\033[90m";
C_BG_BLUE="\033[44m"; C_BG_GREEN="\033[42m";

_clear_screen() { tput clear; }
_move_cursor() { tput cup "$1" "$2"; }
_hide_cursor() { tput civis; }
_show_cursor() { tput cnorm; }
_save_term() { _SAVED_TERM=$(stty -g); }
_restore_term() { stty "$_SAVED_TERM"; _show_cursor; }

# --- Helper Functions ---
_log() { printf "${C_CYAN}==>${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$1"; }
_success() { printf "${C_GREEN}  ✓ %s${C_RESET}\n" "$1"; }
_error() { printf "${C_RED}  ✗ %s${C_RESET}\n" "$1"; }
_warn() { printf "${C_YELLOW}  ⚠ %s${C_RESET}\n" "$1"; }

# Draws a box with a title, dynamically sized to the text.
# @param $1: The title text
_draw_dynamic_title_box() {
    _title_text=" $1 " # Add padding
    _title_len=$(expr length "$_title_text")
    _top_bottom_line=""
    i=0
    while [ "$i" -lt "$_title_len" ]; do
        _top_bottom_line="${_top_bottom_line}═"
        i=$((i + 1))
    done

    printf "${C_BOLD}${C_CYAN}╔%s╗\n" "$_top_bottom_line"
    printf "║%s║\n" "$_title_text"
    printf "╚%s╝${C_RESET}\n" "$_top_bottom_line"
}

# --- Core Git Functions ---

# Silently checks the status of a single repo for the TUI
# @param $1: Repository directory name
_get_repo_status() {
    repo_dir="$1"

    if ! [ -d "$repo_dir" ]; then
        printf "${C_RED}Not Cloned${C_RESET}"
        return
    fi

    # Check for uncommitted changes (staged and unstaged) and untracked files
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        printf "${C_RED}Uncommitted${C_RESET}"
        return
    fi

    # Check if branch tracks a remote
    if ! git -C "$repo_dir" rev-parse @{u} >/dev/null 2>&1; then
        printf "${C_RED}No Remote${C_RESET}"
        return
    fi

    # Check for unpushed commits
    unpushed=$(git -C "$repo_dir" log @{u}.. --oneline 2>/dev/null | wc -l)
    if [ "$unpushed" -gt 0 ]; then
        printf "${C_RED}%s Unpushed${C_RESET}" "$unpushed"
        return
    fi

    printf "${C_GREEN}OK${C_RESET}"
}

# Checks fetch status: contacts remote and checks for unpulled commits
# @param $1: Repository directory name
_get_repo_fetch_status() {
    repo_dir="$1"

    if ! [ -d "$repo_dir" ]; then
        printf "${C_RED}Not Cloned${C_RESET}"
        return
    fi

    # Check if branch tracks a remote
    if ! git -C "$repo_dir" rev-parse @{u} >/dev/null 2>&1; then
        printf "${C_RED}No Remote${C_RESET}"
        return
    fi

    # Fetch from remote quietly
    if ! git -C "$repo_dir" fetch --quiet 2>/dev/null; then
        printf "${C_RED}Fetch Failed${C_RESET}"
        return
    fi

    # Check for unpulled commits (commits on remote not in local)
    unpulled=$(git -C "$repo_dir" log HEAD..@{u} --oneline 2>/dev/null | wc -l)
    if [ "$unpulled" -gt 0 ]; then
        printf "${C_RED}%s To Pull${C_RESET}" "$unpulled"
        return
    fi

    printf "${C_GREEN}Up to Date${C_RESET}"
}


# @param $1: Repository directory name
# @param $2: Repository git URL
# @param $3: Pull strategy ('ours' or 'theirs' or 'none' for push-only)
# @param $4: Action ('sync', 'pull', 'push')
process_repo() {
    repo_dir="$1"; repo_url="$2"; strategy="$3"; action="$4"

    _log "Processing '$repo_dir'"

    if ! [ -d "$repo_dir" ]; then
        _log "Cloning '$repo_dir'..."
        if git clone "$repo_url" "$repo_dir" 2>&1; then
            _success "Clone complete."
        else
            _error "Clone failed."
        fi
        printf "\n"; return
    fi

    case "$action" in
        sync|pull)
            # First, commit any uncommitted changes to avoid merge conflicts
            if ! git -C "$repo_dir" diff-index --quiet HEAD -- 2>/dev/null; then
                printf "  Found uncommitted changes, committing before pull...\n"
                git -C "$repo_dir" add .
                if ! git -C "$repo_dir" diff-index --quiet --cached HEAD -- 2>/dev/null; then
                    if git -C "$repo_dir" commit -q -m "Auto-commit before pull"; then
                        _success "Changes committed."
                    else
                        _error "Commit failed. Cannot pull with uncommitted changes."
                        printf "\n"
                        return
                    fi
                fi
            fi

            printf "  Pulling with strategy: ${C_BOLD}%s${C_RESET}\n" "$strategy"

            # --- FIX: Added --no-rebase to force a merge ---
            # This prevents "divergent branches" error and allows --strategy-option to work.
            pull_output=$(git -C "$repo_dir" pull --no-rebase --strategy-option="$strategy" 2>&1)
            pull_status=$?

            if [ $pull_status -eq 0 ]; then
            # --- END FIX ---
                _success "Pull complete."

                if [ "$action" = "sync" ]; then
                    printf "  Staging all changes...\n"
                    git -C "$repo_dir" add .
                    # Commit only if there are staged changes
                    if ! git -C "$repo_dir" diff-index --quiet --cached HEAD --;
 then
                        printf "  Found changes, committing with default message 'fixes'...\n"
                        if git -C "$repo_dir" commit -q -m "fixes"; then
                            _success "Commit complete."
                        else
                            _error "Commit failed unexpectedly."
                        fi
                    fi

                    printf "  Pushing changes...\n"
                    if git -C "$repo_dir" push 2>&1; then
                        _success "Push complete."
                    else
                        _error "Push failed."
                    fi
                fi
            else
                _error "Pull failed."

                # Check for specific error types and provide helpful messages
                if echo "$pull_output" | grep -q "File name too long\|Filename too long"; then
                    _warn "Filesystem limitation: Path/filename exceeds system limits."
                    _warn "Attempting automatic fix..."

                    # Try to enable long paths
                    if git -C "$repo_dir" config core.longpaths true 2>/dev/null; then
                        _success "Enabled core.longpaths for this repo."
                        _warn "Please re-run sync/pull for this repo."
                    else
                        _warn "Could not auto-fix. Manual steps needed:"
                        printf "    ${C_YELLOW}1. Run: git config core.longpaths true${C_RESET}\n"
                        printf "    ${C_YELLOW}2. On Windows: Enable long path support in registry${C_RESET}\n"
                        printf "    ${C_YELLOW}3. Clone to shorter path (e.g., C:\\git\\)${C_RESET}\n"
                    fi
                elif echo "$pull_output" | grep -q "symlink"; then
                    _warn "Symlink creation failed. Attempting fix..."

                    # Try to disable symlinks
                    if git -C "$repo_dir" config core.symlinks false 2>/dev/null; then
                        _success "Disabled symlinks for this repo."
                        _warn "Please re-run sync/pull for this repo."
                    else
                        _warn "Try manually: git config core.symlinks false"
                    fi
                fi

                # Abort failed merge if in progress
                if git -C "$repo_dir" rev-parse MERGE_HEAD >/dev/null 2>&1; then
                    _warn "Aborting failed merge..."
                    git -C "$repo_dir" merge --abort 2>/dev/null
                fi

                printf "  ${C_YELLOW}Error details:${C_RESET}\n"
                echo "$pull_output" | sed 's/^/    /'
            fi
            ;;
        push)
            printf "  Staging all changes...\n"
            git -C "$repo_dir" add .
            # Commit only if there are staged changes
            if ! git -C "$repo_dir" diff-index --quiet --cached HEAD --;
 then
                printf "  Found changes, committing with default message 'fixes'...\n"
                if git -C "$repo_dir" commit -q -m "fixes"; then
                    _success "Commit complete."
                else
                    _error "Commit failed unexpectedly."
                fi
            fi
            printf "  Pushing changes...\n"
            if git -C "$repo_dir" push 2>&1; then
                _success "Push complete."
            else
                _error "Push failed."
            fi
            ;;
    esac
    printf "\n"
}

# --- CLI Actions ---
run_cli_sync() {
    strategy_arg="$1"; git_strategy="theirs"
    repos_to_process="${2:-$ALL_REPOS}"
    [ "$strategy_arg" = "local" ] && git_strategy="ours"
    _log "Starting Bidirectional Sync (Strategy: $git_strategy)"
    printf "%s" "$repos_to_process" | while IFS=: read -r repo_dir repo_url;
        do
        [ -z "$repo_dir" ] && continue
        # If the line doesn't contain ':', it's just a repo name from the TUI
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi
        process_repo "$repo_dir" "$repo_url" "$git_strategy" "sync"
    done
}

run_cli_push() {
    repos_to_process="${1:-$ALL_REPOS}"
    _log "Starting Push"
    printf "%s" "$repos_to_process" | while IFS=: read -r repo_dir repo_url;
        do
        [ -z "$repo_dir" ] && continue
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi
        process_repo "$repo_dir" "$repo_url" "none" "push"
    done
}

run_cli_pull() {
    repos_to_process="${1:-$ALL_REPOS}"
    _log "Starting Forced Pull (Remote Overwrites Local on Conflict)"
    printf "%s" "$repos_to_process" | while IFS=: read -r repo_dir repo_url;
        do
        [ -z "$repo_dir" ] && continue
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi
        process_repo "$repo_dir" "$repo_url" "theirs" "pull"
    done
}

run_cli_fetch() {
    repos_to_process="${1:-$ALL_REPOS}"
    _log "Starting Fetch"
    printf "%s" "$repos_to_process" | while IFS=: read -r repo_dir repo_url;
        do
        [ -z "$repo_dir" ] && continue
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi
        if [ -d "$repo_dir" ]; then
            printf "  Fetching in '$repo_dir'...\n"
            if git -C "$repo_dir" fetch 2>&1; then
                _success "Fetch complete."
            else
                _error "Fetch failed."
            fi
        else
            _warn "'$repo_dir' not cloned. Skipping."
        fi
        printf "\n"
    done
}

run_cli_status() {
    repos_to_process="${1:-$ALL_REPOS}"
    _log "Checking Git Status for Repositories"
    printf "%s" "$repos_to_process" | while IFS=: read -r repo_dir repo_url;
        do
        [ -z "$repo_dir" ] && continue
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi

        if ! [ -d "$repo_dir" ]; then
            _warn "'$repo_dir' not cloned yet."
            printf "\n"
            continue
        fi

        _log "Checking '$repo_dir'"

        # Check for uncommitted changes (staged and unstaged)
        if ! git -C "$repo_dir" diff-index --quiet HEAD -- 2>/dev/null; then
            _warn "Has uncommitted changes (staged or unstaged)"
            printf "  ${C_YELLOW}Files changed:${C_RESET}\n"
            git -C "$repo_dir" status --short | sed 's/^/    /'
        else
            _success "Working tree clean"
        fi

        # Check for unpushed commits
        unpushed=$(git -C "$repo_dir" log @{u}.. --oneline 2>/dev/null | wc -l)
        if [ "$unpushed" -gt 0 ]; then
            _warn "Has $unpushed unpushed commit(s)"
            printf "  ${C_YELLOW}Unpushed commits:${C_RESET}\n"
            git -C "$repo_dir" log @{u}.. --oneline | sed 's/^/    /'
        else
            # Check if branch tracks a remote
            if git -C "$repo_dir" rev-parse @{u} >/dev/null 2>&1; then
                _success "All commits pushed"
            else
                _warn "Branch does not track a remote"
            fi
        fi

        printf "\n"
    done
}

run_cli_untracked() {
    repos_to_process="${1:-$ALL_REPOS}"
    _log "Listing Untracked Files (excluding ignored files)"
    while IFS=: read -r repo_dir repo_url;
    do
        [ -z "$repo_dir" ] && continue
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi

        if ! [ -d "$repo_dir" ]; then
            _warn "'$repo_dir' not cloned yet."
            printf "\n"
            continue
        fi

        _log "Checking '$repo_dir'"

        # Get untracked files (excluding those that would be ignored by .gitignore)
        untracked_files=$(git -C "$repo_dir" ls-files --others --exclude-standard)

        if [ -n "$untracked_files" ]; then
            untracked_count=$(echo "$untracked_files" | wc -l)
            _warn "Has $untracked_count untracked file(s)"
            printf "  ${C_YELLOW}Untracked files:${C_RESET}\n"
            echo "$untracked_files" | sed 's/^/    /'
        else
            _success "No untracked files"
        fi

        printf "\n"
    done <<EOF
$(printf "%s" "$repos_to_process")
EOF
}

run_cli_ignored() {
    repos_to_process="${1:-$ALL_REPOS}"
    _log "Listing Ignored Files"
    while IFS=: read -r repo_dir repo_url;
    do
        [ -z "$repo_dir" ] && continue
        if ! echo "$repo_dir" | grep -q ':'; then
            repo_url=$(printf "%s" "$ALL_REPOS" | grep "^${repo_dir}:" | cut -d: -f2-)
        fi

        if ! [ -d "$repo_dir" ]; then
            _warn "'$repo_dir' not cloned yet."
            printf "\n"
            continue
        fi

        _log "Checking '$repo_dir'"

        # Get ignored files
        ignored_files=$(git -C "$repo_dir" ls-files --others --ignored --exclude-standard)

        if [ -n "$ignored_files" ]; then
            ignored_count=$(echo "$ignored_files" | wc -l)
            _warn "Has $ignored_count ignored file(s)"
            printf "  ${C_YELLOW}Ignored files:${C_RESET}\n"
            echo "$ignored_files" | sed 's/^/    /'
        else
            _success "No ignored files"
        fi

        printf "\n"
    done <<EOF
$(printf "%s" "$repos_to_process")
EOF
}

# --- TUI Functions ---
_read_key() {
    char=""
    key=""
    char=$(dd bs=1 count=1 2>/dev/null)
    if [ "$char" = "$(printf '\033')" ]; then
        char2=$(dd bs=1 count=2 2>/dev/null)
        case "$char2" in
            '[A') key="up" ;; 
            '[B') key="down" ;; 
        esac
    elif [ "$char" = "$(printf '\n')" ] || [ "$char" = "$(printf '\r')" ]; then
        key="enter"
    elif [ "$char" = " " ]; then
        key="space"
    elif [ "$char" = "$(printf '\t')" ]; then
        key="tab"
    # --- New Shortcuts ---
    elif [ "$char" = "o" ]; then # NEW: 'o' for Local
        key="local"
    elif [ "$char" = "e" ]; then
        key="remote"
    elif [ "$char" = "s" ]; then
        key="sync"
    elif [ "$char" = "p" ]; then
        key="push"
    elif [ "$char" = "l" ]; then # NEW: 'l' for Pull
        key="pull"
    elif [ "$char" = "n" ]; then # NEW: 'n' for uNtracked
        key="untracked"
    elif [ "$char" = "i" ]; then
        key="ignored"
    elif [ "$char" = "k" ]; then
        key="selectnotok"
    # --- End New Shortcuts ---
    elif [ "$char" = "a" ]; then
        key="selectall"
    elif [ "$char" = "u" ]; then
        key="unselectall"
    elif [ "$char" = "t" ]; then
        key="status"
    elif [ "$char" = "f" ]; then
        key="fetch"
    elif [ "$char" = "r" ]; then
        key="refresh"
    elif [ "$char" = "w" ]; then
        key="editpath"
    elif [ "$char" = "y" ]; then
        key="restoresymlinks"
    elif [ "$char" = "q" ]; then
        key="quit"
    fi
    printf "%s" "$key"
}

draw_interface() {
    _clear_screen; _move_cursor 0 0
    # Get terminal width and height
    _t_width=${COLUMNS:-$(tput cols)}
    _t_height=${LINES:-$(tput lines)}

    # Always use full layout
    _draw_dynamic_title_box "gcl.sh - Git Sync Manager"

    # --- Working Directory Selection ---
    _line=4;
    _move_cursor $_line 2; printf "${C_BOLD}${C_BLUE}WORKING DIRECTORY:${C_RESET}"
    _move_cursor $((_line + 1)) 2; printf "${C_BLUE}══════════════════${C_RESET}"

    _line=$((_line + 2)); _move_cursor $_line 4
    _line_text=$(printf "[%s] Current Directory (.)" "$([ "$_workdir_selected" -eq 0 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 0 ] && [ "$_workdir_selected" -eq 0 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] Custom Path:" "$([ "$_workdir_selected" -eq 1 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 0 ] && [ "$_workdir_selected" -eq 1 ]; then
        printf "${C_BG_BLUE}%s %s" "$_line_text" "$_workdir_path"; tput el; printf "${C_RESET}"
    else
        printf "%s %s" "$_line_text" "$_workdir_path"
    fi
    printf "\n"

    # --- Strategy Selection (FIXED with tput el) ---
    _line=$((_line + 3));
    _move_cursor $_line 2; printf "${C_BOLD}${C_BLUE}MERGE STRATEGY (On Conflict):${C_RESET}"
    _move_cursor $((_line + 1)) 2; printf "${C_BLUE}══════════════════════════════${C_RESET}"

    _line=$((_line + 2)); _move_cursor $_line 4
    _line_text=$(printf "[%s] L${C_YELLOW}${C_BOLD}O${C_RESET}CAL  (Keep local changes)" "$([ "$_strategy_selected" -eq 0 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 1 ] && [ "$_strategy_selected" -eq 0 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] R${C_YELLOW}${C_BOLD}E${C_RESET}MOTE (Overwrite with remote)" "$([ "$_strategy_selected" -eq 1 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 1 ] && [ "$_strategy_selected" -eq 1 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi
    printf "\n"

    # --- Action Selection (FIXED with tput el) ---
    _line=$((_line + 3)); _move_cursor $_line 2; printf "${C_BOLD}${C_BLUE}ACTION:${C_RESET}"
    _move_cursor $((_line + 1)) 2; printf "${C_BLUE}═══════${C_RESET}"

    _line=$((_line + 2)); _move_cursor $_line 4
    _line_text=$(printf "[%s] ${C_YELLOW}${C_BOLD}S${C_RESET}YNC   (Add/Commit, Fetch, Pull, Add/Commit, Push)" "$([ "$_action_selected" -eq 0 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 0 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] ${C_YELLOW}${C_BOLD}P${C_RESET}USH   (Merge from Local)" "$([ "$_action_selected" -eq 1 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 1 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] PU${C_YELLOW}${C_BOLD}L${C_RESET}L (Merge from Remote)" "$([ "$_action_selected" -eq 2 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 2 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); # Jump line

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] S${C_YELLOW}${C_BOLD}T${C_RESET}ATUS (Check Local Untracked and Uncommitted)" "$([ "$_action_selected" -eq 3 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 3 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] ${C_YELLOW}${C_BOLD}F${C_RESET}ETCH (Get from Remote)" "$([ "$_action_selected" -eq 4 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 4 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] U${C_YELLOW}${C_BOLD}N${C_RESET}TRACKED (List untracked files)" "$([ "$_action_selected" -eq 5 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 5 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi

    _line=$((_line + 1)); _move_cursor $_line 4
    _line_text=$(printf "[%s] ${C_YELLOW}${C_BOLD}I${C_RESET}GNORED (List ignored files)" "$([ "$_action_selected" -eq 6 ] && printf "●" || printf " ")")
    if [ "$_current_field" -eq 2 ] && [ "$_action_selected" -eq 6 ]; then
        printf "${C_BG_BLUE}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        printf "%s" "$_line_text"
    fi
    printf "\n"

    # --- Repository Selection (FIXED with tput el) ---
    _line=$((_line + 3));
    _move_cursor $_line 2;  printf "${C_BOLD}${C_BLUE}REPOSITORIES (Toggle with SPACE):${C_RESET}"
    _move_cursor $_line 40; printf "${C_BOLD}${C_BLUE}LOCAL STATUS:${C_RESET}"
    _move_cursor $_line 60; printf "${C_BOLD}${C_BLUE}REMOTE STATUS:${C_RESET}"
    _line=$((_line + 1));
    _move_cursor $_line 2; printf "${C_BLUE}═════════════════════════════════${C_RESET}"
    _move_cursor $_line 40; printf "${C_BLUE}═════════════${C_RESET}"
    _move_cursor $_line 60; printf "${C_BLUE}══════════════${C_RESET}"

    i=0
    while [ "$i" -lt "$_repo_count" ]; do
        _line=$((_line + 1));

        repo_name=$(echo "$_repo_list" | sed -n "$((i + 1))p")
        is_selected=$(echo "$_repo_selection" | cut -c $((i + 1)))
        status_string=$(echo "$_repo_status_list" | sed -n "$((i + 1))p")
        fetch_status_string=$(echo "$_repo_fetch_status_list" | sed -n "$((i + 1))p")
        marker="$([ "$is_selected" = "y" ] && printf "✓" || printf " ")"

        repo_line=$(printf "[%s] %-30.30s" "$marker" "$repo_name")
        _full_line=$(printf "%s  %-18s  %s" "$repo_line" "$status_string" "$fetch_status_string")

        _move_cursor $_line 4
        if [ "$_current_field" -eq 3 ] && [ "$i" -eq "$_repo_cursor_index" ]; then
            # This is the new fix: print text, fill line, reset
            printf "${C_BG_BLUE}%s" "$_full_line"; tput el; printf "${C_RESET}"
        else
            # This is the original, correct code for non-selected lines
            printf "%s" "$repo_line"
            _move_cursor $_line 40
            printf "%-18s" "$status_string"
            _move_cursor $_line 60
            printf "%s" "$fetch_status_string"
        fi

        i=$((i + 1))
    done

    # --- Execute Button (FIXED with tput el) ---
    _run_button_line=$((_line + 2))
    _move_cursor $_run_button_line 2
    _line_text="   [ RUN ]"
    if [ "$_current_field" -eq 4 ]; then
        # When selected: green background
        printf "${C_BG_GREEN}%s" "$_line_text"; tput el; printf "${C_RESET}"
    else
        # When not selected: just bold text
        printf "${C_BOLD}%s${C_RESET}" "$_line_text"
    fi

    # --- MOVED HELP TEXT ---
    _help_line=$((_run_button_line + 6))
    _move_cursor $_help_line 2
    printf "${C_BOLD}${C_BLUE}KEYBOARD SHORTCUTS${C_RESET}\n"
    _move_cursor $(($_help_line + 1)) 2
    printf "${C_BLUE}═══════════════════${C_RESET}\n"
    _help_line=$((_help_line + 2))

    _move_cursor $_help_line 2
    printf "${C_BOLD}Navigate:${C_RESET} (${C_YELLOW}${C_BOLD}↑${C_RESET}/${C_YELLOW}${C_BOLD}↓${C_RESET}) List | (${C_YELLOW}${C_BOLD}TAB${C_RESET}) Field | (${C_YELLOW}${C_BOLD}SPACE${C_RESET}) Toggle | (${C_YELLOW}${C_BOLD}ENTER${C_RESET}) Run | (${C_YELLOW}${C_BOLD}q${C_RESET}) Quit\n"
    _help_line=$((_help_line + 1))

    _move_cursor $_help_line 2
    printf "${C_BOLD}Select:${C_RESET}   (${C_YELLOW}${C_BOLD}a${C_RESET}) All | (${C_YELLOW}${C_BOLD}u${C_RESET}) None | (${C_YELLOW}${C_BOLD}k${C_RESET}) Not OK\n"
    _help_line=$((_help_line + 1))

    _move_cursor $_help_line 2
    printf "${C_BOLD}Strategy:${C_RESET} (${C_YELLOW}${C_BOLD}o${C_RESET}) Local | (${C_YELLOW}${C_BOLD}e${C_RESET}) Remote\n"
    _help_line=$((_help_line + 1))

    _move_cursor $_help_line 2
    printf "${C_BOLD}Actions:${C_RESET}  (${C_YELLOW}${C_BOLD}s${C_RESET}) Sync | (${C_YELLOW}${C_BOLD}p${C_RESET}) Push | (${C_YELLOW}${C_BOLD}l${C_RESET}) Pull | (${C_YELLOW}${C_BOLD}f${C_RESET}) Fetch\n"
    _help_line=$((_help_line + 1))

    _move_cursor $_help_line 13; printf "(${C_YELLOW}${C_BOLD}n${C_RESET}) Untracked | (${C_YELLOW}${C_BOLD}t${C_RESET}) Status | (${C_YELLOW}${C_BOLD}r${C_RESET}) Refresh\n"
    _help_line=$((_help_line + 1))

    _move_cursor $_help_line 2
    printf "${C_BOLD}Tools:${C_RESET}    (${C_YELLOW}${C_BOLD}w${C_RESET}) Toggle Workdir\n"

    _move_cursor $(($_help_line + 2)) 0
}

run_tui_action() {
    _restore_term
    # Don't clear screen immediately - will clear after showing message
    printf "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}                    Executing Actions...                       ${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n\n"

    strategy="theirs"; [ "$_strategy_selected" -eq 0 ] && strategy="ours"

    # Determine working directory
    if [ "$_workdir_selected" -eq 0 ]; then
        work_dir="."
    else
        work_dir="$_workdir_path"
    fi

    # Verify working directory exists
    if [ ! -d "$work_dir" ]; then
        _error "Working directory does not exist: $work_dir"
        printf "\n${C_YELLOW}Press 'q' to quit or any other key to return to menu.${C_RESET}\n"
        read -r choice
        case "$choice" in
            q|Q) return 1 ;;  # Quit
            *) return 0 ;;    # Return to menu
        esac
    fi

    # Save current directory and change to working directory
    original_dir=$(pwd)
    cd "$work_dir" || {
        _error "Failed to change to working directory: $work_dir"
        printf "\n${C_YELLOW}Press 'q' to quit or any other key to return to menu.${C_RESET}\n"
        read -r choice
        case "$choice" in
            q|Q) return 1 ;;  # Quit
            *) return 0 ;;    # Return to menu
        esac
    }

    # Build the list of selected repos
    selected_repos=""
    i=0
    while IFS= read -r repo_name || [ -n "$repo_name" ]; do
        is_selected=$(echo "$_repo_selection" | cut -c $((i + 1)))
        if [ "$is_selected" = "y" ]; then
            if [ -z "$selected_repos" ]; then
                selected_repos="$repo_name"
            else
                selected_repos="${selected_repos}
${repo_name}"
            fi
        fi
        i=$((i + 1))
    done <<EOF
$_repo_list
EOF

    if [ -z "$selected_repos" ]; then
        _warn "No repositories selected. Nothing to do."
    else
        case "$_action_selected" in
            0) run_cli_sync "$([ "$_strategy_selected" -eq 0 ] && echo "local" || echo "remote")" "$selected_repos" ;; 
            1) run_cli_push "$selected_repos" ;; 
            2) run_cli_pull "$selected_repos" ;; 
            3) run_cli_status "$selected_repos" ;; 
            4) run_cli_fetch "$selected_repos" ;; 
            5) run_cli_untracked "$selected_repos" ;; 
            6) run_cli_ignored "$selected_repos" ;; 
        esac
    fi

    # Return to original directory
    cd "$original_dir"

    printf "\n${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}                  All tasks complete!                          ${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n"
    printf "\n${C_YELLOW}Press 'q' to quit or any other key to return to menu.${C_RESET}\n"

    # Read user choice
    read -r choice
    case "$choice" in
        q|Q) return 1 ;;  # Exit
        *) return 0 ;;    # Return to menu
    esac
}

# --- FUNCTION: To refresh repo statuses (both local and remote) ---
_refresh_repo_statuses() {
    # Get current working directory
    if [ "$_workdir_selected" -eq 0 ]; then
        work_dir="."
    else
        work_dir="$_workdir_path"
    fi

    # Temporarily show a loading message
    _clear_screen; _move_cursor 5 5;
    printf "${C_BOLD}${C_YELLOW}Refreshing all statuses (local + remote fetch)...${C_RESET}"

    _repo_status_list=""
    _repo_fetch_status_list=""

    # Save current directory and change to working directory
    original_dir=$(pwd)
    if [ -d "$work_dir" ]; then
        cd "$work_dir" 2>/dev/null || true
    fi

    i=1
    while [ "$i" -le "$_repo_count" ]; do
        repo_name=$(echo "$_repo_list" | sed -n "${i}p")
        status=$(_get_repo_status "$repo_name")
        fetch_status=$(_get_repo_fetch_status "$repo_name")
        _repo_status_list="${_repo_status_list}${status}
"
        _repo_fetch_status_list="${_repo_fetch_status_list}${fetch_status}
"
        i=$((i+1))
    done

    # Return to original directory
    cd "$original_dir"
}

# --- FUNCTION: To refresh local status only (no fetch) ---
_refresh_status_only() {
    # Get current working directory
    if [ "$_workdir_selected" -eq 0 ]; then
        work_dir="."
    else
        work_dir="$_workdir_path"
    fi

    # Temporarily show a loading message
    _clear_screen; _move_cursor 5 5;
    printf "${C_BOLD}${C_YELLOW}Refreshing local status only...${C_RESET}"

    _repo_status_list=""

    # Save current directory and change to working directory
    original_dir=$(pwd)
    if [ -d "$work_dir" ]; then
        cd "$work_dir" 2>/dev/null || true
    fi

    i=1
    while [ "$i" -le "$_repo_count" ]; do
        repo_name=$(echo "$_repo_list" | sed -n "${i}p")
        status=$(_get_repo_status "$repo_name")
        _repo_status_list="${_repo_status_list}${status}
"
        i=$((i+1))
    done

    # Return to original directory
    cd "$original_dir"
}

# --- FUNCTION: To refresh fetch status only (no local check) ---
_refresh_fetch_only() {
    # Get current working directory
    if [ "$_workdir_selected" -eq 0 ]; then
        work_dir="."
    else
        work_dir="$_workdir_path"
    fi

    # Temporarily show a loading message
    _clear_screen; _move_cursor 5 5;
    printf "${C_BOLD}${C_YELLOW}Fetching from remote only...${C_RESET}"

    _repo_fetch_status_list=""

    # Save current directory and change to working directory
    original_dir=$(pwd)
    if [ -d "$work_dir" ]; then
        cd "$work_dir" 2>/dev/null || true
    fi

    i=1
    while [ "$i" -le "$_repo_count" ]; do
        repo_name=$(echo "$_repo_list" | sed -n "${i}p")
        fetch_status=$(_get_repo_fetch_status "$repo_name")
        _repo_fetch_status_list="${_repo_fetch_status_list}${fetch_status}
"
        i=$((i+1))
    done

    # Return to original directory
    cd "$original_dir"
}


run_interactive_mode() {
    # --- Initialize TUI-specific repo variables ---
    # Extract just the repo names, trimming leading/trailing whitespace
    _repo_list=$(printf "%s" "$ALL_REPOS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -d: -f1 | sed '/^$/d')
    _repo_count=$(echo "$_repo_list" | wc -l)

    # Initialize all repos to be selected ('y')
    _repo_selection=""
    i=1; while [ "$i" -le "$_repo_count" ]; do _repo_selection="${_repo_selection}y"; i=$((i+1)); done

    # --- Pre-load repository statuses (local only for fast startup) ---
    _refresh_status_only # Fast startup: local status only, no remote fetch

    # Initialize fetch status with placeholder
    _repo_fetch_status_list=""
    i=1; while [ "$i" -le "$_repo_count" ]; do
        _repo_fetch_status_list="${_repo_fetch_status_list}${C_GRAY}Not Checked${C_RESET}
"
        i=$((i+1))
    done

    # Reset cursor positions
    _repo_cursor_index=0
    _current_field=0

    trap '_restore_term' EXIT INT TERM; _save_term
    stty -icanon -echo; _hide_cursor

    _return_to_menu=0

    while true; do
        draw_interface
        key=$(_read_key)
        case "$key" in
            up)
                if [ "$_current_field" -eq 3 ]; then # In repo list
                    _repo_cursor_index=$(( (_repo_cursor_index - 1 + _repo_count) % _repo_count ))
                else
                    _current_field=$(((_current_field - 1 + _total_fields) % _total_fields))
                fi
                ;;
            down)
                if [ "$_current_field" -eq 3 ]; then # In repo list
                    _repo_cursor_index=$(( (_repo_cursor_index + 1) % _repo_count ))
                else
                    _current_field=$(((_current_field + 1) % _total_fields))
                fi
                ;;
            tab)
                _current_field=$(((_current_field + 1) % _total_fields))
                ;;

            # --- Repo Selection Shortcuts ---
            selectall) # 'a'
                _repo_selection=""
                i=1; while [ "$i" -le "$_repo_count" ]; do _repo_selection="${_repo_selection}y"; i=$((i+1)); done
                ;;
            unselectall) # 'u'
                _repo_selection=""
                i=1; while [ "$i" -le "$_repo_count" ]; do _repo_selection="${_repo_selection}n"; i=$((i+1)); done
                ;;
            selectnotok) # 'k'
                OK_STRING=$(printf "${C_GREEN}OK${C_RESET}")
                new_selection=""
                i=0
                while [ "$i" -lt "$_repo_count" ]; do
                    status=$(echo "$_repo_status_list" | sed -n "$((i + 1))p")
                    if [ "$status" != "$OK_STRING" ]; then
                        new_selection="${new_selection}y"
                    else
                        new_selection="${new_selection}n"
                    fi
                    i=$((i + 1))
                done
                _repo_selection="$new_selection"
                ;;
            refresh) # 'r' - Refresh both local status and fetch from remote
                _refresh_repo_statuses
                ;;
            status) # 't' - Selects STATUS and refreshes local status
                _action_selected=3
                _refresh_status_only
                ;;
            editpath) # 'w'
                # Allow editing the custom path
                _restore_term
                printf "\n${C_BOLD}${C_BLUE}Enter new working directory path:${C_RESET}\n"
                printf "${C_YELLOW}Current: %s${C_RESET}\n" "$_workdir_path"
                printf "> "
                read -r new_path
                if [ -n "$new_path" ]; then
                    _workdir_path="$new_path"
                    _workdir_selected=1  # Switch to custom path
                    _refresh_repo_statuses
                fi
                _save_term
                stty -icanon -echo
                ;;
            restoresymlinks) # 'y' - Restore 0.spec symlinks
                _restore_term
                _clear_screen

                # Get working directory
                if [ "$_workdir_selected" -eq 0 ]; then
                    work_dir="."
                else
                    work_dir="$_workdir_path"
                fi

                # Get script path (same directory as gcl.sh)
                script_dir="$(cd "$(dirname "$0")" && pwd)"
                symlink_script="$script_dir/restore-spec-symlinks.sh"

                if [ ! -f "$symlink_script" ]; then
                    _error "Script not found: $symlink_script"
                    printf "\n${C_YELLOW}Press any key to return to menu...${C_RESET}\n"
                    read -r
                    _save_term
                    stty -icanon -echo
                    break
                fi

                printf "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n"
                printf "${C_BOLD}${C_CYAN}           Restoring 0.spec Symlinks...                        ${C_RESET}\n"
                printf "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n\n"

                # Run the script
                bash "$symlink_script" "$work_dir"

                printf "\n${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n"
                printf "${C_GREEN}${C_BOLD}                  Done!                                         ${C_RESET}\n"
                printf "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════${C_RESET}\n"
                printf "${C_YELLOW}Press any key to return to menu...${C_RESET}\n"
                read -r
                _save_term
                stty -icanon -echo
                ;;

            # --- Menu Shortcuts (MODIFIED) ---
            local)  _strategy_selected=0 ;; # 'o'
            remote) _strategy_selected=1 ;; # 'e'
            sync)   _action_selected=0 ;; # 's'
            push)   _action_selected=1 ;; # 'p'
            pull)   _action_selected=2 ;; # 'l'
            fetch)
                _action_selected=4
                _refresh_fetch_only
                ;;
            untracked) _action_selected=5 ;; # 'n'
            ignored) _action_selected=6 ;; # 'i'

            space)
                case "$_current_field" in
                    0) _workdir_selected=$((1 - _workdir_selected)) ;; 
                    1) _strategy_selected=$((1 - _strategy_selected)) ;; 
                    2) _action_selected=$((($_action_selected + 1) % 7)) ;; 
                    3) # Toggle repo selection
                        current_char=$(echo "$_repo_selection" | cut -c $((_repo_cursor_index + 1)))
                        new_char=$([ "$current_char" = "y" ] && echo "n" || echo "y")
                        _repo_selection=$(echo "$_repo_selection" | sed "s/./$new_char/$((_repo_cursor_index + 1))")
                        ;; 
                esac
                ;; 
            enter)
                run_tui_action
                if [ $? -eq 0 ]; then
                    _return_to_menu=1
                fi
                break
                ;;
            quit) break ;; 
        esac
    done
    _restore_term

    # If user wants to return to menu, restart interactive mode
    if [ "$_return_to_menu" -eq 1 ]; then
        run_interactive_mode
    fi
}

show_help() {
    printf "${C_BOLD}${C_CYAN}gcl.sh - Git Clone/Pull/Push Manager${C_RESET}\n\n"
    printf "Manages multiple git repositories via a TUI or command-line arguments.\n\n"
    printf "${C_BOLD}${C_YELLOW}USAGE:${C_RESET}\n"
    printf "  ${C_BOLD}gcl.sh${C_RESET} [command] [options]\n\n"
    printf "${C_BOLD}${C_YELLOW}COMMANDS:${C_RESET}\n"
    printf "  (no command)\t\tLaunches the interactive TUI menu.\n"
    printf "  ${C_GREEN}sync [local|remote]${C_RESET}\tBidirectional sync. (Add/Commit, Fetch, Pull, Add/Commit, Push). Default: 'remote'.\n"
    printf "  ${C_GREEN}push${C_RESET}\t\t\tPushes committed changes.\n"
    printf "  ${C_GREEN}pull${C_RESET}\t\t\tPulls using 'remote' strategy.\n"
    printf "  ${C_GREEN}fetch${C_RESET}\t\t\tFetches from remote.\n"
    printf "  ${C_GREEN}status${C_RESET}\t\t\tChecks for local untracked and uncommitted changes.\n"
    printf "  ${C_GREEN}untracked${C_RESET}\t\tLists untracked files (excluding ignored).\n"
    printf "  ${C_GREEN}ignored${C_RESET}\t\tLists ignored files.\n"
    printf "  ${C_GREEN}help${C_RESET}\t\t\tShows this help message.\n\E[0m\n"
}

# --- Main Entry Point ---
main() {
    case "$1" in
        sync) run_cli_sync "$2" ;; 
        push) run_cli_push ;; 
        pull) run_cli_pull ;; 
        fetch) run_cli_fetch ;; 
        status) run_cli_status ;; 
        untracked) run_cli_untracked ;; 
        ignored) run_cli_ignored ;; 
        help|-h|--help) show_help ;; 
        "") run_interactive_mode ;; 
        *) _error "Invalid command: $1"; show_help; exit 1 ;; 
    esac
}

main "$@"