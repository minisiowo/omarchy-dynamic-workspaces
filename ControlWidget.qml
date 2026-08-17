import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
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

  readonly property bool applyNeedsHook: root.service
    && root.service.applyEnabled === true
    && root.service.hookInstalled !== true
  readonly property bool applyStatusUrgent: (root.service && root.service.applyError !== "") || applyNeedsHook
  readonly property string applyStatusText: {
    if (!root.service) return ""
    if (root.service.applyError !== "") return "Hyprland error: " + root.service.applyError
    if (!root.service.applyEnabled) return "Preview only — Hyprland keeps the workspace rules from your own config."
    if (!root.service.hookInstalled) return "Rules are written, but your Hyprland config does not load them yet."
    var at = Number(root.service.appliedAt)
    if (!isFinite(at) || at <= 0) return "Applied through " + root.service.rulesPath
    return "Applied " + Qt.formatDateTime(new Date(at), "HH:mm:ss") + " through " + root.service.rulesPath
  }

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function closeForPopoutSwitch() { close() }
  function togglePanel() { popupOpen = !popupOpen }

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

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
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

          // The hero's trailingControl is instantiated inside PanelHero, where a
          // bare `root` resolves to the hero rather than to this widget, so the
          // switch reaches this widget's state through `heroBlock`.
          Item {
            id: heroBlock
            width: parent.width
            implicitHeight: hero.implicitHeight

            readonly property bool applyEnabled: root.service ? root.service.applyEnabled === true : false
            readonly property color foreground: root.panelForeground
            readonly property string fontFamily: root.panelFont

            function toggleApply() {
              if (root.service) root.service.setApply(!root.service.applyEnabled)
            }

            PanelHero {
              id: hero
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

              trailingControl: Component {
                Row {
                  spacing: Style.spacing.controlGap

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "APPLY"
                    color: Qt.darker(heroBlock.foreground, 1.4)
                    font.family: heroBlock.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  ToggleSwitch {
                    id: applySwitch
                    anchors.verticalCenter: parent.verticalCenter
                    checked: heroBlock.applyEnabled
                    foreground: heroBlock.foreground
                    onToggled: heroBlock.toggleApply()

                    PanelToolTip {
                      visible: applySwitch.containsMouse
                      text: heroBlock.applyEnabled
                        ? "Stop applying workspace assignments"
                        : "Apply workspace assignments to Hyprland"
                      fontFamily: heroBlock.fontFamily
                    }
                  }
                }
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
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "Drag a chip to reorder it or move it to another monitor. Click a chip to rename it."
              color: root.panelDim
              wrapMode: Text.WordWrap
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
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

    readonly property string description: String(card.group.description)
    readonly property int workspaceCount: card.group.workspaces.length
    readonly property bool dropActive: root.dropMonitor === card.description

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
              color: chipCell.modelData.focused
                ? Style.selectedFillFor(root.panelForeground, Color.accent)
                : Style.normalFillFor(root.panelForeground, Color.accent)
              border.width: chipCell.selected ? Math.max(1, Style.normalBorderWidth) : 0
              border.color: Color.accent
              opacity: chipCell.modelData.occupied || chipCell.modelData.focused ? 1.0 : 0.55

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
                font.bold: chipCell.modelData.focused
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
