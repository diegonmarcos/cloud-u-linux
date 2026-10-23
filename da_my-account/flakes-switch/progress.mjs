#!/usr/bin/env node
// progress.mjs — parse nix's `--log-format internal-json` activity
// stream (on stdin) into a real percentage and print a single, data-dense
// ASCII progress line (both an overall bar and a current-step bar, byte
// sizes, elapsed/remaining/total ETA) to its own stdout for every update.
// Consumed by the wrapper's ONE companion Konsole window — see
// default.nix (programs/flakes-switch-progress-logs). Invoked by
// default.nix; never run directly. No kdialog / D-Bus involved — this is
// the only progress surface, by design (previously drove two separate
// kdialog popup windows; merged into this single in-window text line
// 2026-07-04 per direct request).
//
// nix emits, on stderr, lines containing `@nix {…json…}`. Relevant events:
//   action:"start"  type:105 (actBuild)      text:"building '/nix/store/…drv'"
//   action:"start"  type:100 (actCopyPath)   text:"copying path '…'"
//   action:"result" type:105 (resProgress)   fields:[done, expected, running, failed]
// resProgress is emitted on the aggregate build/copy/substitute activities, so
// summing done/expected across activities that declare an expected>0 yields a
// faithful overall %. The current build's drv name becomes the label.
//
// Env: NSP_CAP (cap % until the command exits, default 99),
//      NSP_START_MS (epoch ms the wrapped command started).
import { createInterface } from "node:readline";

const CAP = Number(process.env.NSP_CAP || "99");
const START_MS = Number(process.env.NSP_START_MS || Date.now());

const acts = new Map(); // activityId -> [done, expected]
let lastActId = null;   // id of the most recently updated activity — "current step"
let lastLabel = "";

const bar = (pct, width = 24) => {
  const filled = Math.round((width * pct) / 100);
  return "█".repeat(filled) + "░".repeat(width - filled);
};

const fmtDur = (ms) => {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60), r = s % 60;
  if (m < 60) return `${m}m ${r}s`;
  const h = Math.floor(m / 60), rm = m % 60;
  return `${h}h ${rm}m`;
};
const fmtBytes = (n) => {
  if (!n) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let i = 0, v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v < 10 && i > 0 ? 2 : 0)} ${units[i]}`;
};

// Universal 3-phase model, self-detected from the stream (works whether the
// wrapped command is a full local eval+build+activate `switch local`, or a
// `pull` that skips straight to a short prep + activate) — NOT bespoke per
// build.sh subcommand, so no extra wiring is needed there:
//   Preparing        — before any @nix line arrives (flake eval / fetch)
//   Building/Copying — while @nix lines stream
//   Activating       — first non-@nix line AFTER the @nix stream (the real
//                       command's own plain-text activation-script output)
let sawNixLine = false, announcedBuild = false, announcedActivate = false;

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const i = line.indexOf("@nix ");
  if (i < 0) {
    if (sawNixLine && !announcedActivate) {
      announcedActivate = true;
      process.stdout.write(`\n\x1b[1;33m▶▶▶ PHASE: Activating   [${bar(CAP)}] ${CAP}%\x1b[0m\n`);
    }
    if (line.trim()) process.stdout.write(`\x1b[2m${line}\x1b[0m\n`);
    return;
  }
  if (!sawNixLine) {
    sawNixLine = true;
    if (!announcedBuild) {
      announcedBuild = true;
      process.stdout.write("\x1b[1;33m▶▶▶ PHASE: Building / Copying\x1b[0m\n");
    }
  }
  let j;
  try { j = JSON.parse(line.slice(i + 5)); } catch { return; }

  if (j.action === "start" && typeof j.text === "string") {
    if (j.type === 105) {
      const m = j.text.match(/([^/]+)\.drv/);
      lastLabel = m ? "building " + m[1] : j.text;
    } else if (j.type === 100 || j.type === 108) {
      lastLabel = j.text;
    }
  } else if (j.action === "result" && j.type === 105 && Array.isArray(j.fields)) {
    acts.set(j.id, [Number(j.fields[0]) || 0, Number(j.fields[1]) || 0]);
    lastActId = j.id; // whichever activity just reported is "the current step"
  } else {
    return;
  }

  let done = 0, exp = 0;
  for (const [d, e] of acts.values()) { if (e > 0) { done += d; exp += e; } }
  const pct = exp > 0 ? Math.min(CAP, Math.round((done / exp) * 100)) : 0;

  // Step %: THIS activity's own ratio, not the aggregate — e.g. "this one
  // huge copy is 40% done" vs. the macro bar's "40% through everything".
  const step = lastActId != null ? acts.get(lastActId) : null;
  const [stepDone, stepExp] = step || [0, 0];
  const stepPct = stepExp > 0 ? Math.min(CAP, Math.round((stepDone / stepExp) * 100)) : 0;

  const now = Date.now();
  const elapsedMs = now - START_MS;
  let etaLine = `elapsed ${fmtDur(elapsedMs)}`;
  if (done > 0 && exp > done) {
    const remainMs = (elapsedMs / done) * (exp - done);
    etaLine += `  remaining ~${fmtDur(remainMs)}  total ~${fmtDur(elapsedMs + remainMs)}`;
  }

  // Single data-dense line — both bars, both size counts, both step and
  // overall byte totals, and the full ETA breakdown — all in the ONE window.
  const sizeSuffix = exp > 1_000_000 ? `  (${fmtBytes(done)}/${fmtBytes(exp)})` : "";
  const stepSizeSuffix = stepExp > 1_000_000 ? `  (${fmtBytes(stepDone)}/${fmtBytes(stepExp)})` : "";
  process.stdout.write(
    `overall [${bar(pct)}] ${String(pct).padStart(3)}%  ${done}/${exp || "?"}${sizeSuffix}\n` +
    `step    [${bar(stepPct)}] ${String(stepPct).padStart(3)}%  ${stepDone}/${stepExp || "?"}${stepSizeSuffix}  ${lastLabel}\n` +
    `${etaLine}\n`
  );
});
rl.on("close", () => process.exit(0));
