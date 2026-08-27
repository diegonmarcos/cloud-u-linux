#!/bin/sh

# IMPORTANT: The Shebang is changed to #!/bin/sh for POSIX compatibility.
# If you run this file, please use 'sh rclone_mount.sh' or ensure it has execute permissions.

# ... Header ...
# Script Name:  rclone_mount.sh
# Description:  GUI startup commands
# Author:       Diego
# Date:

#ACTIONS:

# 1.Rclone config menu


#2. Check Status Mount (flags used)
# Mount
# Umount (force)
# Reset (Umount+Mount)

#rclone mount remote:path /local/mountpoint \
#--vfs-cache-mode full \
##--poll-interval 60s \
###--tpslimit 10 \
##--vfs-cache-max-age 1h \
##--vfs-cache-max-size 50G \
##--vfs-read-chunk-size 32M \
##--vfs-read-chunk-size-limit off \
#--dir-cache-time 10000h \
#--drive-skip-gdocs \
#--log-level INFO \
#--daemon

#3. Check If the list of localmoutpoint/folder (s) folders already exists and rclone check
#rclone check /local/path/folder1 remote:path/folder1 --combined -
#rclone bisync /local/path/folder1 remote:path/folder1 --dry-run --verbose

# 4. Bisync it
#rclone bisync /local/path/folder1 remote:path/folder1 --resync --verbose --drive-skip-gdocs --log-level INFO
#rclone bisync /local/path/folder1 remote:path/folder1 --verbose --drive-skip-gdocs --log-level INFO

#rclone bisync remote:path/folder1 /local/mountpoint/folder1 \
#--conflict-resolve path1
#--tpslimit 10 \
#--drive-skip-gdocs \
#--log-level INFO

#rclone bisync remote:path/folder2 /local/mountpoint/folder2 \
#--conflict-resolve path1
#--tpslimit 10 \
#--drive-skip-gdocs \
#--log-level INFO

# --- CONFIGURATION ---
MOUNT_POINT="/home/diego/Documents/Gdrive"
LOG_FILE="/tmp/rclone_mount.log"

# 1. Default Mode (Immediate upload/write-through)
# LOG LEVEL CHANGED from INFO to WARNING to suppress VFS cache messages.
RCLONE_DEFAULT_OPTS="--log-level WARNING --dir-cache-time 72h --drive-skip-gdocs --vfs-cache-max-size 10G --vfs-cache-mode writes"

# 2. Fast Upload Mode (Delays uploads by 5s for burst writing)
# LOG LEVEL CHANGED from INFO to WARNING.
RCLONE_FAST_OPTS="--log-level WARNING --dir-cache-time 72h --drive-skip-gdocs --vfs-cache-max-size 10G --vfs-cache-mode full"

# --- FUNCTIONS ---
show_help() {
    echo "Syntax: How to run the script"
    echo "  The script typically requires a 2-character argument: [ACTION] followed by [MODE]."
    echo "  Usage: \$0 [ACTION][MODE] or \$0 c"
    echo "  Example: \$0 a1 (Checks for mount status using Default Mode)"
    echo ""
    echo "Actions (The first character of the argument)"
    echo "  a) Check and mount: Mounts the drive ONLY if it is not currently mounted or if it's mounted in a different mode."
    echo "  b) Reset: Forces an unmount, then immediately remounts the drive. Use to switch modes or fix a hung mount."
    echo "  c) Config: Opens the rclone interactive configuration tool (rclone config) to set up or refresh credentials."
    echo ""
    echo "Modes (The second character, only used with actions 'a' and 'b')"
    echo " 1) Default Mode: Standard rclone options for general use (immediate upload/write-through)."
    echo " 2) Fast Mode: Optimized for burst writing by delaying uploads by 5 seconds (--vfs-write-back 5s)."
    echo ""
    echo "Other Options:"
    echo "  (no argument) Show this help message and current mount status."
    echo "  help          Show this help message."
	echo "" # Added jump line
	echo "--- Current Status ---"

	STATUS_MODE=`get_current_rclone_mode`

	# Show the raw mount output
	mount | grep Gdrive

	# Show the descriptive mode status
	if [ "$STATUS_MODE" = "UNMOUNTED" ]; then
		echo "Mount Status: Not currently mounted."
	else
		echo "Mount Status: Mounted in $STATUS_MODE."
	fi
}

# NEW FUNCTION: Checks the command line of the running rclone process to determine the active mode.
get_current_rclone_mode() {
    # Check if the MOUNT_POINT is listed in 'mount' output first
    if ! mount | grep -q "$MOUNT_POINT"; then
        echo "UNMOUNTED"
        return
    fi

    # Check the running rclone process command line for the Fast Mode flag.
    # Note: We use 'ps -ef | grep' chain for POSIX compatibility.
    # We grep for rclone, then for the MOUNT_POINT, then for the specific flag.
    if ps -ef | grep rclone | grep "$MOUNT_POINT" | grep -q -- "--vfs-write-back 5s"; then
        echo "Fast Mode"
        return
    fi

    # If mounted, and the fast flag is not found, assume it's the default mode.
    if ps -ef | grep rclone | grep -q "$MOUNT_POINT"; then
        echo "Default Mode"
        return
    fi

    # Fallback
    echo "UNMOUNTED"
}

mount_gdrive() {
    # We rely on positional parameter $1 here.
    echo "Mounting Google Drive with options: $1"
    
    # Run rclone in the background and log stderr
    rclone mount Gdrive: "$MOUNT_POINT" $1 > "$LOG_FILE" 2>&1 &
    
    # Wait for a moment to let rclone initialize
    sleep 3

    # Check if the mount point is active
    if ! mount | grep -q "$MOUNT_POINT"; then
        # Mount failed, check for authentication error
        if grep -q "googleapi: Error 401" "$LOG_FILE"; then
            echo "Error: Google Drive authentication failed."
            echo "Please run the script with the 'c' argument to re-authenticate:"
            echo "  $0 c"
        else
            echo "Error: rclone mount failed. See $LOG_FILE for details."
        fi
        return 1
    else
        echo "Google Drive mounted successfully."
    fi
    return 0
}

unmount_gdrive() {
    echo "Attempting to unmount $MOUNT_POINT..."
    fusermount -u -z "$MOUNT_POINT" 2>/dev/null || umount -l -f "$MOUNT_POINT"
    if mount | grep -q "$MOUNT_POINT"; then
        echo "Error: Unmount failed. Manual intervention may be needed."
        return 1
    else
        echo "Unmounted successfully."
        return 0
    fi
}

rclone_config() {
    if [ "$1" = "1" ]; then
        echo "Starting Rclone interactive configuration for 'Gdrive'..."
        echo "Please follow these steps to re-authenticate:"
        echo "1. At the first menu, enter 'e' for 'Edit existing remote'."
        echo "2. At the next menu, enter the number corresponding to the 'Gdrive' remote (usually '1')."
        echo "3. Keep pressing Enter to accept the defaults until you get to the 'Use auto config?' question."
        echo "4. Answer 'y' to 'Use auto config?' and follow the browser authentication flow."
        rclone config
    else
        echo "Starting Rclone interactive configuration..."
        echo "You must select the remote 'Gdrive' and follow the steps to refresh your token."
        rclone config
    fi
}

# --- BODY ---

# 1. Handle Help or No Argument
if [ -z "$1" ] || [ "$1" = "help" ]; then
    show_help
    exit 0
fi

# 2. Validate and Parse the Argument using POSIX case patterns
ARGUMENT="$1"

# Default extraction setup
ACTION=""
MODE=""

# We use case to check the structure and extract characters simultaneously.
case "$ARGUMENT" in
    [ab][12])
        # Valid 2-character argument (a1, a2, b1, b2).
        ACTION=`expr substr "$ARGUMENT" 1 1`
        MODE=`expr substr "$ARGUMENT" 2 1`
        ;;
    c1)
        ACTION="c"
        MODE="1"
        ;;
    c)
        # Valid 1-character argument (c). Does not use a MODE.
        ACTION="c"
        MODE="0" # Dummy mode to skip MODE selection
        ;;
    *)
        # Invalid argument length or content
        echo "Error: Invalid argument '$ARGUMENT'. Please use the [ACTION][MODE] syntax (e.g., a1, b2) or 'c'."
        show_help
        exit 1
        ;;
esac


# 3. Select Options based on MODE (Only needed for actions 'a' and 'b')
OPTS=""
MODE_NAME=""

if [ "$ACTION" != "c" ]; then
    case "$MODE" in
        "1")
            OPTS="$RCLONE_DEFAULT_OPTS"
            MODE_NAME="Default Mode"
            ;;
        "2")
            OPTS="$RCLONE_FAST_OPTS"
            MODE_NAME="Fast Mode"
            ;;
        *)
            # Should not happen due to validation above, but included for safety.
            echo "Internal Error: Invalid MODE '$MODE'."
            exit 1
            ;;
    esac
fi


# 4. Execute Action
case "$ACTION" in
    "a")
        # Action: Check and Mount (Enhanced to check for mode consistency)
        echo "Executing Action: Check and Mount | Requested Mode: $MODE_NAME"

        CURRENT_MODE=`get_current_rclone_mode`

        if [ "$CURRENT_MODE" = "UNMOUNTED" ]; then
            echo "Google Drive is not mounted. Mounting in $MODE_NAME..."
            mount_gdrive "$OPTS"
        elif [ "$CURRENT_MODE" = "$MODE_NAME" ]; then
            echo "SUCCESS: Google Drive is already mounted in the requested $MODE_NAME."
        else
            echo "WARNING: Google Drive is currently mounted in $CURRENT_MODE, but $MODE_NAME is requested."
            echo "Use action 'b' (Reset) to force unmount and remount in $MODE_NAME."
        fi
        ;;
    "b")
        # Action: Reset (Unmount then Remount)
        echo "Executing Action: Reset | Mode: $MODE_NAME"
        if mount | grep -q "$MOUNT_POINT"; then
            unmount_gdrive
        else
            echo "Google Drive is not mounted, performing fresh mount."
        fi
        # Always mount after 'Reset' (b) action
        mount_gdrive "$OPTS"
        ;;
    "c")
        # Action: Rclone Config
        rclone_config "$MODE"
        ;;
    *)
        # Should not happen due to validation above, but included for safety.
        echo "Internal Error: Invalid ACTION '$ACTION'."
        exit 1
        ;;
esac

# Display the final status of Gdrive processes/mounts
echo "--- Final Mount Status ---"
mount | grep Gdrive
