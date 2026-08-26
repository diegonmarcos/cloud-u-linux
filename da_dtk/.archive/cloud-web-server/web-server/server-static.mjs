#!/usr/bin/env node
/**
 * Lightweight HTTP server with Eruda DevTools injection and styled directory listings.
 * Node.js equivalent of static-server.py
 */

import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.argv[2]) || 8000;
const DIRECTORY = process.argv[3] ? path.resolve(process.argv[3]) : process.cwd();

// MIME types
const MIME_TYPES = {
  '.html': 'text/html',
  '.htm': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.eot': 'application/vnd.ms-fontobject',
  '.otf': 'font/otf',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.xml': 'application/xml',
};

// Eruda DevTools injection script
const ERUDA_SCRIPT = `
<!-- AUTO-INJECTED: Eruda DevTools (early load) -->
<script>
(function() {
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

  console.log = function() { capture("log", arguments); orig.log.apply(console, arguments); };
  console.error = function() { capture("error", arguments); orig.error.apply(console, arguments); };
  console.warn = function() { capture("warn", arguments); orig.warn.apply(console, arguments); };
  console.info = function() { capture("info", arguments); orig.info.apply(console, arguments); };
  console.debug = function() { capture("debug", arguments); orig.debug.apply(console, arguments); };

  var s = document.createElement("script");
  s.src = "//cdn.jsdelivr.net/npm/eruda";
  s.onload = function() {
    eruda.init();
    erudaReady = true;
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
`;

// Styled directory listing template
function generateDirectoryListing(dirPath, urlPath, files) {
  const parentPath = urlPath === '/' ? null : path.dirname(urlPath);

  const fileList = files
    .filter(f => !f.startsWith('.'))
    .map(file => {
      const filePath = path.join(dirPath, file);
      const stat = fs.statSync(filePath);
      const isDir = stat.isDirectory();
      const size = isDir ? '-' : formatSize(stat.size);
      const modified = stat.mtime.toISOString().split('T')[0];
      const href = path.join(urlPath, file) + (isDir ? '/' : '');
      const icon = isDir ? '📁' : getFileIcon(file);

      return { file, href, isDir, size, modified, icon };
    })
    .sort((a, b) => {
      if (a.isDir && !b.isDir) return -1;
      if (!a.isDir && b.isDir) return 1;
      return a.file.localeCompare(b.file);
    });

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Index of ${urlPath}</title>
  <style>
    :root {
      --bg: #1a1a2e;
      --surface: #16213e;
      --border: #0f3460;
      --text: #e4e4e7;
      --text-muted: #a1a1aa;
      --accent: #e94560;
      --link: #00d9ff;
      --link-hover: #00fff7;
    }

    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f4f4f5;
        --surface: #ffffff;
        --border: #e4e4e7;
        --text: #18181b;
        --text-muted: #71717a;
        --accent: #dc2626;
        --link: #2563eb;
        --link-hover: #1d4ed8;
      }
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: ui-monospace, 'Cascadia Code', 'Source Code Pro', Menlo, Monaco, 'Courier New', monospace;
      background: var(--bg);
      color: var(--text);
      line-height: 1.6;
      padding: 2rem;
      min-height: 100vh;
    }

    .container {
      max-width: 900px;
      margin: 0 auto;
    }

    header {
      margin-bottom: 2rem;
      padding-bottom: 1rem;
      border-bottom: 1px solid var(--border);
    }

    h1 {
      font-size: 1.25rem;
      font-weight: 500;
      color: var(--text-muted);
    }

    h1 span {
      color: var(--accent);
    }

    .parent-link {
      display: inline-block;
      margin-top: 0.5rem;
      color: var(--link);
      text-decoration: none;
      font-size: 0.875rem;
    }

    .parent-link:hover {
      color: var(--link-hover);
      text-decoration: underline;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      background: var(--surface);
      border-radius: 8px;
      overflow: hidden;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }

    th, td {
      padding: 0.75rem 1rem;
      text-align: left;
    }

    th {
      background: var(--border);
      font-weight: 500;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--text-muted);
    }

    tr:not(:last-child) td {
      border-bottom: 1px solid var(--border);
    }

    tr:hover td {
      background: var(--bg);
    }

    .icon {
      width: 2rem;
      text-align: center;
    }

    .name {
      font-weight: 500;
    }

    .name a {
      color: var(--link);
      text-decoration: none;
    }

    .name a:hover {
      color: var(--link-hover);
      text-decoration: underline;
    }

    .size, .modified {
      color: var(--text-muted);
      font-size: 0.875rem;
      white-space: nowrap;
    }

    .size {
      text-align: right;
      width: 6rem;
    }

    .modified {
      width: 7rem;
    }

    footer {
      margin-top: 2rem;
      padding-top: 1rem;
      border-top: 1px solid var(--border);
      font-size: 0.75rem;
      color: var(--text-muted);
    }

    @media (max-width: 600px) {
      body { padding: 1rem; }
      .modified { display: none; }
      th, td { padding: 0.5rem; }
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Index of <span>${urlPath}</span></h1>
      ${parentPath !== null ? `<a class="parent-link" href="${parentPath}">← Parent Directory</a>` : ''}
    </header>

    <table>
      <thead>
        <tr>
          <th class="icon"></th>
          <th class="name">Name</th>
          <th class="size">Size</th>
          <th class="modified">Modified</th>
        </tr>
      </thead>
      <tbody>
        ${fileList.map(f => `
        <tr>
          <td class="icon">${f.icon}</td>
          <td class="name"><a href="${f.href}">${f.file}${f.isDir ? '/' : ''}</a></td>
          <td class="size">${f.size}</td>
          <td class="modified">${f.modified}</td>
        </tr>
        `).join('')}
      </tbody>
    </table>

    <footer>
      Node.js Static Server • ${fileList.length} items
    </footer>
  </div>
</body>
</html>`;
}

function formatSize(bytes) {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function getFileIcon(filename) {
  const ext = path.extname(filename).toLowerCase();
  const icons = {
    '.html': '📄', '.htm': '📄',
    '.css': '🎨',
    '.js': '⚡', '.mjs': '⚡', '.ts': '⚡',
    '.json': '📋',
    '.md': '📝', '.txt': '📝',
    '.png': '🖼️', '.jpg': '🖼️', '.jpeg': '🖼️', '.gif': '🖼️', '.svg': '🖼️', '.webp': '🖼️',
    '.mp4': '🎬', '.webm': '🎬',
    '.mp3': '🎵', '.wav': '🎵',
    '.pdf': '📕',
    '.zip': '📦', '.tar': '📦', '.gz': '📦',
  };
  return icons[ext] || '📄';
}

function injectEruda(html) {
  // Inject into <head>
  if (/<head[^>]*>/i.test(html)) {
    return html.replace(/(<head[^>]*>)/i, `$1${ERUDA_SCRIPT}`);
  }
  // Inject after <html>
  if (/<html[^>]*>/i.test(html)) {
    return html.replace(/(<html[^>]*>)/i, `$1<head>${ERUDA_SCRIPT}</head>`);
  }
  // Prepend if no structure
  return ERUDA_SCRIPT + html;
}

function timestamp() {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

// Create server
const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent(req.url.split('?')[0]);
  const filePath = path.join(DIRECTORY, urlPath);

  // Security: prevent directory traversal
  if (!filePath.startsWith(DIRECTORY)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.stat(filePath, (err, stat) => {
    if (err) {
      console.log(`[${timestamp()}] 404 ${req.method} ${urlPath}`);
      res.writeHead(404, { 'Content-Type': 'text/html' });
      res.end(`<h1>404 Not Found</h1><p>${urlPath}</p>`);
      return;
    }

    // Directory
    if (stat.isDirectory()) {
      const indexPath = path.join(filePath, 'index.html');

      if (fs.existsSync(indexPath)) {
        // Serve index.html with Eruda injection
        const content = injectEruda(fs.readFileSync(indexPath, 'utf-8'));
        console.log(`[${timestamp()}] 200 ${req.method} ${urlPath} (index.html)`);
        res.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'no-cache',
        });
        res.end(content);
      } else {
        // Generate directory listing
        fs.readdir(filePath, (err, files) => {
          if (err) {
            res.writeHead(500);
            res.end('Error reading directory');
            return;
          }
          console.log(`[${timestamp()}] 200 ${req.method} ${urlPath} (listing)`);
          const html = generateDirectoryListing(filePath, urlPath, files);
          res.writeHead(200, {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-cache',
          });
          res.end(html);
        });
      }
      return;
    }

    // File
    const ext = path.extname(filePath).toLowerCase();
    const mimeType = MIME_TYPES[ext] || 'application/octet-stream';

    // HTML files: inject Eruda
    if (ext === '.html' || ext === '.htm') {
      const content = injectEruda(fs.readFileSync(filePath, 'utf-8'));
      console.log(`[${timestamp()}] 200 ${req.method} ${urlPath}`);
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': Buffer.byteLength(content),
        'Cache-Control': 'no-cache',
      });
      res.end(content);
      return;
    }

    // Other files: stream directly
    console.log(`[${timestamp()}] 200 ${req.method} ${urlPath}`);
    res.writeHead(200, {
      'Content-Type': mimeType,
      'Content-Length': stat.size,
    });
    fs.createReadStream(filePath).pipe(res);
  });
});

server.listen(PORT, () => {
  console.log('Static Server with Eruda DevTools');
  console.log(`  URL:   http://localhost:${PORT}`);
  console.log(`  Mount: ${DIRECTORY}`);
  console.log('  Mode:  Eruda auto-injection (no logging)');
  console.log('');
  console.log('Press Ctrl+C to stop');
});

process.on('SIGINT', () => {
  console.log('\nServer stopped.');
  process.exit(0);
});
