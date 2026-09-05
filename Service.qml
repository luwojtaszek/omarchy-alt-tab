import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick
import "WindowModel.js" as WindowModel

// Background half of the switcher, mounted at shell startup. Two jobs:
//
// 1. Keybindings. Dynamic binds don't survive a Hyprland config reload, so
//    apply-binds.sh runs at startup and again after every configreloaded
//    event. The script never touches combos the user bound themselves; see
//    its header (and the README) for the policy and the {"autoBinds": false}
//    opt-out.
//
// 2. Focus history. The switcher lists windows most-recently-used first. It
//    reads the shell's own Hyprland toplevel model rather than running
//    `hyprctl clients`, and that model's focusHistoryID is refreshed only on
//    connect and on config reload -- so the order is tracked here, from the
//    compositor's activewindowv2 events, for as long as the shell runs.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ── Keybindings ────────────────────────────────────────────────────
  readonly property string scriptPath: {
    var url = Qt.resolvedUrl("apply-binds.sh").toString()
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  // Whole-process deadline. coreutils timeout runs the script in its own
  // process group and, on expiry, signals the group: bash and every
  // hyprctl, jq or logger it started go down together (TERM, then KILL
  // two seconds later).
  Process {
    id: applyProc
    command: ["timeout", "--kill-after=2s", "20s", "bash", root.scriptPath]
    onRunningChanged: {
      if (running) return
      watchdog.stop()
      if (root.applyQueued) {
        root.applyQueued = false
        root.apply()
      }
    }
  }

  // A reload that lands while the script is still running must not be
  // dropped: it means the compositor has just wiped the binds again.
  property bool applyQueued: false

  function apply() {
    if (applyProc.running) { applyQueued = true; return }
    applyProc.running = true
    watchdog.restart()
  }

  // Second layer above timeout's own deadline: should the wrapper itself
  // hang, SIGTERM it (it forwards the signal to the script).
  Timer {
    id: watchdog
    interval: 30000
    onTriggered: if (applyProc.running) applyProc.signal(15)
  }

  // Give the compositor a moment to finish evaluating its config before
  // inspecting the bind table (both at startup and after a reload).
  Timer {
    id: applyTimer
    interval: 1000
    onTriggered: root.apply()
  }

  Component.onCompleted: {
    applyTimer.restart()
    // The toplevel model's focusHistoryID snapshot is refreshed by the
    // host only on connect and config reload; take a fresh one now so the
    // seed for windows this service has not yet seen focused is current.
    Hyprland.refreshToplevels()
  }
  Component.onDestruction: {
    applyTimer.stop()
    watchdog.stop()
    if (applyProc.running) applyProc.signal(15)
  }

  // ── Focus history ──────────────────────────────────────────────────
  // Window addresses (hex without 0x, the form Hyprland's events and
  // Quickshell's HyprlandToplevel.address share), most recently focused
  // first. Bounded: entries leave on closewindow, and the list never grows
  // past historyLimit (WindowModel.noteFocus drops the oldest).
  property var history: []
  readonly property int historyLimit: 512

  // 0 = focused most recently, -1 = never seen focused by this service.
  function historyRank(address) {
    return history.indexOf(String(address))
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") applyTimer.restart()
      else if (event.name === "activewindowv2") root.history = WindowModel.noteFocus(root.history, event.data, root.historyLimit)
      else if (event.name === "closewindow") root.history = WindowModel.forget(root.history, event.data)
    }
  }
}
