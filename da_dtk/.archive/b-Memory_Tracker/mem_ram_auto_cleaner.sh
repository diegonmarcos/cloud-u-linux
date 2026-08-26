#!/bin/sh

# ... Header ...
# Script Name:   kill_halt.sh
# Description:   Recovers the system from a high memory usage state by killing the user's
#                most memory-intensive processes until usage is below a threshold.
# Author:        Diego
# Date:

################################################################################
# Prints usage information for the script.
################################################################################
usage() {
    echo "Usage: $(basename "$0") [threshold]"
    echo "  Recovers system memory by killing user processes if RAM usage exceeds a threshold."
    echo
    echo "  threshold: Optional. An integer between 1 and 99 for the max RAM usage percentage."
    echo "             Defaults to 90 if not provided."
}

################################################################################
# Calculates and returns the current percentage of used RAM.
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   An integer representing the current RAM usage percentage.
################################################################################
get_ram_usage() {
    # Uses `free` to get memory stats and `awk` to calculate the percentage of used RAM.
    free | awk '/Mem/ {printf "%.0f", $3/$2 * 100.0}'
}

################################################################################
# Checks RAM usage and kills processes if it exceeds the specified threshold.
#
# Globals:
#   USER
# Arguments:
#   $1 - The maximum allowed RAM usage percentage (integer).
# Returns:
#   0 if successful, 1 on error.
################################################################################
recover_ram() {
    max_usage_threshold=$1
    current_usage=$(get_ram_usage)

    echo "Current RAM usage is ${current_usage}%."

    while [ "${current_usage}" -gt "${max_usage_threshold}" ]; do
        echo "RAM usage (${current_usage}%) is above the ${max_usage_threshold}% threshold. Finding process to kill..."

        # Find the PID and command of the top memory-consuming process owned by the current user.
        # This prevents the script from killing system-level services.
        # `ps aux`: List all processes
        # `awk ...`: Filter for processes owned by the current user ($USER),
        #            exclude the script itself ($$), sort by memory (field 4), print PID and Command.
        process_info=$(ps aux | awk -v user="$USER" -v mypid="$$" '
            NR>1 && $1==user && $2 != mypid {
                mem[$2] = $4
                cmd[$2] = $11
            }
            END {
                max_mem = 0
                max_pid = ""
                for (pid in mem) {
                    if (mem[pid] > max_mem) {
                        max_mem = mem[pid]
                        max_pid = pid
                    }
                }
                if (max_pid != "") print max_pid, cmd[max_pid]
            }')

        if [ -n "${process_info}" ]; then
            pid_to_kill=$(echo "${process_info}" | awk '{print $1}')
            command_name=$(echo "${process_info}" | awk '{print $2}')
            echo "Killing process: PID: ${pid_to_kill}, Command: ${command_name}..."
            kill -9 "${pid_to_kill}" # Forcefully terminate the process.
            sleep 2 # Pause for a moment to allow the system to reclaim memory.
            current_usage=$(get_ram_usage)
            echo "New RAM usage is ${current_usage}%."
        else
            echo "Could not find any of your processes to kill. Exiting."
            break # Exit the loop if no suitable process is found.
        fi
    done

    echo "RAM usage is now within the acceptable limit."
}

################################################################################
# Validates that input is an integer between 1 and 99
################################################################################
is_valid_threshold() {
    # Check if it's a number (digits only)
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Check range
    [ "$1" -ge 1 ] && [ "$1" -le 99 ]
}

################################################################################
# Main function to parse arguments and start the recovery process.
################################################################################
main() {
    threshold=90 # Default threshold

    if [ -n "$1" ]; then
        # Check if the input is a valid integer between 1 and 99
        if is_valid_threshold "$1"; then
            threshold=$1
        else
            echo "Error: Invalid threshold '$1'. Please provide an integer between 1 and 99." >&2
            usage >&2
            return 1
        fi
    fi

    recover_ram "${threshold}"
}

# Execute the main function with all script arguments
main "$@"
