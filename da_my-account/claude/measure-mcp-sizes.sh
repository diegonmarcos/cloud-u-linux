#!/usr/bin/env bash
# Refresh mcp-sizes.json (the declared per-server size table the budget guard reads): for each server named in the given
# project .mcp.json files, ask tools/list over the existing mcp-connect.mjs path
# (mesh first, else public bearer; http entries are called directly with the same
# bearer) and record tools + ceil(bytes/4) of the tools array. Unreachable servers
# keep their recorded entry. Never prints the token.
#
# Usage: measure-mcp-sizes.sh [--write] [mcp.json ...]   (default: ./.mcp.json)
#   without --write the table is only printed.
set -euo pipefail
SOT="$(cd "$(dirname "$0")" && pwd)"
WRITE=0; [ "${1:-}" = "--write" ] && { WRITE=1; shift; }
[ $# -gt 0 ] || set -- "${CLAUDE_PROJECT_DIR:-.}/.mcp.json"
node --no-warnings - "$SOT" "$WRITE" "$@" <<'JS'
const fs = require('fs'), path = require('path'), { spawn } = require('child_process');
const [sot, write, ...files] = process.argv.slice(2);
const servers = {};
for (const f of files) Object.assign(servers, JSON.parse(fs.readFileSync(f, 'utf8')).mcpServers || {});
const rpc = (id, method, params) => ({ jsonrpc: '2.0', id, method, ...(params ? { params } : {}) });
function viaStdio(e) {
  const args = e.args.map((a) => a.replace('${CLAUDE_PROJECT_DIR:-.}/.claude', sot));
  return new Promise((res, rej) => {
    const p = spawn(e.command, args, { stdio: ['pipe', 'pipe', 'ignore'] });
    let buf = '', done = false;
    const t = setTimeout(() => { p.kill(); rej(new Error('timeout')); }, 45000);
    p.stdout.on('data', (d) => { buf += d; let i;
      while ((i = buf.indexOf('\n')) >= 0) { const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
        if (m.id === 1) { p.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
          p.stdin.write(JSON.stringify(rpc(2, 'tools/list')) + '\n'); }
        if (m.id === 2) { clearTimeout(t); p.kill(); m.error ? rej(new Error(m.error.message)) : res(m.result.tools); } } });
    p.stdin.write(JSON.stringify(rpc(1, 'initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'measure', version: '1' } })) + '\n');
  });
}
async function viaHttp(e) {
  const tok = process.env.FLEET_BEARER || process.env.AUTHELIA_BEARER_TOKEN || '';
  const h = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', Authorization: `Bearer ${tok}` };
  const post = async (m, sid) => { const r = await fetch(e.url, { method: 'POST', headers: { ...h, ...(sid ? { 'Mcp-Session-Id': sid } : {}) }, body: JSON.stringify(m) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`); const txt = await r.text();
    const line = txt.startsWith('{') ? txt : (txt.split('\n').find((l) => l.startsWith('data:')) || '').slice(5);
    return { sid: r.headers.get('mcp-session-id'), body: line.trim() ? JSON.parse(line) : null }; };
  const i = await post(rpc(1, 'initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'measure', version: '1' } }));
  await post({ jsonrpc: '2.0', method: 'notifications/initialized' }, i.sid);
  return (await post(rpc(2, 'tools/list'), i.sid)).body.result.tools;
}
(async () => {
  const sf = path.join(sot, 'mcp-sizes.json');
  const pol = JSON.parse(fs.readFileSync(sf, 'utf8'));
  const tbl = pol.servers;
  for (const [n, e] of Object.entries(servers)) {
    try {
      const tools = await (e.type === 'stdio' ? viaStdio(e) : viaHttp(e));
      tbl[n] = { tools: tools.length, tokens: Math.ceil(Buffer.byteLength(JSON.stringify(tools)) / 4) };
      console.log(`${n}: ${tbl[n].tools} tools, ${tbl[n].tokens} tokens`);
    } catch (x) { console.log(`${n}: unreachable (${x.message}) — entry kept`); }
  }
  if (write === '1') { pol.measured = new Date().toISOString().slice(0, 10); fs.writeFileSync(sf, JSON.stringify(pol, null, 2) + '\n'); };
})();
JS
