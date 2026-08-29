// Authored source for dist/report.js. Compile with ./build.sh.
//
// The renderer for the report my-konsole-dash exports to ~/.watchdog/html; the
// compiled bundle is embedded in that binary. It reads the same snapshot the
// TUI reads, so the page and the panel cannot disagree about a number.
//
// Separate from watchdog.ts, which drives the live panel: that one polls a
// changing snapshot into a different DOM, this one renders a frozen envelope
// once. Sharing an entry point would mean both carrying the other's branches.
//
// The overview used to be the markdown export in a <pre>. A transcript of the
// dashboard is not the dashboard: this draws the panel's boxes, in the panel's
// order, with the panel's bars.

const MIB = 1048576, GIB = 1073741824;

interface Machine { alias: string; ip?: string; local?: boolean }
interface Envelope {
  snapshot?: Snap; report?: string; files?: string[];
  machines?: Machine[]; exported?: string; measured?: string;
}
type Dict = Record<string, any>;
interface Snap extends Dict {
  cpu?: number; mem?: number; swap?: number;
  cores?: number[];
  load1?: number; load5?: number; load15?: number;
  slice_gib?: number; slice_max_gib?: number; slice_pct?: number;
}

const E: Envelope = JSON.parse(
  (document.getElementById('env') as HTMLElement).textContent || '{}');
const S: Snap = E.snapshot || {};
const out = document.getElementById('out') as HTMLElement;

const esc = (s: unknown): string =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const num = (o: Dict | undefined, k: string): number => {
  const v = o && o[k];
  return typeof v === 'number' && isFinite(v) ? v : 0;
};

// ── the panel's own formatters ─────────────────────────────────────────────
// Memory is mebibytes. Always, everywhere, WHOLE ones: the two decimals hold
// the column's shape, they do not report a quantity, so anything under a
// mebibyte reads "0.00 MiB". That is the true answer to "how many megabytes is
// this", which is the only question the column asks. A column that slides to K
// under a megabyte is how "356KiB" ends up looking bigger than "5.379MiB".
const mib = (bytes: number): string =>
  Math.floor(Math.max(0, bytes || 0) / MIB).toFixed(2) + ' MiB';
// /proc reports several of these in GiB already; converting at each call site
// is exactly how units drift apart, so there is one place that does it.
const mibG = (g: number): string => mib((g || 0) * GIB);
const bare = (g: number): string => mibG(g).replace(' MiB', '');
// Storage is the one exception and keeps gigabytes: memory and disk are never
// read against each other, so they do not need a shared unit.
const gb = (g: number): string => (g || 0).toFixed(1) + 'G';
const pc = (x: number | null | undefined): string => (x == null ? 0 : x).toFixed(1) + '%';

const bytes = (n: number): string => {
  n = n || 0;
  const u = ['B', 'K', 'M', 'G', 'T'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i ? n.toFixed(1) : String(Math.round(n))) + u[i];
};

// draw::grad — the same two lerps about the same 0.5 split, so a bar here is
// the colour it is there. green(64,220,120) → yellow(240,222,64) → red(240,72,72).
function grad(t: number): string {
  t = Math.max(0, Math.min(1, t));
  const L = (a: number, b: number, x: number) => Math.round(a + (b - a) * x);
  return t < 0.5
    ? `rgb(${L(64,240,t*2)},${L(220,222,t*2)},${L(120,64,t*2)})`
    : `rgb(${L(240,240,(t-.5)*2)},${L(222,72,(t-.5)*2)},${L(64,72,(t-.5)*2)})`;
}

// draw::meter — real glyphs, so the bar sits on the same cell grid as the text
// beside it and survives being pasted into a mail.
function meter(frac: number, w = 14): string {
  const f = Math.max(0, Math.min(w, Math.round((frac || 0) * w)));
  return `<span class="mtr"><i style="color:${grad(frac)}">${'█'.repeat(f)}</i>`
       + `<i class="e">${'░'.repeat(w - f)}</i></span>`;
}

// ── row primitives ─────────────────────────────────────────────────────────
const bar = (label: string, p: number, txt: string): string =>
  `<div class="r"><span class="lb">${esc(label)}</span>${meter((p || 0) / 100, 20)}`
  + `<span class="v">${esc(txt)}</span></div>`;

const kv = (...parts: string[]): string => {
  let h = '<div class="r dt">';
  for (let i = 0; i < parts.length; i += 2)
    h += `<span class="dk">${esc(parts[i])}</span><span class="dv">${esc(parts[i + 1])}</span>`;
  return h + '</div>';
};

const head = (t: string): string => `<div class="sub">${esc(t)}</div>`;

function panel(title: string, count: string | null, inner: string, pad = false): string {
  return `<div class="panel"><div class="panel-head"><h3>${esc(title)}</h3>`
    + (count === null ? '' : `<span class="count">${esc(count)}</span>`)
    + `</div>${pad ? `<div class="panel-body">${inner}</div>` : inner}</div>`;
}

// ── the boxes, in the panel's order ────────────────────────────────────────
function boxCpu(): string {
  const d = S.cpu_detail || {}, i = S.cpu_info || {}, h = S.health || {};
  let b = bar('total', S.cpu || 0, pc(S.cpu));
  (S.cores || []).forEach((c, n) => { b += bar('c' + n, c, pc(c)); });
  b += kv('user', pc(num(d,'user')), 'sys', pc(num(d,'system')), 'iowait', pc(num(d,'iowait')));
  b += kv('irq', pc(num(d,'irq')), 'steal', pc(num(d,'steal')), 'nice', pc(num(d,'nice')));
  b += kv('load', [S.load1, S.load5, S.load15].map(x => (x || 0).toFixed(2)).join('  '),
          'run/blk', `${num(h,'procs_running')} / ${num(h,'procs_blocked')}`);
  b += kv('clock', num(i,'mhz')
            ? `${Math.round(num(i,'mhz'))} / ${Math.round(num(h,'max_mhz'))} MHz` : '-',
          'temp', num(i,'temp_c') ? num(i,'temp_c').toFixed(0) + '°C' : '-');
  if (i.model) b += kv('model', i.model);
  return panel('cpu', null, b, true);
}

function boxMem(): string {
  const m = S.mem_detail || {}, w = S.swap_detail || {}, v = S.vram_detail || {};
  const tot = num(m, 'total');
  const share = (x: number) => tot > 0 ? pc(x / tot * 100) : '0.0%';
  let b = head('RAM');
  b += bar('used', S.mem || 0, `${mibG(num(m,'used'))} / ${mibG(tot)}`);
  // These four are disjoint and sum to total, which is what makes it a
  // breakdown rather than four unrelated numbers.
  b += kv('anon', `${mibG(num(m,'anon'))} ${share(num(m,'anon'))}`,
          'cache', `${mibG(num(m,'cached'))} ${share(num(m,'cached'))}`);
  b += kv('kern', `${mibG(num(m,'kernel'))} ${share(num(m,'kernel'))}`,
          'free', `${mibG(num(m,'free'))} ${share(num(m,'free'))}`);
  b += kv('buffers', mibG(num(m,'buffers')), 'shmem', mibG(num(m,'shmem')),
          'avail', mibG(num(m,'available')));
  // Two figures in the same unit do not need it named twice, and in a line
  // that already names it four times that is what pushes the row off the edge.
  b += kv('dirty', mibG(num(m,'dirty')), 'wb', mibG(num(m,'writeback')),
          'commit', `${bare(num(m,'committed'))}/${mibG(num(m,'commit_limit'))}`);
  // RAM and swap kept apart on purpose: two different stores, and a page can
  // be in BOTH at once, so one merged figure is arithmetic on overlapping sets.
  b += head('SWAP');
  b += bar('used', S.swap || 0, `${mibG(num(w,'used'))} / ${mibG(num(w,'total'))}`);
  b += kv('free', mibG(num(w,'free')), 'cached', mibG(num(w,'cached')),
          'zswap', `${bare(num(w,'zswapped'))}→${mibG(num(w,'zswap'))}`);
  // The slice's own cap is what decides who gets OOM-killed here; RAM% can
  // look calm while the slice is at its limit.
  if (num(S, 'slice_max_gib') > 0) {
    b += head('SESSION SLICE');
    b += bar('slice', S.slice_pct || 0,
             `${mibG(num(S,'slice_gib'))} / ${mibG(num(S,'slice_max_gib'))}`);
  }
  // Dedicated belongs to the card and filling it makes the GPU evict; shared
  // comes out of the same RAM as everything else. One merged "VRAM" answers
  // neither question. These two report bytes, not gibibytes.
  (['dedicated', 'shared'] as const).forEach(k => {
    const x = (v as Dict)[k];
    if (!x || !num(x, 'total')) return;
    b += head('VRAM ' + k);
    b += bar(k, num(x,'used') / num(x,'total') * 100,
             `${mib(num(x,'used'))} / ${mib(num(x,'total'))}`);
  });
  return panel('mem', null, b, true);
}

function boxStorage(): string {
  let b = '';
  (S.disks || []).forEach((d: Dict) => {
    b += bar(d.mount, num(d,'pct'), `${gb(num(d,'used_gib'))} / ${gb(num(d,'total_gib'))}`);
  });
  (S.storage || []).forEach((s: Dict) => {
    b += head(s.label || 'pool');
    const dt = num(s,'data_total'), mt = num(s,'meta_total');
    if (dt) b += bar('data', num(s,'data_used') / dt * 100,
                     `${gb(num(s,'data_used') / GIB)} / ${gb(dt / GIB)}`);
    if (mt) b += bar('meta', num(s,'meta_used') / mt * 100,
                     `${gb(num(s,'meta_used') / GIB)} / ${gb(mt / GIB)}`);
    if (num(s,'dev_size')) b += kv('device', gb(num(s,'dev_size') / GIB));
  });
  b += kv('read', bytes(num(S,'disk_r')) + '/s', 'write', bytes(num(S,'disk_w')) + '/s');
  return panel('storage', null, b, true);
}

function boxNet(): string {
  const h = S.host_info || {};
  let b = '';
  (h.ifaces || []).forEach((f: Dict) => {
    b += kv(String(f.name || ''), String(f.addr || '') + (f.mesh ? '  mesh' : ''));
  });
  b += kv('gateway', h.gateway || '-');
  if (h.public) b += kv('public', String(h.public));
  b += head('RATE');
  b += kv('rx', bytes(num(S,'net_rx')) + '/s', 'tx', bytes(num(S,'net_tx')) + '/s');
  const t = S.totals || {};
  b += kv('total rx', bytes(num(t,'net_rx_bytes')), 'tx', bytes(num(t,'net_tx_bytes')));
  return panel('net', null, b, true);
}

function boxPsi(): string {
  const p = S.psi || {};
  let b = kv('', 'some10   some60  some300');
  (['cpu', 'io', 'memory'] as const).forEach(k => {
    const x = (p as Dict)[k] || {};
    b += bar(k, num(x,'some10'),
      [num(x,'some10'), num(x,'some60'), num(x,'some300')]
        .map(v => v.toFixed(2).padStart(7)).join(' '));
  });
  return panel('pressure', null, b, true);
}

function boxSlices(): string {
  let b = '';
  (S.slices || []).forEach((s: Dict) => {
    const cur = num(s, 'current'), max = num(s, 'max');
    // max is -1 when the slice has no limit, and a bar against no limit is a
    // bar against nothing — so it gets the figure and no meter.
    b += max > 0
      ? bar(s.name, cur / max * 100, `${mib(cur)} / ${mib(max)}`)
      : `<div class="r"><span class="lb">${esc(s.name)}</span>`
        + `<span class="mtr nolimit">no limit</span>`
        + `<span class="v">${mib(cur)}</span></div>`;
    b += kv('pids', String(num(s,'pids')), 'psi cpu', num(s,'cpu_psi').toFixed(2),
            'io', num(s,'io_psi').toFixed(2), 'mem', num(s,'mem_psi').toFixed(2));
  });
  return panel('slices', String((S.slices || []).length), b, true);
}

function boxHealth(): string {
  const h = S.health || {}, r = S.reclaim || {}, bat = S.battery || {};
  let b = kv('iops', String(num(h,'disk_iops')), 'busy', pc(num(h,'disk_busy_pct')),
             'avio', num(h,'disk_avio_ms').toFixed(2) + 'ms');
  b += kv('ctxt/s', String(num(h,'ctxt_per_s')), 'intr/s', String(num(h,'intr_per_s')),
          'oom', String(num(h,'oom_kill')));
  b += kv('scan kswapd', String(num(r,'scan_kswapd')), 'direct', String(num(r,'scan_direct')));
  b += kv('swap in', String(num(r,'swap_in')), 'out', String(num(r,'swap_out')),
          'refault file', String(num(r,'refault_file')));
  if (bat.present) b += bar('battery', num(bat,'pct'), pc(num(bat,'pct')) + '  ' + (bat.status || ''));
  return panel('health', null, b, true);
}

// Every machine this user can reach, not only the one measured. The report is
// read as "what have I got", and the list is the ssh config — the declaration
// rather than a probe, so a VM that is switched off is still a VM you have.
function boxMachines(): string {
  const h = S.host_info || {}, ms = E.machines || [];
  let b = kv('host', h.host || '-', 'user', h.user || '-');
  b += kv('os', h.os || '-');
  b += kv('kernel', h.kernel || '-');
  if (!ms.length) return panel('machine', null, b, true);
  b += head('MACHINES');
  ms.forEach(m => {
    b += `<div class="r"><span class="lb">${esc(m.alias)}</span>`
       + `<span class="v ip">${esc(m.ip || '-')}</span>`
       + (m.local ? '<span class="pill ok">this one</span>' : '') + '</div>';
  });
  return panel('machine', ms.length + ' machines', b, true);
}

function overview(): string {
  return '<div class="dash">'
    + `<div class="w3">${boxCpu()}</div>`
    + boxMem() + boxStorage() + boxNet()
    + `<div class="w2">${boxSlices()}</div>`
    + boxPsi()
    + boxHealth()
    + `<div class="w2">${boxMachines()}</div>`
    + '</div>';
}

// ── the tabular views ──────────────────────────────────────────────────────
// The panel colours a socket by who can reach it; so does this.
const SCOPE: Record<string, string> = {
  world: 'bad', mesh: 'warn', loopback: 'ok', running: 'ok', exited: 'bad', dead: 'bad',
};
// A column is a meter when it is a percentage: the panel draws a bar for every
// one of these and a bare number for nothing else.
const PCT = /(^|_)(pct|percent|usage)$|%/i;

function cell(v: unknown, col?: string): string {
  if (v === null || v === undefined || v === '') return '<td class="nil">-</td>';
  if (typeof v === 'boolean')
    return `<td><span class="pill ${v ? 'ok' : 'bad'}">${v}</span></td>`;
  if (typeof v === 'number' && col && PCT.test(col))
    return `<td class="num">${meter(v / 100, 12)}${v.toFixed(1)}%</td>`;
  if (typeof v === 'number') return `<td class="num">${v}</td>`;
  if (typeof v === 'object') return `<td>${esc(JSON.stringify(v))}</td>`;
  const c = SCOPE[String(v).toLowerCase()];
  return c ? `<td><span class="pill ${c}">${esc(v)}</span></td>` : `<td>${esc(v)}</td>`;
}

function table(rows: Dict[]): string {
  if (!rows.length) return '<div class="panel-body"><pre>no rows</pre></div>';
  // Union of keys, not the first row's: a row carrying one extra field must
  // not make that field invisible for the whole table.
  const cols: string[] = [];
  rows.forEach(r => Object.keys(r).forEach(k => { if (!cols.includes(k)) cols.push(k); }));
  return '<div class="scroll"><table><thead><tr>'
    + cols.map(c => `<th>${esc(c)}</th>`).join('')
    + '</tr></thead><tbody>'
    + rows.map(r => '<tr>' + cols.map(c => cell(r[c], c)).join('') + '</tr>').join('')
    + '</tbody></table></div>';
}

function show(k: string): void {
  if (k === '__overview') out.innerHTML = overview();
  else if (k === '__report')
    out.innerHTML = panel('report', null, `<pre>${esc(E.report || '')}</pre>`, true);
  else if (k === '__files') {
    const f = E.files || [];
    out.innerHTML = panel('files', f.length + ' paths', `<pre>${esc(f.join('\n'))}</pre>`, true);
  } else if (k === '__raw')
    out.innerHTML = panel('raw envelope', null, `<pre>${esc(JSON.stringify(E, null, 2))}</pre>`, true);
  else {
    const rows: Dict[] = (S as Dict)[k] || [];
    out.innerHTML = panel(k, rows.length + ' rows', table(rows));
  }
  if (window.innerWidth < 1000) closeDrawer();
  window.scrollTo(0, 0);
}

const sb = document.getElementById('sb') as HTMLElement;
const scrim = document.getElementById('scrim') as HTMLElement;
function closeDrawer(): void { sb.classList.remove('open'); scrim.classList.remove('on'); }
(document.getElementById('ham') as HTMLElement).onclick = () => {
  sb.classList.add('open'); scrim.classList.add('on');
};
(document.getElementById('cls') as HTMLElement).onclick = closeDrawer;
scrim.onclick = closeDrawer;
document.querySelectorAll<HTMLElement>('.t').forEach(b => {
  b.onclick = () => {
    document.querySelectorAll('.t').forEach(x => x.classList.remove('on'));
    b.classList.add('on');
    show(b.dataset.k || '__overview');
  };
});
show('__overview');
