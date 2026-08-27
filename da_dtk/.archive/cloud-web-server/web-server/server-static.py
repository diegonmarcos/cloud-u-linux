#!/usr/bin/env python3
"""Lightweight HTTP server with Eruda DevTools injection (no logging)."""

import http.server
import socketserver
import sys
import os
import re

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()

ERUDA_SCRIPT = '''
<!-- AUTO-INJECTED: Eruda DevTools (early load) -->
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
})();
</script>
'''

class ErudaHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        # Get the file path
        path = self.translate_path(self.path)

        # Handle directory -> index.html
        if os.path.isdir(path):
            index_path = os.path.join(path, 'index.html')
            if os.path.exists(index_path):
                path = index_path
            else:
                # Let parent handle directory listing
                return super().do_GET()

        # Check if it's an HTML file
        if path.endswith(('.html', '.htm')) and os.path.exists(path):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    content = f.read()

                # Inject Eruda in <head> (early) to capture all console messages
                if re.search(r'<head[^>]*>', content, re.IGNORECASE):
                    content = re.sub(
                        r'(<head[^>]*>)',
                        r'\1' + ERUDA_SCRIPT,
                        content,
                        count=1,
                        flags=re.IGNORECASE
                    )
                elif re.search(r'<html[^>]*>', content, re.IGNORECASE):
                    content = re.sub(
                        r'(<html[^>]*>)',
                        r'\1<head>' + ERUDA_SCRIPT + '</head>',
                        content,
                        count=1,
                        flags=re.IGNORECASE
                    )
                else:
                    content = ERUDA_SCRIPT + content

                # Send response
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', len(content.encode('utf-8')))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(content.encode('utf-8'))
                return
            except Exception as e:
                print(f"Error processing {path}: {e}")

        # Non-HTML or error: use default handler
        return super().do_GET()

    def log_message(self, format, *args):
        # Simpler log format
        print(f"[{self.log_date_time_string()}] {args[0]}")

if __name__ == '__main__':
    os.chdir(DIRECTORY)

    with socketserver.TCPServer(("", PORT), ErudaHandler) as httpd:
        print(f"Static Server with Eruda DevTools")
        print(f"  URL:   http://localhost:{PORT}")
        print(f"  Mount: {DIRECTORY}")
        print(f"  Mode:  Eruda auto-injection (no logging)")
        print()
        print("Press Ctrl+C to stop")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped.")
