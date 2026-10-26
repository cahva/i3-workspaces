import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// i3bar-style workspace indicators: plain numbered boxes, sharp corners,
// filtered to the monitor this bar instance lives on.
BarWidget {
  id: root
  moduleName: "i3-workspaces"

  readonly property int maxWorkspaceId: root.setting("maxWorkspaceId", 10)

  readonly property color activeColor: Commons.Color.accent
  readonly property color inactiveColor: Commons.Color.muted
  readonly property color urgentColor: Commons.Color.urgent
  readonly property color bgColor: Commons.Color.background
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // --- which monitor is this bar on -----------------------------------------
  // One bar surface exists per monitor, so read the screen off the window this
  // widget was instantiated into rather than off global focus state. QsWindow
  // carries no change notification, so a cached readonly property can freeze
  // at "" if evaluated before the widget is parented into its window -- read
  // it fresh on every call instead.
  function screenName() {
    var win = root.QsWindow ? root.QsWindow.window : null
    return win && win.screen ? String(win.screen.name || "") : ""
  }

  readonly property var hyprMonitor: {
    var _ = root.revision
    var mine = root.screenName()
    if (mine === "") return null
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (String(monitors[i].name) === mine) return monitors[i]
    }
    return null
  }

  // Workspace active *on this monitor* -- not the same as the globally
  // focused workspace once a second monitor exists. hyprMonitor's own
  // change-notify only fires when the monitor object reference itself
  // changes, not when its activeWorkspace sub-property is updated in place
  // -- depend on revision explicitly so a workspace switch on another
  // monitor's bar surface still forces a fresh read here.
  readonly property int activeId: {
    var _ = root.revision
    if (root.hyprMonitor && root.hyprMonitor.activeWorkspace) return root.hyprMonitor.activeWorkspace.id
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  }

  // --- keeping Hyprland's view fresh -----------------------------------------
  property int revision: 0

  readonly property var workspaceEvents: ["workspace", "workspacev2", "createworkspace", "createworkspacev2", "destroyworkspace", "destroyworkspacev2", "moveworkspace", "moveworkspacev2", "focusedmon", "urgent"]

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.workspaceEvents.indexOf(event.name) !== -1) {
        Hyprland.refreshWorkspaces()
        root.revision++
      }
    }
  }

  // The window this widget lives in may not be attached yet on first paint;
  // force one re-check once the event loop settles so screenName() resolves
  // even if no Hyprland event fires early on.
  Timer {
    interval: 50
    running: true
    repeat: false
    onTriggered: root.revision++
  }

  function monitorNameOf(workspace) {
    if (!workspace) return ""
    if (workspace.monitor && workspace.monitor.name) return String(workspace.monitor.name)
    var ipc = workspace.lastIpcObject
    if (ipc && ipc.monitor) return String(ipc.monitor)
    return ""
  }

  // Omarchy gives each monitor a block of ten global ids (1-10, 11-20, ...);
  // the slot is the number Super+N uses within the block. See
  // default/hypr/monitor-workspaces.lua.
  function blockOf(id) {
    return Math.floor((id - 1) / 10)
  }

  function slotOf(id) {
    return (id - 1) % 10 + 1
  }

  // Connector -> block, from the state file Omarchy keeps them in.
  property var blocks: ({})

  function readBlocks(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "") next[fields[1]] = parseInt(fields[0], 10)
    }
    root.blocks = next
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  // Until Omarchy has written the file, the workspace this monitor shows is in
  // its own block.
  readonly property int block: {
    var _ = root.revision
    var own = root.blocks[root.screenName()]
    if (own !== undefined) return own
    return root.activeId > 0 ? root.blockOf(root.activeId) : 0
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  // This monitor's own workspace ids, then guests: workspaces of an unplugged
  // monitor that found no free slot in this one's block. Always includes the
  // active id so the bar never renders empty.
  readonly property var workspaceIds: {
    var _ = root.revision
    var mine = root.screenName()
    var ids = []
    var guests = []
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      var id = workspace.id
      if (id <= 0) continue

      if (mine !== "") {
        var owner = root.monitorNameOf(workspace)
        // An unknown owner is kept rather than dropped: better a stray box
        // than a workspace that silently vanishes from every bar.
        if (owner !== "" && owner !== mine) continue
      }

      root.addWorkspaceId(id, ids, guests)
    }

    if (root.activeId > 0) root.addWorkspaceId(root.activeId, ids, guests)

    ids.sort(function(left, right) { return left - right })
    guests.sort(function(left, right) { return left - right })
    return ids.concat(guests)
  }

  // maxWorkspaceId limits the monitor's own slots; guests always show, or the
  // bar would hide a workspace that has nowhere else to appear.
  function addWorkspaceId(id, ids, guests) {
    if (root.blockOf(id) !== root.block) {
      if (guests.indexOf(id) === -1) guests.push(id)
    } else if (root.slotOf(id) <= root.maxWorkspaceId && ids.indexOf(id) === -1) {
      ids.push(id)
    }
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds.length
    columnSpacing: 0
    rowSpacing: 0

    Repeater {
      model: root.workspaceIds

      Item {
        id: box
        required property int modelData
        required property int index

        readonly property var workspace: {
          var _ = root.revision
          return root.workspaceById(box.modelData)
        }
        readonly property bool active: box.modelData === root.activeId
        readonly property bool urgent: {
          var _ = root.revision
          return box.workspace !== null && box.workspace.urgent === true
        }

        // A gap sets visiting workspaces apart from the monitor's own.
        readonly property bool firstGuest: root.blockOf(box.modelData) !== root.block && box.index > 0 && root.blockOf(root.workspaceIds[box.index - 1]) === root.block
        Layout.leftMargin: box.firstGuest && !root.vertical ? Style.space(6) : 0
        Layout.topMargin: box.firstGuest && root.vertical ? Style.space(6) : 0

        Layout.alignment: Qt.AlignVCenter
        Layout.fillHeight: true
        Layout.fillWidth: root.vertical
        implicitWidth: root.vertical ? root.barSize : Style.space(20)
        implicitHeight: root.barSize

        // Text-color-only contrast is too weak when a theme's accent and
        // muted tones sit close in hue/lightness -- a solid fill makes the
        // active workspace unmistakable regardless of theme.
        Rectangle {
          anchors.centerIn: parent
          anchors.margins: 2
          width: Math.max(label.implicitWidth + Style.space(4), height)
          height: root.barSize - Style.space(6)
          radius: 3
          visible: box.active || box.urgent
          color: box.urgent ? root.urgentColor : root.activeColor
        }

        Text {
          id: label
          anchors.centerIn: parent
          text: String(root.slotOf(box.modelData) % 10)
          color: (box.active || box.urgent) ? root.bgColor : root.inactiveColor
          font.bold: box.active || box.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: root.vertical ? Style.font.icon : Style.font.body
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.focusWorkspace(box.modelData)
        }
      }
    }
  }
}
