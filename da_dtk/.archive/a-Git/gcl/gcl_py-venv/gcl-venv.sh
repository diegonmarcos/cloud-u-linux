#!/bin/bash
# gcl-venv.sh - Unified Python virtual environment manager for gcl.py
# Usage:
#   ./gcl-venv.sh           # Interactive menu
#   ./gcl-venv.sh setup     # Setup venv
#   ./gcl-venv.sh run       # Run gcl.py in venv
#   ./gcl-venv.sh [args]    # Pass args to gcl.py

set -e  # Exit on error

VENV_DIR="venv"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_CYAN="\033[36m"

# Helper functions
_log() { printf "${C_CYAN}==>${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$1"; }
_success() { printf "${C_GREEN}✓ %s${C_RESET}\n" "$1"; }
_error() { printf "${C_RED}✗ %s${C_RESET}\n" "$1"; }
_warn() { printf "${C_YELLOW}⚠ %s${C_RESET}\n" "$1"; }

# Check if Python is available
check_python() {
    PYTHON_CMD=""
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        _error "Python 3 not found. Please install Python 3.8 or higher."
        exit 1
    fi

    # Check Python version is 3.8+
    PYTHON_VERSION=$($PYTHON_CMD --version | cut -d' ' -f2)
    MAJOR=$(echo $PYTHON_VERSION | cut -d'.' -f1)
    MINOR=$(echo $PYTHON_VERSION | cut -d'.' -f2)

    if [ "$MAJOR" -lt 3 ] || ([ "$MAJOR" -eq 3 ] && [ "$MINOR" -lt 8 ]); then
        _error "Python 3.8+ required. Found: $PYTHON_VERSION"
        exit 1
    fi

    echo "$PYTHON_CMD"
}

# Setup virtual environment
setup_venv() {
    echo ""
    _log "Setting up Python virtual environment for gcl.py"
    echo ""

    PYTHON_CMD=$(check_python)
    _success "Using Python $($PYTHON_CMD --version | cut -d' ' -f2)"

    # Check if venv exists
    if [ -d "$SCRIPT_DIR/$VENV_DIR" ]; then
        echo ""
        _warn "Virtual environment already exists at ./$VENV_DIR"
        echo ""
        read -p "$(printf "${C_YELLOW}Do you want to recreate it? [y/N]${C_RESET} ")" -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            _log "Removing old virtual environment..."
            rm -rf "$SCRIPT_DIR/$VENV_DIR"
        else
            _log "Using existing virtual environment"
            echo ""
            _success "Setup already complete!"
            return 0
        fi
    fi

    # Create virtual environment
    echo ""
    _log "Creating virtual environment..."
    $PYTHON_CMD -m venv "$SCRIPT_DIR/$VENV_DIR"
    _success "Virtual environment created"

    # Activate and upgrade pip
    _log "Upgrading pip..."
    source "$SCRIPT_DIR/$VENV_DIR/bin/activate"
    pip install --upgrade pip > /dev/null 2>&1
    _success "Pip upgraded"

    # Install dependencies (if any)
    if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
        _log "Installing dependencies from requirements.txt..."
        pip install -r "$SCRIPT_DIR/requirements.txt" > /dev/null 2>&1
        _success "Dependencies installed"
    fi

    deactivate

    echo ""
    printf "${C_GREEN}${C_BOLD}✓ Setup complete!${C_RESET}\n"
    echo ""
    echo "To use gcl.py:"
    printf "  ${C_CYAN}./gcl-venv.sh run${C_RESET}       # Launch TUI\n"
    printf "  ${C_CYAN}./gcl-venv.sh status${C_RESET}    # Run CLI command\n"
    echo ""
}

# Run gcl.py in venv
run_gcl() {
    # Check if venv exists
    if [ ! -d "$SCRIPT_DIR/$VENV_DIR" ]; then
        echo ""
        _error "Virtual environment not found!"
        echo ""
        echo "Run setup first:"
        printf "  ${C_CYAN}./gcl-venv.sh setup${C_RESET}\n"
        echo ""
        exit 1
    fi

    # Activate venv and run gcl.py
    source "$SCRIPT_DIR/$VENV_DIR/bin/activate"
    python3 "$SCRIPT_DIR/../gcl.py" "$@"
    RESULT=$?
    deactivate

    exit $RESULT
}

# Show interactive menu
show_menu() {
    clear
    printf "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║           gcl.py - Virtual Environment Manager          ║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}\n"
    echo ""

    # Check venv status
    if [ -d "$SCRIPT_DIR/$VENV_DIR" ]; then
        printf "  ${C_GREEN}Status: Virtual environment exists ✓${C_RESET}\n"
    else
        printf "  ${C_YELLOW}Status: Virtual environment NOT found ⚠${C_RESET}\n"
    fi

    echo ""
    printf "${C_BOLD}${C_BLUE}OPTIONS:${C_RESET}\n"
    printf "${C_BLUE}════════${C_RESET}\n"
    echo ""
    printf "  ${C_BOLD}1)${C_RESET} ${C_GREEN}Setup${C_RESET}     - Create/recreate virtual environment\n"
    printf "  ${C_BOLD}2)${C_RESET} ${C_GREEN}Run${C_RESET}       - Launch gcl.py TUI\n"
    printf "  ${C_BOLD}3)${C_RESET} ${C_GREEN}Status${C_RESET}    - Run 'gcl.py status' command\n"
    printf "  ${C_BOLD}4)${C_RESET} ${C_GREEN}Cleanup${C_RESET}   - Remove virtual environment\n"
    printf "  ${C_BOLD}5)${C_RESET} ${C_GREEN}Info${C_RESET}      - Show venv information\n"
    echo ""
    printf "  ${C_BOLD}q)${C_RESET} Quit\n"
    echo ""
}

# Show venv info
show_info() {
    echo ""
    _log "Virtual Environment Information"
    echo ""

    if [ ! -d "$SCRIPT_DIR/$VENV_DIR" ]; then
        _warn "Virtual environment not found"
        echo ""
        printf "  Location: ${C_YELLOW}$SCRIPT_DIR/$VENV_DIR${C_RESET} (doesn't exist)\n"
        echo ""
        return
    fi

    # Activate and get info
    source "$SCRIPT_DIR/$VENV_DIR/bin/activate"

    printf "  Location:     ${C_CYAN}$SCRIPT_DIR/$VENV_DIR${C_RESET}\n"
    printf "  Python:       ${C_CYAN}$(python --version)${C_RESET}\n"
    printf "  Python path:  ${C_CYAN}$(which python)${C_RESET}\n"
    printf "  Pip version:  ${C_CYAN}$(pip --version | cut -d' ' -f2)${C_RESET}\n"

    echo ""
    _log "Installed packages:"
    pip list --format=columns | head -n 20

    PKG_COUNT=$(pip list | tail -n +3 | wc -l)
    if [ "$PKG_COUNT" -gt 15 ]; then
        echo ""
        printf "  ${C_YELLOW}... and $((PKG_COUNT - 15)) more packages${C_RESET}\n"
    fi

    deactivate
    echo ""
}

# Cleanup venv
cleanup_venv() {
    echo ""
    if [ ! -d "$SCRIPT_DIR/$VENV_DIR" ]; then
        _warn "Virtual environment not found - nothing to clean"
        echo ""
        return
    fi

    _warn "This will delete the virtual environment at:"
    printf "  ${C_YELLOW}$SCRIPT_DIR/$VENV_DIR${C_RESET}\n"
    echo ""
    read -p "$(printf "${C_RED}Are you sure? [y/N]${C_RESET} ")" -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        _log "Removing virtual environment..."
        rm -rf "$SCRIPT_DIR/$VENV_DIR"
        _success "Virtual environment removed"
    else
        _log "Cancelled"
    fi
    echo ""
}

# Interactive menu loop
interactive_menu() {
    while true; do
        show_menu
        read -p "$(printf "${C_BOLD}Select option [1-5, q]:${C_RESET} ")" -n 1 -r choice
        echo ""

        case $choice in
            1)
                setup_venv
                echo ""
                read -p "Press any key to continue..." -n 1 -r
                ;;
            2)
                run_gcl
                ;;
            3)
                run_gcl status
                echo ""
                read -p "Press any key to continue..." -n 1 -r
                ;;
            4)
                cleanup_venv
                read -p "Press any key to continue..." -n 1 -r
                ;;
            5)
                show_info
                read -p "Press any key to continue..." -n 1 -r
                ;;
            q|Q)
                echo ""
                _log "Goodbye!"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                _error "Invalid option. Please select 1-5 or q"
                sleep 1
                ;;
        esac
    done
}

# Main entry point
main() {
    case "${1:-menu}" in
        setup|build|install)
            setup_venv
            ;;
        run)
            shift
            run_gcl "$@"
            ;;
        cleanup|clean|remove)
            cleanup_venv
            ;;
        info|status)
            show_info
            ;;
        help|--help|-h)
            echo ""
            printf "${C_BOLD}${C_CYAN}gcl-venv.sh - Virtual Environment Manager for gcl.py${C_RESET}\n"
            echo ""
            printf "${C_BOLD}Usage:${C_RESET}\n"
            printf "  ./gcl-venv.sh           ${C_BLUE}# Interactive menu${C_RESET}\n"
            printf "  ./gcl-venv.sh setup     ${C_BLUE}# Setup virtual environment${C_RESET}\n"
            printf "  ./gcl-venv.sh run       ${C_BLUE}# Run gcl.py TUI${C_RESET}\n"
            printf "  ./gcl-venv.sh status    ${C_BLUE}# Run 'gcl.py status'${C_RESET}\n"
            printf "  ./gcl-venv.sh sync      ${C_BLUE}# Run 'gcl.py sync'${C_RESET}\n"
            printf "  ./gcl-venv.sh cleanup   ${C_BLUE}# Remove virtual environment${C_RESET}\n"
            printf "  ./gcl-venv.sh info      ${C_BLUE}# Show venv information${C_RESET}\n"
            printf "  ./gcl-venv.sh help      ${C_BLUE}# Show this help${C_RESET}\n"
            echo ""
            printf "${C_BOLD}Examples:${C_RESET}\n"
            printf "  ./gcl-venv.sh              ${C_BLUE}# Opens interactive menu${C_RESET}\n"
            printf "  ./gcl-venv.sh setup        ${C_BLUE}# One-time setup${C_RESET}\n"
            printf "  ./gcl-venv.sh run          ${C_BLUE}# Launch TUI${C_RESET}\n"
            printf "  ./gcl-venv.sh status       ${C_BLUE}# Check repo status${C_RESET}\n"
            echo ""
            ;;
        menu)
            interactive_menu
            ;;
        *)
            # Pass all args to gcl.py
            run_gcl "$@"
            ;;
    esac
}

main "$@"
