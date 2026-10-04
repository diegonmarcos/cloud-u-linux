#!/bin/sh

# This script is a wrapper for rclone bisync and check,
# allowing for easy standard syncs, "first-time" syncs
# with a defined winner, and status checks.

# --- Configuration ---
REMOTE_NAME="Gdrive"                    # <<< FIX: The name of your rclone remote
BASE_REMOTE="/shared-sync-SurfaceP8" # The base path on that remote

# --- Helper Function ---
# Displays the help menu
show_help() {
    echo "Usage: $(basename "$0") [command]"
    echo
    echo "Commands:"
    echo "  --sync            Run a standard bidirectional sync for all folders."
    echo "                    (This is the default action if no command is given)"
    echo
    echo "  --sync_local      Run a 'first sync' where LOCAL files win."
    echo "                    WARNING: Overwrites remote changes. (Uses --resync)"
    echo
    echo "  --sync_remote     Run a 'first sync' where REMOTE files win."
    echo "                    WARNING: Overwrites local changes. (Swaps paths and uses --resync)"
    echo
    echo "  --status          Show differences between local and remote."
    echo "                    (Uses rclone check --combined -)"
    echo
    echo "  --status_dev      Show what a standard --sync would do without"
    echo "                    making any changes. (Uses bisync --dry-run)"
    echo
    echo "  -h, --help        Show this help menu and exit."
}

# --- Core Sync Function ---
# Runs the rclone bisync command with different modes.
# $1: A descriptive name (e.g., "Documents")
# $2: The local directory path
# $3: The remote directory path (relative to the rclone remote)
# $4: Sync mode ("standard", "local_wins", "remote_wins", "dry_run")
run_bisync() {
    _name="$1"
    _local_path="$2"
    _remote_path="$REMOTE_NAME:$3" # <<< FIX: Use the configured REMOTE_NAME
    _mode="$4"

    echo "=========================================="
    echo "Syncing $_name..."

    # Set command flags based on the mode
    case "$_mode" in
        "standard")
            echo "  Mode:   Standard delta sync"
            echo "  Path1 (Local):  $_local_path"
            echo "  Path2 (Remote): $_remote_path"
            echo "=========================================="
            rclone bisync "$_local_path" "$_remote_path" \
                --drive-skip-gdocs \
                --log-level INFO
            ;;
        "local_wins")
            echo "  Mode:   First-time sync (Local wins)"
            echo "  Path1 (Local):  $_local_path"
            echo "  Path2 (Remote): $_remote_path"
            echo "=========================================="
            rclone bisync "$_local_path" "$_remote_path" \
                --resync \
                --drive-skip-gdocs \
                --log-level INFO
            ;;
        "remote_wins")
            echo "  Mode:   First-time sync (Remote wins)"
            echo "  Path1 (Remote): $_remote_path"
            echo "  Path2 (Local):  $_local_path"
            echo "=========================================="
            # NOTE: Paths are swapped here!
            rclone bisync "$_remote_path" "$_local_path" \
                --resync \
                --drive-skip-gdocs \
                --log-level INFO
            ;;
        "dry_run")
            echo "  Mode:   Dry-run (showing changes)"
            echo "  Path1 (Local):  $_local_path"
            echo "  Path2 (Remote): $_remote_path"
            echo "=========================================="
            rclone bisync "$_local_path" "$_remote_path" \
                --dry-run \
                --drive-skip-gdocs \
                --log-level INFO
            ;;
    esac

    echo "Finished action for $_name."
    echo # Add a blank line for readability
}

# --- Core Check Function ---
# Runs the rclone check command.
# $1: A descriptive name (e.g., "Documents")
# $2: The local directory path
# $3: The remote directory path (relative to the rclone remote)
run_check() {
    _name="$1"
    _local_path="$2"
    _remote_path="$REMOTE_NAME:$3" # <<< FIX: Use the configured REMOTE_NAME

    echo "=========================================="
    echo "Checking status for $_name..."
    echo "  Local:  $_local_path"
    echo "  Remote: $_remote_path"
    echo "  Mode:   Check (--combined)"
    echo "=========================================="

    rclone check "$_local_path" "$_remote_path" --combined -

    echo "Finished check for $_name."
    echo # Add a blank line for readability
}

# --- Argument Parsing & Main Execution ---
# Parse the first command-line argument ($1) and run the
# appropriate functions for all directories.

case "$1" in
    # --sync (standard) or no argument
    "" | "--sync" | "--syn")
        echo "Starting standard sync for all folders..."
        echo
        run_bisync "Documents" "/home/diego/Documents/Documents/" "$BASE_REMOTE/Documents" "standard"
        run_bisync "Downloads" "/home/diego/Downloads/" "$BASE_REMOTE/Downloads" "standard"
        run_bisync "Pictures" "/home/diego/Pictures/" "$BASE_REMOTE/Screen_Shots" "standard"
        ;;

    # --sync_local (local wins)
    "--sync_local")
        echo "***************************************************"
        echo "WARNING: Running in --sync_local mode."
        echo "Local files will OVERWRITE remote files."
        echo "Pausing for 3 seconds... Press Ctrl+C to cancel."
        echo "***************************************************"
        sleep 3
        run_bisync "Documents" "/home/diego/Documents/Documents/" "$BASE_REMOTE/Documents" "local_wins"
        run_bisync "Downloads" "/home/diego/Downloads/" "$BASE_REMOTE/Downloads" "local_wins"
        run_bisync "Pictures" "/home/diego/Pictures/" "$BASE_REMOTE/Screen_Shots" "local_wins"
        ;;

    # --sync_remote (remote wins)
    "--sync_remote")
        echo "***************************************************"
        echo "WARNING: Running in --sync_remote mode."
        echo "Remote files will OVERWRITE local files."
        echo "Pausing for 3 seconds... Press Ctrl+C to cancel."
        echo "***************************************************"
        sleep 3
        run_bisync "Documents" "/home/diego/Documents/Documents/" "$BASE_REMOTE/Documents" "remote_wins"
        run_bisync "Downloads" "/home/diego/Downloads/" "$BASE_REMOTE/Downloads" "remote_wins"
        run_bisync "Pictures" "/home/diego/Pictures/" "$BASE_REMOTE/Screen_Shots" "remote_wins"
        ;;

    # --status (rclone check)
    "--status_dev")
        echo "Running status check (rclone check) for all folders..."
        echo
        run_check "Documents" "/home/diego/Documents/Documents/" "$BASE_REMOTE/Documents"
        run_check "Downloads" "/home/diego/Downloads/" "$BASE_REMOTE/Downloads"
        run_check "Pictures" "/home/diego/Pictures/" "$BASE_REMOTE/Screen_Shots"
        ;;

    # --status_dev (bisync dry-run)
    "--status")
        echo "Running dev status (bisync --dry-run) for all folders..."
        echo
        run_bisync "Documents" "/home/diego/Documents/Documents/" "$BASE_REMOTE/Documents" "dry_run"
        run_bisync "Downloads" "/home/diego/Downloads/" "$BASE_REMOTE/Downloads" "dry_run"
        run_bisync "Pictures" "/home/diego/Pictures/" "$BASE_REMOTE/Screen_Shots" "dry_run"
        ;;

    # -h or --help
    "-h" | "--help")
        show_help
        exit 0
        ;;

    # Any other argument: show error and help
    *)
        echo "Error: Invalid argument '$1'"
        echo
        show_help
        exit 1
        ;;
esac

echo
echo "All tasks complete."
