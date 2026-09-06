import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar icon for locally running dev projects: plain processes (found via
// `ss -ltnp` + /proc/<pid>/cwd) and Docker Compose stacks (found via
// docker-compose labels), grouped by the project folder they run from.
// Every entry is a background process (a daemon or a container), so
// closing it is a kill/stop action, never a window close — hence the
// confirmation step before either one runs.
Panel {
  id: root
  moduleName: "io.github.gbflores.local-projects"
  ipcTarget: "io.github.gbflores.local-projects"

  // Groups from Model.groupByFolder: [{ folder, entries: [{port, label, source, pid, containerName, cpuPercent, memBytes}] }]
  property var groups: []
  // Same data flattened for keyboard/hover cursor indexing, each row carries
  // its folder and whether it is the first row of its group (draws the header).
  property var flatRows: []

  property int selectedIndex: 0
  property bool cursorActive: false

  // Row pending a kill/stop confirmation, or null when the dialog is closed.
  property var killRow: null

  readonly property int refreshMs: Math.max(1000, setting("refreshMs", 5000))
  readonly property int totalPorts: flatRows.length

  function flatten(groups) {
    var rows = []
    for (var g = 0; g < groups.length; g++) {
      var group = groups[g]
      for (var e = 0; e < group.entries.length; e++) {
        var entry = group.entries[e]
        rows.push({
          folder: group.folder,
          port: entry.port,
          label: entry.label,
          source: entry.source,
          pid: entry.pid,
          containerName: entry.containerName,
          cpuPercent: entry.cpuPercent,
          memBytes: entry.memBytes,
          isGroupStart: e === 0
        })
      }
    }
    return rows
  }

  function urlFor(row) {
    return "http://localhost:" + row.port + "/"
  }

  function statLabel(row) {
    if (!row) return ""
    var parts = []
    parts.push(row.cpuPercent !== "" ? ("CPU " + row.cpuPercent + "%") : "CPU —")
    parts.push(row.memBytes > 0 ? ("MEM " + Model.formatBytes(row.memBytes)) : "MEM —")
    return parts.join(" · ")
  }

  function killLabel(row) {
    if (!row) return ""
    return row.source === "docker" ? ("Stop " + row.containerName + "?") : ("Kill " + row.label + " (pid " + row.pid + ")?")
  }

  function openRow(row) {
    if (!row) return
    Quickshell.execDetached(["omarchy-launch-browser", root.urlFor(row)])
  }

  function copyRow(row) {
    if (!row) return
    Quickshell.execDetached(["wl-copy", root.urlFor(row)])
  }

  function requestKill(row) {
    if (!row) return
    root.killRow = row
  }

  function cancelKill() {
    root.killRow = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmKill() {
    var row = root.killRow
    root.killRow = null
    if (!row || killProc.running) return
    if (row.source === "docker") killProc.command = ["docker", "stop", row.containerName]
    else killProc.command = ["kill", String(row.pid)]
    killProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function refresh() {
    if (!refreshProc.running) refreshProc.running = true
  }

  function moveCursor(delta) {
    if (flatRows.length === 0) return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > flatRows.length - 1) next = flatRows.length - 1
    selectedIndex = next
  }

  function clampCursor() {
    if (flatRows.length === 0) { selectedIndex = 0; return }
    if (selectedIndex > flatRows.length - 1) selectedIndex = flatRows.length - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin) flick.contentY = bottom + margin - flick.height
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      selectedIndex = 0
      cursorActive = false
      killRow = null
    }
  }

  onGroupsChanged: {
    flatRows = flatten(groups)
    clampCursor()
    // A killed row can vanish from the next snapshot before the user sees a
    // confirmation result; drop a stale reference rather than re-kill it.
    if (killRow) {
      var stillThere = flatRows.some(function(r) { return r.port === killRow.port })
      if (!stillThere) killRow = null
    }
  }

  Timer {
    interval: root.refreshMs
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Reassigning `groups` gives the Repeater a brand-new array every refresh,
  // which rebuilds all delegates and would otherwise snap the scroll back to
  // the top mid-read. Save/restore contentY across that rebuild.
  function applyGroups(newGroups) {
    var flick = scrollArea.contentItem
    var savedY = flick ? flick.contentY : 0
    root.groups = newGroups
    Qt.callLater(function() {
      if (!flick) return
      flick.contentY = Math.max(0, Math.min(savedY, flick.contentHeight - scrollArea.height))
    })
  }

  Process {
    id: refreshProc
    command: ["bash", "-c", Model.snapshotScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyGroups(Model.parseSnapshot(String(text || "")))
    }
  }

  Process {
    id: killProc
    onExited: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      focus: root.killRow === null
      blocked: root.killRow !== null
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.openRow(root.flatRows[root.selectedIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.requestKill(root.flatRows[root.selectedIndex])
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "c" && root.cursorActive) root.copyRow(root.flatRows[root.selectedIndex])
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Local Projects"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: {
                  var n = root.totalPorts
                  if (n === 0) return "NOTHING LISTENING ON LOCALHOST"
                  return (n + (n === 1 ? " PORT" : " PORTS") + " · " + root.groups.length + (root.groups.length === 1 ? " PROJECT" : " PROJECTS")).toUpperCase()
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Empty state ----------
          PanelSeparator {
            visible: root.totalPorts === 0
            foreground: root.bar.foreground
          }

          Text {
            visible: root.totalPorts === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No project is currently listening on localhost or 127.0.0.1."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---------- Projects ----------
          PanelSeparator {
            visible: root.totalPorts > 0
            foreground: root.bar.foreground
          }

          Repeater {
            model: root.flatRows

            delegate: Column {
              id: rowWrap
              required property var modelData
              required property int index

              readonly property var row: modelData

              width: panelColumn.width
              spacing: Style.space(6)

              // Group header: the project folder name, drawn once above its ports.
              Text {
                visible: rowWrap.row.isGroupStart
                text: rowWrap.row.folder
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
                topPadding: rowWrap.index === 0 ? 0 : Style.space(6)
              }

              CursorSurface {
                id: entryRow
                width: parent.width
                implicitHeight: rowColumn.implicitHeight + Style.spacing.xl
                hasCursor: root.cursorActive && root.selectedIndex === rowWrap.index
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(entryRow)
                foreground: root.bar.foreground
                fill: Style.hoverFillFor(root.bar.foreground, Color.accent)

                Column {
                  id: rowColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(2)

                  Item {
                    width: parent.width
                    implicitHeight: portText.implicitHeight

                    Text {
                      id: portText
                      text: "localhost:" + rowWrap.row.port
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: rowWrap.row.label + (rowWrap.row.source === "docker" ? " (docker)" : "")
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      anchors.left: portText.right
                      anchors.leftMargin: Style.space(8)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      horizontalAlignment: Text.AlignRight
                    }
                  }

                  Text {
                    text: root.statLabel(rowWrap.row)
                    color: Qt.darker(root.bar.foreground, 1.6)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onEntered: {
                    root.cursorActive = true
                    root.selectedIndex = rowWrap.index
                  }
                  onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) root.requestKill(rowWrap.row)
                    else root.openRow(rowWrap.row)
                  }
                }
              }
            }
          }

          // ---------- Footer ----------
          PanelSeparator {
            visible: root.totalPorts > 0
            foreground: root.bar.foreground
          }

          Text {
            visible: root.totalPorts > 0
            width: parent.width
            text: "click/enter open · right-click/x kill · c copy · r refresh"
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }

      Item {
        id: killKeys
        anchors.fill: parent
        focus: root.killRow !== null
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (killConfirm.handleKey(event)) event.accepted = true
        }
      }

      ConfirmDialog {
        id: killConfirm
        anchors.fill: parent
        z: 10
        opened: root.killRow !== null
        message: root.killLabel(root.killRow)
        confirmText: root.killRow && root.killRow.source === "docker" ? "Stop" : "Kill"
        background: Color.background
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onCanceled: root.cancelKill()
        onConfirmed: root.confirmKill()
      }
    }
  }
}
