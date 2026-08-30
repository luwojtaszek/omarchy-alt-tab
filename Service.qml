import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick

// Out-of-the-box keybindings for the switcher. Dynamic binds don't survive a
// Hyprland config reload, so apply-binds.sh runs at shell startup and again
// after every configreloaded event. The script never touches combos the user
// bound themselves; see its header (and README) for the exact policy and the
// {"autoBinds": false} opt-out.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string scriptPath: {
    var url = Qt.resolvedUrl("apply-binds.sh").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  Process {
    id: applyProc
    command: ["bash", root.scriptPath]
  }

  function apply() {
    if (!applyProc.running) applyProc.running = true
  }

  // Give the compositor a moment to finish evaluating its config before
  // inspecting the bind table (both at startup and after a reload).
  Timer {
    id: applyTimer
    interval: 1000
    onTriggered: root.apply()
  }

  Component.onCompleted: applyTimer.restart()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") applyTimer.restart()
    }
  }
}
