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
interface RuleRow { rule: string; trigger: string; effect?: string; fires: number | null }
/** `rows` is the table. `lines` is what c3-watchdog shipped before the table
 *  existed, and it still arrives from any PEER running an older build — the
 *  machines page fetches a snapshot from that machine's own binary, so the
 *  envelope version is a property of the machine being measured, not of this
 *  page. Both are rendered; neither is assumed. */
interface Rule { head: string; rows?: RuleRow[]; lines?: string[] }
interface Envelope {
  snapshot?: Snap; report?: string; files?: string[]; tui?: string; tui_narrow?: string;
  machines?: Machine[]; exported?: string; measured?: string;
  /** The disk guard's own policy, serialised by the machine that has the file.
   *  Read there rather than here: a second reader is a second thing that can
   *  disagree with the guard about what it will freeze. */
  rules?: Rule[];
  /** The panel's page tree, generated from its own tab table. */
  app_map?: { depth: number; key: string; name: string; desc: string }[];
}
type Dict = Record<string, any>;
interface Snap extends Dict {
  cpu?: number; mem?: number; swap?: number;
  cores?: number[];
  load1?: number; load5?: number; load15?: number;
  slice_gib?: number; slice_max_gib?: number; slice_pct?: number;
}

// `let`, not `const`, and that is the whole point. The page used to be a
// frozen export: one envelope, baked in at write time, read once. The phone
// app renders the SAME document but gets its snapshot afterwards, over ssh,
// and may get a new one every few seconds — so the envelope has to be
// replaceable without rebuilding the page around it.
//
// It also means the UI no longer depends on having data to exist. With an
// empty envelope every panel renders its own frame with zeros, which is what
// lets the app open instantly and fill in later instead of showing an error
// where a dashboard should be.
let E: Envelope = JSON.parse(
  (document.getElementById('env') as HTMLElement).textContent || '{}');
let S: Snap = E.snapshot || {};
const out = document.getElementById('out') as HTMLElement;
// Which panel is on screen, so a data refresh redraws THAT one rather than
// throwing the reader back to the overview every time a snapshot lands.
let current = '__overview';
// The last thing the app's bridge said — "ssh nix-on-droid: Auth fail",
// "stale: oci-apps unreachable". The bridge always pushed these; the page
// never defined the function they were pushed at, so every reason a machine
// did not answer was thrown away and the only symptom left was a dashboard
// that never filled in.
let lastEvent = '';
// Set by index-mobile.html. Not a viewport query: the page is chosen when it
// is written, so a phone in landscape gets the phone page and a narrow window
// on a desktop does not.
const MOBILE = document.body.dataset.view === 'mobile';
// Assigned by the phone shell below; a no-op on the desktop page so every
// caller can just call it without asking which page it is on.
let fitNow: () => void = () => {};
// Two designs on the phone. "cards": the boxed dashboard, one column, built
// from the numbers — readable at phone size. "desktop": the panel's wide
// transcript scaled to the screen width, the exact desktop screen, for
// seeing the whole shape at once (pinch to read). Remembered per device.
type View = 'cards' | 'desktop';
let view: View = 'cards';
try { view = (localStorage.getItem('wd.view') as View) || 'cards'; } catch { /* no storage */ }
// A 20-cell meter needs ~20ch beside a label and two figures. That fits a
// terminal and does not fit 390px, so the bar gives up cells rather than
// letting the numbers wrap — the numbers are the part being read.
const BAR = MOBILE ? 10 : 20;

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
// Storage is the one exception to the mebibyte rule and keeps human units,
// which means it also has to SLIDE like the panel's: a 102MB boot partition
// reads "102M", not "0.1G", and a 44GB root reads "44.07G". Forcing one
// decimal of gigabytes turned every small mount into 0.0G and lost it.
const gb = (g: number): string =>
  (g || 0) < 1 ? Math.round((g || 0) * 1024) + 'M' : (g || 0).toFixed(2) + 'G';
// Coerce ANYTHING to a number, because the values reaching these formatters
// are read defensively out of a snapshot whose shape grows on the daemon side
// — and, in the shipped app-shell, are placeholder `{}` objects with no fields
// at all. `({}).toFixed` threw and took the whole page down with it; a
// dashboard must never blank because one cell is the wrong type, exactly as
// the Rust `num()` never blanks a panel for a missing key.
const n = (x: unknown): number => (typeof x === 'number' && isFinite(x) ? x : 0);
const pc = (x: unknown): string => n(x).toFixed(1) + '%';

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
  `<div class="r"><span class="lb">${esc(label)}</span>${meter((p || 0) / 100, BAR)}`
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
  const cores = S.cores || [];
  // The total bar is labelled CPU and spans the box, exactly as draw() writes
  // it — "total" is a word the panel never uses here.
  let b = bar('CPU', S.cpu || 0, pc(S.cpu));
  // Per core: short meter, because eight of them stacked at full width is a
  // wall. The panel gives these six cells beside a mini history.
  cores.forEach((c, n) => {
    b += `<div class="r core"><span class="lb">C${n}</span>`
       + meter((c || 0) / 100, MOBILE ? 6 : 8)
       + `<span class="v">${pc(c)}</span></div>`;
  });
  // ONE line, the panel's abbreviations, the panel's order. usr sys io irq
  // nice steal — steal last because it is the one that means the machine is
  // not yours, and it reads as the punchline of the row.
  b += kv('usr', pc(num(d,'user')), 'sys', pc(num(d,'system')), 'io', pc(num(d,'iowait')),
          'irq', pc(num(d,'irq')), 'nice', pc(num(d,'nice')), 'steal', pc(num(d,'steal')));
  b += kv('load', [S.load1, S.load5, S.load15].map(x => (x || 0).toFixed(2)).join(' '),
          '', `${cores.length} cores`);
  if (num(h,'procs_running') || num(h,'procs_blocked'))
    b += kv('run/blk', `${num(h,'procs_running')} / ${num(h,'procs_blocked')}`,
            'clock', num(i,'mhz') ? `${Math.round(num(i,'mhz'))} / ${Math.round(num(h,'max_mhz'))} MHz` : '-',
            'temp', num(i,'temp_c') ? num(i,'temp_c').toFixed(0) + '°C' : '-');
  // The model belongs in the frame, the way bbox() puts it there — it names
  // the box rather than being another row of data inside it.
  const ghz = num(i,'mhz') ? `  ${(num(h,'max_mhz') / 1000 || num(i,'mhz') / 1000).toFixed(2)}GHz` : '';
  return panel(`cpu  ${i.model || ''}${ghz}`.trim(), null, b, true);
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

// The disk guard's ladder, the same numbers the panel's storage box badges
// with (emergency.alert_ladder_pct 91/93/94, emergency.pct 95, no_mercy 99).
// A percentage in a bar is a number to interpret; this says what the machine
// will DO at that level.
function diskBadge(pct: number): string {
  const b = (t: string, c: string) =>
    `<b class="badge" style="background:${c};color:#0b0e14">${t}</b>`;
  if (pct >= 99) return b('NO-MERCY', '#ff5a5a');
  if (pct >= 95) return b('EMERGENCY', '#ff785a');
  if (pct >= 93) return b('PRE-EMERG', '#ffb450');
  if (pct >= 91) return b('WARN', '#f0dc5a');
  return '';
}

function boxStorage(): string {
  let b = '';
  (S.disks || []).forEach((d: Dict) => {
    b += bar(d.mount, num(d,'pct'), `${gb(num(d,'used_gib'))}/${gb(num(d,'total_gib'))}`);
  });
  (S.storage || []).forEach((s: Dict) => {
    b += head(s.label || 'pool');
    const dt = num(s,'data_total'), mt = num(s,'meta_total');
    if (dt) b += bar('data', num(s,'data_used') / dt * 100,
                     `${gb(num(s,'data_used') / GIB)}/${gb(dt / GIB)}`);
    if (mt) b += bar('meta', num(s,'meta_used') / mt * 100,
                     `${gb(num(s,'meta_used') / GIB)}/${gb(mt / GIB)}`);
    if (num(s,'dev_size')) {
      const fill = num(s,'alloc_used') / Math.max(1, num(s,'dev_size')) * 100;
      b += kv('device', gb(num(s,'dev_size') / GIB) + ' ' + diskBadge(fill));
    }
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
  // ▼ and ▲ with the rate, the way the panel heads its two graphs. The
  // graphs themselves need a history series a frozen snapshot does not carry.
  b = `<div class="r"><span class="lb">▼ rx</span><span class="v">${bytes(num(S,'net_rx'))}/s</span></div>`
    + `<div class="r"><span class="lb">▲ tx</span><span class="v">${bytes(num(S,'net_tx'))}/s</span></div>`
    + b;
  const t = S.totals || {};
  b += kv('total rx', bytes(num(t,'net_rx_bytes')), 'tx', bytes(num(t,'net_tx_bytes')));
  return panel('net', null, b, true);
}

function boxPsi(): string {
  const p = S.psi || {}, h = S.health || {}, r = S.reclaim || {}, m = S.mem_detail || {};
  // The panel's own grid: a header of windows, then some/full for each
  // resource. Three bars threw away the 60s and 300s columns, which are what
  // separate a spike from a machine that has been stalling for five minutes.
  let b = '<div class="r hd"><span class="lb"></span>'
        + '<span class="w">10s</span><span class="w">60s</span><span class="w">300s</span>'
        + '<span class="nw">now</span></div>';
  (['cpu', 'io', 'memory'] as const).forEach(k => {
    const x = (p as Dict)[k] || {};
    (['some', 'full'] as const).forEach(kind => {
      const v10 = num(x, kind + '10'), v60 = num(x, kind + '60'), v300 = num(x, kind + '300');
      b += `<div class="r"><span class="lb">${kind === 'some' ? esc(k === 'memory' ? 'mem' : k) : ''} ${kind}</span>`
         + `<span class="w">${v10.toFixed(2)}</span><span class="w">${v60.toFixed(2)}</span>`
         + `<span class="w">${v300.toFixed(2)}</span>`
         + `<span class="nw">${meter(v10 / 100, MOBILE ? 8 : 14)}</span></div>`;
    });
  });
  const dash = (v: number) => (v ? String(Math.round(v)) : '—');
  b += kv('reclaim/s', '', 'direct', dash(num(r,'scan_direct')), 'kswapd', dash(num(r,'scan_kswapd')));
  b += kv('refault/s', '', 'file', dash(num(r,'refault_file')), 'anon', dash(num(r,'refault_anon')));
  b += kv('swap/s', '', 'in', dash(num(r,'swap_in')), 'out', dash(num(r,'swap_out')));
  const cl = num(m,'commit_limit');
  b += kv('cpu', '', 'steal', pc(num(S.cpu_detail || {},'steal')), 'wait', pc(num(S.cpu_detail || {},'iowait')));
  b += kv('mem', '', 'commit', cl > 0 ? Math.round(num(m,'committed') / cl * 100) + '%' : '-',
          'dirty', mibG(num(m,'dirty')));
  b += kv('io/net', '', 'busy', pc(num(h,'disk_busy_pct')), 'avio', num(h,'disk_avio_ms').toFixed(2) + 'ms',
          'iops', String(num(h,'disk_iops')));
  // WHY — the same reading the panel's psi box gives. Reads that match the
  // file-refault rate are the page cache being evicted and re-read: memory,
  // not disk, and charged to no process.
  const bps = (v: number) => bytes(v) + '/s';
  const readB = num(S as Dict, 'disk_r') * 1048576;
  const refB = num(r, 'refault_file') * 4096, swapB = (num(r, 'swap_in') + num(r, 'swap_out')) * 4096;
  const avail = mibG(num(m, 'available'));
  const why: [number, string][] = [];
  const io = num((p as Dict).io || {}, 'some10'), me = num((p as Dict).memory || {}, 'some10'), cp = num((p as Dict).cpu || {}, 'some10');
  if (io >= 5) why.push([io, refB > 0 && refB >= readB * 0.5
    ? `io: reads ${bps(readB)} ≈ file refaults ${bps(refB)} — page cache evicted and re-read, avail ${avail} → MEMORY, not disk`
    : swapB > 0 && swapB >= readB * 0.5 ? `io: swap ${bps(swapB)}, avail ${avail} → MEMORY, not disk`
    : num(h,'disk_busy_pct') >= 80 ? `io: disk saturated — ${Math.round(num(h,'disk_iops'))} iops at ${Math.round(num(h,'disk_avio_ms'))}ms`
    : `io: ${Math.round(num(h,'procs_blocked'))} blocked (D state), wait ${pc(num(S.cpu_detail || {},'iowait'))}`]);
  if (me >= 5) why.push([me, `mem: direct reclaim ${dash(num(r,'scan_direct'))}/s, kswapd ${dash(num(r,'scan_kswapd'))}/s, avail ${avail}`]);
  if (cp >= 5) why.push([cp, `cpu: runq ${Math.round(num(h,'procs_running'))}, steal ${pc(num(S.cpu_detail || {},'steal'))}`]);
  why.sort((a, b2) => b2[0] - a[0]).slice(0, 2).forEach(([, t]) =>
    b += `<div class="r why"><span class="lb">why</span><span class="v">${esc(t)}</span></div>`);
  return panel('psi', null, b, true);
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
  return panel('watchdog · slices', String((S.slices || []).length), b, true);
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

// draw of the panel's mesh box: peer, addr, rtt — with the status dot in
// front. A frozen export has probed nothing, so every dot is the panel's
// unprobed "·" rather than a green one this page has not earned.
interface Machine {
  name: string; alias?: string; ip?: string; public?: string;
  role?: string; user?: string; kind?: string; local?: boolean;
}
function boxMesh(): string {
  const ms: Machine[] = E.machines || [];
  let b = `<div class="r hd"><span class="lb">peer</span>`
        + `<span class="v a">addr</span><span class="v t">kind</span></div>`;
  ms.forEach(m => {
    const here = !!m.local;
    b += `<div class="r${here ? ' here' : ''}">`
       + `<span class="dot">${here ? '●' : '·'}</span>`
       + `<span class="lb">${esc(m.name)}</span>`
       + `<span class="v a">${esc(m.ip || '-')}</span>`
       + `<span class="v t">${esc(here ? 'here' : (m.role || m.kind || ''))}</span></div>`;
    // The public address and the login are what you need to reach it, and a
    // declared VM is the only kind that has them.
    if (m.public && m.public !== m.ip)
      b += kv('', `${m.public}${m.user ? '  ' + m.user : ''}`);
  });
  return panel('mesh', ms.length + ' machines', b, true);
}

// The panel's own rows, in the panel's own order: a header line, cpu across
// the top, then mem | storage | net, then psi | slices | mesh, then the big
// box — which on this tab is the process table. Not a box more, not a box in
// a different place. The one thing missing is the braille history graph in
// cpu's left column: a frozen snapshot carries averages, not the series the
// panel accumulates while it runs, and drawing a shape from a single sample
// would be inventing data.
function overview(): string {
  // The panel's own screen, drawn headless into a ratatui buffer by the
  // exporter and transcribed cell by cell. Frames, alignment and colour are
  // not reproduced here — they arrive already correct, because draw() drew
  // them. The boxes below are the fallback for an envelope written before the
  // exporter could do this, or by a build that could not.
  // The phone gets its own transcript, drawn by the panel at 104 columns
  // rather than the 200-column one scaled down — 200 across a 390pt screen is
  // about three pixels a character, which is a texture, not text.
  if (MOBILE && view === 'cards' && typeof S.cpu === 'number') return legacyOverview();
  const t = MOBILE ? (E.tui || E.tui_narrow) : E.tui;
  if (t) return `<div class="tui-wrap">${t}</div>`;
  // NO TRANSCRIPT. Two very different reasons, and only one of them is a
  // dashboard.
  //
  // The app ships an EMPTY shell — every snapshot array is a single `{}`
  // placeholder and there are no real numbers yet — so it can open before it
  // has reached anything. Drawing the boxes against that placeholder is what
  // crashed the whole page: legacyOverview() read `cores: [{}]` and called
  // .toFixed on an object. Until a machine answers there is nothing to draw,
  // and saying so is the honest state — not a wall of zeros pretending to be a
  // measurement.
  if (typeof S.cpu !== 'number') {
    return panel('overview', 'waiting for a machine',
      '<pre>Pick a machine in the drawer, or wait for this one to answer.\n\n'
      + 'The interface is here; the numbers arrive when the sampler does.'
      + (lastEvent ? `\n\n${esc(lastEvent)}` : '') + '</pre>', true);
  }
  // A real envelope that predates the transcript, or a build that could not
  // draw one. The numbers are genuine here, so the boxes are too.
  return legacyOverview();
}

function legacyOverview(): string {
  return '<div class="dash">'
    + `<div class="w3">${boxCpu()}</div>`
    + boxMem() + boxStorage() + boxNet()
    + boxPsi() + boxSlices() + boxMesh()
    + `<div class="w3">${panel('processes',
        (S.proc_table || []).length + ' rows', table(S.proc_table || []))}</div>`
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
    return `<td class="num">${meter(v / 100, MOBILE ? 6 : 12)}${v.toFixed(1)}%</td>`;
  if (typeof v === 'number') return `<td class="num">${v}</td>`;
  if (typeof v === 'object') return `<td>${esc(JSON.stringify(v))}</td>`;
  const c = SCOPE[String(v).toLowerCase()];
  return c ? `<td><span class="pill ${c}">${esc(v)}</span></td>` : `<td>${esc(v)}</td>`;
}

// The columns a phone shows, in order, when a row has them. The process table
// is 18 wide, and scrolling sideways through 18 columns to find a number is
// not reading it. Desktop is untouched — this narrows the phone page only.
// pid is deliberately absent: the panel dropped the column, and a phone that
// still shows it is the same page disagreeing with itself.
const PHONE_COLS = ['name', 'user', 'origin', 'cpu_pct', 'mem_pct', 'mem_rss_bytes',
                    'slice',
                    // the fleet's per-network pages
                    'machine', 'addr', 'role', 'alias', 'ip',
                    // both firewall halves
                    'port', 'proto', 'source', 'state', 'desc',
                    'bind', 'container', 'socket', 'declared',
                    // the journal, and its 24h summary
                    'section', 'alerts_24h', 'time', 'unit', 'msg',
                    // about/update
                    'way', 'step', 'why', 'cmd',
                    // the day rollup
                    'date', 'cpu_pct_avg', 'mem_pct_avg',
                    'mount', 'pct'];

function table(rows: Dict[]): string {
  if (!rows.length) return '<div class="panel-body"><pre>no rows</pre></div>';
  // Union of keys, not the first row's: a row carrying one extra field must
  // not make that field invisible for the whole table.
  let cols: string[] = [];
  rows.forEach(r => Object.keys(r).forEach(k => { if (!cols.includes(k)) cols.push(k); }));
  if (MOBILE) {
    const keep = PHONE_COLS.filter(c => cols.includes(c));
    // Only narrow when there is something recognisable to narrow TO: a table
    // this list has never heard of stays whole rather than losing every column.
    if (keep.length >= 3) cols = keep;
  }
  return '<div class="scroll"><table><thead><tr>'
    + cols.map(c => `<th>${esc(c)}</th>`).join('')
    + '</tr></thead><tbody>'
    + rows.map(r => '<tr>' + cols.map(c => cell(r[c], c)).join('') + '</tr>').join('')
    + '</tbody></table></div>';
}

// ── choosing a machine ──────────────────────────────────────────────────────
// ONE answer to "which machines are there, which one am I on, which can be
// measured, and what happens when you pick one" — for the two places that ask:
// the drawer's machine group and the machines page.
//
// It was written twice and the two copies had ALREADY DIVERGED. The page
// offered a measure button on any peer; the drawer refused one with no
// reachable address, so `vast-RTX-p_0` — declared with ip "TBD" — got a button
// on one surface that could never have worked. And "is this the machine we are
// measuring" was spelled differently in each, so they could disagree about
// which row to mark. Neither difference was intended by anyone.
//
// So the list is `E.machines`, the judgement is [`fleet`], the verb is
// [`bindPicks`], and the two renderers decide nothing: they lay out rows and
// say which ones are pickable by copying the flag.

interface Choice {
  m: Machine;
  /** What the host is asked to measure — the ssh alias, or the name. */
  target: string;
  /** The machine this page is running on. */
  here: boolean;
  /** The machine this envelope describes. */
  current: boolean;
  /** There is a host to ask, and something for it to reach. */
  pickable: boolean;
}

/**
 * The host bridge, or null.
 *
 * "Measure" asks the HOST, because the phone cannot: it reaches exactly one
 * machine and every other peer is behind an ssh hop only that host can make.
 * A static export has no host at all, and there the fleet still lists — it
 * simply does not offer the verb.
 */
function bridge(): Dict | null {
  const h = (window as unknown as Dict).AndroidWatchdog as Dict | undefined;
  return h && h.refresh ? h : null;
}

function fleet(): Choice[] {
  const measured = E.measured || 'local';
  const can = !!bridge();
  return (E.machines || []).map((m: Machine) => {
    const here = !!m.local;
    const target = m.alias || m.name;
    return {
      m,
      target,
      here,
      current: here ? measured === 'local' || measured === target : measured === target,
      // A machine with no way in is never offered: the host you are already
      // on, and a VM declared with ip "TBD", which is in the fleet and not
      // reachable. A button that cannot work is worse than no button.
      pickable: can && !here && !!target && (m.ip || '') !== 'TBD',
    };
  });
}

/**
 * Wire everything the render marked pickable.
 *
 * `data-alias` is what to measure and `data-busy` is what the element should
 * say while it waits — the only two things the surfaces differ about, and both
 * of them are text.
 */
function bindPicks(root: HTMLElement): void {
  const h = bridge();
  if (!h) return;
  root.querySelectorAll<HTMLElement>('[data-alias]').forEach(el => {
    el.onclick = () => {
      el.textContent = el.dataset.busy || 'measuring…';
      (h.refresh as (a?: string) => void)(el.dataset.alias);
      // Harmless where the drawer is already shut, and the point of the click
      // where it is not: you asked for a machine, not for a menu.
      closeDrawer();
    };
  });
}

function show(k: string): void {
  if (k === '__overview') out.innerHTML = overview();
  else if (k === '__appmap') {
    // Generated by the panel from the same table its tab strip is drawn from,
    // so this cannot describe a page that does not exist. Rendered rather than
    // restated: a map maintained in two places is a map that will disagree
    // with itself.
    const ns = E.app_map || [];
    const b = ns.map(n =>
      `<div class="r d${n.depth}">`
      + `<span class="mk">${esc(n.key)}</span>`
      + `<span class="mn">${esc(n.name)}</span>`
      + `<span class="md">${esc(n.desc)}</span></div>`).join('');
    out.innerHTML = panel('app map', ns.length ? ns.length + ' entries' : null,
      ns.length ? b : '<pre>this build shipped no map</pre>', true);
  }
  else if (k === '__machines') {
    // EVERY machine, and a way to measure each one.
    //
    // The mesh box existed only inside legacyOverview(), which nothing renders
    // any more now that the overview is the panel's own transcript — so the
    // fleet was in the envelope and on no page at all.
    //
    // The fleet, whether a row is current and whether it can be picked all
    // come from `fleet()`, which is also what the drawer's machine group is
    // built from. This function lays out columns and nothing else.
    const fs = fleet();
    const can = !!bridge();
    let b = `<div class="r hd"><span class="lb">machine</span>`
          + `<span class="v a">addr</span><span class="v t">role</span></div>`;
    fs.forEach(c => {
      const m = c.m;
      b += `<div class="r${c.current ? ' here' : ''}">`
         + `<span class="dot">${c.current ? '●' : '·'}</span>`
         + `<span class="lb">${esc(m.name)}</span>`
         + `<span class="v a">${esc(m.ip || m.public || '-')}</span>`
         + `<span class="v t">${esc(c.here ? 'this host' : (m.role || m.kind || ''))}</span>`
         + (c.pickable
             ? `<button class="measure" data-alias="${esc(c.target)}" `
               + `data-busy="measuring…">measure</button>`
             : '')
         + `</div>`;
    });
    out.innerHTML = panel('machines', fs.length + (can ? ' — tap to measure' : ''), b, true);
    bindPicks(out);
  }
  else if (k === '__rules') {
    // The guards freeze and SIGTERM whole slices on thresholds that live in a
    // file only the measured machine can read. It travels in the envelope, so
    // this page shows the same rules the panel does without a second reader.
    const rs = E.rules || [];
    // A TABLE, because a threshold with no fire count is a claim and the count
    // is what the machine actually did. The guard froze workload.slice 986
    // times in a day while the page it was described on said only "frozen
    // first".
    const cell = (r: RuleRow) => {
      // null is "the journal could not answer", which is not zero — showing 0
      // would claim a rule never fired on a machine we cannot read.
      if (r.fires === null || r.fires === undefined) return '<span class="f none">—</span>';
      if (r.fires === 0) return '<span class="f zero">0</span>';
      return `<span class="f ${r.fires >= 100 ? 'hot' : 'warm'}">${r.fires}</span>`;
    };
    out.innerHTML = panel('rules', rs.length ? 'fires: last 24h' : 'no disk guard on this machine',
      rs.length
        ? rs.map(r =>
            `<div class="rule"><b>${esc(r.head)}</b>`
            + (r.rows && r.rows.length
                ? '<table class="rules"><thead><tr>'
                  + '<th>rule</th><th>triggers at</th><th class="n">fires</th><th>effect</th>'
                  + '</tr></thead><tbody>'
                  + r.rows.map(x =>
                      `<tr><td>${esc(x.rule)}</td><td>${esc(x.trigger)}</td>`
                      + `<td class="n">${cell(x)}</td><td class="e">${esc(x.effect || '')}</td></tr>`
                    ).join('')
                  + '</tbody></table>'
                // Older peer: prose, shown as it was written. Rendering it as
                // an empty table would report "no rules" for a machine that
                // has them, which is worse than showing the old shape.
                : `<pre>${(r.lines || []).map(esc).join('\n')}</pre>`)
            + '</div>').join('')
        : '<pre>this machine declares no disk-protection policy</pre>',
      true);
  }
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
  if (window.innerWidth < 1000 || MOBILE) closeDrawer();
  window.scrollTo(0, 0);
  if (MOBILE) requestAnimationFrame(fitNow);
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
    current = b.dataset.k || '__overview';
    show(current);
  };
});
// ── the phone application ──────────────────────────────────────────────────
// index-mobile.html is the APK's UI, so it gets an app bar rather than the
// report's header line. Built here rather than in the Rust template: a second
// template is a second place for the two pages to drift, and everything this
// needs is already in the DOM — the hamburger is simply moved into the bar it
// belongs to.
if (MOBILE) {
  const bar = document.createElement('div');
  bar.className = 'appbar';
  const ham = document.getElementById('ham') as HTMLElement;
  bar.appendChild(ham);

  const title = document.createElement('span');
  title.className = 't';
  const h = S.host_info || {};
  title.textContent = String(h.host || 'c3-watchdog');
  bar.appendChild(title);

  // How old the sample is, which is the one fact that decides whether
  // anything else on the page can be believed.
  const age = document.createElement('span');
  age.className = 'age';
  age.textContent = E.exported ? String(E.exported) : '';
  bar.appendChild(age);

  // Fit-to-width by default, 1:1 on demand. Scaling keeps every column in
  // position relative to every other; reflowing a terminal grid breaks all of
  // them at once, which is the failure this whole approach exists to end.
  const zoom = document.createElement('button');
  zoom.className = 'zoom';
  zoom.type = 'button';
  zoom.textContent = view;
  zoom.setAttribute('aria-label', 'switch between cards and the desktop screen');
  bar.appendChild(zoom);
  document.body.insertBefore(bar, document.body.firstChild);

  const root = document.documentElement;
  // A scaled element keeps its ORIGINAL box for layout, so the wrapper has to
  // be told the scaled height or the page carries a screenful of empty space
  // under the transcript.
  const fit = () => {
    const pre = document.querySelector('.tui') as HTMLElement | null;
    const wrap = document.querySelector('.tui-wrap') as HTMLElement | null;
    if (!pre || !wrap) return;
    pre.style.transform = '';
    wrap.style.height = '';
    // To the width, whichever way that is: the wide screen shrinks, a narrow
    // one grows. The grid keeps every column in place either way.
    const k = wrap.clientWidth / Math.max(1, pre.scrollWidth);
    pre.style.transform = `scale(${k})`;
    wrap.style.height = `${pre.offsetHeight * k}px`;
  };
  zoom.onclick = () => {
    view = view === 'cards' ? 'desktop' : 'cards';
    try { localStorage.setItem('wd.view', view); } catch { /* no storage */ }
    zoom.textContent = view;
    show(current);
  };
  void root;
  // Rotation changes the available width, so the fit is recomputed rather
  // than left at whatever the launch orientation happened to need.
  window.addEventListener('resize', fit);
  fitNow = fit;
}

/**
 * The drawer's "machine" group.
 *
 * It has always been the first thing in the sidebar and, in the app, it has
 * always been EMPTY: the switcher is built at export time as plain <a href>
 * links between sibling files, which is exactly right for a directory of
 * static reports read from a USB stick with the network off — and meaningless
 * in an APK, where there are no sibling files and `app_shell` passes "". So
 * the phone shipped a heading called "machine" with nothing under it, while
 * the fleet sat one page away on __machines.
 *
 * Filled from the envelope when the static list is absent. Same verb as the
 * machines page, and deliberately the same code path: "pick a machine" is one
 * behaviour and a second implementation of it is a second thing to diverge.
 * Where there is no host to ask — the exported report is a static file — the
 * rows still name the fleet and simply do not offer the verb.
 */
function fillSwitcher(): void {
  const ul = document.getElementById('sw');
  // A static export already put real links here. Never overwrite them: those
  // work offline and these do not.
  if (!ul || ul.querySelector('a[href]')) return;
  const fs = fleet();
  if (!fs.length) {
    ul.innerHTML = `<li><a class="off">no fleet in this envelope${lastEvent ? ' — ' + esc(lastEvent) : ''}</a></li>`;
    return;
  }
  ul.innerHTML = fs.map(c =>
    `<li><a class="m${c.current ? ' on' : ''}${c.pickable ? '' : ' off'}"`
    + (c.pickable
        ? ` data-alias="${esc(c.target)}" data-busy="${esc(c.m.name)} …"`
        : '')
    + `>${esc(c.m.name)}</a></li>`).join('');
  bindPicks(ul);
}

/**
 * Hand the page a new envelope. The app calls this when a snapshot comes back
 * from the machine; nothing else changes, so the drawer, the scroll position
 * and the selected panel all survive a refresh.
 *
 * Returns false rather than throwing on bad JSON: a half-written snapshot is
 * a thing that happens while the sampler is writing one, and dropping that
 * frame is correct — the next one is two seconds away.
 */
(window as unknown as Dict).__wdRender = (json: string): boolean => {
  let next: Envelope;
  try { next = JSON.parse(json); } catch { return false; }
  E = next;
  S = E.snapshot || {};
  // Before the panel, so switching machine repaints the list that says which
  // one you are on — the row would otherwise keep pointing at the previous
  // machine until something else happened to redraw.
  fillSwitcher();
  show(current);
  return true;
};

(window as unknown as Dict).__wdEvent = (kind: string, payload: string): void => {
  lastEvent = `${kind}: ${payload}`;
  // Repaint only the surfaces that show it: the placeholder overview and the
  // empty drawer. A live dashboard is not redrawn for a status line.
  if (current === '__overview' && typeof S.cpu !== 'number') show('__overview');
  const ul = document.getElementById('sw');
  const off = ul?.querySelector('a.off');
  if (off && !fleet().length) off.textContent = `no fleet in this envelope — ${lastEvent}`;
};

fillSwitcher();
show('__overview');
// The first fit has to wait for layout: scrollWidth is 0 until the browser
// has measured the <pre> it was just handed.
if (MOBILE) requestAnimationFrame(fitNow);
