(() => {
  (function() {
    "use strict";
    var LIVE = "/__api__/watchdog";
    var POLL_MS = 2e3;
    var $ = function(id) {
      return document.getElementById(id);
    };
    $("hamburger").addEventListener("click", function() {
      $("sidebar").classList.add("open");
    });
    $("close-btn").addEventListener("click", function() {
      $("sidebar").classList.remove("open");
    });
    function txt(o, path) {
      var cur = o, parts = String(path).split(".");
      for (var i = 0; i < parts.length; i++) {
        if (cur === null || typeof cur !== "object") return "";
        cur = cur[parts[i]];
      }
      return cur === void 0 || cur === null ? "" : String(cur);
    }
    function num(o, path) {
      var v = parseFloat(txt(o, path));
      return isNaN(v) ? 0 : v;
    }
    function li(k, v) {
      return "<li><span>" + k + "</span><b>" + v + "</b></li>";
    }
    function pct(v) {
      return v.toFixed(1) + "%";
    }
    function table(el, cols, rows) {
      var h = "<thead><tr>" + cols.map(function(c) {
        return "<th>" + c.h + "</th>";
      }).join("") + "</tr></thead><tbody>";
      h += rows.map(function(r) {
        return "<tr>" + cols.map(function(c) {
          var v = c.f(r);
          return "<td" + (c.num ? ' class="num"' : "") + ">" + v + "</td>";
        }).join("") + "</tr>";
      }).join("");
      el.innerHTML = h + "</tbody>";
    }
    function esc(s) {
      return String(s).replace(/[&<>"]/g, function(c) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
      });
    }
    function imageIdle(s, img) {
      var id = txt(img, "id");
      var full = txt(img, "repo") + ":" + txt(img, "tag");
      return !(s.containers || []).some(function(c) {
        var cid = txt(c, "image_id");
        if (cid && id) {
          var n = Math.min(cid.length, id.length);
          return cid.slice(0, n) === id.slice(0, n);
        }
        return txt(c, "image") === full;
      });
    }
    function render(s) {
      $("host-name").textContent = txt(s, "host_info.hostname") || "my-watchdog";
      $("host-info").innerHTML = li("kernel", esc(txt(s, "host_info.kernel"))) + li("uptime", esc(txt(s, "totals.uptime"))) + li("cpu", pct(num(s, "cpu"))) + li("mem", pct(num(s, "mem.pct"))) + li("swap", pct(num(s, "swap.pct"))) + li("load", esc(txt(s, "load1")));
      $("pressure-info").innerHTML = li("cpu some10", pct(num(s, "pressure_cpu.some.avg10"))) + li("io full10", pct(num(s, "pressure_io.full.avg10"))) + li("mem full10", pct(num(s, "pressure_memory.full.avg10")));
      var active = s.docker_daemon && s.docker_daemon.active;
      var state = txt(s, "docker_daemon.state") || "unknown";
      $("docker-info").innerHTML = li("dockerd", '<span class="pill ' + (active ? "ok" : "bad") + '">' + esc(state) + "</span>") + li("containers", (s.containers || []).length) + li("images", (s.images || []).length);
      $("listening-list").innerHTML = (s.listening || []).slice(0, 20).map(function(l) {
        return li(esc(txt(l, "port")), esc(txt(l, "proc") || txt(l, "comm")));
      }).join("") || '<li><span class="muted">nothing listening</span></li>';
      var procs = (s.proc_table || []).slice(0, 40);
      $("proc-count").textContent = "(" + (s.proc_table || []).length + ")";
      table($("procs"), [
        { h: "PID", num: true, f: function(p) {
          return esc(txt(p, "pid"));
        } },
        { h: "COMM", f: function(p) {
          return esc(txt(p, "comm"));
        } },
        { h: "CPU%", num: true, f: function(p) {
          return num(p, "cpu").toFixed(1);
        } },
        { h: "MEM MB", num: true, f: function(p) {
          return num(p, "rss_mb").toFixed(0);
        } }
      ], procs);
      var ctrs = s.containers || [];
      $("ctr-count").textContent = "(" + ctrs.length + ")";
      table($("containers"), [
        { h: "NAME", f: function(c) {
          return esc(txt(c, "name"));
        } },
        { h: "STATUS", f: function(c) {
          return esc(txt(c, "status"));
        } },
        { h: "CPU%", num: true, f: function(c) {
          return esc(txt(c, "cpu"));
        } },
        { h: "MEM", num: true, f: function(c) {
          return esc(txt(c, "mem_usage"));
        } }
      ], ctrs);
      var imgs = s.images || [];
      $("img-count").textContent = "(" + imgs.length + ")";
      table($("images"), [
        { h: "IMAGE", f: function(i) {
          return esc(txt(i, "repo") + ":" + txt(i, "tag"));
        } },
        { h: "SIZE", num: true, f: function(i) {
          return esc(txt(i, "size"));
        } },
        { h: "CREATED", f: function(i) {
          return esc(txt(i, "created"));
        } },
        { h: "IN USE", f: function(i) {
          return imageIdle(s, i) ? '<span class="muted">nothing runs this</span>' : '<span class="pill ok">in use</span>';
        } }
      ], imgs);
    }
    function status(cls, text) {
      $("status-dot").className = "dot " + cls;
      $("status-text").textContent = text;
    }
    function poll() {
      fetch(LIVE, { cache: "no-store" }).then(function(r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      }).then(function(s) {
        render(s);
        status("live", "live \xB7 " + (/* @__PURE__ */ new Date()).toLocaleTimeString());
      }).catch(function(e) {
        var fb = window.__WATCHDOG_FALLBACK__;
        if (fb) {
          render(fb);
          status("stale", "offline snapshot \xB7 " + (fb.ts ? new Date(fb.ts * 1e3).toLocaleString() : "unknown time"));
        } else {
          status("down", "no data: " + e.message);
        }
      });
    }
    poll();
    setInterval(poll, POLL_MS);
  })();
})();
