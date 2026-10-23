/*
 * Watchdog panel widget — reads ONE file, draws everything.
 *
 * The stock org.kde.plasma.systemmonitor applet is expensive, but NOT because
 * of the charts and not because reading /proc is slow — ksystemstats, which
 * actually reads it, costs 2.5%. It is that each applet instance carries a
 * sensor-face controller and its own ksystemstats subscription. Fourteen of
 * them settled at ~24% CPU and 410MB, 135MB of it QML JS heap, for eight
 * numbers.
 *
 * So the charts stay and the plumbing goes. org.kde.quickcharts is the same
 * library KSysGuard's own piechart face draws with, used here directly against
 * values from $XDG_RUNTIME_DIR/my-konsole-watchdog.json — one file the
 * my-konsole tray daemon publishes every 2s. No sensor faces, no per-applet
 * subscriptions, one sampler for the whole machine.
 *
 * `mode` picks which cluster an instance renders, so one widget serves the
 * whole panel and another metric is a config change rather than another applet.
 * The cluster COMPOSITION (title + which items, in which order) is data —
 * contents/data/clusters.json — read once at startup via XHR against
 * Qt.resolvedUrl(); main.qml supplies the kind->component mapping and the
 * metric->{value,label,fill} lookups the JSON's item entries name. Growing a
 * mode means editing that JSON, not adding another hardcoded Loader block.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.quickcharts as Charts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    property var snap: ({})
    property bool stale: true

    // freeze-guard's own PSI-voter state, published by the SYSTEM-level
    // watchdog (root-watchdog, configuration_system-protection.nix) — a
    // separate publisher from the my-konsole tray daemon above, hence its own
    // snap/stale pair and its own poll Timer below. The file will not exist
    // until a system rebuild lands the publish() change, so every access
    // below MUST be defensive (missing file / parse failure / missing
    // properties → neutral empty state, never a QML error that blanks the
    // whole applet — that regression was just fixed once already).
    property var guardSnap: ({})
    property bool guardStale: true

    readonly property int pollMs: 2000   // matches the daemon publish rate; polling faster only wastes ticks
    readonly property string runtimeDir: "/run/user/" + Plasmoid.configuration.uid
    readonly property string snapUrl: "file://" + runtimeDir + "/my-konsole-watchdog.json"
    readonly property string killPath: runtimeDir + "/my-konsole-watchdog.kill"
    readonly property string guardUrl: "file:///run/freeze-guard.json"

    // Last publisher timestamp actually applied. Assigning root.snap is what
    // invalidates every binding in this instance, so it must not happen for a
    // payload we have already shown.
    property real lastTs: -1

    function refresh() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            // Break the self-reference BEFORE any other return path.
            // `xhr` is captured by this very closure, so xhr ->
            // onreadystatechange -> closure -> xhr is a cycle, and the
            // 25KB responseText hangs off it. V4 only reclaims that on a
            // cycle-tracing pass, and the buffer is native memory the JS
            // heap never feels — so nothing ever makes the collector feel
            // urgent. Measured 2026-08-24: plasmashell's anonymous heap
            // grew 12.8 MB/h, monotonic, across seven instances polling
            // at 1.5s. Nulling the handler drops the last reference here
            // instead of whenever GC gets around to proving the cycle.
            xhr.onreadystatechange = null;
            // The callback can outlive the component: a panel edit or a shell
            // restart destroys the applet while a request is in flight, and
            // then `root` is null and every line below throws. That is the
            // 196 "TypeError: Value is null and could not be converted to an
            // object" pairs this widget logged in one session — thrown from
            // inside the catch block, so even the error path failed.
            if (!root) return;
            try {
                var d = JSON.parse(xhr.responseText);
                // Older than a few periods means the daemon died. Showing its
                // last numbers forever is how a dead publisher hides — exactly
                // what froze the Claude status line for hours.
                root.stale = ((Date.now() / 1000) - (d.ts || 0)) > 15;
                // Skip the rebind when the publisher has not moved. pollMs is
                // 1500 against a 2s publish cycle, so roughly a quarter of all
                // polls used to re-assign an identical object and invalidate
                // every binding in the applet for nothing — times seven
                // instances. Staleness above is still updated every poll,
                // because "the daemon stopped" must be noticed even when the
                // payload is unchanged.
                if (d.ts !== undefined && d.ts === root.lastTs) return;
                root.lastTs = (d.ts === undefined ? -1 : d.ts);
                root.snap = d;
            } catch (e) {
                root.stale = true;
            }
        };
        xhr.open("GET", root.snapUrl);
        xhr.send();
    }

    // Same shape as refresh() above, against freeze-guard's own snapshot.
    // On ANY failure (file absent, bad JSON, mid-write partial read) fall
    // back to an empty object + stale=true rather than throwing — the guard
    // cluster below already treats {} as "nothing to show".
    property real lastGuardTs: -1

    function refreshGuard() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            // Break the self-reference BEFORE any other return path.
            // `xhr` is captured by this very closure, so xhr ->
            // onreadystatechange -> closure -> xhr is a cycle, and the
            // 25KB responseText hangs off it. V4 only reclaims that on a
            // cycle-tracing pass, and the buffer is native memory the JS
            // heap never feels — so nothing ever makes the collector feel
            // urgent. Measured 2026-08-24: plasmashell's anonymous heap
            // grew 12.8 MB/h, monotonic, across seven instances polling
            // at 1.5s. Nulling the handler drops the last reference here
            // instead of whenever GC gets around to proving the cycle.
            xhr.onreadystatechange = null;
            if (!root) return;   // destroyed mid-flight — see refresh()
            try {
                var d = JSON.parse(xhr.responseText);
                root.guardStale = ((Date.now() / 1000) - (d.ts || 0)) > 15;
                if (d.ts !== undefined && d.ts === root.lastGuardTs) return;
                root.lastGuardTs = (d.ts === undefined ? -1 : d.ts);
                root.guardSnap = d || {};
            } catch (e) {
                root.guardStale = true;
                // Only clear if we were showing something; assigning {} over {}
                // is another needless invalidation, and this path runs on every
                // poll while the publisher is down.
                if (root.lastGuardTs !== -1) {
                    root.lastGuardTs = -1;
                    root.guardSnap = {};
                }
            }
        };
        xhr.open("GET", root.guardUrl);
        xhr.send();
    }

    // ── clusters.json: which items each mode's cluster draws, and its title.
    // Read once, synchronously, at startup — it is a small static file
    // shipped inside the plasmoid, not a value that changes at runtime like
    // snap/guardSnap above, so there is no polling Timer for it. Sync XHR
    // against a local file:// URL is supported by QML's XMLHttpRequest and
    // keeps clusterDefs populated before the first paint instead of racing an
    // async load against the compact representation's first layout pass.
    // Qt.resolvedUrl() is used (rather than the bare relative string
    // "data/clusters.json") because that string would resolve relative to
    // this file's own directory (contents/ui/), not contents/ — verified by
    // reading Qt.resolvedUrl's own resolution rules; "../data/clusters.json"
    // from contents/ui/main.qml correctly lands on contents/data/clusters.json.
    readonly property string clustersUrl: Qt.resolvedUrl("../data/clusters.json")
    property var clusterDefs: ({})

    function loadClusters() {
        var xhr = new XMLHttpRequest();
        try {
            xhr.open("GET", root.clustersUrl, false); // sync: tiny static file, once
            xhr.send();
            root.clusterDefs = JSON.parse(xhr.responseText);
        } catch (e) {
            // Missing/unparsable clusters.json must not blank the whole
            // applet — same defensive stance as refresh()/refreshGuard().
            root.clusterDefs = {};
        }
    }

    // The cluster this instance renders, keyed by Plasmoid.configuration.mode.
    // Falls back to an empty title/items pair for a mode string clusters.json
    // doesn't (yet) know about, rather than throwing.
    readonly property var currentCluster: root.clusterDefs[Plasmoid.configuration.mode] || { title: "", items: [] }

    Component.onCompleted: root.loadClusters()

    Timer {
        interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refreshGuard()
    }

    function pct(v)  { return (v === undefined ? "--" : v.toFixed(0) + "%"); }
    function two(v)  { return (v === undefined ? "--" : v.toFixed(1)); }
    function mbs(v)  { return (v === undefined ? "--" : v.toFixed(1) + "M/s"); }
    function psi(k, f) { return (snap.psi && snap.psi[k]) ? snap.psi[k][f] : undefined; }

    // Battery text for tooltip/header. `battery` is JSON `null` on a desktop
    // (no BAT* in sysfs), `{present:false}` if the kernel briefly reports no
    // cell, or the full reading otherwise. minutes_left is JSON `null`
    // whenever the daemon couldn't safely compute a rate (charging, or
    // power_now zero/absent) — never trust it to always be a number.
    function batteryText() {
        var b = root.snap.battery;
        if (!b || !b.present) return "";
        var t = "batt " + b.pct.toFixed(0) + "% " + b.status;
        if (b.minutes_left !== null && b.minutes_left !== undefined) {
            var h = Math.floor(b.minutes_left / 60);
            var m = Math.round(b.minutes_left % 60);
            t += " (" + h + "h" + m + "m left)";
        }
        return t;
    }

    // Pressure earns colour: it predicts a stall, and the reason this panel
    // exists is a machine that froze with nothing on screen saying so.
    function heat(v) {
        if (v === undefined) return Kirigami.Theme.disabledTextColor;
        if (v >= 40) return Kirigami.Theme.negativeTextColor;
        if (v >= 15) return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.positiveTextColor;
    }

    // ── freeze-guard voter helpers — every one defensive: guardSnap is {}
    // until the first successful poll, and stays {} forever on a machine
    // that hasn't rebuilt with the publish() change yet. Every accessor here
    // must degrade to "empty"/"neutral", never touch a property of undefined.
    function guardVoters() {
        return (root.guardSnap && root.guardSnap.voters) ? root.guardSnap.voters : [];
    }
    // value/threshold as a percent (100 = exactly at the kill line), fed into
    // the existing Bar component the same way the PSI bars use a 0-100 value.
    function guardRatio(v) {
        if (!v || !v.threshold) return 0;
        return (v.value || 0) / v.threshold * 100;
    }
    function guardColor(v) {
        if (!v) return Kirigami.Theme.disabledTextColor;
        if (v.armed) return Kirigami.Theme.negativeTextColor;
        return root.heat(root.guardRatio(v));
    }
    // Two-letter tags so 7 bars fit a 30px-tall panel row; falls back to the
    // full id (still short) for any voter this map hasn't been taught yet —
    // additive-safe if the JSON ever grows a voter.
    readonly property var guardShortLabels: ({
        "mem_psi_full": "Mp", "io_psi_full": "Ip", "cpu_psi_some": "Cp",
        "desktop_io_psi_full": "dI", "desktop_mem_psi_full": "dM",
        "mem_high_thrash": "Th", "write_storm": "Ws"
    })
    function shortGuardLabel(v) {
        if (!v) return "?";
        return root.guardShortLabels[v.id] || (v.id ? v.id.substring(0, 2) : "?");
    }
    // One "label  value/threshold  (Ns/Ns)" line per voter, for the tooltip.
    function guardTooltipLines() {
        var voters = root.guardVoters();
        if (!voters.length) return root.guardStale ? "freeze-guard: not publishing" : "";
        var lines = [];
        for (var i = 0; i < voters.length; i++) {
            var v = voters[i];
            if (!v) continue;
            var label = v.label || v.id || "?";
            var value = (v.value !== undefined && v.value !== null) ? Number(v.value).toFixed(1) : "--";
            var thr = (v.threshold !== undefined && v.threshold !== null) ? v.threshold : "--";
            var sus = (v.sustain !== undefined && v.sustain !== null) ? v.sustain : 0;
            var susNeed = (v.sustain_need !== undefined && v.sustain_need !== null) ? v.sustain_need : 0;
            lines.push(label + "  " + value + "/" + thr + "  (" + sus + "s/" + susNeed + "s)" + (v.armed ? "  ARMED" : ""));
        }
        return lines.join("\n");
    }

    // Short mount label for the disk bars — "/" stays "/", everything else
    // is the last path segment ("home", "boot" for "/boot").
    function shortMount(m) {
        if (!m) return "?";
        if (m === "/") return "/";
        var parts = m.split("/");
        return parts[parts.length - 1] || m;
    }

    // mem_detail ({total,used,buffers,cached,free} GiB) is what the sampler
    // is growing to emit; today's daemon only has the overall `mem` percent.
    // Fall back to a two-segment used/free ring so the pie still means
    // something instead of throwing on the missing field.
    function memLayers() {
        var m = root.snap.mem_detail;
        if (m && m.total) return [m.used || 0, m.buffers || 0, m.cached || 0, m.free || 0];
        var used = root.snap.mem || 0;
        return [used, 100 - used];
    }
    function memLayerColors() {
        var m = root.snap.mem_detail;
        if (m && m.total)
            return [Kirigami.Theme.highlightColor, Kirigami.Theme.neutralTextColor,
                    Kirigami.Theme.positiveTextColor, Kirigami.Theme.disabledTextColor];
        return [Kirigami.Theme.highlightColor, Kirigami.Theme.disabledTextColor];
    }
    // Centre number: reclaimable memory as a percent of total (free + buffers
    // + cached) / total — falls back to 100 - mem% when mem_detail is absent.
    function memCentreText() {
        var m = root.snap.mem_detail;
        if (m && m.total)
            return Math.round(((m.free || 0) + (m.buffers || 0) + (m.cached || 0)) / m.total * 100) + "%";
        return root.snap.mem !== undefined ? Math.round(100 - root.snap.mem) + "%" : "--";
    }

    // vram is JSON `null` on machines with no discrete GPU sysfs node — that
    // is normal here, not an error, so callers must treat undefined as "—".
    // Lives in the `cpu` cluster (see clusters.json) rather than its own mode:
    // it is CPU's GPU sibling, not a resource big enough to earn a panel slot
    // of its own on a machine that mostly doesn't have a discrete GPU anyway.
    function vramPct() {
        var v = root.snap.vram;
        if (!v || !v.total) return undefined;
        return (v.used / v.total) * 100;
    }

    // slice_pct is published directly today; the GiB-pair fallback covers an
    // older daemon build that hasn't been rebuilt yet.
    function slicePct() {
        if (root.snap.slice_pct !== undefined) return root.snap.slice_pct;
        if (root.snap.slice_max_gib) return (root.snap.slice_gib / root.snap.slice_max_gib) * 100;
        return undefined;
    }

    function pct0(v) { return v === undefined ? "--" : Math.round(v) + "%"; }

    // Bytes/sec -> human string for the proctable's read/write columns.
    // Matches mbs()'s one-decimal style but scales down to K/s since a lot
    // of processes sit well under 1 MB/s and "0.0M/s" for everything below
    // that would make the column useless for sorting-by-eye.
    function bps(v) {
        if (v === undefined || v === null) return "--";
        if (v >= 1048576) return (v / 1048576).toFixed(1) + "M/s";
        if (v >= 1024) return (v / 1024).toFixed(1) + "K/s";
        return Math.round(v) + "B/s";
    }

    // Bytes (absolute, not per-second) -> human string, for the RSS column.
    function bytesFmt(v) {
        if (v === undefined || v === null) return "--";
        if (v >= 1073741824) return (v / 1073741824).toFixed(1) + "G";
        if (v >= 1048576) return (v / 1048576).toFixed(0) + "M";
        if (v >= 1024) return (v / 1024).toFixed(0) + "K";
        return Math.round(v) + "B";
    }

    // ── proctable mode: sortable multi-column process table ──────────────────
    // Column set matches the `proc_table` JSON keys 1:1 so sorting is a
    // straight compare on modelData[key], never a re-derivation.
    readonly property var ptColumns: [
        { key: "name",              label: "Name",  width: 130 },
        { key: "user",              label: "User",  width: 70 },
        { key: "pid",               label: "PID",   width: 55 },
        { key: "cpu_pct",           label: "CPU%",  width: 55 },
        { key: "mem_pct",           label: "Mem%",  width: 55 },
        { key: "mem_rss_bytes",     label: "RSS",   width: 65 },
        { key: "read_bytes_per_s",  label: "Read",  width: 65 },
        { key: "write_bytes_per_s", label: "Write", width: 65 },
        { key: "runq_wait_pct",     label: "RunQ%", width: 60 }
    ]
    property string ptSortKey: "cpu_pct"
    property bool ptSortAsc: false

    // Clicking a column header is the ONLY way to sort (2026-08-11 — the
    // "Sort by" ComboBox that used to sit above the table is gone). Same key
    // toggles direction, a different key selects it descending, which is the
    // useful default for every numeric column: biggest consumer first. Every
    // column is clickable, name/user/pid included — ptSorted() compares
    // strings case-insensitively, so those sort alphabetically.
    function ptSort(key) {
        if (root.ptSortKey === key) root.ptSortAsc = !root.ptSortAsc;
        else { root.ptSortKey = key; root.ptSortAsc = false; }
    }

    // ── proctable averaging window ───────────────────────────────────────────
    // "live" | "1m" | "5m" | "15m". Only the PROCESS TABLE averages; the panel
    // clusters always show the current tick. watchdog.rs publishes each row's
    // averages as row.avg["1m"|"5m"|"15m"], each carrying the same six keys as
    // the live row, so switching window is a projection here rather than any
    // per-metric special-casing.
    readonly property var ptWindows: ["live", "1m", "5m", "15m"]
    readonly property var ptWindowLabels: ({ "live": "live", "1m": "1 min avg", "5m": "5 min avg", "15m": "15 min avg" })
    readonly property string ptWindow: {
        var w = Plasmoid.configuration.ptWindow || "live";
        return root.ptWindows.indexOf(w) === -1 ? "live" : w;
    }

    // Right-click menu: pick the window. Four flat checkable entries rather
    // than a submenu — Plasmoid.contextualActions is a flat list and four
    // entries do not need nesting. Only the proctable instance shows them;
    // every other mode renders the current tick and has nothing to switch.
    Plasmoid.contextualActions: [
        ptWindowActionLive, ptWindowAction1m, ptWindowAction5m, ptWindowAction15m
    ]
    PlasmaCore.Action {
        id: ptWindowActionLive
        text: "Show: live"
        checkable: true
        checked: root.ptWindow === "live"
        visible: Plasmoid.configuration.mode === "proctable"
        onTriggered: Plasmoid.configuration.ptWindow = "live"
    }
    PlasmaCore.Action {
        id: ptWindowAction1m
        text: "Show: 1 min avg"
        checkable: true
        checked: root.ptWindow === "1m"
        visible: Plasmoid.configuration.mode === "proctable"
        onTriggered: Plasmoid.configuration.ptWindow = "1m"
    }
    PlasmaCore.Action {
        id: ptWindowAction5m
        text: "Show: 5 min avg"
        checkable: true
        checked: root.ptWindow === "5m"
        visible: Plasmoid.configuration.mode === "proctable"
        onTriggered: Plasmoid.configuration.ptWindow = "5m"
    }
    PlasmaCore.Action {
        id: ptWindowAction15m
        text: "Show: 15 min avg"
        checkable: true
        checked: root.ptWindow === "15m"
        visible: Plasmoid.configuration.mode === "proctable"
        onTriggered: Plasmoid.configuration.ptWindow = "15m"
    }

    // One row with the selected window's numbers hoisted into the live keys.
    // Everything downstream (sorting, cell formatting, the Signal button) then
    // works on one row shape and never has to know a window was chosen.
    // A row missing its avg block — an old daemon still running, or a pid
    // sampled for the first time — falls back to the live values rather than
    // rendering blanks.
    function ptProject(row) {
        if (root.ptWindow === "live") return row;
        var a = row.avg ? row.avg[root.ptWindow] : null;
        if (!a) return row;
        return {
            pid: row.pid, name: row.name, user: row.user,
            protected: row.protected, protected_reason: row.protected_reason,
            cpu_pct: a.cpu_pct, mem_pct: a.mem_pct, mem_rss_bytes: a.mem_rss_bytes,
            read_bytes_per_s: a.read_bytes_per_s, write_bytes_per_s: a.write_bytes_per_s,
            runq_wait_pct: a.runq_wait_pct
        };
    }

    // The ListView's model reads THIS, never ptSorted() directly.
    //
    // `model: root.ptSorted()` is a binding loop: the function returns a fresh
    // array every call, so assigning it to ListView.model dirties the binding,
    // which calls the function again, which yields another new array — forever.
    // plasmashell logged "Binding loop detected for property model" several
    // times a second, in each of the 7 applet instances. Measured cost: with
    // the publisher running plasmashell sat at 83-90% of a core; with the
    // publisher stopped (so `ts` never changes and the loop is never kicked)
    // it dropped to 4%. The XHR and the 25KB JSON.parse were never the problem.
    //
    // Routing it through a plain property fixes it because a property binding
    // re-evaluates only when its own dependencies (snap, ptWindow, sort state)
    // change; the ListView merely READS the property, which cannot dirty it.
    // ...and it is EMPTY while the popup is shut. fullRepresentation is created
    // once (see the note at its declaration), so without this guard all 7 panel
    // instances rebuilt a 40-row process table on every tick for a popup nobody
    // had open. Gating on `expanded` means the rows are built only while they
    // are actually on screen; opening the popup fills it on the next poll.
    property var ptRows: root.expanded ? ptSorted() : []

    // Sorted copy of proc_table — never mutates root.snap.proc_table itself,
    // since that array is replaced wholesale by refresh() every poll and a
    // sort-in-place would race a JSON.parse landing mid-sort.
    function ptSorted() {
        // Project BEFORE sorting, so the table is ordered by the numbers it
        // actually shows — picking "15 min avg" and then sorting by live CPU%
        // would rank rows by a column nobody can see.
        var arr = (root.snap.proc_table || []).map(root.ptProject);
        var key = root.ptSortKey, asc = root.ptSortAsc;
        arr.sort(function (a, b) {
            var av = a[key], bv = b[key];
            if (typeof av === "string") {
                av = (av || "").toLowerCase();
                bv = (bv || "").toLowerCase();
            } else {
                av = av || 0;
                bv = bv || 0;
            }
            if (av < bv) return asc ? -1 : 1;
            if (av > bv) return asc ? 1 : -1;
            return 0;
        });
        return arr;
    }

    // Formatted cell text for one (row, column) pair.
    function ptCellText(row, key) {
        switch (key) {
            case "cpu_pct":
            case "runq_wait_pct": return Number(row[key] || 0).toFixed(1) + "%";
            case "mem_pct": return Number(row[key] || 0).toFixed(1) + "%";
            case "mem_rss_bytes": return root.bytesFmt(row[key]);
            case "read_bytes_per_s":
            case "write_bytes_per_s": return root.bps(row[key]);
            default: return String(row[key] !== undefined ? row[key] : "--");
        }
    }

    // ── compact-representation sizing — the actual bug being fixed. Every
    // pie/bar/font size below derives from contentH instead of a fixed pixel
    // number, so the widget fits whatever thickness the panel gives it
    // (44px top / 60px bottom here, see panels.json)
    // instead of overflowing/overlapping at a size nobody chose.
    //
    // availH is the height the panel containment actually granted the
    // COMPACT REPRESENTATION instance — not root.height. root is the
    // PlasmoidItem, and in a panel the PlasmoidItem's own height is not
    // reliably the panel thickness; the item the containment layout actually
    // sizes to the panel is compactRepresentation (compactRoot below). A
    // Binding down in compactRepresentation pushes compactRoot.height into
    // this property, one-way, so nothing here reads back from a size this
    // same property influences — contentH must never feed something that
    // feeds availH, or it becomes the exact feedback loop that was here
    // before (implicitHeight computed from contentH, contentH computed from
    // the height implicitHeight was supposed to inform).
    property int availH: 0
    readonly property real titleH: Math.max(9, Math.round(Kirigami.Theme.smallFont.pixelSize * 1.2))
    readonly property real clusterSpacing: 2
    // The Math.max floor is load-bearing, not decorative, on TWO counts:
    // first frame availH is still 0 (the Binding below hasn't fired yet), so
    // without a floor this would go negative before any panel geometry
    // exists at all. Second, KDE bug 489307 is the same failure mode at a
    // nonzero-but-small panel thickness — a chart-style widget's rendered
    // size collapsing to zero, so the widget occupies no visible space
    // rather than merely looking small. panels.json documents that
    // incident; this floor exists so this widget cannot repeat it no matter
    // how thin a panel someone picks, or how early this binding evaluates.
    readonly property real contentH: Math.max(16, root.availH - root.titleH - root.clusterSpacing)
    readonly property real fontPt: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize, root.contentH / 4))

    // ── pie, the same element KSysGuard's piechart face uses ─────────────────
    component Pie : Item {
        id: pie
        property string label: ""
        property real value: 0
        property color fill: Kirigami.Theme.highlightColor
        property real size: 26   // floor/default; callers bind this to root.contentH
        implicitWidth: Math.max(16, size)
        implicitHeight: Math.max(16, size)

        Charts.PieChart {
            anchors.fill: parent
            range { from: 0; to: 100; automatic: false }
            valueSources: Charts.SingleValueSource { value: pie.value }
            colorSource: Charts.SingleValueSource { value: pie.fill }
            backgroundColor: Kirigami.Theme.backgroundColor
            thickness: Math.max(3, pie.size * 0.19)
            filled: false
        }
        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: pie.label
            font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize - 1, pie.size / 4))
            opacity: 0.9
        }
    }

    // ── layered pie: several segments in one ring, e.g. mem used/buffers/
    // cached/free. Chart.IndexAllValues treats a single ArraySource's array
    // as one segment per entry instead of one source per segment — confirmed
    // against Chart/ArraySource/PieChart in kquickcharts' QuickCharts.qmltypes.
    component MultiPie : Item {
        id: mpie
        property string label: ""
        property var values: []
        property var colors: []
        property real size: 26   // floor/default; callers bind this to root.contentH
        implicitWidth: Math.max(16, size)
        implicitHeight: Math.max(16, size)

        Charts.PieChart {
            anchors.fill: parent
            range { automatic: true }
            indexingMode: Charts.Chart.IndexAllValues
            valueSources: [ Charts.ArraySource { array: mpie.values } ]
            colorSource: Charts.ArraySource { array: mpie.colors }
            backgroundColor: Kirigami.Theme.backgroundColor
            thickness: Math.max(3, mpie.size * 0.19)
            filled: false
        }
        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: mpie.label
            font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize - 1, mpie.size / 4))
            opacity: 0.9
        }
    }

    // ── horizontal bar, for the PSI/guard/disk grids ──────────────────────────
    component Bar : RowLayout {
        id: bar
        property string label: ""
        property real value: 0
        property color fill: Kirigami.Theme.highlightColor
        property real barWidth: 30    // floor/default; callers bind these off contentH
        property real barHeight: 6
        // Width reserved for the label, so every bar in a grid STARTS at the
        // same x. Without it the label is sized to its own text and a grid of
        // "nix" / "shared-lib" / "kali-root" staircases its bars rightward,
        // which makes the fills impossible to compare by eye — the one thing
        // a column of bars is for. The caller measures the widest label in
        // the grid (see bargridLabelW) and passes it to every row.
        property real labelW: 0
        // Total vertical budget for this row, set by the caller from the
        // available height divided by the number of grid rows. It exists
        // because barHeight alone never controlled the row: a RowLayout is as
        // tall as its TALLEST child, and the label below has a text height
        // that ignores barHeight entirely. On the 2-row grids (psi 6/3,
        // guard 8/4) a 6pt label measured ~13px against a ~10px budget, so
        // two rows overran the panel and the second was sliced off by the
        // panel edge — visible as half-height "Fc Fi Fm" / "dM Th Ws".
        property real rowH: 12
        // Optional reading rendered after the bar. Empty for grids where the
        // fill IS the reading (disk usage, guard voters); set for PSI, whose
        // real values are too small to see as a fill.
        property string valueText: ""
        // How full to draw, 0..1. Negative means "derive it linearly from
        // value", which is right for every grid whose values genuinely span
        // 0-100 (disk usage, guard voters). PSI passes an explicit log-scaled
        // fraction instead — see psiFraction().
        property real fraction: -1
        readonly property real fillRatio: bar.fraction >= 0
            ? bar.fraction
            : Math.max(0, Math.min(1, bar.value / 100))
        Layout.preferredHeight: bar.rowH
        Layout.maximumHeight: bar.rowH
        spacing: 3
        PlasmaComponents.Label {
            text: bar.label
            // pixelSize, not pointSize: the budget being fitted is in pixels,
            // and pointSize goes through DPI scaling that can silently land
            // above it. Floor of 7px keeps the label legible; below that the
            // grid genuinely does not fit and clipping the text is the honest
            // outcome.
            font.pixelSize: Math.max(6, Math.round(bar.rowH * 0.8))
            Layout.preferredHeight: bar.rowH
            Layout.preferredWidth: bar.labelW > 0 ? bar.labelW : implicitWidth
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            opacity: 0.75
        }
        Rectangle {
            Layout.preferredWidth: Math.max(14, bar.barWidth)
            Layout.preferredHeight: Math.max(4, bar.barHeight)
            radius: 2
            color: Kirigami.Theme.backgroundColor
            border { color: Kirigami.Theme.disabledTextColor; width: 1 }
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                // A non-zero reading always paints at least 2px. Rounding a
                // real-but-small value down to an empty bar is what made the
                // PSI grid look like a dead publisher.
                width: bar.fillRatio <= 0
                    ? 0
                    : Math.max(2, bar.fillRatio * (parent.width - 2))
                radius: 1
                color: bar.fill
                // Deliberately not animated: a 2s sample eased over 2s is a
                // repaint every frame, which is the cost being removed.
            }
        }
        PlasmaComponents.Label {
            visible: bar.valueText !== ""
            text: bar.valueText
            font.pixelSize: Math.max(6, Math.round(bar.rowH * 0.8))
            Layout.preferredHeight: bar.rowH
            verticalAlignment: Text.AlignVCenter
            opacity: 0.9
        }
    }

    // ── metric lookups — clusters.json items name a "metric" id; these
    // functions are the other half of that data-driven split: JSON says
    // WHICH items a mode shows and in what order, these say what a given
    // metric id actually reads off snap/guardSnap and how to render it.
    function pieMetric(metric) {
        switch (metric) {
            case "cpu": return { value: root.snap.cpu || 0, label: root.pct0(root.snap.cpu), fill: root.heat(root.snap.cpu) };
            case "vram": {
                var v = root.vramPct();
                return { value: v || 0, label: v !== undefined ? root.pct0(v) : "--",
                         fill: v !== undefined ? root.heat(v) : Kirigami.Theme.disabledTextColor };
            }
            case "swap": return { value: root.snap.swap || 0, label: root.pct0(root.snap.swap), fill: root.heat(root.snap.swap) };
            case "slice": {
                var s = root.slicePct();
                return { value: s || 0, label: root.pct0(s), fill: root.heat(s) };
            }
            // Headline for the storage cluster: how full the pool is overall.
            // Summed BYTES, not the mean of the per-mount percentages —
            // averaging percentages weights a 90MB /boot/efi the same as a
            // 116GB /mnt/shared-lib and reports a number no disk actually has.
            case "storage_pool": {
                var p = root.storagePoolPct();
                return { value: p || 0, label: p !== undefined ? root.pct0(p) : "--",
                         fill: p !== undefined ? root.heat(p) : Kirigami.Theme.disabledTextColor };
            }
            // Headline for PSI: CPU some-pressure over 10s. The grid below
            // carries every category and window; this is the one number worth
            // reading at a glance. Value is the log fraction so the ring moves
            // on the same scale the bars do; the label is the real figure.
            case "psi_cpu": {
                var pv = root.psi("cpu", "some10");
                return { value: root.psiFraction(pv) * 100, label: root.psiText(pv),
                         fill: pv !== undefined ? root.heat(Math.min(100, pv * 8)) : Kirigami.Theme.disabledTextColor };
            }
            // Headline for the guard cluster: the CLOSEST any voter is to its
            // kill threshold. A mean would hide the one voter about to fire
            // behind seven idle ones, and the only question this cluster
            // answers is "how close is the machine to being frozen out".
            case "guard_worst": {
                var voters = root.guardVoters();
                if (!voters.length) return { value: 0, label: "--", fill: Kirigami.Theme.disabledTextColor };
                var worst = 0, armed = false;
                for (var gi = 0; gi < voters.length; gi++) {
                    var r = root.guardRatio(voters[gi]);
                    if (r > worst) worst = r;
                    if (voters[gi].armed) armed = true;
                }
                return { value: Math.min(100, worst), label: root.pct0(worst),
                         fill: armed ? Kirigami.Theme.negativeTextColor : root.heat(worst) };
            }
            default: return { value: 0, label: "--", fill: Kirigami.Theme.disabledTextColor };
        }
    }
    function multiPieMetric(metric) {
        switch (metric) {
            case "mem": return { values: root.memLayers(), colors: root.memLayerColors(), label: root.memCentreText() };
            default: return { values: [], colors: [], label: "--" };
        }
    }
    // Fixed sub-metrics of the PSI 3x2 grid — structurally the same kind of
    // small labeled table as ptColumns/signalList/guardShortLabels above,
    // not a magic-number list: it names the 6 (category, avg10-field) pairs
    // PSI has, which is not itself something clusters.json's generic
    // {kind,metric} item schema can express any more cheaply.
    // PSI as text, because PSI as a bar is unreadable on a healthy machine:
    // a typical idle reading is 0.02%, which fills 1/5000th of the bar — the
    // grid rendered six empty outlines and looked broken rather than calm.
    // Two decimals below 10 so the normal range stays legible, whole numbers
    // above it where the bar carries the message anyway. "--" (not "0.00")
    // when the field is genuinely absent, so a missing publisher never
    // masquerades as zero pressure.
    function psiText(v) {
        if (v === undefined || v === null) return "--";
        return v >= 10 ? v.toFixed(0) : v.toFixed(2);
    }
    // Pool fill across every mounted filesystem, by BYTES. See the
    // "storage_pool" case above for why this is not a mean of percentages.
    function storagePoolPct() {
        var d = root.snap.disks;
        if (!d || !d.length) return undefined;
        var used = 0, total = 0;
        for (var i = 0; i < d.length; i++) {
            used += d[i].used_gib || 0;
            total += d[i].total_gib || 0;
        }
        return total > 0 ? used / total * 100 : undefined;
    }
    // Load average expressed against the core count: load 8 on 8 cores is
    // 100%, not "8". The raw figure is meaningless without knowing the width
    // of the machine, and the widget already knows it from cores.length.
    function coreCount() {
        return (root.snap.cores && root.snap.cores.length) ? root.snap.cores.length : 1;
    }
    function loadPct(l) {
        return l === undefined ? undefined : (l / root.coreCount() * 100);
    }
    // How full to draw a PSI bar. NOT value/100: pressure is a quantity whose
    // entire interesting range lives in its first percent, so a linear bar is
    // blank at 0.12% and blank at 1.2% — it cannot distinguish "idle" from
    // "starting to hurt", which is the only thing the bar is for. This is a
    // log decade scale instead: 0.01% empty, 0.1% a quarter, 1% half, 10%
    // three quarters, 100% full. Each quarter of the bar is one order of
    // magnitude. The exact number is printed alongside by psiText(), so the
    // bar is the at-a-glance shape and the text is the reading.
    function psiFraction(v) {
        if (!v || v <= 0.01) return 0;
        var f = (Math.log(v) / Math.LN10 + 2) / 4;   // 0.01% -> 0, 100% -> 1
        return Math.max(0, Math.min(1, f));
    }
    // PSI grid: some/full x cpu/io/mem x 1min/5min. The 10s window is not
    // here — it is the headline pie, so the grid is the trend rather than a
    // second copy of "now". Row 1 is every SOME reading, row 2 every FULL,
    // so a glance down a column compares "some tasks stalled" against "every
    // task stalled" for the same resource and window.
    // Labels are <resource><minutes>: c1 = cpu over 1 min.
    readonly property var psiRows: [
        { label: "c1", cat: "cpu",    field: "some60"  },
        { label: "c5", cat: "cpu",    field: "some300" },
        { label: "i1", cat: "io",     field: "some60"  },
        { label: "i5", cat: "io",     field: "some300" },
        { label: "m1", cat: "memory", field: "some60"  },
        { label: "m5", cat: "memory", field: "some300" },
        { label: "c1", cat: "cpu",    field: "full60"  },
        { label: "c5", cat: "cpu",    field: "full300" },
        { label: "i1", cat: "io",     field: "full60"  },
        { label: "i5", cat: "io",     field: "full300" },
        { label: "m1", cat: "memory", field: "full60"  },
        { label: "m5", cat: "memory", field: "full300" }
    ]
    // Memory breakdown as bars rather than only a ring: the ring shows the
    // proportions, these show the absolute GiB behind them. Swap rides in the
    // same grid because it is the same question (what is resident where) and
    // a separate cluster for two numbers is not worth a panel slot.
    function memRows() {
        var m = root.snap.mem_detail || {};
        var s = root.snap.swap_detail || {};
        var t = m.total || 0;
        var st = s.total || 0;
        var pctOf = function (v, tot) { return tot > 0 ? (v || 0) / tot * 100 : 0; };
        return [
            { label: "used",  value: pctOf(m.used, t),      text: root.gib(m.used),   fill: root.heat(pctOf(m.used, t)) },
            { label: "cache", value: pctOf(m.cached, t),    text: root.gib(m.cached), fill: Kirigami.Theme.positiveTextColor },
            { label: "buff",  value: pctOf(m.buffers, t),   text: root.gib(m.buffers), fill: Kirigami.Theme.neutralTextColor },
            { label: "free",  value: pctOf(m.free, t),      text: root.gib(m.free),   fill: Kirigami.Theme.disabledTextColor },
            { label: "swap",  value: pctOf(s.used, st),     text: root.gib(s.used),   fill: root.heat(pctOf(s.used, st)) }
        ];
    }
    function gib(v) { return v === undefined ? "--" : Number(v).toFixed(1) + "G"; }

    // Why the CPU is busy, not just how much. A single busy percentage cannot
    // tell a machine pegged in userspace apart from one drowning in iowait,
    // and those want opposite responses from whoever is reading the panel.
    //
    // Fed by cpu_detail, published by watchdog.rs from the per-mode columns of
    // /proc/stat against the SAME two samples the aggregate uses, so these
    // always sum to the busy figure beside them. Returns [] when the field is
    // absent — an older daemon — and the bargrid then renders nothing rather
    // than a row of confident zeroes.
    function cpuRows() {
        var c = root.snap.cpu_detail;
        if (!c) return [];
        var mk = function (label, v, fill) {
            return { label: label, value: v || 0, text: root.pct1(v), fill: fill };
        };
        return [
            mk("usr", c.user,   Kirigami.Theme.highlightColor),
            mk("sys", c.system, Kirigami.Theme.neutralTextColor),
            mk("io",  c.iowait, Kirigami.Theme.negativeTextColor),
            mk("nice", c.nice,  Kirigami.Theme.positiveTextColor),
            mk("irq", c.irq,    Kirigami.Theme.disabledTextColor),
            mk("stl", c.steal,  Kirigami.Theme.disabledTextColor)
        ];
    }
    function pct1(v) { return v === undefined ? "--" : Number(v).toFixed(1); }
    function bargridModel(metric) {
        switch (metric) {
            case "disks":
                return (root.snap.disks || []).map(function (d) {
                    return { label: root.shortMount(d.mount), value: d.pct || 0,
                             fill: root.heat(d.pct), text: root.pct0(d.pct) };
                });
            case "mem_break": return root.memRows();
            case "cpu_break": return root.cpuRows();
            // One vertical-ish bar per core. Same Bar component, just fed the
            // per-core percentages the daemon already publishes in `cores`.
            case "cores":
                return (root.snap.cores || []).map(function (c, i) {
                    return { label: String(i), value: c || 0, fill: root.heat(c) };
                });
            case "psi":
                return root.psiRows.map(function (r) {
                    var v = root.psi(r.cat, r.field);
                    return {
                        label: r.label, value: v || 0, fill: root.heat(v),
                        text: root.psiText(v), fraction: root.psiFraction(v)
                    };
                });
            case "guard":
                return root.guardVoters().map(function (v) {
                    return { label: root.shortGuardLabel(v), value: root.guardRatio(v), fill: root.guardColor(v) };
                });
            default: return [];
        }
    }
    // Per-row bar height for a bargrid: rows are computed from the actual
    // item count and column count (never assumed), then contentH is divided
    // across them — this is what keeps the psi 3x2 / guard 4-col grids
    // inside the panel instead of overflowing it.
    // Height budget for ONE row of a bargrid: the content height minus the
    // 1px rowSpacing between rows, split evenly. Every element of a row —
    // label text included — is sized from this, so `rows * bargridRowH` can
    // never exceed contentH and a multi-row grid cannot overflow the panel.
    // NO floor on the result. A floor is what a height budget cannot have:
    // clamping rowH up to a minimum re-creates the overflow this function
    // exists to prevent the moment rows * minimum exceeds contentH — which
    // storage (3 mounts, 1 column) does at a 44px panel. If the arithmetic
    // says 6px per row, 6px per row is what fits; the fix for illegibly thin
    // rows is a taller panel or fewer rows, not a number that lies.
    // Width to reserve for every label in a grid, so the bars all START at
    // the same x instead of staircasing right behind labels of different
    // lengths ("nix" vs "shared-lib" vs "kali-root").
    //
    // Estimated from the longest label's character count, NOT measured with
    // TextMetrics. A shared TextMetrics is the obvious way to do this and is
    // wrong here: writing its text/font inside a binding that also reads its
    // advanceWidth makes the binding depend on something it mutates, and QML
    // detects the loop and drops the binding ("Binding loop detected for
    // property implicitWidth"). 0.62em per character is a good enough
    // approximation for the short lowercase labels these grids use, and the
    // Label elides anyway if a real string overshoots.
    function bargridLabelW(metric, columns) {
        var rows = root.bargridModel(metric);
        var maxChars = 0;
        for (var i = 0; i < rows.length; i++) {
            var n = (rows[i].label || "").length;
            if (n > maxChars) maxChars = n;
        }
        // 0.78em per character, not the 0.62 an average lowercase glyph
        // measures: these labels are capitals and digits ("Mp", "Wp", "c1"),
        // which sit at the wide end of the font, and a label that overshoots
        // its reservation elides to "…" rather than pushing the bar — losing
        // the very thing the column is labelled with. Erring wide costs a few
        // pixels of gap; erring narrow costs the label.
        var fontPx = Math.max(6, Math.round(root.bargridRowH(metric, columns) * 0.8));
        return Math.ceil(maxChars * fontPx * 0.78) + 4;
    }
    function bargridRowH(metric, columns) {
        var count = root.bargridModel(metric).length;
        var cols = Math.max(1, columns || 1);
        var rows = Math.max(1, Math.ceil(count / cols));
        return Math.max(1, (root.contentH - (rows - 1)) / rows);
    }
    // The bar rectangle itself sits inside that row budget, leaving room for
    // the label's ascender/descender either side of it.
    function bargridBarHeight(metric, columns) {
        return Math.max(4, root.bargridRowH(metric, columns) * 0.55);
    }
    function rateItems(metric) {
        switch (metric) {
            case "disk_io": return [ { label: "R ", text: root.mbs(root.snap.disk_r) }, { label: "W ", text: root.mbs(root.snap.disk_w) } ];
            case "net_io": return [ { label: "↓", text: root.mbs(root.snap.net_rx) }, { label: "↑", text: root.mbs(root.snap.net_tx) } ];
            default: return [];
        }
    }
    // Truncate to n characters with an ellipsis. Panel widgets must never let
    // daemon-supplied strings size them (2026-09-02: a long process name in
    // proctable_head overflowed the whole top panel).
    function clip(str, n) {
        var v = String(str === undefined || str === null ? "" : str);
        return v.length > n ? v.slice(0, n - 1) + "…" : v;
    }
    function textMetric(metric) {
        switch (metric) {
            // Raw load plus what it means on THIS machine. "1.84" says
            // nothing without the core count; "1.84 (23%)" does, and the
            // widget already knows the width from cores.length. The percent
            // is of the 1-minute figure — the one that moves.
            case "load": {
                var p = root.loadPct(root.snap.load1);
                return root.two(root.snap.load1) + " " + root.two(root.snap.load5) + " " + root.two(root.snap.load15)
                     + (p === undefined ? "" : "  " + p.toFixed(0) + "% of " + root.coreCount() + "c");
            }
            case "proctable_head": {
                var t = root.snap.proc_table;
                if (!t || !t.length || !t[0]) return "procs --";
                // .toFixed() on an absent/null cpu_pct throws, which blanks
                // the whole binding — every other accessor in this file is
                // defensive (`|| 0`), this one needs to be too.
                // A process name is UNBOUNDED — comm is 15 chars but a
                // cmdline-derived name is not, and this box runs things like
                // "ld-linux-x86-64.so.2" and full /nix/store paths. Left
                // unbounded it reached compactRoot.Layout.minimumWidth (via
                // content.implicitWidth) and the applet demanded the whole
                // panel, pushing every other widget off the bar. Cap it here;
                // textDelegate elides as the second line of defence.
                return root.clip(t[0].name || "?", 14) + " " + Number(t[0].cpu_pct || 0).toFixed(0) + "%";
            }
            default: return "";
        }
    }

    // Every signal the daemon accepts. A process table that can only destroy is
    // a blunt instrument — STOP freezes a runaway without losing its state,
    // which on this box is usually the right first move, and HUP reloads a
    // daemon rather than ending it.
    readonly property var signalList: [
        { sig: "TERM", label: "Term — ask it to exit" },
        { sig: "INT",  label: "Int — as if Ctrl-C" },
        { sig: "HUP",  label: "HUP — reload / hangup" },
        { sig: "QUIT", label: "Quit — exit + core dump" },
        { sig: "STOP", label: "Stop — freeze, keep state" },
        { sig: "CONT", label: "Cont — resume a stopped one" },
        { sig: "USR1", label: "USR1 — application-defined" },
        { sig: "KILL", label: "Kill — unignorable, no cleanup" }
    ]

    // QML cannot signal a process. Handing a panel widget an exec path is worse
    // than handing the daemon a mailbox: the daemon runs as this user, so it
    // can only ever signal what the user already could.
    //
    // Writing to that mailbox is its own problem: QML's XMLHttpRequest against
    // a file:// URL only ever supports GET in Qt's implementation — there is
    // no writable file scheme handler, so a PUT here silently does nothing
    // and every signal request would vanish. The executable data engine is
    // the supported way a plasmoid runs a shell command; used here only to
    // append a line, never to run anything built from unsanitised input.
    Plasma5Support.DataSource {
        id: killWriter
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName) => disconnectSource(sourceName)
    }

    function sendSignal(pid, sig) {
        var cmd = "printf '%s %s\\n' '" + pid + "' '" + sig + "' >> '" + root.killPath + "'";
        killWriter.connectSource(cmd);
    }

    preferredRepresentation: compactRepresentation

    compactRepresentation: MouseArea {
        id: compactRoot
        // Width is genuinely content-driven — the panel gives a horizontal
        // applet whatever width it asks for, so implicitWidth stays derived
        // from the rendered content below.
        implicitWidth: content.implicitWidth
        // A panel containment sizes an applet from the Layout attached
        // properties of its compact representation; implicitWidth alone is
        // not enough for a MouseArea root. Without these, every watchdog
        // instance was allotted the layout minimum -- effectively zero -- so
        // all five left-hand instances piled into ~300px at the panel's left
        // edge and drew their pies and labels on top of one another, while
        // the rest of the panel sat empty (screenshotted 2026-08-11).
        Layout.minimumWidth: content.implicitWidth
        Layout.preferredWidth: content.implicitWidth
        // Height is NOT content-driven: the panel containment dictates it
        // (44px top / 60px bottom), and the widget must not fight that by
        // asking for a height computed from its own content — that was the
        // circular binding (implicitHeight -> contentH -> availH ->
        // compactRoot.height -> implicitHeight) that reproduced the exact
        // overflow this widget exists to fix. No implicitHeight binding
        // here at all; a small constant floor only matters before the panel
        // has assigned any geometry (e.g. a desktop-widget preview), and
        // even then it must not reference contentH/availH.
        implicitHeight: 16
        onClicked: root.expanded = !root.expanded

        // One-way: pushes the height the panel containment actually granted
        // THIS item into root.availH, which contentH (above) derives from.
        // `when: compactRoot.height > 0` keeps a stale/zero read from ever
        // landing during the brief window before the panel has laid this
        // item out; until then contentH's own floor (16) covers rendering.
        Binding {
            target: root
            property: "availH"
            value: compactRoot.height
            when: compactRoot.height > 0
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            spacing: root.clusterSpacing
            opacity: root.stale ? 0.45 : 1.0

            // Per-cluster title, small and low-opacity — every mode gets
            // one now instead of the old bare row of pies/bars.
            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.currentCluster.title || ""
                font.pointSize: Math.max(6, Math.min(Kirigami.Theme.smallFont.pointSize - 1, root.titleH * 0.7))
                opacity: 0.6
                elide: Text.ElideRight
            }

            RowLayout {
                id: itemsRow
                Layout.alignment: Qt.AlignHCenter
                spacing: 6

                // One mode's cluster is one array of {kind, metric, columns?}
                // items from clusters.json; kind picks which Component below
                // renders it, metric picks which snap/guardSnap field(s) it
                // reads via the metric-lookup functions above.
                Repeater {
                    model: root.currentCluster.items || []
                    delegate: Loader {
                        id: itemLoader
                        readonly property var itemDef: modelData
                        sourceComponent: {
                            switch (itemDef.kind) {
                                case "pie": return pieDelegate;
                                case "multipie": return multipieDelegate;
                                case "bargrid": return bargridDelegate;
                                case "rate": return rateDelegate;
                                case "text": return textDelegate;
                                default: return null;
                            }
                        }

                        Component {
                            id: pieDelegate
                            Pie {
                                readonly property var m: root.pieMetric(itemLoader.itemDef.metric)
                                label: m.label; value: m.value; fill: m.fill
                                size: root.contentH
                            }
                        }
                        Component {
                            id: multipieDelegate
                            MultiPie {
                                readonly property var m: root.multiPieMetric(itemLoader.itemDef.metric)
                                label: m.label; values: m.values; colors: m.colors
                                size: root.contentH
                            }
                        }
                        Component {
                            id: bargridDelegate
                            GridLayout {
                                id: bargrid
                                // The Repeater's model is a COUNT, not the array.
                                //
                                // bargridModel() .map()s a brand-new array of
                                // brand-new objects on every call, so an array
                                // model is a *different* model every tick, and a
                                // Repeater answers a new model by destroying and
                                // rebuilding every delegate -- 8 bars x 7 panel
                                // instances, twice a second, just to redraw the
                                // same 8 bars with new numbers.
                                //
                                // A count is equal across ticks, so the Bars
                                // survive and only the leaf bindings that read
                                // rows[index] re-evaluate. The widget reads; it
                                // does not rebuild.
                                readonly property var rows: root.bargridModel(itemLoader.itemDef.metric)
                                columns: Math.max(1, itemLoader.itemDef.columns || 1)
                                rowSpacing: 1
                                columnSpacing: 5
                                Repeater {
                                    model: bargrid.rows.length
                                    delegate: Bar {
                                        // rows can shrink between ticks (a disk
                                        // unmounts, a voter drops out); guard so a
                                        // briefly-stale index reads an empty row
                                        // rather than undefined.
                                        readonly property var row: bargrid.rows[index] || ({})
                                        label: row.label || ""
                                        value: row.value || 0
                                        fill: row.fill || "transparent"
                                        rowH: root.bargridRowH(itemLoader.itemDef.metric, itemLoader.itemDef.columns || 1)
                                        labelW: root.bargridLabelW(itemLoader.itemDef.metric, itemLoader.itemDef.columns || 1)
                                        valueText: row.text || ""
                                        fraction: row.fraction === undefined ? -1 : row.fraction
                                        barHeight: root.bargridBarHeight(itemLoader.itemDef.metric, itemLoader.itemDef.columns || 1)
                                        barWidth: Math.max(18, root.contentH * 1.6)
                                    }
                                }
                            }
                        }
                        Component {
                            id: rateDelegate
                            RowLayout {
                                id: rateRow
                                // Count model, same reason as bargrid above.
                                readonly property var rows: root.rateItems(itemLoader.itemDef.metric)
                                spacing: 4
                                Repeater {
                                    model: rateRow.rows.length
                                    delegate: PlasmaComponents.Label {
                                        readonly property var row: rateRow.rows[index] || ({})
                                        text: (row.label || "") + (row.text || "")
                                        font.pointSize: root.fontPt
                                    }
                                }
                            }
                        }
                        Component {
                            id: textDelegate
                            PlasmaComponents.Label {
                                text: root.textMetric(itemLoader.itemDef.metric)
                                font.pointSize: root.fontPt
                                // compactRoot feeds content.implicitWidth into
                                // its own Layout.minimumWidth, so an unelided
                                // Label here is a direct lever on how much
                                // panel this applet claims — and minimumWidth
                                // means the panel CANNOT shrink it back. Cap
                                // the claim and elide inside it.
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }

    // ── expanded: process table, every signal available ──────────────────────
    fullRepresentation: PlasmaExtras.Representation {
        // 26 gridUnits fits the simple (name/rss/pid/Signal) list every
        // other mode uses; proctable's 9 columns (8 + RSS) + a Signal button
        // need more — widened rather than made
        // mode-conditional since fullRepresentation is created once and
        // Loader.active can't retroactively resize it.
        Layout.minimumWidth: Plasmoid.configuration.mode === "proctable"
            ? Kirigami.Units.gridUnit * 46 : Kirigami.Units.gridUnit * 26
        Layout.minimumHeight: Kirigami.Units.gridUnit * 22

        header: PlasmaExtras.PlasmoidHeading {
            contentItem: PlasmaComponents.Label {
                text: root.stale
                    ? "watchdog daemon is not publishing"
                    : "slice " + root.two(root.snap.slice_gib) + " / " + root.two(root.snap.slice_max_gib) + " GiB"
                      + "   ·   load " + root.two(root.snap.load1) + " " + root.two(root.snap.load5) + " " + root.two(root.snap.load15)
                      + "   ·   net ↓" + root.mbs(root.snap.net_rx) + " ↑" + root.mbs(root.snap.net_tx)
                      + (root.batteryText() ? "   ·   " + root.batteryText() : "")
                elide: Text.ElideRight
            }
        }

        // Non-proctable instances (storage/mem/cpu/network/psi/guard) keep
        // the simple RSS-sorted list this always had — the rich sortable
        // table below is gated to mode==="proctable" only, same
        // Loader-on-mode pattern the compact clusters used to use.
        Loader {
            anchors.fill: parent
            // Also gated on `expanded`: fullRepresentation is created on first
            // open and then kept alive, so without this the list below keeps
            // replacing its array model every tick for a popup nobody is
            // looking at.
            active: root.expanded && Plasmoid.configuration.mode !== "proctable"
            visible: active
            sourceComponent: ListView {
                id: procList
                model: root.snap.procs || []
                clip: true
                spacing: 2
                delegate: RowLayout {
                    id: procRow
                    // The inner Repeater below (over signalList) has its own
                    // modelData/index that shadow this delegate's — reading
                    // procList.model[index] inside onTriggered used the SIGNAL
                    // list's index against the PROCESS list, sending a signal to
                    // whatever pid happened to sit at that row instead of the one
                    // the menu was opened on. Capture the pid up front instead.
                    property int procPid: modelData.pid
                    width: procList.width
                    spacing: 6
                    PlasmaComponents.Label { text: modelData.name; Layout.fillWidth: true; elide: Text.ElideRight }
                    PlasmaComponents.Label { text: modelData.rss + "M"; opacity: 0.85 }
                    PlasmaComponents.Label { text: modelData.pid; opacity: 0.5 }
                    PlasmaComponents.Button {
                        text: "Signal"
                        icon.name: "process-stop"
                        onClicked: sigMenu.open()
                        PlasmaComponents.Menu {
                            id: sigMenu
                            Repeater {
                                model: root.signalList
                                delegate: PlasmaComponents.MenuItem {
                                    text: modelData.label
                                    onTriggered: root.sendSignal(procRow.procPid, modelData.sig)
                                }
                            }
                        }
                    }
                }
            }
        }

        // proctable mode: sortable multi-column table over `proc_table`
        // (pid/name/user/cpu/mem/rss/read/write/runq_wait), clickable
        // headers with a hover highlight and a ▲/▼ direction indicator.
        // Clicking a header is the only sort control; the "Sort by" ComboBox
        // that used to sit above the table was removed 2026-08-11 by request.
        // Each row also carries a per-row Signal menu offering every signal
        // in signalList — disabled with the reason shown when the daemon
        // marked the row `protected` (pid 1 / a protected slice), so a user
        // sees WHY a row can't be killed instead of a silent no-op.
        Loader {
            anchors.fill: parent
            active: Plasmoid.configuration.mode === "proctable"
            visible: active
            sourceComponent: ColumnLayout {
                spacing: 4

                RowLayout {
                    id: ptHeader
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.ptColumns
                        delegate: Item {
                            id: ptHeaderCell
                            Layout.preferredWidth: modelData.width
                            implicitHeight: ptHeaderLabel.implicitHeight + 4

                            Rectangle {
                                anchors.fill: parent
                                radius: 2
                                color: Kirigami.Theme.highlightColor
                                opacity: ptHeaderHover.containsMouse ? 0.25 : 0
                            }
                            PlasmaComponents.Label {
                                id: ptHeaderLabel
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                font.bold: root.ptSortKey === modelData.key
                                text: modelData.label + (root.ptSortKey === modelData.key ? (root.ptSortAsc ? " ▲" : " ▼") : "")
                            }
                            MouseArea {
                                id: ptHeaderHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.ptSort(modelData.key)
                            }
                        }
                    }
                    // Signal column header — no sort, just aligns with the
                    // per-row Signal buttons below. It also carries the
                    // current averaging window, because a table of 15-minute
                    // averages is indistinguishable from a very calm machine
                    // unless it says so somewhere.
                    Item {
                        Layout.fillWidth: true
                        PlasmaComponents.Label {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.ptWindowLabels[root.ptWindow]
                            opacity: 0.7
                            font.italic: root.ptWindow !== "live"
                        }
                    }
                }

                ListView {
                    id: ptList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: root.ptRows
                    clip: true
                    spacing: 1
                    delegate: RowLayout {
                        id: ptRow
                        // Same shadowing hazard as procList above: capture
                        // pid/protected state up front, before the inner
                        // Repeater over signalList introduces its own
                        // modelData that would otherwise shadow this one.
                        property int ptPid: modelData.pid
                        property bool ptProtected: !!modelData.protected
                        property string ptReason: modelData.protected_reason || ""
                        width: ptList.width
                        spacing: 6
                        opacity: ptProtected ? 0.6 : 1.0

                        PlasmaComponents.Label { Layout.preferredWidth: 130; text: modelData.name; elide: Text.ElideRight }
                        PlasmaComponents.Label { Layout.preferredWidth: 70; text: modelData.user; elide: Text.ElideRight }
                        PlasmaComponents.Label { Layout.preferredWidth: 55; text: modelData.pid }
                        PlasmaComponents.Label { Layout.preferredWidth: 55; text: root.ptCellText(modelData, "cpu_pct") }
                        PlasmaComponents.Label { Layout.preferredWidth: 55; text: root.ptCellText(modelData, "mem_pct") }
                        PlasmaComponents.Label { Layout.preferredWidth: 65; text: root.ptCellText(modelData, "mem_rss_bytes") }
                        PlasmaComponents.Label { Layout.preferredWidth: 65; text: root.ptCellText(modelData, "read_bytes_per_s") }
                        PlasmaComponents.Label { Layout.preferredWidth: 65; text: root.ptCellText(modelData, "write_bytes_per_s") }
                        PlasmaComponents.Label { Layout.preferredWidth: 60; text: root.ptCellText(modelData, "runq_wait_pct") }

                        PlasmaComponents.Button {
                            Layout.fillWidth: true
                            text: ptRow.ptProtected ? "Protected" : "Signal"
                            icon.name: "process-stop"
                            enabled: !ptRow.ptProtected
                            // Shown even though the button is disabled: this
                            // is the "show the user why, not fail silently"
                            // requirement — a disabled button with no
                            // explanation is indistinguishable from a bug.
                            PlasmaComponents.ToolTip.visible: ptRow.ptProtected && hovered
                            PlasmaComponents.ToolTip.text: ptRow.ptReason
                            onClicked: ptSigMenu.open()
                            PlasmaComponents.Menu {
                                id: ptSigMenu
                                Repeater {
                                    model: root.signalList
                                    delegate: PlasmaComponents.MenuItem {
                                        text: modelData.label
                                        onTriggered: root.sendSignal(ptRow.ptPid, modelData.sig)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    toolTipMainText: "Watchdog"
    toolTipSubText: root.stale
        ? "my-konsole watchdog daemon is not publishing\n(systemctl --user status my-konsole-tray)"
        : "cpu " + pct(snap.cpu) + "   mem " + pct(snap.mem) + "   swap " + pct(snap.swap)
          + "\ndisk " + pct(snap.disk) + "   r " + mbs(snap.disk_r) + "   w " + mbs(snap.disk_w)
          + "\nnet ↓" + mbs(snap.net_rx) + "  ↑" + mbs(snap.net_tx)
          + "\nload " + two(snap.load1) + "  " + two(snap.load5) + "  " + two(snap.load15)
          + "\nPSI some avg10  cpu " + two(psi("cpu","some10")) + "  io " + two(psi("io","some10")) + "  mem " + two(psi("memory","some10"))
          + "\nPSI full avg10  cpu " + two(psi("cpu","full10")) + "  io " + two(psi("io","full10")) + "  mem " + two(psi("memory","full10"))
          + "\nuser slice " + two(snap.slice_gib) + " / " + two(snap.slice_max_gib) + " GiB"
          + (batteryText() ? "\n" + batteryText() : "")
          + (root.guardTooltipLines() ? "\n\nfreeze-guard voters:\n" + root.guardTooltipLines() : "")
}
