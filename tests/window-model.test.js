// Unit tests for WindowModel.js, the logic behind the window list.
//
//   node tests/window-model.test.js
"use strict";

const assert = require("assert");
const path = require("path");
const M = require(path.join(__dirname, "..", "WindowModel.js"));

function toplevel(overrides) {
  return Object.assign({
    address: "1",
    title: "title",
    workspace: { id: 1 },
    wayland: { appId: "app", title: "wl title" },
    lastIpcObject: {}
  }, overrides || {});
}

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; }
  catch (e) { console.error("FAIL " + name + "\n  " + e.message); process.exitCode = 1; }
}

test("isAddress accepts lowercase hex without 0x, up to 16 digits", () => {
  ["1", "5577d19c9740", "f".repeat(16)].forEach(a => assert.strictEqual(M.isAddress(a), true, a));
  ["", "0x1", "ZZ", "1 ", "f".repeat(17), 12, null, undefined].forEach(a => assert.strictEqual(M.isAddress(a), false, String(a)));
});

test("clip stringifies and bounds", () => {
  assert.strictEqual(M.clip(undefined, 5), "");
  assert.strictEqual(M.clip(null, 5), "");
  assert.strictEqual(M.clip(12, 5), "12");
  assert.strictEqual(M.clip("abcdefgh", 5), "abcde");
});

test("rowFor drops windows on special or unassigned workspaces", () => {
  assert.strictEqual(M.rowFor(toplevel({ workspace: { id: -99 } }), "", null, true, 256), null);
  assert.strictEqual(M.rowFor(toplevel({ workspace: { id: 0 } }), "", null, true, 256), null);
  assert.strictEqual(M.rowFor(toplevel({ workspace: { id: "x" } }), "", null, true, 256), null);
  assert.strictEqual(M.rowFor(toplevel({ workspace: null }), "", null, true, 256), null);
  assert.strictEqual(M.rowFor(null, "", null, true, 256), null);
});

test("rowFor needs a live handle when the model has handles", () => {
  assert.strictEqual(M.rowFor(toplevel({ wayland: null }), "", null, true, 256), null);
  assert.strictEqual(M.rowFor(toplevel({ wayland: null, lastIpcObject: { mapped: true } }), "", null, true, 256), null);
  assert.notStrictEqual(M.rowFor(toplevel({ lastIpcObject: { mapped: false } }), "", null, true, 256), null);
});

test("rowFor falls back to the ipc snapshot when no handles exist", () => {
  assert.notStrictEqual(M.rowFor(toplevel({ wayland: null }), "", null, false, 256), null);
  assert.notStrictEqual(M.rowFor(toplevel({ wayland: null, lastIpcObject: { mapped: true } }), "", null, false, 256), null);
  assert.strictEqual(M.rowFor(toplevel({ wayland: null, lastIpcObject: { mapped: false } }), "", null, false, 256), null);
});

test("rowFor rejects malformed addresses", () => {
  ["", "0x1", "ZZ", "1".repeat(17), null, undefined].forEach(a =>
    assert.strictEqual(M.rowFor(toplevel({ address: a }), "", null, true, 256), null, String(a)));
});

test("rowFor copies only the fields the UI needs, clipped", () => {
  const row = M.rowFor(toplevel({
    title: "x".repeat(300),
    wayland: { appId: "y".repeat(300), title: "ignored" },
    lastIpcObject: { focusHistoryID: 3, mapped: true, pid: 42, secret: "not copied" }
  }), "1", () => 7, true, 256);
  assert.deepStrictEqual(Object.keys(row).sort(), ["active", "address", "class", "history", "rank", "title", "workspaceId"]);
  assert.strictEqual(row.title.length, 256);
  assert.strictEqual(row.class.length, 256);
  assert.strictEqual(row.active, true);
  assert.strictEqual(row.rank, 7);
  assert.strictEqual(row.history, 3);
  assert.strictEqual(row.workspaceId, 1);
});

test("rowFor prefers the live appId and title, falls back to the ipc snapshot", () => {
  let row = M.rowFor(toplevel({ wayland: { appId: "live", title: "wl" }, lastIpcObject: { class: "stale" } }), "", null, true, 256);
  assert.strictEqual(row.class, "live");
  assert.strictEqual(row.title, "title");
  row = M.rowFor(toplevel({ title: "", wayland: { appId: "", title: "wl" }, lastIpcObject: { class: "stale" } }), "", null, true, 256);
  assert.strictEqual(row.class, "stale");
  assert.strictEqual(row.title, "wl");
  row = M.rowFor(toplevel({ title: "", wayland: null }), "", null, false, 256);
  assert.strictEqual(row.class, "");
  assert.strictEqual(row.title, "");
});

test("rowFor: unknown history sorts last, unknown rank is -1", () => {
  const row = M.rowFor(toplevel({ lastIpcObject: {} }), "", null, true, 256);
  assert.strictEqual(row.history, Number.MAX_VALUE);
  assert.strictEqual(row.rank, -1);
  assert.strictEqual(M.rowFor(toplevel({ lastIpcObject: { focusHistoryID: -1 } }), "", null, true, 256).history, Number.MAX_VALUE);
});

test("byRecency: active, then ranked, then history, then address", () => {
  const rows = [
    { address: "d", active: false, rank: -1, history: 5 },
    { address: "c", active: false, rank: -1, history: 2 },
    { address: "b", active: false, rank: 1, history: 0 },
    { address: "a", active: true, rank: -1, history: 9 },
    { address: "e", active: false, rank: 0, history: 7 },
    { address: "g", active: false, rank: -1, history: Number.MAX_VALUE },
    { address: "f", active: false, rank: -1, history: Number.MAX_VALUE }
  ];
  assert.deepStrictEqual(rows.slice().sort(M.byRecency).map(r => r.address), ["a", "e", "b", "c", "d", "f", "g"]);
});

test("collect orders by the tracked focus history and puts the active window first", () => {
  const ranks = { "a": 2, "b": 0, "c": 1 };
  const tops = ["a", "b", "c", "d"].map((addr, i) => toplevel({ address: addr, lastIpcObject: { focusHistoryID: 3 - i } }));
  const rows = M.collect(tops, "d", addr => (addr in ranks ? ranks[addr] : -1), 256, 256);
  assert.deepStrictEqual(rows.map(r => r.address), ["d", "b", "c", "a"]);
});

test("collect caps the list at maxWindows, keeping the most recent", () => {
  const tops = [];
  for (let i = 0; i < 300; i++) tops.push(toplevel({ address: (i + 1).toString(16), lastIpcObject: { focusHistoryID: i } }));
  const rows = M.collect(tops, "", null, 256, 256);
  assert.strictEqual(rows.length, 256);
  assert.strictEqual(rows[0].history, 0);
  assert.strictEqual(rows[255].history, 255);
});

test("collect skips unlistable toplevels without failing the rest", () => {
  const tops = [toplevel({ address: "a" }), null, toplevel({ address: "b", workspace: { id: -1 } }), toplevel({ address: "bad!" })];
  assert.deepStrictEqual(M.collect(tops, "", null, 256, 256).map(r => r.address), ["a"]);
});

test("noteFocus moves to the front, dedupes, bounds and validates", () => {
  let h = [];
  h = M.noteFocus(h, "a1", 3);
  h = M.noteFocus(h, "b2", 3);
  h = M.noteFocus(h, "a1", 3);
  assert.deepStrictEqual(h, ["a1", "b2"]);
  h = M.noteFocus(h, "c3", 3);
  h = M.noteFocus(h, "d4", 3);
  assert.deepStrictEqual(h, ["d4", "c3", "a1"]);
  assert.strictEqual(M.noteFocus(h, "", 3), h);
  assert.strictEqual(M.noteFocus(h, "0xZZ", 3), h);
  assert.strictEqual(M.noteFocus(h, "f".repeat(40), 3), h);
  assert.strictEqual(M.noteFocus(h, undefined, 3), h);
});

test("forget removes an address and ignores unknown or malformed ones", () => {
  const h = ["a1", "b2", "c3"];
  assert.deepStrictEqual(M.forget(h, "b2"), ["a1", "c3"]);
  assert.deepStrictEqual(h, ["a1", "b2", "c3"]);
  assert.strictEqual(M.forget(h, "zz"), h);
  assert.strictEqual(M.forget(h, ""), h);
});

if (!process.exitCode) console.log(passed + " window-model tests passed");
