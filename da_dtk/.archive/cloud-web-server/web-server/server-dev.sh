#!/bin/sh
# Pure POSIX HTTP server with auto-injection of dev tools into HTML

# OOM Protection: Mark as sacrificial (kill first to protect Claude)
echo 1000 > /proc/$$/oom_score_adj 2>/dev/null

# Memory Limit: Cap RAM usage at 1GB
ulimit -v 1048576 2>/dev/null

# Use absolute paths for utilities (socat subprocess may not inherit PATH)
TR="$(which tr)"
CUT="$(which cut)"
AWK="$(which awk)"
WC="$(which wc)"
CAT="$(which cat)"
LS="$(which ls)"
STAT="$(which stat)"

PORT=${1:-8000}
# Use env var if set (for subprocess), else use arg, else pwd
MOUNT_DIR=${MOUNT_DIR:-${2:-$(pwd)}}
LOG_FILE="${MOUNT_DIR}/browser-console.log"
SED="/bin/sed"

# Get MIME type based on file extension
get_mime_type() {
    case "$1" in
        *.html|*.htm) echo "text/html" ;;
        *.css) echo "text/css" ;;
        *.js) echo "application/javascript" ;;
        *.json) echo "application/json" ;;
        *.png) echo "image/png" ;;
        *.jpg|*.jpeg) echo "image/jpeg" ;;
        *.gif) echo "image/gif" ;;
        *.svg) echo "image/svg+xml" ;;
        *.ico) echo "image/x-icon" ;;
        *.woff|*.woff2) echo "font/woff" ;;
        *.ttf) echo "font/ttf" ;;
        *.webp) echo "image/webp" ;;
        *.mp4) echo "video/mp4" ;;
        *.webm) echo "video/webm" ;;
        *) echo "application/octet-stream" ;;
    esac
}

# URL decode (POSIX-compliant)
urldecode() {
    input="$1"
    # Replace + with space
    input=$(echo "$input" | $TR '+' ' ')
    # Decode percent-encoded characters using awk
    echo "$input" | $AWK '
        BEGIN {
            for (i = 0; i < 256; i++) hex[sprintf("%02X", i)] = sprintf("%c", i)
        }
        {
            decoded = ""
            i = 1
            while (i <= length($0)) {
                c = substr($0, i, 1)
                if (c == "%") {
                    code = substr($0, i+1, 2)
                    decoded = decoded hex[toupper(code)]
                    i += 3
                } else {
                    decoded = decoded c
                    i++
                }
            }
            print decoded
        }
    '
}

# Generate directory listing HTML
generate_listing() {
    DIR_PATH="$1"
    URL_PATH="$2"

    # Ensure URL path ends with /
    case "$URL_PATH" in
        */) ;;
        *) URL_PATH="${URL_PATH}/" ;;
    esac

    echo '<!DOCTYPE html>'
    echo '<html><head>'
    echo '<meta charset="utf-8">'
    echo '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
    echo "<title>Index of ${URL_PATH}</title>"
    echo '<style>'
    echo 'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 40px; background: #1a1a2e; color: #eee; }'
    echo 'h1 { color: #00d4ff; border-bottom: 2px solid #00d4ff; padding-bottom: 10px; }'
    echo 'a { color: #00d4ff; text-decoration: none; }'
    echo 'a:hover { text-decoration: underline; }'
    echo 'ul { list-style: none; padding: 0; }'
    echo 'li { padding: 8px 0; border-bottom: 1px solid #333; display: flex; align-items: center; }'
    echo 'li:hover { background: #252542; }'
    echo '.icon { margin-right: 10px; font-size: 1.2em; }'
    echo '.folder { color: #ffd700; }'
    echo '.file { color: #87ceeb; }'
    echo '.size { color: #888; margin-left: auto; font-size: 0.9em; }'
    echo '</style></head><body>'
    echo "<h1>Index of ${URL_PATH}</h1>"
    echo '<ul>'

    # Parent directory link (if not root)
    if [ "$URL_PATH" != "/" ]; then
        echo '<li><span class="icon folder">..</span><a href="../">Parent Directory</a></li>'
    fi

    # List directories first, then files
    for entry in "$DIR_PATH"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")

        if [ -d "$entry" ]; then
            echo "<li><span class=\"icon folder\">📁</span><a href=\"${name}/\">${name}/</a></li>"
        fi
    done

    for entry in "$DIR_PATH"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")

        if [ -f "$entry" ]; then
            # Get file size
            size=$($STAT -c%s "$entry" 2>/dev/null || echo "0")
            if [ "$size" -gt 1048576 ]; then
                size_str="$((size / 1048576)) MB"
            elif [ "$size" -gt 1024 ]; then
                size_str="$((size / 1024)) KB"
            else
                size_str="${size} B"
            fi
            echo "<li><span class=\"icon file\">📄</span><a href=\"${name}\">${name}</a><span class=\"size\">${size_str}</span></li>"
        fi
    done

    echo '</ul>'
    echo '<hr style="border-color:#333;margin-top:20px;">'
    echo '<p style="color:#666;font-size:0.8em;">Dev Server with Auto-Injection</p>'
    echo '</body></html>'
}

# Handle HTTP request
handle_request() {
    # Read request line
    read -r METHOD REQ_PATH PROTOCOL

    # Remove carriage return and query string
    REQ_PATH=$(echo "$REQ_PATH" | $TR -d '\r' | $CUT -d'?' -f1)

    # Read headers and capture Content-Length
    CONTENT_LEN=0
    while read -r line; do
        line=$(echo "$line" | $TR -d '\r')
        [ -z "$line" ] && break
        case "$line" in
            Content-Length:*|content-length:*) CONTENT_LEN=$(echo "$line" | $CUT -d: -f2 | $TR -d ' ') ;;
        esac
    done

    # Handle /log endpoint for browser console logging
    if [ "$REQ_PATH" = "/log" ]; then
        if [ "$METHOD" = "OPTIONS" ]; then
            printf "HTTP/1.1 200 OK\r\n"
            printf "Access-Control-Allow-Origin: *\r\n"
            printf "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
            printf "Access-Control-Allow-Headers: Content-Type\r\n"
            printf "Content-Length: 0\r\n\r\n"
            return
        fi
        if [ "$METHOD" = "POST" ]; then
            # Read POST body
            BODY=""
            if [ "$CONTENT_LEN" -gt 0 ] 2>/dev/null; then
                BODY=$(head -c "$CONTENT_LEN")
            fi
            if [ -n "$BODY" ]; then
                SERVER_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                echo "$BODY" | $SED "s/}$/,\"server_timestamp\":\"$SERVER_TS\"}/" >> "$LOG_FILE"
            fi
            printf "HTTP/1.1 200 OK\r\n"
            printf "Access-Control-Allow-Origin: *\r\n"
            printf "Content-Type: text/plain\r\n"
            printf "Content-Length: 2\r\n\r\nOK"
            return
        fi
    fi

    # Decode and sanitize path
    REQ_PATH=$(urldecode "$REQ_PATH")

    # Handle trailing slash for root
    [ "$REQ_PATH" = "" ] && REQ_PATH="/"

    FILE_PATH="${MOUNT_DIR}${REQ_PATH}"

    # If path is a directory
    if [ -d "$FILE_PATH" ]; then
        # Check for index.html
        if [ -f "${FILE_PATH}/index.html" ]; then
            FILE_PATH="${FILE_PATH}/index.html"
        else
            # Generate directory listing
            CONTENT=$(generate_listing "$FILE_PATH" "$REQ_PATH")
            CONTENT_LENGTH=$(printf '%s' "$CONTENT" | $WC -c | $TR -d ' ')
            printf "HTTP/1.1 200 OK\r\n"
            printf "Content-Type: text/html\r\n"
            printf "Content-Length: %s\r\n" "$CONTENT_LENGTH"
            printf "Cache-Control: no-cache\r\n"
            printf "Connection: close\r\n"
            printf "\r\n"
            printf '%s' "$CONTENT"
            return
        fi
    fi

    # Check if file exists and is readable
    if [ ! -f "$FILE_PATH" ] || [ ! -r "$FILE_PATH" ]; then
        printf "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found"
        return
    fi

    MIME_TYPE=$(get_mime_type "$FILE_PATH")

    # Process HTML files with injection, serve others as-is
    if [ "$MIME_TYPE" = "text/html" ]; then
        # HTML file - inject dev tools in <head> (early load for message capture)
        CONTENT=$($CAT "$FILE_PATH" | $AWK '
            BEGIN { injected = 0 }
            tolower($0) ~ /<head[^>]*>/ {
                print $0
                if (!injected) {
                    print "<!-- AUTO-INJECTED DEV TOOLS (early load) -->"
                    print "<script>"
                    print "(function() {"
                    print "  // Queue for early console messages"
                    print "  var queue = [];"
                    print "  var erudaReady = false;"
                    print "  var LOG = location.origin + \"/log\";"
                    print "  var _fetch = window.fetch;"
                    print "  var _XHR = window.XMLHttpRequest;"
                    print ""
                    print "  var o = {"
                    print "    log: console.log,"
                    print "    error: console.error,"
                    print "    warn: console.warn,"
                    print "    info: console.info,"
                    print "    debug: console.debug"
                    print "  };"
                    print ""
                    print "  function send(lvl, data) {"
                    print "    try {"
                    print "      var payload = typeof data === \"object\" ? data : {message: String(data)};"
                    print "      payload.level = lvl;"
                    print "      payload.url = location.href;"
                    print "      payload.timestamp = new Date().toISOString();"
                    print "      _fetch.call(window, LOG, {"
                    print "        method: \"POST\","
                    print "        headers: {\"Content-Type\": \"application/json\"},"
                    print "        body: JSON.stringify(payload)"
                    print "      }).catch(function(){});"
                    print "    } catch(e) {}"
                    print "  }"
                    print ""
                    print "  function sendLog(lvl, args) {"
                    print "    var msg = Array.from(args).map(function(a) {"
                    print "      return typeof a === \"object\" ? JSON.stringify(a) : String(a);"
                    print "    }).join(\" \");"
                    print "    send(lvl, {message: msg});"
                    print "  }"
                    print ""
                    print "  function capture(lvl, args) {"
                    print "    if (!erudaReady) {"
                    print "      queue.push({ level: lvl, args: Array.from(args) });"
                    print "    }"
                    print "  }"
                    print ""
                    print "  // Override console immediately to capture early messages"
                    print "  console.log = function() { capture(\"log\", arguments); o.log.apply(console, arguments); sendLog(\"log\", arguments); };"
                    print "  console.error = function() { capture(\"error\", arguments); o.error.apply(console, arguments); sendLog(\"error\", arguments); };"
                    print "  console.warn = function() { capture(\"warn\", arguments); o.warn.apply(console, arguments); sendLog(\"warn\", arguments); };"
                    print "  console.info = function() { capture(\"info\", arguments); o.info.apply(console, arguments); sendLog(\"info\", arguments); };"
                    print "  console.debug = function() { capture(\"debug\", arguments); o.debug.apply(console, arguments); sendLog(\"debug\", arguments); };"
                    print ""
                    print "  // Load Eruda"
                    print "  var s = document.createElement(\"script\");"
                    print "  s.src = \"//cdn.jsdelivr.net/npm/eruda\";"
                    print "  s.onload = function() {"
                    print "    eruda.init();"
                    print "    erudaReady = true;"
                    print "    // Replay queued messages"
                    print "    if (queue.length > 0) {"
                    print "      console.info(\"[Eruda] Replaying \" + queue.length + \" early messages...\");"
                    print "      queue.forEach(function(item) {"
                    print "        console[item.level].apply(console, item.args);"
                    print "      });"
                    print "    }"
                    print "    queue = [];"
                    print "    console.info(\"[Eruda] DevTools ready - all messages captured\");"
                    print "  };"
                    print "  document.head.appendChild(s);"
                    print ""
                    print "  window.addEventListener(\"error\", function(e) {"
                    print "    var msg = e.message + \" @ \" + e.filename + \":\" + e.lineno + \":\" + e.colno;"
                    print "    o.error.call(console, \"[UNCAUGHT]\", msg);"
                    print "    send(\"uncaught\", {message: msg});"
                    print "  });"
                    print ""
                    print "  window.addEventListener(\"unhandledrejection\", function(e) {"
                    print "    o.error.call(console, \"[UNHANDLED REJECTION]\", e.reason);"
                    print "    send(\"promise\", {message: \"Unhandled: \" + e.reason});"
                    print "  });"
                    print ""
                    print "  // Network: intercept fetch"
                    print "  window.fetch = function(url, opts) {"
                    print "    var method = (opts && opts.method) || \"GET\";"
                    print "    var start = Date.now();"
                    print "    return _fetch.apply(window, arguments).then(function(res) {"
                    print "      if (String(url).indexOf(\"/log\") === -1) {"
                    print "        send(\"network\", {"
                    print "          method: method,"
                    print "          resource: String(url).substring(0,200),"
                    print "          status: res.status,"
                    print "          duration: Date.now() - start + \"ms\""
                    print "        });"
                    print "      }"
                    print "      return res;"
                    print "    }).catch(function(err) {"
                    print "      if (String(url).indexOf(\"/log\") === -1) {"
                    print "        send(\"network\", {"
                    print "          method: method,"
                    print "          resource: String(url).substring(0,200),"
                    print "          status: \"FAILED\","
                    print "          error: err.message"
                    print "        });"
                    print "      }"
                    print "      throw err;"
                    print "    });"
                    print "  };"
                    print ""
                    print "  // Network: intercept XHR"
                    print "  window.XMLHttpRequest = function() {"
                    print "    var xhr = new _XHR();"
                    print "    var _open = xhr.open;"
                    print "    var method, url, start;"
                    print "    xhr.open = function(m, u) {"
                    print "      method = m; url = u; start = Date.now();"
                    print "      return _open.apply(xhr, arguments);"
                    print "    };"
                    print "    xhr.addEventListener(\"loadend\", function() {"
                    print "      if (url && String(url).indexOf(\"/log\") === -1) {"
                    print "        send(\"network\", {"
                    print "          method: method,"
                    print "          resource: String(url).substring(0,200),"
                    print "          status: xhr.status || \"FAILED\","
                    print "          duration: Date.now() - start + \"ms\""
                    print "        });"
                    print "      }"
                    print "    });"
                    print "    return xhr;"
                    print "  };"
                    print "  window.XMLHttpRequest.prototype = _XHR.prototype;"
                    print ""
                    print "  // Client info (one-time)"
                    print "  send(\"client-info\", {"
                    print "    userAgent: navigator.userAgent,"
                    print "    platform: navigator.platform,"
                    print "    language: navigator.language,"
                    print "    screen: screen.width + \"x\" + screen.height,"
                    print "    viewport: window.innerWidth + \"x\" + window.innerHeight,"
                    print "    devicePixelRatio: window.devicePixelRatio,"
                    print "    online: navigator.onLine,"
                    print "    cookiesEnabled: navigator.cookieEnabled,"
                    print "    connection: navigator.connection ? {"
                    print "      type: navigator.connection.effectiveType,"
                    print "      downlink: navigator.connection.downlink + \"Mbps\","
                    print "      rtt: navigator.connection.rtt + \"ms\""
                    print "    } : \"N/A\""
                    print "  });"
                    print ""
                    print "  console.info(\"[Dev] Console + Network logging enabled\");"
                    print "})();"
                    print "</script>"
                    injected = 1
                }
                next
            }
            { print }
            END {
                if (!injected) {
                    print "<!-- HTML without <head> tag - prepending dev tools -->"
                    print "<script>"
                    print "(function() {"
                    print "  var s = document.createElement(\"script\");"
                    print "  s.src = \"//cdn.jsdelivr.net/npm/eruda\";"
                    print "  s.onload = function() { eruda.init(); console.info(\"[Eruda] DevTools ready\"); };"
                    print "  document.head.appendChild(s);"
                    print "})();"
                    print "</script>"
                }
            }
        ')
        # Calculate content length for HTML
        CONTENT_LENGTH=$(printf '%s' "$CONTENT" | $WC -c | $TR -d ' ')

        # Send HTTP response for HTML
        printf "HTTP/1.1 200 OK\r\n"
        printf "Content-Type: %s\r\n" "$MIME_TYPE"
        printf "Content-Length: %s\r\n" "$CONTENT_LENGTH"
        printf "Cache-Control: no-cache\r\n"
        printf "Connection: close\r\n"
        printf "\r\n"
        printf '%s' "$CONTENT"
    else
        # Non-HTML file - serve directly (binary-safe)
        FILE_SIZE=$($STAT -c%s "$FILE_PATH" 2>/dev/null || $STAT -f%z "$FILE_PATH" 2>/dev/null || echo 0)

        # Send HTTP response headers
        printf "HTTP/1.1 200 OK\r\n"
        printf "Content-Type: %s\r\n" "$MIME_TYPE"
        printf "Content-Length: %s\r\n" "$FILE_SIZE"
        printf "Cache-Control: no-cache\r\n"
        printf "Connection: close\r\n"
        printf "\r\n"

        # Send file content directly (binary-safe)
        $CAT "$FILE_PATH"
    fi
}

# Check dependencies
if ! command -v socat >/dev/null 2>&1; then
    echo "Error: 'socat' required. Install: pkg install socat"
    exit 1
fi

# If called with 'handle' argument, handle one request and exit
if [ "$1" = "handle" ]; then
    handle_request
    exit 0
fi

echo "Bash Dev Server with Auto-Injection"
echo "  URL:   http://localhost:$PORT"
echo "  Mount: $MOUNT_DIR"
echo "  Mode:  Auto-injecting Eruda + console logger into HTML"
echo ""
echo "Press Ctrl+C to stop"

export MOUNT_DIR TR CUT AWK WC CAT LS STAT SED LOG_FILE

# Start HTTP server
socat -T 30 TCP-LISTEN:$PORT,reuseaddr,fork EXEC:"$0 handle"
