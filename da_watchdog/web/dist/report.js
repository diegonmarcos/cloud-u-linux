(() => {
  const MIB = 1048576;
  const GIB = 1073741824;
  let E = JSON.parse(
    document.getElementById("env").textContent || "{}"
  );
  let S = E.snapshot || {};
  const out = document.getElementById("out");
  let current = "__overview";
  const MOBILE = document.body.dataset.view === "mobile";
  let fitNow = () => {
  };
  const BAR = MOBILE ? 10 : 20;
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const num = (o, k) => {
    const v = o && o[k];
    return typeof v === "number" && isFinite(v) ? v : 0;
  };
  const mib = (bytes2) => Math.floor(Math.max(0, bytes2 || 0) / MIB).toFixed(2) + " MiB";
  const mibG = (g) => mib((g || 0) * GIB);
  const bare = (g) => mibG(g).replace(" MiB", "");
  const gb = (g) => (g || 0) < 1 ? Math.round((g || 0) * 1024) + "M" : (g || 0).toFixed(2) + "G";
  const n = (x) => typeof x === "number" && isFinite(x) ? x : 0;
  const pc = (x) => n(x).toFixed(1) + "%";
  const bytes = (n2) => {
    n2 = n2 || 0;
    const u = ["B", "K", "M", "G", "T"];
    let i = 0;
    while (n2 >= 1024 && i < u.length - 1) {
      n2 /= 1024;
      i++;
    }
    return (i ? n2.toFixed(1) : String(Math.round(n2))) + u[i];
  };
  function grad(t) {
    t = Math.max(0, Math.min(1, t));
    const L = (a, b, x) => Math.round(a + (b - a) * x);
    return t < 0.5 ? `rgb(${L(64, 240, t * 2)},${L(220, 222, t * 2)},${L(120, 64, t * 2)})` : `rgb(${L(240, 240, (t - 0.5) * 2)},${L(222, 72, (t - 0.5) * 2)},${L(64, 72, (t - 0.5) * 2)})`;
  }
  function meter(frac, w = 14) {
    const f = Math.max(0, Math.min(w, Math.round((frac || 0) * w)));
    return `<span class="mtr"><i style="color:${grad(frac)}">${"\u2588".repeat(f)}</i><i class="e">${"\u2591".repeat(w - f)}</i></span>`;
  }
  const bar = (label, p, txt) => `<div class="r"><span class="lb">${esc(label)}</span>${meter((p || 0) / 100, BAR)}<span class="v">${esc(txt)}</span></div>`;
  const kv = (...parts) => {
    let h = '<div class="r dt">';
    for (let i = 0; i < parts.length; i += 2)
      h += `<span class="dk">${esc(parts[i])}</span><span class="dv">${esc(parts[i + 1])}</span>`;
    return h + "</div>";
  };
  const head = (t) => `<div class="sub">${esc(t)}</div>`;
  function panel(title, count, inner, pad = false) {
    return `<div class="panel"><div class="panel-head"><h3>${esc(title)}</h3>` + (count === null ? "" : `<span class="count">${esc(count)}</span>`) + `</div>${pad ? `<div class="panel-body">${inner}</div>` : inner}</div>`;
  }
  function boxCpu() {
    const d = S.cpu_detail || {}, i = S.cpu_info || {}, h = S.health || {};
    const cores = S.cores || [];
    let b = bar("CPU", S.cpu || 0, pc(S.cpu));
    cores.forEach((c, n2) => {
      b += `<div class="r core"><span class="lb">C${n2}</span>` + meter((c || 0) / 100, MOBILE ? 6 : 8) + `<span class="v">${pc(c)}</span></div>`;
    });
    b += kv(
      "usr",
      pc(num(d, "user")),
      "sys",
      pc(num(d, "system")),
      "io",
      pc(num(d, "iowait")),
      "irq",
      pc(num(d, "irq")),
      "nice",
      pc(num(d, "nice")),
      "steal",
      pc(num(d, "steal"))
    );
    b += kv(
      "load",
      [S.load1, S.load5, S.load15].map((x) => (x || 0).toFixed(2)).join(" "),
      "",
      `${cores.length} cores`
    );
    if (num(h, "procs_running") || num(h, "procs_blocked"))
      b += kv(
        "run/blk",
        `${num(h, "procs_running")} / ${num(h, "procs_blocked")}`,
        "clock",
        num(i, "mhz") ? `${Math.round(num(i, "mhz"))} / ${Math.round(num(h, "max_mhz"))} MHz` : "-",
        "temp",
        num(i, "temp_c") ? num(i, "temp_c").toFixed(0) + "\xB0C" : "-"
      );
    const ghz = num(i, "mhz") ? `  ${(num(h, "max_mhz") / 1e3 || num(i, "mhz") / 1e3).toFixed(2)}GHz` : "";
    return panel(`cpu  ${i.model || ""}${ghz}`.trim(), null, b, true);
  }
  function boxMem() {
    const m = S.mem_detail || {}, w = S.swap_detail || {}, v = S.vram_detail || {};
    const tot = num(m, "total");
    const share = (x) => tot > 0 ? pc(x / tot * 100) : "0.0%";
    let b = head("RAM");
    b += bar("used", S.mem || 0, `${mibG(num(m, "used"))} / ${mibG(tot)}`);
    b += kv(
      "anon",
      `${mibG(num(m, "anon"))} ${share(num(m, "anon"))}`,
      "cache",
      `${mibG(num(m, "cached"))} ${share(num(m, "cached"))}`
    );
    b += kv(
      "kern",
      `${mibG(num(m, "kernel"))} ${share(num(m, "kernel"))}`,
      "free",
      `${mibG(num(m, "free"))} ${share(num(m, "free"))}`
    );
    b += kv(
      "buffers",
      mibG(num(m, "buffers")),
      "shmem",
      mibG(num(m, "shmem")),
      "avail",
      mibG(num(m, "available"))
    );
    b += kv(
      "dirty",
      mibG(num(m, "dirty")),
      "wb",
      mibG(num(m, "writeback")),
      "commit",
      `${bare(num(m, "committed"))}/${mibG(num(m, "commit_limit"))}`
    );
    b += head("SWAP");
    b += bar("used", S.swap || 0, `${mibG(num(w, "used"))} / ${mibG(num(w, "total"))}`);
    b += kv(
      "free",
      mibG(num(w, "free")),
      "cached",
      mibG(num(w, "cached")),
      "zswap",
      `${bare(num(w, "zswapped"))}\u2192${mibG(num(w, "zswap"))}`
    );
    if (num(S, "slice_max_gib") > 0) {
      b += bar(
        "slice",
        S.slice_pct || 0,
        `${mibG(num(S, "slice_gib"))} / ${mibG(num(S, "slice_max_gib"))}`
      );
    }
    ["dedicated", "shared"].forEach((k) => {
      const x = v[k];
      if (!x || !num(x, "total")) return;
      b += head("VRAM " + k);
      b += bar(
        k,
        num(x, "used") / num(x, "total") * 100,
        `${mib(num(x, "used"))} / ${mib(num(x, "total"))}`
      );
    });
    return panel("mem", null, b, true);
  }
  function diskBadge(pct) {
    const b = (t, c) => `<b class="badge" style="background:${c};color:#0b0e14">${t}</b>`;
    if (pct >= 99) return b("NO-MERCY", "#ff5a5a");
    if (pct >= 95) return b("EMERGENCY", "#ff785a");
    if (pct >= 93) return b("PRE-EMERG", "#ffb450");
    if (pct >= 91) return b("WARN", "#f0dc5a");
    return "";
  }
  function boxStorage() {
    let b = "";
    (S.disks || []).forEach((d) => {
      b += bar(d.mount, num(d, "pct"), `${gb(num(d, "used_gib"))}/${gb(num(d, "total_gib"))}`);
    });
    (S.storage || []).forEach((s) => {
      b += head(s.label || "pool");
      const dt = num(s, "data_total"), mt = num(s, "meta_total");
      if (dt) b += bar(
        "data",
        num(s, "data_used") / dt * 100,
        `${gb(num(s, "data_used") / GIB)}/${gb(dt / GIB)}`
      );
      if (mt) b += bar(
        "meta",
        num(s, "meta_used") / mt * 100,
        `${gb(num(s, "meta_used") / GIB)}/${gb(mt / GIB)}`
      );
      if (num(s, "dev_size")) {
        const fill = num(s, "alloc_used") / Math.max(1, num(s, "dev_size")) * 100;
        b += kv("device", gb(num(s, "dev_size") / GIB) + " " + diskBadge(fill));
      }
    });
    b += kv("read", bytes(num(S, "disk_r")) + "/s", "write", bytes(num(S, "disk_w")) + "/s");
    return panel("storage", null, b, true);
  }
  function boxNet() {
    const h = S.host_info || {};
    let b = "";
    (h.ifaces || []).forEach((f) => {
      b += kv(String(f.name || ""), String(f.addr || "") + (f.mesh ? "  mesh" : ""));
    });
    b += kv("gateway", h.gateway || "-");
    if (h.public) b += kv("public", String(h.public));
    b = `<div class="r"><span class="lb">\u25BC rx</span><span class="v">${bytes(num(S, "net_rx"))}/s</span></div><div class="r"><span class="lb">\u25B2 tx</span><span class="v">${bytes(num(S, "net_tx"))}/s</span></div>` + b;
    const t = S.totals || {};
    b += kv("total rx", bytes(num(t, "net_rx_bytes")), "tx", bytes(num(t, "net_tx_bytes")));
    return panel("net", null, b, true);
  }
  function boxPsi() {
    const p = S.psi || {}, h = S.health || {}, r = S.reclaim || {}, m = S.mem_detail || {};
    let b = '<div class="r hd"><span class="lb"></span><span class="w">10s</span><span class="w">60s</span><span class="w">300s</span><span class="nw">now</span></div>';
    ["cpu", "io", "memory"].forEach((k) => {
      const x = p[k] || {};
      ["some", "full"].forEach((kind) => {
        const v10 = num(x, kind + "10"), v60 = num(x, kind + "60"), v300 = num(x, kind + "300");
        b += `<div class="r"><span class="lb">${kind === "some" ? esc(k === "memory" ? "mem" : k) : ""} ${kind}</span><span class="w">${v10.toFixed(2)}</span><span class="w">${v60.toFixed(2)}</span><span class="w">${v300.toFixed(2)}</span><span class="nw">${meter(v10 / 100, MOBILE ? 8 : 14)}</span></div>`;
      });
    });
    const dash = (v) => v ? String(Math.round(v)) : "\u2014";
    b += kv("reclaim/s", "", "direct", dash(num(r, "scan_direct")), "kswapd", dash(num(r, "scan_kswapd")));
    b += kv("refault/s", "", "file", dash(num(r, "refault_file")), "anon", dash(num(r, "refault_anon")));
    b += kv("swap/s", "", "in", dash(num(r, "swap_in")), "out", dash(num(r, "swap_out")));
    const cl = num(m, "commit_limit");
    b += kv("cpu", "", "steal", pc(num(S.cpu_detail || {}, "steal")), "wait", pc(num(S.cpu_detail || {}, "iowait")));
    b += kv(
      "mem",
      "",
      "commit",
      cl > 0 ? Math.round(num(m, "committed") / cl * 100) + "%" : "-",
      "dirty",
      mibG(num(m, "dirty"))
    );
    b += kv(
      "io/net",
      "",
      "busy",
      pc(num(h, "disk_busy_pct")),
      "avio",
      num(h, "disk_avio_ms").toFixed(2) + "ms",
      "iops",
      String(num(h, "disk_iops"))
    );
    return panel("psi", null, b, true);
  }
  function boxSlices() {
    let b = "";
    (S.slices || []).forEach((s) => {
      const cur = num(s, "current"), max = num(s, "max");
      b += max > 0 ? bar(s.name, cur / max * 100, `${mib(cur)} / ${mib(max)}`) : `<div class="r"><span class="lb">${esc(s.name)}</span><span class="mtr nolimit">no limit</span><span class="v">${mib(cur)}</span></div>`;
      b += kv(
        "pids",
        String(num(s, "pids")),
        "psi cpu",
        num(s, "cpu_psi").toFixed(2),
        "io",
        num(s, "io_psi").toFixed(2),
        "mem",
        num(s, "mem_psi").toFixed(2)
      );
    });
    return panel("watchdog \xB7 slices", String((S.slices || []).length), b, true);
  }
  function boxMesh() {
    const ms = E.machines || [];
    let b = `<div class="r hd"><span class="lb">peer</span><span class="v a">addr</span><span class="v t">kind</span></div>`;
    ms.forEach((m) => {
      const here = !!m.local;
      b += `<div class="r${here ? " here" : ""}"><span class="dot">${here ? "\u25CF" : "\xB7"}</span><span class="lb">${esc(m.name)}</span><span class="v a">${esc(m.ip || "-")}</span><span class="v t">${esc(here ? "here" : m.role || m.kind || "")}</span></div>`;
      if (m.public && m.public !== m.ip)
        b += kv("", `${m.public}${m.user ? "  " + m.user : ""}`);
    });
    return panel("mesh", ms.length + " machines", b, true);
  }
  function overview() {
    const t = MOBILE ? E.tui_narrow || E.tui : E.tui;
    if (t) return `<div class="tui-wrap">${t}</div>`;
    if (typeof S.cpu !== "number") {
      return panel(
        "overview",
        "waiting for a machine",
        "<pre>Pick a machine in the drawer, or wait for this one to answer.\n\nThe interface is here; the numbers arrive when the sampler does.</pre>",
        true
      );
    }
    return legacyOverview();
  }
  function legacyOverview() {
    return `<div class="dash"><div class="w3">${boxCpu()}</div>` + boxMem() + boxStorage() + boxNet() + boxPsi() + boxSlices() + boxMesh() + `<div class="w3">${panel(
      "processes",
      (S.proc_table || []).length + " rows",
      table(S.proc_table || [])
    )}</div></div>`;
  }
  const SCOPE = {
    world: "bad",
    mesh: "warn",
    loopback: "ok",
    running: "ok",
    exited: "bad",
    dead: "bad"
  };
  const PCT = /(^|_)(pct|percent|usage)$|%/i;
  function cell(v, col) {
    if (v === null || v === void 0 || v === "") return '<td class="nil">-</td>';
    if (typeof v === "boolean")
      return `<td><span class="pill ${v ? "ok" : "bad"}">${v}</span></td>`;
    if (typeof v === "number" && col && PCT.test(col))
      return `<td class="num">${meter(v / 100, MOBILE ? 6 : 12)}${v.toFixed(1)}%</td>`;
    if (typeof v === "number") return `<td class="num">${v}</td>`;
    if (typeof v === "object") return `<td>${esc(JSON.stringify(v))}</td>`;
    const c = SCOPE[String(v).toLowerCase()];
    return c ? `<td><span class="pill ${c}">${esc(v)}</span></td>` : `<td>${esc(v)}</td>`;
  }
  const PHONE_COLS = [
    "name",
    "user",
    "origin",
    "cpu_pct",
    "mem_pct",
    "mem_rss_bytes",
    "slice",
    // the fleet's per-network pages
    "machine",
    "addr",
    "role",
    "alias",
    "ip",
    // both firewall halves
    "port",
    "proto",
    "source",
    "state",
    "desc",
    "bind",
    "container",
    "socket",
    "declared",
    // the journal, and its 24h summary
    "section",
    "alerts_24h",
    "time",
    "unit",
    "msg",
    // about/update
    "way",
    "step",
    "why",
    "cmd",
    // the day rollup
    "date",
    "cpu_pct_avg",
    "mem_pct_avg",
    "mount",
    "pct"
  ];
  function table(rows) {
    if (!rows.length) return '<div class="panel-body"><pre>no rows</pre></div>';
    let cols = [];
    rows.forEach((r) => Object.keys(r).forEach((k) => {
      if (!cols.includes(k)) cols.push(k);
    }));
    if (MOBILE) {
      const keep = PHONE_COLS.filter((c) => cols.includes(c));
      if (keep.length >= 3) cols = keep;
    }
    return '<div class="scroll"><table><thead><tr>' + cols.map((c) => `<th>${esc(c)}</th>`).join("") + "</tr></thead><tbody>" + rows.map((r) => "<tr>" + cols.map((c) => cell(r[c], c)).join("") + "</tr>").join("") + "</tbody></table></div>";
  }
  function bridge() {
    const h = window.AndroidWatchdog;
    return h && h.refresh ? h : null;
  }
  function fleet() {
    const measured = E.measured || "local";
    const can = !!bridge();
    return (E.machines || []).map((m) => {
      const here = !!m.local;
      const target = m.alias || m.name;
      return {
        m,
        target,
        here,
        current: here ? measured === "local" || measured === target : measured === target,
        // A machine with no way in is never offered: the host you are already
        // on, and a VM declared with ip "TBD", which is in the fleet and not
        // reachable. A button that cannot work is worse than no button.
        pickable: can && !here && !!target && (m.ip || "") !== "TBD"
      };
    });
  }
  function bindPicks(root) {
    const h = bridge();
    if (!h) return;
    root.querySelectorAll("[data-alias]").forEach((el) => {
      el.onclick = () => {
        el.textContent = el.dataset.busy || "measuring\u2026";
        h.refresh(el.dataset.alias);
        closeDrawer();
      };
    });
  }
  function show(k) {
    if (k === "__overview") out.innerHTML = overview();
    else if (k === "__appmap") {
      const ns = E.app_map || [];
      const b = ns.map((n2) => `<div class="r d${n2.depth}"><span class="mk">${esc(n2.key)}</span><span class="mn">${esc(n2.name)}</span><span class="md">${esc(n2.desc)}</span></div>`).join("");
      out.innerHTML = panel(
        "app map",
        ns.length ? ns.length + " entries" : null,
        ns.length ? b : "<pre>this build shipped no map</pre>",
        true
      );
    } else if (k === "__machines") {
      const fs = fleet();
      const can = !!bridge();
      let b = `<div class="r hd"><span class="lb">machine</span><span class="v a">addr</span><span class="v t">role</span></div>`;
      fs.forEach((c) => {
        const m = c.m;
        b += `<div class="r${c.current ? " here" : ""}"><span class="dot">${c.current ? "\u25CF" : "\xB7"}</span><span class="lb">${esc(m.name)}</span><span class="v a">${esc(m.ip || m.public || "-")}</span><span class="v t">${esc(c.here ? "this host" : m.role || m.kind || "")}</span>` + (c.pickable ? `<button class="measure" data-alias="${esc(c.target)}" data-busy="measuring\u2026">measure</button>` : "") + `</div>`;
      });
      out.innerHTML = panel("machines", fs.length + (can ? " \u2014 tap to measure" : ""), b, true);
      bindPicks(out);
    } else if (k === "__rules") {
      const rs = E.rules || [];
      const cell2 = (r) => {
        if (r.fires === null || r.fires === void 0) return '<span class="f none">\u2014</span>';
        if (r.fires === 0) return '<span class="f zero">0</span>';
        return `<span class="f ${r.fires >= 100 ? "hot" : "warm"}">${r.fires}</span>`;
      };
      out.innerHTML = panel(
        "rules",
        rs.length ? "fires: last 24h" : "no disk guard on this machine",
        rs.length ? rs.map((r) => `<div class="rule"><b>${esc(r.head)}</b>` + (r.rows && r.rows.length ? '<table class="rules"><thead><tr><th>rule</th><th>triggers at</th><th class="n">fires</th><th>effect</th></tr></thead><tbody>' + r.rows.map(
          (x) => `<tr><td>${esc(x.rule)}</td><td>${esc(x.trigger)}</td><td class="n">${cell2(x)}</td><td class="e">${esc(x.effect || "")}</td></tr>`
        ).join("") + "</tbody></table>" : `<pre>${(r.lines || []).map(esc).join("\n")}</pre>`) + "</div>").join("") : "<pre>this machine declares no disk-protection policy</pre>",
        true
      );
    } else if (k === "__report")
      out.innerHTML = panel("report", null, `<pre>${esc(E.report || "")}</pre>`, true);
    else if (k === "__files") {
      const f = E.files || [];
      out.innerHTML = panel("files", f.length + " paths", `<pre>${esc(f.join("\n"))}</pre>`, true);
    } else if (k === "__raw")
      out.innerHTML = panel("raw envelope", null, `<pre>${esc(JSON.stringify(E, null, 2))}</pre>`, true);
    else {
      const rows = S[k] || [];
      out.innerHTML = panel(k, rows.length + " rows", table(rows));
    }
    if (window.innerWidth < 1e3 || MOBILE) closeDrawer();
    window.scrollTo(0, 0);
    if (MOBILE) requestAnimationFrame(fitNow);
  }
  const sb = document.getElementById("sb");
  const scrim = document.getElementById("scrim");
  function closeDrawer() {
    sb.classList.remove("open");
    scrim.classList.remove("on");
  }
  document.getElementById("ham").onclick = () => {
    sb.classList.add("open");
    scrim.classList.add("on");
  };
  document.getElementById("cls").onclick = closeDrawer;
  scrim.onclick = closeDrawer;
  document.querySelectorAll(".t").forEach((b) => {
    b.onclick = () => {
      document.querySelectorAll(".t").forEach((x) => x.classList.remove("on"));
      b.classList.add("on");
      current = b.dataset.k || "__overview";
      show(current);
    };
  });
  if (MOBILE) {
    const bar2 = document.createElement("div");
    bar2.className = "appbar";
    const ham = document.getElementById("ham");
    bar2.appendChild(ham);
    const title = document.createElement("span");
    title.className = "t";
    const h = S.host_info || {};
    title.textContent = String(h.host || "my-watchdog");
    bar2.appendChild(title);
    const age = document.createElement("span");
    age.className = "age";
    age.textContent = E.exported ? String(E.exported) : "";
    bar2.appendChild(age);
    const zoom = document.createElement("button");
    zoom.className = "zoom";
    zoom.type = "button";
    zoom.textContent = "1:1";
    zoom.setAttribute("aria-pressed", "false");
    zoom.setAttribute("aria-label", "actual size");
    bar2.appendChild(zoom);
    document.body.insertBefore(bar2, document.body.firstChild);
    const root = document.documentElement;
    const fit = () => {
      const pre = document.querySelector(".tui");
      const wrap = document.querySelector(".tui-wrap");
      if (!pre || !wrap) return;
      if (root.classList.contains("zoom1")) {
        pre.style.transform = "";
        wrap.style.height = "";
        return;
      }
      pre.style.transform = "";
      wrap.style.height = "";
      const k = Math.min(1, wrap.clientWidth / Math.max(1, pre.scrollWidth));
      pre.style.transform = `scale(${k})`;
      wrap.style.height = `${pre.offsetHeight * k}px`;
    };
    zoom.onclick = () => {
      const on = root.classList.toggle("zoom1");
      zoom.setAttribute("aria-pressed", String(on));
      zoom.textContent = on ? "fit" : "1:1";
      fit();
    };
    window.addEventListener("resize", fit);
    fitNow = fit;
  }
  function fillSwitcher() {
    const ul = document.getElementById("sw");
    if (!ul || ul.querySelector("a[href]")) return;
    const fs = fleet();
    if (!fs.length) {
      ul.innerHTML = '<li><a class="off">no fleet in this envelope</a></li>';
      return;
    }
    ul.innerHTML = fs.map((c) => `<li><a class="m${c.current ? " on" : ""}${c.pickable ? "" : " off"}"` + (c.pickable ? ` data-alias="${esc(c.target)}" data-busy="${esc(c.m.name)} \u2026"` : "") + `>${esc(c.m.name)}</a></li>`).join("");
    bindPicks(ul);
  }
  window.__wdRender = (json) => {
    let next;
    try {
      next = JSON.parse(json);
    } catch (e) {
      return false;
    }
    E = next;
    S = E.snapshot || {};
    fillSwitcher();
    show(current);
    return true;
  };
  fillSwitcher();
  show("__overview");
  if (MOBILE) requestAnimationFrame(fitNow);
})();
