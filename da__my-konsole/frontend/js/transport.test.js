// transport.test.js — unit test for transport.js's pure wire-protocol fns.
// Run: node frontend/js/transport.test.js
const assert = require("node:assert/strict");
const { _encode, _decode } = require("./transport.js");

assert.equal(
  _encode({ op: "start", id: "t", cols: 80, rows: 24, cwd: null }),
  '{"op":"start","id":"t","cols":80,"rows":24,"cwd":null}'
);

assert.deepEqual(
  _decode('{"ev":"output","id":"t","data":"hi"}'),
  { ev: "output", id: "t", data: "hi" }
);

// fs_* request/response round-trip (Task 3 — frozen protocol).
const fsReq = { op: "fs_read", rid: 1, path: "/x" };
assert.deepEqual(_decode(_encode(fsReq)), fsReq);

const fsRes = { ev: "fs_result", rid: 1, ok: true, content: "hi" };
assert.deepEqual(_decode(_encode(fsRes)), fsRes);

console.log("transport.test.js: PASS");
