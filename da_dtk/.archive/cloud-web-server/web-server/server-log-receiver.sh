#!/bin/sh
# Pure POSIX log receiver - writes raw JSONL (JSON Lines)

# OOM Protection: Mark as sacrificial (kill first to protect Claude)
echo 1000 > /proc/$$/oom_score_adj 2>/dev/null

# Memory Limit: Cap RAM usage at 1GB
ulimit -v 1048576 2>/dev/null

# Use absolute paths for utilities (socat subprocess may not inherit PATH)
CAT="/bin/cat"
HEAD="/usr/bin/head"
TAIL="/usr/bin/tail"
AWK="/usr/bin/awk"
SED="/bin/sed"
TR="/usr/bin/tr"

LOG_FILE="browser-console.log"
PORT=19001

# Handle incoming HTTP request
handle_request() {
    # Read entire request
    REQUEST=$($CAT)

    # Extract method from first line
    METHOD=$(echo "$REQUEST" | $HEAD -1 | $AWK '{print $1}')

    # Handle CORS preflight
    if [ "$METHOD" = "OPTIONS" ]; then
        printf "HTTP/1.1 200 OK\r\n"
        printf "Access-Control-Allow-Origin: *\r\n"
        printf "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
        printf "Access-Control-Allow-Headers: Content-Type\r\n"
        printf "Content-Length: 0\r\n"
        printf "\r\n"
        return
    fi

    # Handle POST
    if [ "$METHOD" = "POST" ]; then
        # Extract JSON body (remove CR, then get everything after blank line)
        BODY=$(echo "$REQUEST" | $TR -d '\r' | $SED -n '/^$/,$ p' | $TAIL -n +2)

        if [ -n "$BODY" ]; then
            # Add server-side timestamp to the JSON
            SERVER_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

            # Remove trailing brace, add server timestamp, close brace
            ENHANCED_JSON=$(echo "$BODY" | $SED "s/}$/,\"server_timestamp\":\"$SERVER_TS\"}/")

            # Write the complete JSON object as one line
            echo "$ENHANCED_JSON" >> "$LOG_FILE"
        fi

        # Send HTTP response
        printf "HTTP/1.1 200 OK\r\n"
        printf "Access-Control-Allow-Origin: *\r\n"
        printf "Content-Type: text/plain\r\n"
        printf "Content-Length: 2\r\n"
        printf "\r\n"
        printf "OK"
        return
    fi

    # 404 for other methods
    printf "HTTP/1.1 404 Not Found\r\n"
    printf "Content-Length: 0\r\n"
    printf "\r\n"
}

# Check dependencies
if ! command -v socat >/dev/null 2>&1; then
    echo "Error: 'socat' not found. Install with: pkg install socat"
    exit 1
fi

# If called with 'handle' argument, handle one request and exit
if [ "$1" = "handle" ]; then
    handle_request
    exit 0
fi

echo "JSON log receiver starting on http://localhost:$PORT"
echo "Writing JSON lines to: $(pwd)/$LOG_FILE"
echo "Press Ctrl+C to stop"
echo ""
echo "Tip: View logs with: jq . $LOG_FILE"

# Export variables for child processes
export LOG_FILE CAT HEAD TAIL AWK SED TR

# Start HTTP server
socat -T 30 TCP-LISTEN:$PORT,reuseaddr,fork EXEC:"$0 handle"
