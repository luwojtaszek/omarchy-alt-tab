// Pure helpers behind the window list. No QML types in here: Switcher.qml
// and Service.qml import this file, and tests/window-model.test.js runs the
// same code under node.

var ADDRESS = /^[0-9a-f]{1,16}$/;

function isAddress(value) {
  return typeof value === "string" && ADDRESS.test(value);
}

function clip(value, max) {
  var s = value === undefined || value === null ? "" : String(value);
  return s.length > max ? s.substring(0, max) : s;
}

// One row for one HyprlandToplevel (or anything shaped like one), or null
// when the switcher must not list the window. Only the fields the UI needs
// are copied, each clipped to maxField characters; nothing else from the
// compositor's object reaches the UI.
//
// handlesSeen says whether any toplevel in the model carries a wayland
// (foreign-toplevel) handle. When they do, a handle is the ground truth for
// "mapped": Hyprland creates it on map and destroys it on unmap. When none
// do (no toplevel-mapping protocol), the last IPC snapshot has to serve.
function rowFor(t, activeAddress, rankOf, handlesSeen, maxField) {
  if (!t || !t.workspace) return null;
  var workspaceId = Number(t.workspace.id);
  if (!isFinite(workspaceId) || workspaceId <= 0) return null; // special / unassigned workspaces
  var ipc = t.lastIpcObject || {};
  var wl = t.wayland || null;
  if (handlesSeen ? !wl : ipc.mapped === false) return null;
  var address = t.address === undefined || t.address === null ? "" : String(t.address);
  if (!isAddress(address)) return null;
  var history = Number(ipc.focusHistoryID);
  return {
    address: address,
    class: clip(wl && wl.appId ? wl.appId : ipc["class"], maxField),
    title: clip(t.title ? t.title : (wl ? wl.title : ""), maxField),
    workspaceId: workspaceId,
    active: address === activeAddress,
    rank: rankOf ? rankOf(address) : -1,
    history: isFinite(history) && history >= 0 ? history : Number.MAX_VALUE
  };
}

// Most recently used first: the focused window; then windows in the order
// the service saw them focused (rank); then the rest by the compositor's
// last known focus history; then by address, so the order is total.
function byRecency(a, b) {
  if (a.active !== b.active) return a.active ? -1 : 1;
  var ka = a.rank >= 0 ? 0 : 1;
  var kb = b.rank >= 0 ? 0 : 1;
  if (ka !== kb) return ka - kb;
  var va = ka === 0 ? a.rank : a.history;
  var vb = kb === 0 ? b.rank : b.history;
  if (va !== vb) return va < vb ? -1 : 1;
  return a.address < b.address ? -1 : (a.address > b.address ? 1 : 0);
}

// The MRU list: at most maxWindows rows, built from the toplevel model.
function collect(toplevels, activeAddress, rankOf, maxWindows, maxField) {
  var handlesSeen = false;
  for (var h = 0; h < toplevels.length; h++) {
    if (toplevels[h] && toplevels[h].wayland) { handlesSeen = true; break; }
  }
  var rows = [];
  for (var i = 0; i < toplevels.length; i++) {
    var row = rowFor(toplevels[i], activeAddress, rankOf, handlesSeen, maxField);
    if (row) rows.push(row);
  }
  rows.sort(byRecency);
  return rows.length > maxWindows ? rows.slice(0, maxWindows) : rows;
}

// Focus history as kept by Service.qml: addresses, most recent first.
// Both functions return a new array and leave the input untouched.
function noteFocus(history, address, limit) {
  if (!isAddress(address)) return history;
  var next = [address];
  for (var i = 0; i < history.length && next.length < limit; i++) {
    if (history[i] !== address) next.push(history[i]);
  }
  return next;
}

function forget(history, address) {
  if (!isAddress(address)) return history;
  var i = history.indexOf(address);
  if (i < 0) return history;
  var next = history.slice();
  next.splice(i, 1);
  return next;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    isAddress: isAddress, clip: clip, rowFor: rowFor, byRecency: byRecency,
    collect: collect, noteFocus: noteFocus, forget: forget
  };
}
