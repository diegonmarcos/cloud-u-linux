#!/bin/sh
# sync.sh - Unified Git & Rclone Sync Manager Launcher
# A masterpiece combining gcl.sh elegance with rclone.py power
#
# Usage:
#   ./sync.sh                    # Launch TUI (default)
#   ./sync.sh --venv [command]   # Use venv mode
#   ./sync.sh --docker [command] # Use Docker mode
#   ./sync.sh status             # Show all status
#   ./sync.sh git sync           # Sync all Git repos
#   ./sync.sh rclone mount       # Mount default remote
#   ./sync.sh serve              # Start API server

set -e

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/sync_app/main.py"

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[32m"
C_CYAN="\033[36m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_PURPLE="\033[38;5;141m"
C_BLUE="\033[34m"
C_GRAY="\033[90m"

# Unicode symbols
SYM_CHECK="${C_GREEN}✓${C_RESET}"
SYM_CROSS="${C_RED}✗${C_RESET}"
SYM_ARROW="${C_CYAN}→${C_RESET}"
SYM_GIT="${C_PURPLE}${C_RESET}"
SYM_CLOUD="${C_BLUE}☁${C_RESET}"

# Show beautiful help
show_help() {
    printf "\n"
    printf "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════════════╗${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║                                                                  ║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║   ${C_PURPLE}⚡${C_CYAN} SYNC ${C_RESET}${C_BOLD}${C_CYAN}- Unified Git & Rclone Sync Manager                   ║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║                                                                  ║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════════════╝${C_RESET}\n\n"

    printf "${C_BOLD}SYNTAX${C_RESET}\n"
    printf "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
    printf "  ./sync.sh [${C_YELLOW}MODE${C_RESET}] [${C_PURPLE}COMMAND${C_RESET}] [${C_GRAY}OPTIONS${C_RESET}]\n\n"

    printf "${C_BOLD}MODES${C_RESET}\n"
    printf "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
    printf "  ${C_GREEN}(default)${C_RESET}        Run directly with system Python3\n"
    printf "  ${C_YELLOW}--venv${C_RESET}           Run in Python virtual environment (auto-setup)\n"
    printf "  ${C_YELLOW}--docker${C_RESET}         Run in Docker container (auto-build)\n\n"

    printf "${C_BOLD}COMMANDS${C_RESET}\n"
    printf "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
    printf "  ${C_PURPLE}(none)${C_RESET}           ${C_GRAY}Launch interactive TUI dashboard${C_RESET}\n"
    printf "  ${C_PURPLE}status${C_RESET}           ${C_GRAY}Show status of all repos and syncs${C_RESET}\n\n"

    printf "  ${C_BOLD}${SYM_GIT} Git Commands:${C_RESET}\n"
    printf "  ${C_PURPLE}git status${C_RESET}       ${C_GRAY}Show Git repositories status${C_RESET}\n"
    printf "  ${C_PURPLE}git sync${C_RESET}         ${C_GRAY}Sync all repos (commit→fetch→pull→push)${C_RESET}\n"
    printf "  ${C_PURPLE}git push${C_RESET}         ${C_GRAY}Commit and push all repos${C_RESET}\n"
    printf "  ${C_PURPLE}git pull${C_RESET}         ${C_GRAY}Pull all repos with merge strategy${C_RESET}\n"
    printf "  ${C_PURPLE}git fetch${C_RESET}        ${C_GRAY}Fetch from all remotes${C_RESET}\n\n"

    printf "  ${C_BOLD}${SYM_CLOUD} Rclone Commands:${C_RESET}\n"
    printf "  ${C_PURPLE}rclone status${C_RESET}    ${C_GRAY}Show Rclone sync rules and mounts${C_RESET}\n"
    printf "  ${C_PURPLE}rclone sync${C_RESET}      ${C_GRAY}Run enabled sync rules${C_RESET}\n"
    printf "  ${C_PURPLE}rclone mount${C_RESET}     ${C_GRAY}Mount default remote (Gdrive)${C_RESET}\n"
    printf "  ${C_PURPLE}rclone umount${C_RESET}    ${C_GRAY}Unmount remote${C_RESET}\n\n"

    printf "  ${C_BOLD}Other:${C_RESET}\n"
    printf "  ${C_PURPLE}jobs${C_RESET}             ${C_GRAY}View background sync jobs${C_RESET}\n"
    printf "  ${C_PURPLE}serve${C_RESET}            ${C_GRAY}Start REST API server${C_RESET}\n\n"

    printf "${C_BOLD}EXAMPLES${C_RESET}\n"
    printf "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
    printf "  ./sync.sh                   ${C_GRAY}# Launch TUI dashboard${C_RESET}\n"
    printf "  ./sync.sh status            ${C_GRAY}# Quick status overview${C_RESET}\n"
    printf "  ./sync.sh git sync          ${C_GRAY}# Sync all Git repos${C_RESET}\n"
    printf "  ./sync.sh rclone mount      ${C_GRAY}# Mount Google Drive${C_RESET}\n"
    printf "  ./sync.sh --venv serve      ${C_GRAY}# Start API (venv mode)${C_RESET}\n\n"

    printf "${C_BOLD}OPTIONS${C_RESET}\n"
    printf "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
    printf "  ${C_GREEN}--help, -h${C_RESET}       ${C_GRAY}Show this help message${C_RESET}\n"
    printf "  ${C_GREEN}--version, -v${C_RESET}    ${C_GRAY}Show version${C_RESET}\n"
    printf "  ${C_GREEN}--install${C_RESET}        ${C_GRAY}Install dependencies and setup${C_RESET}\n"
    printf "  ${C_GREEN}--json${C_RESET}           ${C_GRAY}Output in JSON format (for status commands)${C_RESET}\n\n"

    printf "${C_BOLD}TUI KEYBOARD SHORTCUTS${C_RESET}\n"
    printf "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
    printf "  ${C_YELLOW}j/k, ↑/↓${C_RESET}        Navigate repos\n"
    printf "  ${C_YELLOW}Tab${C_RESET}             Switch Git/Rclone/Mounts sections\n"
    printf "  ${C_YELLOW}Space${C_RESET}           Select/deselect repo\n"
    printf "  ${C_YELLOW}S${C_RESET}               Sync selected repos\n"
    printf "  ${C_YELLOW}P${C_RESET}               Push selected Git repos\n"
    printf "  ${C_YELLOW}L${C_RESET}               Pull selected Git repos\n"
    printf "  ${C_YELLOW}m${C_RESET}               Mount selected remote\n"
    printf "  ${C_YELLOW}M${C_RESET}               Unmount selected mount\n"
    printf "  ${C_YELLOW}J${C_RESET}               Jobs panel\n"
    printf "  ${C_YELLOW}r${C_RESET}               Refresh\n"
    printf "  ${C_YELLOW}?${C_RESET}               Help\n"
    printf "  ${C_YELLOW}q${C_RESET}               Quit\n\n"
}

# Show version
show_version() {
    printf "${C_BOLD}sync${C_RESET} version ${C_CYAN}1.0.0${C_RESET}\n"
    printf "${C_DIM}Unified Git & Rclone Sync Manager${C_RESET}\n"
}

# Check Python3 is available
check_python() {
    if ! command -v python3 > /dev/null 2>&1; then
        printf "${SYM_CROSS} Python3 not found. Please install Python 3.8+\n" >&2
        exit 1
    fi
}

# Check and setup virtual environment
setup_venv() {
    VENV_DIR="$SCRIPT_DIR/.venv"

    if [ ! -d "$VENV_DIR" ]; then
        printf "${C_CYAN}==>${C_RESET} ${C_BOLD}Creating virtual environment...${C_RESET}\n"
        python3 -m venv "$VENV_DIR"

        printf "${C_CYAN}==>${C_RESET} ${C_BOLD}Installing dependencies...${C_RESET}\n"
        "$VENV_DIR/bin/pip" install --quiet --upgrade pip
        if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
            "$VENV_DIR/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
        fi
        printf "${SYM_CHECK} Virtual environment ready\n\n"
    fi
}

# Run with virtual environment
run_venv() {
    setup_venv
    exec "$SCRIPT_DIR/.venv/bin/python3" "$PYTHON_SCRIPT" "$@"
}

# Run with Docker
run_docker() {
    DOCKER_IMAGE="sync-app:latest"
    DOCKERFILE="$SCRIPT_DIR/Dockerfile"

    # Check if Docker is available
    if ! command -v docker > /dev/null 2>&1; then
        printf "${SYM_CROSS} Docker not found. Please install Docker.\n" >&2
        exit 1
    fi

    # Build if image doesn't exist
    if ! docker image inspect "$DOCKER_IMAGE" > /dev/null 2>&1; then
        if [ ! -f "$DOCKERFILE" ]; then
            printf "${SYM_CROSS} Dockerfile not found at $DOCKERFILE\n" >&2
            exit 1
        fi
        printf "${C_CYAN}==>${C_RESET} ${C_BOLD}Building Docker image...${C_RESET}\n"
        docker build -t "$DOCKER_IMAGE" "$SCRIPT_DIR"
    fi

    # Run in Docker with necessary mounts
    docker run --rm -it \
        -v "$HOME/Documents/Git:/home/user/Documents/Git" \
        -v "$HOME/Documents/Gdrive:/home/user/Documents/Gdrive" \
        -v "$HOME/.config:/home/user/.config" \
        -v "$HOME/.ssh:/home/user/.ssh:ro" \
        --network host \
        "$DOCKER_IMAGE" "$@"
}

# Run natively
run_native() {
    check_python

    # Check terminal size for TUI mode
    if [ $# -eq 0 ]; then
        if command -v tput > /dev/null 2>&1; then
            TERM_ROWS=$(tput lines 2>/dev/null || echo 0)
            TERM_COLS=$(tput cols 2>/dev/null || echo 0)
            if [ "$TERM_ROWS" -lt 20 ] || [ "$TERM_COLS" -lt 60 ]; then
                printf "${C_YELLOW}Warning:${C_RESET} Terminal may be too small for TUI (got ${TERM_ROWS}x${TERM_COLS})\n" >&2
                printf "Consider resizing to at least 24x80 for best experience.\n\n" >&2
            fi
        fi

        # Set TERM if not set
        if [ -z "$TERM" ] || [ "$TERM" = "dumb" ]; then
            export TERM=xterm-256color
        fi
    fi

    exec python3 "$PYTHON_SCRIPT" "$@"
}

# Install dependencies
run_install() {
    printf "${C_CYAN}==>${C_RESET} ${C_BOLD}Installing sync-app...${C_RESET}\n\n"

    # Check Python
    check_python
    PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    printf "${SYM_CHECK} Python $PYTHON_VERSION found\n"

    # Check rclone
    if command -v rclone > /dev/null 2>&1; then
        RCLONE_VERSION=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
        printf "${SYM_CHECK} rclone $RCLONE_VERSION found\n"
    else
        printf "${SYM_CROSS} rclone not found - install from https://rclone.org/install/\n"
    fi

    # Check git
    if command -v git > /dev/null 2>&1; then
        GIT_VERSION=$(git --version | awk '{print $3}')
        printf "${SYM_CHECK} git $GIT_VERSION found\n"
    else
        printf "${SYM_CROSS} git not found\n"
    fi

    # Check gh CLI
    if command -v gh > /dev/null 2>&1; then
        GH_VERSION=$(gh --version | head -1 | awk '{print $3}')
        printf "${SYM_CHECK} gh CLI $GH_VERSION found\n"
    else
        printf "${C_YELLOW}!${C_RESET} gh CLI not found (optional, for CI status)\n"
    fi

    # Setup venv
    printf "\n${C_CYAN}==>${C_RESET} Setting up virtual environment...\n"
    setup_venv

    # Create config directory
    CONFIG_DIR="$HOME/.config/sync-app"
    mkdir -p "$CONFIG_DIR"
    printf "${SYM_CHECK} Config directory: $CONFIG_DIR\n"

    printf "\n${C_GREEN}${C_BOLD}Installation complete!${C_RESET}\n"
    printf "Run ${C_CYAN}./sync.sh${C_RESET} to launch the TUI.\n"
}

# Main entry point
case "${1:-}" in
    --help|-h|help)
        show_help
        exit 0
        ;;
    --version|-v)
        show_version
        exit 0
        ;;
    --install)
        run_install
        exit 0
        ;;
    --venv)
        shift
        run_venv "$@"
        ;;
    --docker)
        shift
        run_docker "$@"
        ;;
    *)
        # Default: run natively
        run_native "$@"
        ;;
esac
