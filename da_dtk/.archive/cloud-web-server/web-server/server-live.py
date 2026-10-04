#!/usr/bin/env python3
"""HTTP server with Eruda DevTools + Live Reload (no logging)."""

import http.server
import socketserver
import sys
import os
import re
import json
import time
import threading
from pathlib import Path

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()

# Track file modification times
file_mtimes = {}
last_change = time.time()
lock = threading.Lock()

ERUDA_AND_RELOAD_SCRIPT = '''
<!-- AUTO-INJECTED: Eruda DevTools + Live Reload (early load) -->
<script>
(function() {
  // Queue to capture console messages before Eruda loads
  var queue = [];
  var erudaReady = false;
  var orig = {
    log: console.log,
    error: console.error,
    warn: console.warn,
    info: console.info,
    debug: console.debug
  };

  function capture(level, args) {
    if (!erudaReady) {
      queue.push({ level: level, args: Array.from(args), time: Date.now() });
    }
  }

  // Override console methods immediately to capture early messages
  console.log = function() { capture("log", arguments); orig.log.apply(console, arguments); };
  console.error = function() { capture("error", arguments); orig.error.apply(console, arguments); };
  console.warn = function() { capture("warn", arguments); orig.warn.apply(console, arguments); };
  console.info = function() { capture("info", arguments); orig.info.apply(console, arguments); };
  console.debug = function() { capture("debug", arguments); orig.debug.apply(console, arguments); };

  // Load Eruda
  var s = document.createElement("script");
  s.src = "//cdn.jsdelivr.net/npm/eruda";
  s.onload = function() {
    eruda.init();
    erudaReady = true;

    // Replay queued messages to Eruda
    if (queue.length > 0) {
      console.info("[Eruda] Replaying " + queue.length + " early messages...");
      queue.forEach(function(item) {
        console[item.level].apply(console, item.args);
      });
    }
    queue = [];
    console.info("[Eruda] DevTools ready - all console messages captured");
  };
  document.head.appendChild(s);

  // Live Reload - poll for changes
  var lastCheck = Date.now();
  var checkInterval = 1000;

  function checkForChanges() {
    fetch("/__live_reload_check?t=" + lastCheck)
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (data.changed) {
          console.info("[Live] Change detected, reloading...");
          location.reload();
        }
        lastCheck = data.timestamp;
      })
      .catch(function() {})
      .finally(function() {
        setTimeout(checkForChanges, checkInterval);
      });
  }

  setTimeout(checkForChanges, checkInterval);
  console.info("[Live] Auto-reload enabled (1s polling)");
})();
</script>
'''

def scan_files():
    """Scan directory for file changes."""
    global last_change
    changed = False
    current_mtimes = {}

    for root, dirs, files in os.walk(DIRECTORY):
        # Skip hidden directories and node_modules
        dirs[:] = [d for d in dirs if not d.startswith('.') and d != 'node_modules']

        for f in files:
            if f.startswith('.'):
                continue
            filepath = os.path.join(root, f)
            try:
                mtime = os.path.getmtime(filepath)
                current_mtimes[filepath] = mtime

                if filepath in file_mtimes:
                    if mtime > file_mtimes[filepath]:
                        changed = True
                        print(f"[CHANGE] {filepath}")
            except OSError:
                pass

    with lock:
        file_mtimes.clear()
        file_mtimes.update(current_mtimes)
        if changed:
            last_change = time.time()

    return changed

def file_watcher():
    """Background thread to watch for file changes."""
    while True:
        scan_files()
        time.sleep(0.5)

class LiveReloadHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        # Handle live reload check endpoint
        if self.path.startswith('/__live_reload_check'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()

            # Parse timestamp from query
            try:
                t = float(self.path.split('t=')[1]) / 1000  # Convert ms to seconds
            except:
                t = 0

            with lock:
                changed = last_change > t
                response = json.dumps({
                    'changed': changed,
                    'timestamp': int(time.time() * 1000)
                })

            self.wfile.write(response.encode())
            return

        # Get the file path
        path = self.translate_path(self.path)

        # Handle directory -> index.html
        if os.path.isdir(path):
            index_path = os.path.join(path, 'index.html')
            if os.path.exists(index_path):
                path = index_path
            else:
                return super().do_GET()

        # Check if it's an HTML file
        if path.endswith(('.html', '.htm')) and os.path.exists(path):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    content = f.read()

                # Inject in <head> (early) to capture all console messages
                if re.search(r'<head[^>]*>', content, re.IGNORECASE):
                    content = re.sub(
                        r'(<head[^>]*>)',
                        r'\1' + ERUDA_AND_RELOAD_SCRIPT,
                        content,
                        count=1,
                        flags=re.IGNORECASE
                    )
                elif re.search(r'<html[^>]*>', content, re.IGNORECASE):
                    content = re.sub(
                        r'(<html[^>]*>)',
                        r'\1<head>' + ERUDA_AND_RELOAD_SCRIPT + '</head>',
                        content,
                        count=1,
                        flags=re.IGNORECASE
                    )
                else:
                    content = ERUDA_AND_RELOAD_SCRIPT + content

                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', len(content.encode('utf-8')))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(content.encode('utf-8'))
                return
            except Exception as e:
                print(f"Error processing {path}: {e}")

        return super().do_GET()

    def log_message(self, format, *args):
        # Simpler log format, skip reload checks
        if '/__live_reload_check' not in args[0]:
            print(f"[{self.log_date_time_string()}] {args[0]}")

class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == '__main__':
    os.chdir(DIRECTORY)

    # Initial file scan
    scan_files()

    # Start file watcher thread
    watcher = threading.Thread(target=file_watcher, daemon=True)
    watcher.start()

    print(f"Live Server with Eruda + Auto-Reload")
    print(f"  URL:   http://localhost:{PORT}")
    print(f"  Mount: {DIRECTORY}")
    print(f"  Mode:  Eruda + Live Reload (1s polling)")
    print()
    print("Press Ctrl+C to stop")

    with ThreadedTCPServer(("", PORT), LiveReloadHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped.")
