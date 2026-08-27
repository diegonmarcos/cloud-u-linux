#!/bin/sh
# gcl.sh - Git Clone/Pull/Push Manager
# POSIX-compliant shell script
#
# Usage:
#   ./gcl.sh              # Launch TUI
#   ./gcl.sh <command>    # CLI mode (sync|pull|push|status|fetch)
#   ./gcl.sh --check      # Check dependencies
#   ./gcl.sh --help       # Show help

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/gcl.json"

# Global state (loaded from config)
MERGE_STRATEGY="theirs"  # "theirs" (server) or "ours" (local)
AUTO_FETCH="false"

# Colors (disable if not a terminal)
if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
    C_DIM="\033[2m"
    C_BG_BLUE="\033[44m"
else
    C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_DIM='' C_BG_BLUE=''
fi

# Symbols
OK="${C_GREEN}✓${C_RESET}"
FAIL="${C_RED}✗${C_RESET}"
WARN="${C_YELLOW}!${C_RESET}"
INFO="${C_BLUE}→${C_RESET}"

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

# Load dependencies from config or use defaults
load_deps() {
    if [ -f "$CONFIG_FILE" ]; then
        # Extract array content between [ and ]
        DEPS_REQUIRED=$(sed -n '/"required":/{ s/.*\[//; s/\].*//; s/"//g; s/,/ /g; p; }' "$CONFIG_FILE")
        DEPS_OPTIONAL=$(sed -n '/"optional":/{ s/.*\[//; s/\].*//; s/"//g; s/,/ /g; p; }' "$CONFIG_FILE")
    fi
    # Defaults if not found
    : "${DEPS_REQUIRED:=git}"
    : "${DEPS_OPTIONAL:=gh}"
}

check_deps() {
    load_deps
    printf "${C_BOLD}=== Dependency Check ===${C_RESET}\n\n"

    missing_required=""
    missing_optional=""

    # Check required
    printf "${C_BOLD}Required:${C_RESET}\n"
    for dep in $DEPS_REQUIRED; do
        if command -v "$dep" >/dev/null 2>&1; then
            version=$($dep --version 2>&1 | head -1)
            printf "  $OK ${C_GREEN}%-10s${C_RESET} %s\n" "$dep" "$version"
        else
            printf "  $FAIL ${C_RED}%-10s${C_RESET} ${C_DIM}not found${C_RESET}\n" "$dep"
            missing_required="${missing_required}${dep} "
        fi
    done

    # Check optional
    printf "\n${C_BOLD}Optional:${C_RESET}\n"
    for dep in $DEPS_OPTIONAL; do
        if command -v "$dep" >/dev/null 2>&1; then
            version=$($dep --version 2>&1 | head -1)
            printf "  $OK ${C_GREEN}%-10s${C_RESET} %s\n" "$dep" "$version"
        else
            printf "  $WARN ${C_YELLOW}%-10s${C_RESET} ${C_DIM}not found (CI status unavailable)${C_RESET}\n" "$dep"
            missing_optional="${missing_optional}${dep} "
        fi
    done

    # Summary and install suggestions
    all_missing=$(echo "$missing_required $missing_optional" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')

    if [ -n "$missing_required" ] || [ -n "$missing_optional" ]; then
        printf "\n${C_BOLD}Install:${C_RESET}\n"

        # Detect OS/package manager
        if [ -f /etc/NIXOS ] || command -v nixos-rebuild >/dev/null 2>&1; then
            printf "  ${C_CYAN}nix-shell -p $all_missing${C_RESET}\n"
            IS_NIXOS=1
        elif command -v pacman >/dev/null 2>&1; then
            printf "  ${C_CYAN}sudo pacman -S $all_missing${C_RESET}\n"
        elif command -v apt >/dev/null 2>&1; then
            printf "  ${C_CYAN}sudo apt install $all_missing${C_RESET}\n"
        elif command -v dnf >/dev/null 2>&1; then
            printf "  ${C_CYAN}sudo dnf install $all_missing${C_RESET}\n"
        elif command -v brew >/dev/null 2>&1; then
            printf "  ${C_CYAN}brew install $all_missing${C_RESET}\n"
        else
            printf "  ${C_CYAN}<pkg-manager> install $all_missing${C_RESET}\n"
        fi
    fi

    # Result
    if [ -n "$missing_required" ]; then
        printf "\n$FAIL ${C_RED}Missing required dependencies${C_RESET}\n"
        return 1
    else
        printf "\n$OK ${C_GREEN}All required dependencies installed${C_RESET}\n"
        return 0
    fi
}

# =============================================================================
# CONFIG PARSER (reads gcl.json)
# =============================================================================

# Parse JSON config file - extracts settings and repos
# Uses grep/sed for POSIX compatibility (no jq dependency)
parse_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "$FAIL ${C_RED}Config file not found: $CONFIG_FILE${C_RESET}\n"
        exit 1
    fi

    # Extract settings
    WORKDIR=$(grep -E '"workdir"[[:space:]]*:[[:space:]]*"' "$CONFIG_FILE" | grep -v "_comment" | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
    MERGE_STRATEGY=$(grep -E '"merge_strategy"[[:space:]]*:[[:space:]]*"' "$CONFIG_FILE" | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
    AUTO_FETCH=$(grep -E '"auto_fetch"[[:space:]]*:' "$CONFIG_FILE" | sed 's/.*:[[:space:]]*\([a-z]*\).*/\1/' | head -1)

    # Defaults if not found
    [ -z "$WORKDIR" ] && WORKDIR="$(pwd)"
    [ -z "$MERGE_STRATEGY" ] && MERGE_STRATEGY="theirs"
    [ -z "$AUTO_FETCH" ] && AUTO_FETCH="false"

    # Ensure workdir exists
    if [ ! -d "$WORKDIR" ]; then
        printf "$WARN ${C_YELLOW}Workdir does not exist: $WORKDIR${C_RESET}\n"
        printf "Creating... "
        if mkdir -p "$WORKDIR"; then
            printf "${C_GREEN}OK${C_RESET}\n"
        else
            printf "${C_RED}FAILED${C_RESET}\n"
            printf "$FAIL ${C_RED}Cannot create workdir, falling back to current directory${C_RESET}\n"
            WORKDIR="$(pwd)"
        fi
    fi

    # Extract all repos (public + private) as "name:url" pairs
    REPOS=$(grep -E '^\s*"[^_][^"]*":\s*"git@' "$CONFIG_FILE" | \
            sed 's/.*"\([^"]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1:\2/')

    REPO_COUNT=$(echo "$REPOS" | grep -c ':' || echo 0)
}

# Get list of repo names
get_repo_names() {
    echo "$REPOS" | cut -d: -f1
}

# Get repo URL by name
get_repo_url() {
    echo "$REPOS" | grep "^$1:" | cut -d: -f2-
}

# =============================================================================
# GIT ENGINE (POSIX shell)
# =============================================================================

# Check repo status (local changes, unpushed commits)
repo_status() {
    repo_dir="$1"

    if [ ! -d "$repo_dir" ]; then
        printf "${C_RED}Not Cloned${C_RESET}"
        return
    fi

    if [ ! -d "$repo_dir/.git" ]; then
        printf "${C_RED}Not a Repo${C_RESET}"
        return
    fi

    # Check for uncommitted changes
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        printf "${C_YELLOW}Uncommitted${C_RESET}"
        return
    fi

    # Check if tracking remote
    if ! git -C "$repo_dir" rev-parse @{u} >/dev/null 2>&1; then
        printf "${C_YELLOW}No Upstream${C_RESET}"
        return
    fi

    # Check for unpushed commits
    unpushed=$(git -C "$repo_dir" log @{u}.. --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$unpushed" -gt 0 ]; then
        printf "${C_YELLOW}${unpushed} Unpushed${C_RESET}"
        return
    fi

    # Check for unpulled commits
    unpulled=$(git -C "$repo_dir" log ..@{u} --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$unpulled" -gt 0 ]; then
        printf "${C_CYAN}${unpulled} To Pull${C_RESET}"
        return
    fi

    printf "${C_GREEN}OK${C_RESET}"
}

# Clone a repository
repo_clone() {
    repo_name="$1"
    repo_url="$2"
    repo_dir="$WORKDIR/$repo_name"

    printf "$INFO Cloning ${C_BOLD}$repo_name${C_RESET}...\n"

    if git clone "$repo_url" "$repo_dir" 2>&1; then
        printf "$OK ${C_GREEN}Cloned${C_RESET}\n"
        return 0
    else
        printf "$FAIL ${C_RED}Clone failed${C_RESET}\n"
        return 1
    fi
}

# Pull changes
repo_pull() {
    repo_name="$1"
    strategy="${2:-theirs}"  # default: remote wins
    repo_dir="$WORKDIR/$repo_name"

    if [ ! -d "$repo_dir" ]; then
        repo_clone "$repo_name" "$(get_repo_url "$repo_name")"
        return
    fi

    printf "$INFO Pulling ${C_BOLD}$repo_name${C_RESET} (strategy: $strategy)...\n"

    # Stash local changes if any
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        printf "  ${C_DIM}Stashing local changes...${C_RESET}\n"
        git -C "$repo_dir" stash -q
        STASHED=1
    else
        STASHED=0
    fi

    # Pull with strategy
    if git -C "$repo_dir" pull --no-rebase --strategy-option="$strategy" 2>&1; then
        printf "$OK ${C_GREEN}Pulled${C_RESET}\n"
    else
        printf "$FAIL ${C_RED}Pull failed${C_RESET}\n"
    fi

    # Restore stashed changes
    if [ "$STASHED" = "1" ]; then
        printf "  ${C_DIM}Restoring local changes...${C_RESET}\n"
        git -C "$repo_dir" stash pop -q 2>/dev/null || true
    fi
}

# Push changes
repo_push() {
    repo_name="$1"
    repo_dir="$WORKDIR/$repo_name"

    if [ ! -d "$repo_dir" ]; then
        printf "$FAIL ${C_RED}$repo_name not cloned${C_RESET}\n"
        return 1
    fi

    printf "$INFO Pushing ${C_BOLD}$repo_name${C_RESET}...\n"

    if git -C "$repo_dir" push 2>&1; then
        printf "$OK ${C_GREEN}Pushed${C_RESET}\n"
    else
        printf "$FAIL ${C_RED}Push failed${C_RESET}\n"
    fi
}

# Sync: commit local, pull, push
repo_sync() {
    repo_name="$1"
    strategy="${2:-theirs}"
    repo_dir="$WORKDIR/$repo_name"

    if [ ! -d "$repo_dir" ]; then
        repo_clone "$repo_name" "$(get_repo_url "$repo_name")"
        return
    fi

    printf "$INFO Syncing ${C_BOLD}$repo_name${C_RESET}...\n"

    # Stage and commit local changes
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        printf "  ${C_DIM}Committing local changes...${C_RESET}\n"
        git -C "$repo_dir" add -A
        git -C "$repo_dir" commit -q -m "sync: auto-commit" 2>/dev/null || true
    fi

    # Fetch and pull
    git -C "$repo_dir" fetch -q 2>/dev/null || true

    if git -C "$repo_dir" pull --no-rebase --strategy-option="$strategy" -q 2>&1; then
        printf "$OK ${C_GREEN}Pulled${C_RESET}\n"
    else
        printf "$WARN ${C_YELLOW}Pull had conflicts${C_RESET}\n"
    fi

    # Push
    if git -C "$repo_dir" push -q 2>&1; then
        printf "$OK ${C_GREEN}Pushed${C_RESET}\n"
    else
        printf "$WARN ${C_YELLOW}Push failed${C_RESET}\n"
    fi
}

# Fetch all repos
repo_fetch() {
    repo_name="$1"
    repo_dir="$WORKDIR/$repo_name"

    if [ ! -d "$repo_dir" ]; then
        printf "$FAIL ${C_RED}$repo_name not cloned${C_RESET}\n"
        return
    fi

    printf "$INFO Fetching ${C_BOLD}$repo_name${C_RESET}..."

    if git -C "$repo_dir" fetch -q 2>&1; then
        printf " $OK\n"
    else
        printf " $FAIL\n"
    fi
}

# =============================================================================
# DETAILED STATUS FUNCTIONS
# =============================================================================

# Check if repo is cloned
check_cloned() {
    [ -d "$1/.git" ] && echo "1" || echo "0"
}

# Check for uncommitted changes
check_uncommitted() {
    repo_dir="$1"
    [ ! -d "$repo_dir/.git" ] && echo "-" && return
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        echo "1"
    else
        echo "0"
    fi
}

# Check for unpushed commits
check_unpushed() {
    repo_dir="$1"
    [ ! -d "$repo_dir/.git" ] && echo "-" && return
    if ! git -C "$repo_dir" rev-parse @{u} >/dev/null 2>&1; then
        echo "?"  # No upstream
        return
    fi
    count=$(git -C "$repo_dir" log @{u}.. --oneline 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
}

# Check for unpulled commits (requires fetch first)
check_unpulled() {
    repo_dir="$1"
    [ ! -d "$repo_dir/.git" ] && echo "-" && return
    if ! git -C "$repo_dir" rev-parse @{u} >/dev/null 2>&1; then
        echo "?"  # No upstream
        return
    fi
    count=$(git -C "$repo_dir" log ..@{u} --oneline 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
}

# Check GitHub Actions status (requires gh CLI)
check_gh_actions() {
    repo_dir="$1"
    repo_name="$2"

    [ ! -d "$repo_dir/.git" ] && echo "-" && return

    # Check if gh is available
    if ! command -v gh >/dev/null 2>&1; then
        echo "?"
        return
    fi

    # Get remote URL and extract owner/repo
    remote_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null)
    if [ -z "$remote_url" ]; then
        echo "?"
        return
    fi

    # Extract owner/repo from git@github.com:owner/repo.git
    gh_repo=$(echo "$remote_url" | sed 's/.*github.com[:/]\([^/]*\/[^.]*\).*/\1/')

    # Get last workflow run status
    status=$(gh run list --repo "$gh_repo" --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null)

    case "$status" in
        success) echo "✓" ;;
        failure) echo "✗" ;;
        cancelled) echo "○" ;;
        "") echo "-" ;;
        *) echo "?" ;;
    esac
}

# Format cell with color based on value
format_cell() {
    value="$1"
    type="$2"  # cloned, uncommitted, unpushed, unpulled, actions

    case "$type" in
        cloned)
            if [ "$value" = "1" ]; then
                printf "${C_GREEN}Yes${C_RESET}"
            else
                printf "${C_RED}No${C_RESET}"
            fi
            ;;
        uncommitted)
            case "$value" in
                "-") printf "${C_DIM}--${C_RESET}" ;;
                "0") printf "${C_GREEN}Clean${C_RESET}" ;;
                "1") printf "${C_YELLOW}Dirty${C_RESET}" ;;
                *) printf "${C_DIM}?${C_RESET}" ;;
            esac
            ;;
        unpushed)
            case "$value" in
                "-") printf "${C_DIM}--${C_RESET}" ;;
                "?") printf "${C_DIM}?${C_RESET}" ;;
                "0") printf "${C_GREEN}0${C_RESET}" ;;
                *) printf "${C_YELLOW}${value}${C_RESET}" ;;
            esac
            ;;
        unpulled)
            case "$value" in
                "-") printf "${C_DIM}--${C_RESET}" ;;
                "?") printf "${C_DIM}?${C_RESET}" ;;
                "0") printf "${C_GREEN}0${C_RESET}" ;;
                *) printf "${C_CYAN}${value}${C_RESET}" ;;
            esac
            ;;
        actions)
            case "$value" in
                "-") printf "${C_DIM}--${C_RESET}" ;;
                "?") printf "${C_DIM}?${C_RESET}" ;;
                "✓") printf "${C_GREEN}✓${C_RESET}" ;;
                "✗") printf "${C_RED}✗${C_RESET}" ;;
                "○") printf "${C_YELLOW}○${C_RESET}" ;;
                *) printf "${C_DIM}?${C_RESET}" ;;
            esac
            ;;
    esac
}

# =============================================================================
# CLI COMMANDS
# =============================================================================

cmd_status() {
    # Show merge strategy
    printf "${C_BOLD}Merge Strategy:${C_RESET} "
    if [ "$MERGE_STRATEGY" = "theirs" ]; then
        printf "${C_CYAN}Server wins${C_RESET} ${C_DIM}(remote overwrites local on conflict)${C_RESET}\n"
    else
        printf "${C_YELLOW}Local wins${C_RESET} ${C_DIM}(local overwrites remote on conflict)${C_RESET}\n"
    fi
    printf "${C_DIM}Workdir: $WORKDIR${C_RESET}\n\n"

    # Header - reordered: Cloned, To Pull, Local, Unpushed, CI
    printf "${C_BOLD}%-20s  %-8s  %-8s  %-8s  %-8s  %-4s${C_RESET}\n" \
        "Repository" "Cloned" "To Pull" "Local" "Unpushed" "CI"
    printf "${C_DIM}────────────────────  ────────  ────────  ────────  ────────  ────${C_RESET}\n"

    # Collect repo data for sorting
    repo_data=""
    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"

        cloned=$(check_cloned "$repo_dir")
        uncommitted=$(check_uncommitted "$repo_dir")
        unpushed=$(check_unpushed "$repo_dir")
        unpulled=$(check_unpulled "$repo_dir")
        actions=$(check_gh_actions "$repo_dir" "$repo_name")

        # Sort key: cloned (1=yes, 0=no), unpulled count, uncommitted
        # Format: sortkey|name|cloned|unpulled|uncommitted|unpushed|actions
        if [ "$cloned" = "1" ]; then
            sort_cloned="0"  # Cloned first (0 sorts before 1)
        else
            sort_cloned="1"
        fi

        # Convert unpulled to sortable number
        case "$unpulled" in
            "-"|"?"|"0") sort_pull="000" ;;
            *) sort_pull=$(printf "%03d" "$unpulled" 2>/dev/null || echo "000") ;;
        esac

        # Convert uncommitted to sortable
        case "$uncommitted" in
            "1") sort_local="0" ;;  # Dirty first
            *) sort_local="1" ;;
        esac

        repo_data="${repo_data}${sort_cloned}${sort_pull}${sort_local}|${repo_name}|${cloned}|${unpulled}|${uncommitted}|${unpushed}|${actions}\n"
    done

    # Sort and display
    printf "%b" "$repo_data" | sort | while IFS='|' read -r sortkey repo_name cloned unpulled uncommitted unpushed actions; do
        [ -z "$repo_name" ] && continue

        # Print repo name
        printf "%-20s  " "$repo_name"

        # Cloned column
        if [ "$cloned" = "1" ]; then
            printf "${C_GREEN}%-8s${C_RESET}" "Yes"
        else
            printf "${C_RED}%-8s${C_RESET}" "No"
        fi
        printf "  "

        # To Pull column (moved here)
        case "$unpulled" in
            "-") printf "${C_DIM}%-8s${C_RESET}" "--" ;;
            "?") printf "${C_DIM}%-8s${C_RESET}" "?" ;;
            "0") printf "${C_GREEN}%-8s${C_RESET}" "0" ;;
            *) printf "${C_CYAN}%-8s${C_RESET}" "$unpulled" ;;
        esac
        printf "  "

        # Local column
        case "$uncommitted" in
            "-") printf "${C_DIM}%-8s${C_RESET}" "--" ;;
            "0") printf "${C_GREEN}%-8s${C_RESET}" "Clean" ;;
            "1") printf "${C_YELLOW}%-8s${C_RESET}" "Dirty" ;;
            *) printf "${C_DIM}%-8s${C_RESET}" "?" ;;
        esac
        printf "  "

        # Unpushed column
        case "$unpushed" in
            "-") printf "${C_DIM}%-8s${C_RESET}" "--" ;;
            "?") printf "${C_DIM}%-8s${C_RESET}" "?" ;;
            "0") printf "${C_GREEN}%-8s${C_RESET}" "0" ;;
            *) printf "${C_YELLOW}%-8s${C_RESET}" "$unpushed" ;;
        esac
        printf "  "

        # CI column
        case "$actions" in
            "-") printf "${C_DIM}%-4s${C_RESET}" "--" ;;
            "?") printf "${C_DIM}%-4s${C_RESET}" "?" ;;
            "✓") printf "${C_GREEN}%-4s${C_RESET}" "✓" ;;
            "✗") printf "${C_RED}%-4s${C_RESET}" "✗" ;;
            "○") printf "${C_YELLOW}%-4s${C_RESET}" "○" ;;
            *) printf "${C_DIM}%-4s${C_RESET}" "?" ;;
        esac

        printf "\n"
    done
}

cmd_status_fetch() {
    printf "${C_BOLD}=== Repository Status (with fetch) ===${C_RESET}\n"
    printf "${C_DIM}Workdir: $WORKDIR${C_RESET}\n"
    printf "${C_DIM}Fetching from remotes...${C_RESET}\n\n"

    # Fetch all repos first
    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"
        if [ -d "$repo_dir/.git" ]; then
            git -C "$repo_dir" fetch -q 2>/dev/null &
        fi
    done
    wait

    # Now show status
    cmd_status
}

cmd_clone_menu() {
    # Build list of uncloned repos
    uncloned_repos=""
    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"
        if [ ! -d "$repo_dir/.git" ]; then
            uncloned_repos="${uncloned_repos}${repo_name}\n"
        fi
    done

    if [ -z "$uncloned_repos" ]; then
        printf "${C_GREEN}All repositories are already cloned.${C_RESET}\n"
        return
    fi

    # Initialize selection array (all unselected)
    selected=""
    count=$(printf "%b" "$uncloned_repos" | grep -c .)
    i=1
    while [ $i -le $count ]; do
        selected="${selected}0"
        i=$((i + 1))
    done

    while true; do
        clear
        printf "${C_BOLD}${C_CYAN}=== Clone Repositories ===${C_RESET}\n"
        printf "${C_DIM}Workdir: $WORKDIR${C_RESET}\n"
        printf "${C_DIM}Toggle selection with number, then press Enter to clone${C_RESET}\n\n"

        # Display repos with checkboxes
        idx=1
        printf "%b" "$uncloned_repos" | while read -r repo_name; do
            [ -z "$repo_name" ] && continue

            # Get selection state for this index
            sel_char=$(echo "$selected" | cut -c$idx)

            if [ "$sel_char" = "1" ]; then
                printf "  ${C_GREEN}[✓]${C_RESET} ${C_CYAN}%2d${C_RESET}) ${C_BOLD}%s${C_RESET}\n" "$idx" "$repo_name"
            else
                printf "  ${C_DIM}[ ]${C_RESET} ${C_CYAN}%2d${C_RESET}) %s\n" "$idx" "$repo_name"
            fi
            idx=$((idx + 1))
        done

        printf "\n"
        printf "  ${C_GREEN} a${C_RESET}) Select ALL    ${C_GREEN}n${C_RESET}) Select NONE\n"
        printf "  ${C_CYAN}Enter${C_RESET}) Clone selected    ${C_RED}q${C_RESET}) Cancel\n"
        printf "\n${C_BOLD}Toggle (1-%d) or command:${C_RESET} " "$count"
        read -r input

        case "$input" in
            q|Q) return ;;
            a|A)
                # Select all
                selected=""
                i=1
                while [ $i -le $count ]; do
                    selected="${selected}1"
                    i=$((i + 1))
                done
                ;;
            n|N)
                # Select none
                selected=""
                i=1
                while [ $i -le $count ]; do
                    selected="${selected}0"
                    i=$((i + 1))
                done
                ;;
            "")
                # Clone selected
                idx=1
                printf "%b" "$uncloned_repos" | while read -r repo_name; do
                    [ -z "$repo_name" ] && continue
                    sel_char=$(echo "$selected" | cut -c$idx)
                    if [ "$sel_char" = "1" ]; then
                        repo_url=$(get_repo_url "$repo_name")
                        repo_clone "$repo_name" "$repo_url"
                        echo ""
                    fi
                    idx=$((idx + 1))
                done
                return
                ;;
            *)
                # Toggle selection for number
                if [ "$input" -ge 1 ] 2>/dev/null && [ "$input" -le "$count" ]; then
                    # Toggle bit at position $input
                    new_selected=""
                    i=1
                    while [ $i -le $count ]; do
                        cur=$(echo "$selected" | cut -c$i)
                        if [ $i -eq "$input" ]; then
                            if [ "$cur" = "1" ]; then
                                new_selected="${new_selected}0"
                            else
                                new_selected="${new_selected}1"
                            fi
                        else
                            new_selected="${new_selected}${cur}"
                        fi
                        i=$((i + 1))
                    done
                    selected="$new_selected"
                fi
                ;;
        esac
    done
}

# Commit all changes in all repos
cmd_commit_all() {
    printf "${C_BOLD}=== Commit All Repos ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"
        [ ! -d "$repo_dir/.git" ] && continue

        if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
            printf "$INFO Committing ${C_BOLD}$repo_name${C_RESET}...\n"
            git -C "$repo_dir" add -A
            if git -C "$repo_dir" commit -m "auto-commit" 2>/dev/null; then
                printf "$OK ${C_GREEN}Committed${C_RESET}\n"
            else
                printf "$WARN ${C_YELLOW}Nothing to commit${C_RESET}\n"
            fi
        else
            printf "${C_DIM}$repo_name: Clean${C_RESET}\n"
        fi
    done
}

# List untracked files
cmd_untracked() {
    printf "${C_BOLD}=== Untracked Files ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"
        [ ! -d "$repo_dir/.git" ] && continue

        untracked=$(git -C "$repo_dir" ls-files --others --exclude-standard 2>/dev/null)
        if [ -n "$untracked" ]; then
            printf "${C_CYAN}$repo_name:${C_RESET}\n"
            echo "$untracked" | while read -r file; do
                printf "  ${C_YELLOW}+ %s${C_RESET}\n" "$file"
            done
            echo ""
        fi
    done
}

# List unstaged (modified) files
cmd_unstaged() {
    printf "${C_BOLD}=== Unstaged Changes ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"
        [ ! -d "$repo_dir/.git" ] && continue

        unstaged=$(git -C "$repo_dir" diff --name-only 2>/dev/null)
        if [ -n "$unstaged" ]; then
            printf "${C_CYAN}$repo_name:${C_RESET}\n"
            echo "$unstaged" | while read -r file; do
                printf "  ${C_YELLOW}M %s${C_RESET}\n" "$file"
            done
            echo ""
        fi
    done
}

# List ignored files
cmd_ignored() {
    printf "${C_BOLD}=== Ignored Files ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_dir="$WORKDIR/$repo_name"
        [ ! -d "$repo_dir/.git" ] && continue

        ignored=$(git -C "$repo_dir" ls-files --others --ignored --exclude-standard 2>/dev/null)
        if [ -n "$ignored" ]; then
            count=$(echo "$ignored" | wc -l | tr -d ' ')
            printf "${C_CYAN}$repo_name:${C_RESET} ${C_DIM}%s files${C_RESET}\n" "$count"
        fi
    done
}

# Save setting to config file
save_setting() {
    setting_name="$1"
    setting_value="$2"

    if [ -f "$CONFIG_FILE" ]; then
        sed -i "s|\"$setting_name\":[[:space:]]*\"[^\"]*\"|\"$setting_name\": \"$setting_value\"|" "$CONFIG_FILE"
    fi
}

# Toggle merge strategy
toggle_merge_strategy() {
    if [ "$MERGE_STRATEGY" = "theirs" ]; then
        MERGE_STRATEGY="ours"
        printf "$OK Merge strategy: ${C_YELLOW}Local wins${C_RESET}\n"
    else
        MERGE_STRATEGY="theirs"
        printf "$OK Merge strategy: ${C_CYAN}Server wins${C_RESET}\n"
    fi
    save_setting "merge_strategy" "$MERGE_STRATEGY"
}

# Edit workdir
edit_workdir() {
    local_dir="$(pwd)"

    printf "${C_BOLD}=== Edit Working Directory ===${C_RESET}\n\n"
    printf "Current:  ${C_CYAN}$WORKDIR${C_RESET}\n"
    printf "Local:    ${C_DIM}$local_dir${C_RESET}\n\n"

    printf "${C_BOLD}Options:${C_RESET}\n"
    printf "  ${C_GREEN}1${C_RESET}) Use local directory ${C_DIM}(./  →  $local_dir)${C_RESET}\n"
    printf "  ${C_CYAN}2${C_RESET}) Enter custom path\n"
    printf "  ${C_DIM}q${C_RESET}) Cancel\n\n"

    printf "Choice [${C_GREEN}1${C_RESET}]: "
    read -r choice

    # Default to 1 (local)
    [ -z "$choice" ] && choice="1"

    case "$choice" in
        1)
            new_path="$local_dir"
            ;;
        2)
            printf "\nEnter path: "
            read -r new_path
            if [ -z "$new_path" ]; then
                printf "${C_DIM}Cancelled${C_RESET}\n"
                return
            fi
            # Expand ~ to home directory
            new_path=$(echo "$new_path" | sed "s|^~|$HOME|")
            ;;
        q|Q)
            printf "${C_DIM}Cancelled${C_RESET}\n"
            return
            ;;
        *)
            printf "$FAIL ${C_RED}Invalid choice${C_RESET}\n"
            return
            ;;
    esac

    # Check if path exists
    if [ ! -d "$new_path" ]; then
        printf "$WARN ${C_YELLOW}Directory does not exist: $new_path${C_RESET}\n"
        printf "Create it? [y/N] "
        read -r create
        if [ "$create" = "y" ] || [ "$create" = "Y" ]; then
            if mkdir -p "$new_path"; then
                printf "$OK ${C_GREEN}Created${C_RESET}\n"
            else
                printf "$FAIL ${C_RED}Failed to create directory${C_RESET}\n"
                return
            fi
        else
            printf "${C_DIM}Cancelled${C_RESET}\n"
            return
        fi
    fi

    # Update config file
    save_setting "workdir" "$new_path"
    WORKDIR="$new_path"
    printf "$OK ${C_GREEN}Workdir updated to: $new_path${C_RESET}\n"
}

cmd_sync() {
    strategy="${1:-theirs}"
    printf "${C_BOLD}=== Syncing All Repos ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_sync "$repo_name" "$strategy"
        echo ""
    done
}

cmd_pull() {
    strategy="${1:-theirs}"
    printf "${C_BOLD}=== Pulling All Repos ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_pull "$repo_name" "$strategy"
        echo ""
    done
}

cmd_push() {
    printf "${C_BOLD}=== Pushing All Repos ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_push "$repo_name"
        echo ""
    done
}

cmd_fetch() {
    printf "${C_BOLD}=== Fetching All Repos ===${C_RESET}\n\n"

    for repo_name in $(get_repo_names); do
        repo_fetch "$repo_name"
    done
}

# =============================================================================
# SHELL TUI (fallback)
# =============================================================================

tui_shell() {
    while true; do
        clear
        printf "${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}${C_CYAN}║                        gcl - Git Manager (Shell TUI)                          ║${C_RESET}\n"
        printf "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${C_RESET}\n\n"

        # Show status table
        cmd_status

        # Menu - organized by category
        printf "\n"
        printf "${C_BOLD}Actions:${C_RESET}  "
        printf "${C_GREEN}s${C_RESET})ync  "
        printf "${C_CYAN}p${C_RESET})ull  "
        printf "${C_CYAN}c${C_RESET})ommit  "
        printf "${C_CYAN}u${C_RESET})push  "
        printf "${C_CYAN}f${C_RESET})etch\n"

        printf "${C_BOLD}Lists:${C_RESET}    "
        printf "${C_YELLOW}1${C_RESET})Untracked  "
        printf "${C_YELLOW}2${C_RESET})Unstaged  "
        printf "${C_YELLOW}3${C_RESET})Ignored\n"

        printf "${C_BOLD}Setup:${C_RESET}    "
        printf "${C_BLUE}m${C_RESET})erge strategy  "
        printf "${C_BLUE}w${C_RESET})orkdir  "
        printf "${C_BLUE}l${C_RESET})clone menu  "
        printf "${C_BLUE}d${C_RESET})eps  "
        printf "${C_BLUE}r${C_RESET})efresh  "
        printf "${C_RED}q${C_RESET})uit\n"

        printf "\n${C_BOLD}Choice:${C_RESET} "
        read -r choice

        case "$choice" in
            # Actions
            s|S) clear; cmd_sync "$MERGE_STRATEGY"; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            p|P) clear; cmd_pull "$MERGE_STRATEGY"; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            c|C) clear; cmd_commit_all; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            u|U) clear; cmd_push; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            f|F) clear; cmd_status_fetch; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            # Lists
            1) clear; cmd_untracked; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            2) clear; cmd_unstaged; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            3) clear; cmd_ignored; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            # Setup
            m|M) toggle_merge_strategy; sleep 1 ;;
            w|W) clear; edit_workdir; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            l|L) cmd_clone_menu ;;
            d|D) clear; check_deps; printf "\n${C_DIM}Press Enter...${C_RESET}"; read -r _ ;;
            r|R) ;; # Refresh
            q|Q) clear; exit 0 ;;
            *) ;;
        esac
    done
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    printf "${C_BOLD}gcl - Git Clone/Pull/Push Manager${C_RESET}\n\n"

    printf "${C_BOLD}Usage:${C_RESET}\n"
    printf "  ./gcl.sh              ${C_DIM}# Launch TUI${C_RESET}\n"
    printf "  ./gcl.sh <command>    ${C_DIM}# CLI mode${C_RESET}\n"
    printf "  ./gcl.sh --check      ${C_DIM}# Check dependencies${C_RESET}\n\n"

    printf "${C_BOLD}Actions:${C_RESET}\n"
    printf "  ${C_GREEN}sync${C_RESET}       Commit + fetch + pull + push all\n"
    printf "  ${C_CYAN}pull${C_RESET}       Pull all repositories\n"
    printf "  ${C_CYAN}commit${C_RESET}     Commit all local changes\n"
    printf "  ${C_CYAN}push${C_RESET}       Push all repositories\n"
    printf "  ${C_CYAN}fetch${C_RESET}      Fetch + show status\n\n"

    printf "${C_BOLD}Lists:${C_RESET}\n"
    printf "  ${C_YELLOW}status${C_RESET}     Show repository status table\n"
    printf "  ${C_YELLOW}untracked${C_RESET}  List untracked files\n"
    printf "  ${C_YELLOW}unstaged${C_RESET}   List unstaged changes\n"
    printf "  ${C_YELLOW}ignored${C_RESET}    List ignored files\n\n"

    printf "${C_BOLD}Setup:${C_RESET}\n"
    printf "  ${C_BLUE}clone${C_RESET}      Interactive clone menu\n"
    printf "  ${C_BLUE}workdir${C_RESET}    Change working directory\n\n"

    printf "${C_BOLD}Status Columns:${C_RESET}\n"
    printf "  Cloned   ${C_DIM}- Repository exists locally${C_RESET}\n"
    printf "  To Pull  ${C_DIM}- Commits on remote not pulled${C_RESET}\n"
    printf "  Local    ${C_DIM}- Uncommitted changes (Clean/Dirty)${C_RESET}\n"
    printf "  Unpushed ${C_DIM}- Commits not pushed to remote${C_RESET}\n"
    printf "  CI       ${C_DIM}- GitHub Actions status (requires gh)${C_RESET}\n\n"

    printf "${C_BOLD}Config:${C_RESET} ${C_DIM}$CONFIG_FILE${C_RESET}\n"
    printf "${C_BOLD}Workdir:${C_RESET} ${C_DIM}$WORKDIR${C_RESET}\n"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Handle --check before parse_config (may not have git yet)
    case "${1:-}" in
        --check|check)
            check_deps
            exit $?
            ;;
    esac

    # Parse config
    parse_config

    case "${1:-}" in
        --help|-h|help)
            show_help
            ;;
        status)
            cmd_status
            ;;
        fetch)
            cmd_status_fetch
            ;;
        clone)
            cmd_clone_menu
            ;;
        workdir)
            edit_workdir
            ;;
        sync)
            cmd_sync "${2:-$MERGE_STRATEGY}"
            ;;
        pull)
            cmd_pull "${2:-$MERGE_STRATEGY}"
            ;;
        push)
            cmd_push
            ;;
        commit)
            cmd_commit_all
            ;;
        untracked)
            cmd_untracked
            ;;
        unstaged)
            cmd_unstaged
            ;;
        ignored)
            cmd_ignored
            ;;
        "")
            tui_shell
            ;;
        *)
            printf "$FAIL ${C_RED}Unknown command: $1${C_RESET}\n\n"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
