import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "minisiowo.dynamic-workspaces"

  property bool popupOpen: false
  property int selectedWorkspaceId: 0
  property var hostWidget: null

  // Live drop target while a chip is being dragged. `dropMonitor` is the
  // monitor description under the cursor, `dropIndex` the insertion slot
  // inside that monitor's chip row. Both are cleared when the drag ends.
  property string dropMonitor: ""
  property int dropIndex: -1

  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property string configuredIcon: String(setting("icon", "󰕰"))
  readonly property bool opened: popupOpen
  readonly property color panelForeground: bar ? bar.foreground : Color.foreground
  readonly property color panelDim: Qt.darker(panelForeground, 1.55)
  readonly property string panelFont: bar ? bar.fontFamily : Style.font.family

  // Which screen this instance's bar is on, resolved the way the shell's own
  // popup kit does it. When it cannot be determined — or nothing is focused —
  // the instance assumes it is the right one, so a single-monitor setup always
  // responds.
  readonly property string screenName: {
    var window = button.QsWindow.window
    return window && window.screen ? String(window.screen.name) : ""
  }
  readonly property bool onFocusedMonitor: Hyprland.focusedMonitor === null
    || root.screenName === ""
    || root.screenName === String(Hyprland.focusedMonitor.name)

  readonly property bool applyNeedsHook: root.service
    && root.service.applyEnabled === true
    && root.service.hookInstalled !== true
  readonly property bool applyStatusUrgent: (root.service && root.service.applyError !== "") || applyNeedsHook
  // The absolute path is long enough to wrap onto a second line and turn the
  // status into a paragraph, so it is shown the way a shell would write it.
  readonly property string rulesPathShort: {
    if (!root.service) return ""
    var path = String(root.service.rulesPath)
    var home = String(root.service.home)
    return home !== "" && path.indexOf(home) === 0 ? "~" + path.slice(home.length) : path
  }

  // The switch's own row states what applying does, so this line adds only what
  // the switch cannot: failures, the missing hook, and when it last ran.
  readonly property string applyStatusText: {
    if (!root.service) return ""
    if (root.service.applyError !== "") return "Hyprland error: " + root.service.applyError
    if (!root.service.applyEnabled) return ""
    if (!root.service.hookInstalled) return "Rules are written, but your Hyprland config does not load them yet."
    var at = Number(root.service.appliedAt)
    if (!isFinite(at) || at <= 0) return "Applied through " + root.rulesPathShort
    return "Applied " + Qt.formatDateTime(new Date(at), "HH:mm:ss") + " through " + root.rulesPathShort
  }

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function closeForPopoutSwitch() { close() }
  function togglePanel() { popupOpen = !popupOpen }

  function workspaceOccupied(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].id === id)
        return values[i].toplevels ? values[i].toplevels.values.length > 0 : false
    }
    return false
  }

  // The panel is organised by monitor, so "current" has to mean current *on
  // this monitor*. Hyprland.focusedWorkspace names only the one workspace the
  // keyboard is on, which would leave every other monitor's card unmarked.
  function activeWorkspaceOn(monitorName) {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i] && String(values[i].name) === monitorName)
        return values[i].activeWorkspace ? Number(values[i].activeWorkspace.id) : 0
    }
    return 0
  }

  function selectWorkspace(workspace) {
    selectedWorkspaceId = Number(workspace.id)
    labelEditor.text = String(workspace.label || workspace.id)
    labelEditor.forceActiveFocus()
    labelEditor.selectAll()
  }

  function clearDropTarget() {
    dropMonitor = ""
    dropIndex = -1
  }

  function markDropTarget(monitorDescription, index) {
    dropMonitor = monitorDescription
    dropIndex = index
  }

  function commitDrop(source, monitorDescription, index) {
    root.clearDropTarget()
    if (!root.service || !source || !source.workspaceId) return false
    root.service.moveWorkspaceAt(source.workspaceId, monitorDescription, index)
    return true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onPopupOpenChanged: if (!popupOpen) clearDropTarget()

  // The panel's IPC lives on the service, which is a single object per shell.
  // A bar widget exists per monitor, so each one only acts when it is the one
  // the user is looking at.
  Connections {
    target: root.service

    function onPanelRequested(action) {
      if (!root.onFocusedMonitor) return
      if (action === "open") root.open()
      else if (action === "close") root.close()
      else root.togglePanel()
    }
  }

  // BarIconButton rather than a plain WidgetButton: it gives the icon the same
  // slot width, icon font size, and optical centering as the first-party bar
  // icons, so the glyph lines up with its neighbours and the bar's open-panel
  // underline sits centered under what is actually painted.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.configuredIcon
    tooltipText: "Dynamic workspace profiles"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.togglePanel()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root.hostWidget || root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(450))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Dynamic Workspaces"
            meta: root.service ? root.service.activeProfileName : "Loading…"
            detail: root.service && root.service.activeProfileMode === "exact" ? "SAVED" : ""
            foreground: root.panelForeground
            fontFamily: root.panelFont

            iconComponent: Component {
              Text {
                text: root.configuredIcon
                color: root.panelForeground
                font.family: root.panelFont
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            visible: root.service && root.service.configError !== ""
            text: "Config error: " + (root.service ? root.service.configError : "")
            color: root.bar ? root.bar.urgent : Color.urgent
            wrapMode: Text.WordWrap
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }

          // Unsaved monitor set: the fallback profile is in use, so offer to
          // capture the current layout as a named exact profile.
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            visible: root.service && root.service.activeProfileMode !== "exact"

            PanelSectionHeader {
              text: "THIS MONITOR SET IS NOT SAVED"
              foreground: root.panelForeground
              fontFamily: root.panelFont
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.controlGap

              TextField {
                id: profileNameEditor
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                placeholderText: "Profile name for this monitor setup"
                text: "My monitor setup"
                foreground: root.panelForeground
                accent: Color.accent
                onAccepted: saveSetupButton.clicked()
              }

              Button {
                id: saveSetupButton
                Layout.alignment: Qt.AlignVCenter
                text: "Save setup"
                bordered: true
                foreground: root.panelForeground
                fontFamily: root.panelFont
                onClicked: {
                  if (root.service && root.service.saveCurrentSetup(profileNameEditor.text))
                    profileNameEditor.text = "My monitor setup"
                }
              }
            }
          }

          PanelSeparator { foreground: root.panelForeground }

          // Applying is a setting with a state and a consequence, not a title-bar
          // affordance, so it gets a section of its own rather than a third
          // element competing with the title and the SAVED pill in the hero.
          // Its status and the missing-hook hint live here too, next to the
          // switch they describe.
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "APPLY TO HYPRLAND"
              foreground: root.panelForeground
              fontFamily: root.panelFont
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.controlGap

              ToggleSwitch {
                id: applySwitch
                Layout.alignment: Qt.AlignVCenter
                checked: root.service ? root.service.applyEnabled === true : false
                foreground: root.panelForeground
                onToggled: if (root.service) root.service.setApply(!root.service.applyEnabled)

                PanelToolTip {
                  visible: applySwitch.containsMouse
                  text: root.service && root.service.applyEnabled
                    ? "Stop applying workspace assignments"
                    : "Apply workspace assignments to Hyprland"
                  fontFamily: root.panelFont
                }
              }

              Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: root.service && root.service.applyEnabled
                  ? "Hyprland follows this profile."
                  : "Hyprland keeps the workspace rules from your own config."
                color: root.panelForeground
                wrapMode: Text.WordWrap
                font.family: root.panelFont
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: root.applyStatusText
              color: root.applyStatusUrgent ? (root.bar ? root.bar.urgent : Color.urgent) : root.panelDim
              wrapMode: Text.WordWrap
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
            }

            // Hyprland runs the generated module only once the user's own config
            // loads it. The plugin will not edit ~/.config/hypr itself, so the
            // missing line is shown here to be copied.
            Rectangle {
              width: parent.width
              visible: root.applyNeedsHook
              implicitHeight: hookText.implicitHeight + Style.space(20)
              color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.05)
              radius: Style.cornerRadius

              Column {
                id: hookText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.spacing.labelGap

                Text {
                  width: parent.width
                  text: "Add this line to ~/.config/hypr/hyprland.lua:"
                  color: root.panelForeground
                  wrapMode: Text.WordWrap
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                }

                TextEdit {
                  width: parent.width
                  text: root.service ? root.service.hookLine : ""
                  color: Color.accent
                  readOnly: true
                  selectByMouse: true
                  wrapMode: Text.WrapAnywhere
                  selectionColor: Style.selectionFillFor(root.panelForeground, Color.accent)
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { foreground: root.panelForeground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "MONITORS"
              foreground: root.panelForeground
              fontFamily: root.panelFont
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.service ? root.service.groups : []

                MonitorCard {
                  required property var modelData
                  width: parent.width
                  group: modelData
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.panelForeground
            visible: root.selectedWorkspaceId > 0
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            visible: root.selectedWorkspaceId > 0

            PanelSectionHeader {
              text: "WORKSPACE " + root.selectedWorkspaceId
              foreground: root.panelForeground
              fontFamily: root.panelFont
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.controlGap

              TextField {
                id: labelEditor
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                placeholderText: "Number, emoji, icon, or text"
                foreground: root.panelForeground
                accent: Color.accent
                onAccepted: saveLabelButton.clicked()
              }

              Button {
                id: saveLabelButton
                Layout.alignment: Qt.AlignVCenter
                text: "Save label"
                bordered: true
                foreground: root.panelForeground
                fontFamily: root.panelFont
                onClicked: if (root.service) root.service.setWorkspaceLabel(root.selectedWorkspaceId, labelEditor.text)
              }

              PanelActionButton {
                Layout.alignment: Qt.AlignVCenter
                iconText: "󰆴"
                tooltipText: "Remove from this profile"
                foreground: root.panelForeground
                hoverColor: root.bar ? root.bar.urgent : Color.urgent
                fontFamily: root.panelFont
                onClicked: {
                  if (root.service) root.service.removeWorkspace(root.selectedWorkspaceId)
                  root.selectedWorkspaceId = 0
                  labelEditor.text = ""
                }
              }
            }
          }

          PanelSeparator { foreground: root.panelForeground }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "DIVIDER"
              foreground: root.panelForeground
              fontFamily: root.panelFont
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.controlGap

              TextField {
                id: dividerEditor
                Layout.preferredWidth: Style.space(90)
                Layout.alignment: Qt.AlignVCenter
                text: root.service ? root.service.activeDivider : "|"
                placeholderText: "|"
                horizontalAlignment: Text.AlignHCenter
                foreground: root.panelForeground
                accent: Color.accent
                onAccepted: saveDividerButton.clicked()
              }

              Button {
                id: saveDividerButton
                Layout.alignment: Qt.AlignVCenter
                text: "Save"
                bordered: true
                foreground: root.panelForeground
                fontFamily: root.panelFont
                onClicked: if (root.service) root.service.setDivider(dividerEditor.text)
              }

              Item { Layout.fillWidth: true }
            }

            Text {
              width: parent.width
              text: "Shown between monitor groups on the bar."
              color: root.panelDim
              wrapMode: Text.WordWrap
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.panelForeground }

          Column {
            id: focusSection
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "ACTIVE WORKSPACE"
              foreground: root.panelForeground
              fontFamily: root.panelFont
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.controlGap

              // The character is its own switch: there is nothing to turn on,
              // you either give it one or leave the field empty.
              TextField {
                id: focusMarkEditor
                Layout.preferredWidth: Style.space(90)
                Layout.alignment: Qt.AlignVCenter
                text: root.service ? String(root.service.focusMark) : ""
                placeholderText: "\u25cf"
                horizontalAlignment: Text.AlignHCenter
                foreground: root.panelForeground
                accent: Color.accent
                onAccepted: saveFocusMarkButton.clicked()
              }

              Button {
                id: saveFocusMarkButton
                Layout.alignment: Qt.AlignVCenter
                text: "Save"
                bordered: true
                foreground: root.panelForeground
                fontFamily: root.panelFont
                onClicked: if (root.service) root.service.setFocusMark(focusMarkEditor.text)
              }

              Item { Layout.fillWidth: true }
            }

            Text {
              width: parent.width
              text: "The workspace you are looking at is drawn in the bar's own color, the ones holding windows in the accent. Put a character here — text, emoji, or Nerd Font glyph — and the focused workspace shows it in place of its number. Empty keeps the number."
              color: root.panelDim
              wrapMode: Text.WordWrap
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.panelForeground }

          Text {
            width: parent.width
            text: "Drag a chip to reorder it or move it to another monitor. Click a chip to rename it."
            color: root.panelDim
            wrapMode: Text.WordWrap
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // One monitor of the active profile: identity header, inline add button, and
  // the draggable chip row. Chips are laid out flush with the header text; the
  // insertion marker is drawn inside the chip cells rather than as extra
  // spacer items, so nothing shifts sideways while a drag is in flight.
  component MonitorCard: Rectangle {
    id: card
    required property var group

    readonly property string name: String(card.group.name)
    readonly property string description: String(card.group.description)
    readonly property int workspaceCount: card.group.workspaces.length
    readonly property bool dropActive: root.dropMonitor === card.description
    // Nothing in the config assigns this monitor: the default profile handed it
    // a block of workspaces so the bar is never empty on an unfamiliar screen.
    readonly property bool automatic: card.group.automatic === true
    // Another connected screen reports the same EDID description. Assignments
    // and Hyprland's `desc:` selector are both keyed by it, so the two cannot
    // be given different workspaces.
    readonly property bool shared: card.group.shared === true

    implicitHeight: cardContent.implicitHeight + Style.space(12) * 2
    color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.05)
    radius: Style.cornerRadius

    Column {
      id: cardContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(12)
      spacing: Style.space(8)

      RowLayout {
        width: parent.width
        spacing: Style.spacing.controlGap

        Text {
          Layout.alignment: Qt.AlignVCenter
          text: String(card.group.name)
          color: root.panelForeground
          font.family: root.panelFont
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          visible: card.automatic
          implicitWidth: automaticLabel.implicitWidth + Style.space(10)
          implicitHeight: automaticLabel.implicitHeight + Style.space(4)
          radius: height / 2
          color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.10)

          Text {
            id: automaticLabel
            anchors.centerIn: parent
            text: "AUTO"
            color: root.panelDim
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          HoverHandler { id: automaticHover }

          PanelToolTip {
            visible: automaticHover.hovered
            text: "Assigned automatically because no profile names this monitor. Editing it here pins the whole layout."
            fontFamily: root.panelFont
          }
        }

        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          visible: card.shared
          implicitWidth: sharedLabel.implicitWidth + Style.space(10)
          implicitHeight: sharedLabel.implicitHeight + Style.space(4)
          radius: height / 2
          color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.10)

          Text {
            id: sharedLabel
            anchors.centerIn: parent
            text: "SHARED"
            color: root.panelDim
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          HoverHandler { id: sharedHover }

          PanelToolTip {
            visible: sharedHover.hovered
            text: "Another connected screen reports the same description, and Hyprland cannot tell them apart. They share one set of workspaces."
            fontFamily: root.panelFont
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          text: card.description
          color: root.panelDim
          elide: Text.ElideRight
          font.family: root.panelFont
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          Layout.alignment: Qt.AlignVCenter
          iconText: "+"
          tooltipText: "Add the next free workspace to this monitor"
          foreground: root.panelForeground
          fontFamily: root.panelFont
          onClicked: {
            if (!root.service) return
            var workspaceId = root.service.addWorkspace(card.description)
            if (workspaceId > 0) {
              root.selectedWorkspaceId = workspaceId
              labelEditor.text = String(workspaceId)
            }
          }
        }
      }

      RowLayout {
        id: chipRow
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: card.group.workspaces

          Item {
            id: chipCell
            required property var modelData
            required property int index

            readonly property int workspaceId: Number(chipCell.modelData.id)
            readonly property bool selected: root.selectedWorkspaceId === chipCell.workspaceId
            // Live compositor state, read here rather than carried in the
            // service's model: folding it into the model would rebuild every
            // chip in the panel on each focus change, mid-drag included.
            //
            // "Current on its own monitor" rather than "holds the keyboard":
            // each card then marks the workspace that screen is actually
            // showing, which is the question the panel is laid out to answer.
            readonly property bool focused: root.activeWorkspaceOn(card.name) === chipCell.workspaceId
            readonly property bool occupied: root.workspaceOccupied(chipCell.workspaceId)
            readonly property bool markBefore: card.dropActive && root.dropIndex === chipCell.index
            readonly property bool markAfter: card.dropActive
              && root.dropIndex === card.workspaceCount
              && chipCell.index === card.workspaceCount - 1

            Layout.preferredWidth: Math.max(Style.space(30), chipLabel.implicitWidth + Style.space(18))
            Layout.preferredHeight: Style.space(30)
            Layout.alignment: Qt.AlignVCenter
            z: chipDrag.drag.active ? 100 : 1

            // Insertion markers. Drawn half inside the row gap so the target
            // slot reads as the seam between two chips.
            Rectangle {
              visible: chipCell.markBefore
              width: Style.space(2)
              height: parent.height
              x: -Style.space(4)
              radius: width / 2
              color: Color.accent
            }

            Rectangle {
              visible: chipCell.markAfter
              width: Style.space(2)
              height: parent.height
              x: parent.width + Style.space(2)
              radius: width / 2
              color: Color.accent
            }

            DropArea {
              anchors.fill: parent
              onPositionChanged: function(drag) {
                root.markDropTarget(
                  card.description,
                  drag.x > width / 2 ? chipCell.index + 1 : chipCell.index)
              }
              onExited: if (card.dropActive && root.dropIndex === chipCell.index) root.clearDropTarget()
              onDropped: function(drop) {
                var index = root.dropIndex >= 0 ? root.dropIndex : chipCell.index
                if (root.commitDrop(drop.source, card.description, index)) drop.acceptProposedAction()
              }
            }

            Rectangle {
              id: chip
              property int workspaceId: chipCell.workspaceId

              width: chipCell.width
              height: chipCell.height
              radius: Style.cornerRadius
              color: chipCell.focused
                ? Style.selectedFillFor(root.panelForeground, Color.accent)
                : Style.normalFillFor(root.panelForeground, Color.accent)
              border.width: chipCell.selected ? Math.max(1, Style.normalBorderWidth) : 0
              border.color: Color.accent
              opacity: chipCell.occupied || chipCell.focused ? 1.0 : 0.55

              Drag.active: chipDrag.drag.active
              Drag.source: chip
              Drag.hotSpot.x: width / 2
              Drag.hotSpot.y: height / 2

              Behavior on color { ColorAnimation { duration: 120 } }

              Text {
                id: chipLabel
                anchors.centerIn: parent
                text: String(chipCell.modelData.label)
                color: root.panelForeground
                font.bold: chipCell.focused
                font.family: root.panelFont
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: chipDrag
                anchors.fill: parent
                cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                drag.target: chip
                drag.axis: Drag.XAndYAxis
                onClicked: root.selectWorkspace(chipCell.modelData)
                onReleased: {
                  chip.Drag.drop()
                  chip.x = 0
                  chip.y = 0
                  root.clearDropTarget()
                }
              }
            }
          }
        }

        // Tail target: appends on drop and doubles as the empty-monitor hint.
        Item {
          id: chipTail
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          Layout.minimumWidth: Style.space(40)

          Rectangle {
            visible: card.dropActive && root.dropIndex === card.workspaceCount && card.workspaceCount === 0
            anchors.left: parent.left
            width: Style.space(2)
            height: parent.height
            radius: width / 2
            color: Color.accent
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: card.workspaceCount === 0 ? 0 : Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            visible: card.workspaceCount === 0
            text: "Drop a workspace here or press +"
            color: root.panelDim
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }

          DropArea {
            anchors.fill: parent
            onPositionChanged: root.markDropTarget(card.description, card.workspaceCount)
            onExited: if (card.dropActive && root.dropIndex === card.workspaceCount) root.clearDropTarget()
            onDropped: function(drop) {
              if (root.commitDrop(drop.source, card.description, card.workspaceCount)) drop.acceptProposedAction()
            }
          }
        }
      }
    }
  }
}
