// state.js — Rust -> JS state channel.
//
// ponytail: this is a poor man's IPC. Ceiling: it is one-way (Rust -> JS) and
// polls, nothing more. There is no JS -> Rust leg here — see P2 in
// PLAN-deploy-gaps.md for that. The upgrade path, once JS needs to talk back
// to Rust for more than the handful of commands listed there, is a real CEF
// message router (a V8 handler in the render process, or process messages),
// not a fancier version of this polling trick.
//
// Why this exists: the shell renders from file://, and Chromium's
// opaque-origin rule blocks fetch()/XHR against file:// URLs — the obvious
// "poll a JSON file" approach silently fails there. What DOES work from
// file:// is injecting a <script> tag, so the channel is: Rust writes a
// plain .js file next to this one, and this file re-inserts a <script src>
// pointing at it on an interval, reading back whatever global it defined.
//
// ---------------------------------------------------------------------
// wire format — for whoever writes the Rust side
// ---------------------------------------------------------------------
//
// Each channel "<name>" is a file at shell/state/<name>.js. It must be a
// complete, syntactically valid script on every read, assigning exactly one
// global:
//
//   window.__<NAME>  (name upper-cased; "downloads" -> window.__DOWNLOADS)
//
// Write it atomically (write to a temp file in the same directory, then
// rename() into place) — never write in place, or a poll can land on a
// half-written file and throw a syntax error.
//
// The value must be JSON-serializable. It can be any shape; comparison for
// change-detection is done on JSON.stringify(value), so field order does not
// matter but NaN/undefined/functions inside it will not round-trip sanely —
// stick to plain JSON types.
//
// The one channel that is real today is "downloads". shell/state/downloads.js
// must look like:
//
//   window.__DOWNLOADS = [
//     {
//       id:               "string, stable per-download identifier",
//       filename:         "string, display name — untrusted, escape on render",
//       url:              "string, source URL — untrusted, escape on render",
//       bytes_received:   0,        // number, bytes downloaded so far
//       total_bytes:      0,        // number, total size in bytes; -1 or 0 if unknown
//       percent:          0,        // number, 0-100, precomputed so JS need not divide
//       state:            "in_progress",  // "in_progress" | "complete" | "cancelled" | "interrupted"
//       timestamp:        0         // number, ms since epoch, last-updated time
//     },
//     ...
//   ];
//
// A missing file is normal (Rust has not written anything yet) and is
// treated as a silent no-op, not an error.
//
// Future channels (e.g. "title", "progress") are just more files following
// the same convention: shell/state/title.js defining window.__TITLE, etc.
// Nothing else in this file needs to change to add one — call
// STATE.get('title') / STATE.on('title', cb) and it works.

(function () {
  'use strict';

  var POLL_MS = 1500;
  var STATE_DIR = 'state/';

  // name -> { value: <last-seen value|undefined>, serialized: <string|undefined>, listeners: [fn] }
  var channels = Object.create(null);

  var timerId = null;
  var running = false;

  function globalName(name) {
    return '__' + String(name).toUpperCase();
  }

  function channel(name) {
    var existing = channels[name];
    if (existing) return existing;
    var created = { value: undefined, serialized: undefined, listeners: [] };
    channels[name] = created;
    // Probe once immediately so a newly-registered channel doesn't have to
    // wait out a full interval before its first value shows up.
    loadChannel(name);
    return created;
  }

  function loadChannel(name) {
    var script = document.createElement('script');
    script.src = STATE_DIR + encodeURIComponent(name) + '.js?t=' + Date.now();

    function cleanup() {
      if (script.parentNode) script.parentNode.removeChild(script);
    }

    script.onload = function () {
      cleanup();
      applyValue(name, window[globalName(name)]);
    };
    script.onerror = function () {
      // Silent no-op — the file legitimately does not exist yet (Rust
      // hasn't written this channel), which is the common case, not a bug.
      cleanup();
    };
    document.head.appendChild(script);
  }

  function applyValue(name, value) {
    if (value === undefined) return; // file loaded but didn't define its global — ignore
    var ch = channel(name);
    var serialized;
    try {
      serialized = JSON.stringify(value);
    } catch (e) {
      return; // unserializable — ignore rather than throw
    }
    if (serialized === ch.serialized) return; // unchanged — don't wake listeners
    ch.serialized = serialized;
    ch.value = value;
    ch.listeners.forEach(function (cb) {
      try {
        cb(value);
      } catch (e) {
        // one bad listener must not break the others or the poll loop
      }
    });
  }

  function pollOnce() {
    Object.keys(channels).forEach(loadChannel);
  }

  function tick() {
    if (document.hidden) return; // don't burn CPU polling a backgrounded page
    pollOnce();
  }

  function start() {
    if (running) return;
    running = true;
    tick();
    timerId = setInterval(tick, POLL_MS);
  }

  function stop() {
    running = false;
    if (timerId !== null) {
      clearInterval(timerId);
      timerId = null;
    }
  }

  function get(name) {
    return channel(name).value;
  }

  function on(name, cb) {
    if (typeof cb !== 'function') return;
    channel(name).listeners.push(cb);
  }

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && running) tick(); // catch up right away on refocus
  });

  window.STATE = { start: start, stop: stop, get: get, on: on };

  start();
})();
