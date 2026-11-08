import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ProfileLogic.js" as ProfileLogic

BarWidget {
  id: root
  moduleName: "io.github.minisiowo.dynamic-workspaces"

  property bool popupOpen: false
  // The chip being renamed: its real id, and the monitor and slot that name it in
  // the profile.
  property int selectedWorkspaceId: 0
  property string selectedMonitor: ""
  property int selectedSlot: 0
  property string selectedNumber: ""
  property var hostWidget: null
  property string expandedProfileId: ""

  // Live drop target while a chip is being dragged along its row. `dropMonitor`
  // is the monitor it belongs to, `dropIndex` the insertion point in that row.
  // Both are cleared when the drag ends.
  property string dropMonitor: ""
  property int dropIndex: -1

  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property string configuredIcon: String(setting("icon", "󰕰"))
  // The field a pending paste belongs to. Cleared as soon as it lands, so a
  // result that arrives after the panel moved on has nowhere to go.
  property var pasteTarget: null
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

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function closeForPopoutSwitch() { close() }
  function togglePanel() { popupOpen = !popupOpen }

  // Qt's own clipboard hands back nothing on this surface, which is why the rest
  // of the shell shells out to wl-copy / wl-paste as well. Without this, the
  // panel's text fields can only be typed into.
  function pasteInto(field) {
    if (!field || pasteProcess.running) return
    root.pasteTarget = field
    pasteProcess.running = true
  }

  function finishPaste(raw) {
    var field = root.pasteTarget
    root.pasteTarget = null
    if (!field) return

    // These fields are all labels on a bar: one line, and not an essay. A
    // clipboard holding a file or a paragraph would otherwise be pasted whole.
    var value = String(raw || "").split("\n")[0].substring(0, 64)
    if (value === "") return

    // insert() leaves a selection where it is, and the mark field selects its
    // contents when it opens, so the old value has to go first.
    if (field.selectedText !== "") field.remove(field.selectionStart, field.selectionEnd)
    field.insert(field.cursorPosition, value)
  }

  // Whether the selected workspace carries a name of its own. Read from the
  // service's groups rather than tracked alongside selectedWorkspaceId, so it
  // follows a label that was just saved without a second place to keep in sync.
  function workspaceRenamed(id) {
    if (!root.service || id <= 0) return false
    var groups = root.service.groups
    for (var g = 0; g < groups.length; g++) {
      var workspaces = groups[g].workspaces
      for (var w = 0; w < workspaces.length; w++) {
        if (Number(workspaces[w].id) === id) return String(workspaces[w].label) !== String(workspaces[w].number)
      }
    }
    return false
  }

  // Workspaces this monitor is showing or holding that the profile does not list
  // for it, so what is on them can still be reached.
  function strandedOn(monitorName) {
    if (!root.service) return []
    var all = root.service.strandedWorkspaces
    var result = []
    for (var i = 0; i < all.length; i++) {
      if (all[i].monitor === monitorName) result.push(all[i])
    }
    return result
  }

  function focusWorkspace(workspace) {
    if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote(ProfileLogic.focusExpression(workspace)))
  }

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

  function selectWorkspace(workspace, monitorDescription) {
    selectedWorkspaceId = Number(workspace.id)
    selectedMonitor = monitorDescription
    selectedSlot = Number(workspace.slot)
    selectedNumber = String(workspace.number)
    labelEditor.text = String(workspace.label || workspace.number)
    labelEditor.forceActiveFocus()
    labelEditor.selectAll()
  }

  function clearDropTarget() {
    dropMonitor = ""
    dropIndex = -1
  }

  // Chips only move along their own row: every monitor has its own slot 1, so
  // there is no such thing as the same workspace on another screen.
  function markDropTarget(source, monitorDescription, index) {
    if (!source || source.monitorDescription !== monitorDescription) {
      clearDropTarget()
      return
    }
    dropMonitor = monitorDescription
    dropIndex = index
  }

  function commitDrop(source, monitorDescription, index) {
    root.clearDropTarget()
    if (!root.service || !source || source.monitorDescription !== monitorDescription) return false
    root.service.moveSlot(monitorDescription, source.workspaceSlot, index)
    return true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onPopupOpenChanged: if (!popupOpen) {
    clearDropTarget()
    appearanceToggle.expanded = false
    profilesToggle.expanded = false
  }

  Timer {
    id: savedFeedback
    interval: 2000
  }

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
            meta: root.service ? "Profile: " + root.service.activeProfileName : "Loading…"
            detail: savedFeedback.running ? "SAVED" : ""
            foreground: root.panelForeground
            fontFamily: root.panelFont

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            text: "Config error: " + (root.service ? root.service.configError : "")
            color: root.bar ? root.bar.urgent : Color.urgent
            wrapMode: Text.WordWrap
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { foreground: root.panelForeground }

          Repeater {
            model: root.service ? root.service.groups : []

            MonitorCard {
              required property var modelData
              width: parent.width
              group: modelData
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
              text: "WORKSPACE " + root.selectedNumber
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
                Keys.onPressed: function(event) {
                  if (event.matches(StandardKey.Paste)) {
                    root.pasteInto(labelEditor)
                    event.accepted = true
                  }
                }
              }

              Button {
                id: saveLabelButton
                Layout.alignment: Qt.AlignVCenter
                text: "Save label"
                bordered: true
                foreground: root.panelForeground
                fontFamily: root.panelFont
                onClicked: if (root.service) root.service.setWorkspaceLabel(root.selectedMonitor, root.selectedSlot, labelEditor.text)
              }

              PanelActionButton {
                Layout.alignment: Qt.AlignVCenter
                visible: root.workspaceRenamed(root.selectedWorkspaceId)
                iconText: "󰕌"
                tooltipText: "Back to the workspace number"
                foreground: root.panelForeground
                hoverColor: Color.accent
                fontFamily: root.panelFont
                onClicked: {
                  if (root.service) root.service.setWorkspaceLabel(root.selectedMonitor, root.selectedSlot, "")
                  labelEditor.text = root.selectedNumber
                }
              }

              PanelActionButton {
                Layout.alignment: Qt.AlignVCenter
                iconText: "󰆴"
                tooltipText: "Stop showing this one in this profile"
                foreground: root.panelForeground
                hoverColor: root.bar ? root.bar.urgent : Color.urgent
                fontFamily: root.panelFont
                onClicked: {
                  if (root.service) root.service.removeSlot(root.selectedMonitor, root.selectedSlot)
                  root.selectedWorkspaceId = 0
                  labelEditor.text = ""
                }
              }
            }

            Text {
              width: parent.width
              text: "Shortcut on this monitor: Super + " + root.selectedNumber
              color: root.panelDim
              wrapMode: Text.WordWrap
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.panelForeground }

          DisclosureButton {
            id: appearanceToggle
            text: "Bar appearance"
          }

          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: appearanceToggle.expanded

            Column {
              id: focusSection
              width: parent.width
              spacing: Style.spacing.labelGap

              // Empty means the number stays, so the stored character is the whole
              // setting. The last one used is remembered here rather than in the
              // config, so switching to Color and back does not make you type it
              // again, and switching away does not leave a value behind that would
              // outlive the panel.
              readonly property string mark: root.service ? String(root.service.focusMark) : ""
              readonly property string defaultMark: root.service ? String(root.service.defaultFocusMark) : "\u25cf"
              property string lastMark: focusSection.defaultMark
              property bool editing: false

              onMarkChanged: if (mark !== "") lastMark = mark

              PanelSectionHeader {
                text: "ACTIVE WORKSPACE"
                foreground: root.panelForeground
                fontFamily: root.panelFont
              }

              RowLayout {
                width: parent.width
                spacing: Style.spacing.controlGap

                Button {
                  Layout.alignment: Qt.AlignVCenter
                  focusable: true
                  text: "Color [3]"
                  tooltipText: "Keep the workspace number and highlight it with color."
                  bordered: true
                  selected: focusSection.mark === ""
                  foreground: root.panelForeground
                  fontFamily: root.panelFont
                  onClicked: {
                    focusSection.editing = false
                    if (root.service) root.service.setFocusMark("")
                  }
                }

                // One button doing two jobs, so the character does not need a row
                // of its own: off, it says what it does; on, it shows the character
                // it is painting, and clicking it again turns it into the field
                // that edits it.
                Button {
                  Layout.alignment: Qt.AlignVCenter
                  visible: !focusSection.editing
                  focusable: true
                  text: "Symbol [" + (focusSection.mark || focusSection.lastMark) + "]"
                  Layout.maximumWidth: Style.space(180)
                  tooltipText: focusSection.mark === ""
                    ? "Show a symbol in place of the number."
                    : "Click to change the symbol."
                  bordered: true
                  selected: focusSection.mark !== ""
                  foreground: root.panelForeground
                  fontFamily: root.panelFont
                  onClicked: {
                    if (focusSection.mark === "") {
                      if (root.service) root.service.setFocusMark(focusSection.lastMark)
                    } else {
                      focusSection.editing = true
                    }
                  }
                }

                TextField {
                  id: focusMarkEditor
                  Layout.preferredWidth: Style.space(60)
                  Layout.alignment: Qt.AlignVCenter
                  visible: focusSection.editing
                  placeholderText: focusSection.defaultMark
                  horizontalAlignment: Text.AlignHCenter
                  foreground: root.panelForeground
                  accent: Color.accent
                  // Tracked rather than trusting the first focus change: the
                  // panel primes its own key catcher when it opens, so a field
                  // that has not been typed in yet can see focus taken away from
                  // it and must not read that as the user leaving.
                  property bool everFocused: false

                  onVisibleChanged: if (visible) {
                    text = focusSection.mark
                    everFocused = false
                    forceActiveFocus()
                    selectAll()
                  }
                  // Leaving the field is as good as pressing Enter: there is no
                  // Save button beside it any more, and losing the edit because
                  // you clicked elsewhere would be worse than keeping it.
                  onActiveFocusChanged: {
                    if (activeFocus) everFocused = true
                    else if (everFocused && focusSection.editing) accepted()
                  }
                  onAccepted: {
                    focusSection.editing = false
                    if (root.service) root.service.setFocusMark(focusMarkEditor.text)
                  }
                  Keys.onPressed: function(event) {
                    if (event.matches(StandardKey.Paste)) {
                      root.pasteInto(focusMarkEditor)
                      event.accepted = true
                    }
                  }
                }

                // Only worth showing once the character is something you picked:
                // there is nothing to undo while it is off or still the default.
                PanelActionButton {
                  Layout.alignment: Qt.AlignVCenter
                  visible: focusSection.mark !== "" && focusSection.mark !== focusSection.defaultMark
                  iconText: "󰕌"
                  tooltipText: "Back to the default mark"
                  foreground: root.panelForeground
                  hoverColor: Color.accent
                  fontFamily: root.panelFont
                  onClicked: {
                    focusSection.editing = false
                    if (root.service) root.service.setFocusMark(focusSection.defaultMark)
                  }
                }

                Item { Layout.fillWidth: true }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap
              visible: root.service && root.service.populatedGroupCount > 1

              PanelSectionHeader {
                text: "MONITOR DIVIDER"
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
                  Keys.onPressed: function(event) {
                    if (event.matches(StandardKey.Paste)) {
                      root.pasteInto(dividerEditor)
                      event.accepted = true
                    }
                  }
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
            }
          }

          DisclosureButton {
            id: profilesToggle
            text: "Profiles (" + (root.service ? root.service.savedProfiles.length : 0) + ")"
            onExpandedChanged: if (!expanded) {
              root.expandedProfileId = ""
              presetsToggle.expanded = false
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: profilesToggle.expanded

            Column {
              anchors.left: parent.left
              anchors.leftMargin: profilesToggle.labelInset
              anchors.right: parent.right
              spacing: Style.spacing.labelGap
              visible: root.service && root.service.activeProfileMode !== "exact"

              PanelSectionHeader {
                text: "SAVE THIS MONITOR SET"
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
                  Keys.onPressed: function(event) {
                    if (event.matches(StandardKey.Paste)) {
                      root.pasteInto(profileNameEditor)
                      event.accepted = true
                    }
                  }
                }

                Button {
                  id: saveSetupButton
                  Layout.alignment: Qt.AlignVCenter
                  text: "Save setup"
                  bordered: true
                  foreground: root.panelForeground
                  fontFamily: root.panelFont
                  onClicked: {
                    if (root.service && root.service.saveCurrentSetup(profileNameEditor.text)) {
                      profileNameEditor.text = "My monitor setup"
                      savedFeedback.restart()
                    }
                  }
                }
              }
            }

            Repeater {
              model: root.service ? root.service.savedProfiles : []

              Column {
                id: profileRow
                required property var modelData
                anchors.left: parent.left
                anchors.leftMargin: profilesToggle.labelInset
                anchors.right: parent.right
                spacing: Style.spacing.labelGap

                readonly property bool isActive: root.service && root.service.activeProfileId === modelData.id
                readonly property bool isDefault: modelData.mode === "default"
                readonly property bool expanded: root.expandedProfileId === modelData.id
                readonly property bool canDelete: !isDefault && root.service && root.service.savedProfiles.length > 1

                RowLayout {
                  width: parent.width
                  spacing: Style.spacing.controlGap

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: profileRow.modelData.name
                    elide: Text.ElideRight
                    color: root.panelForeground
                    font.family: root.panelFont
                    font.pixelSize: Style.font.bodySmall
                    font.bold: profileRow.isActive
                  }

                  Text {
                    visible: profileRow.isActive
                    text: "Active"
                    color: root.panelDim
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                  }

                  PanelActionButton {
                    focusable: true
                    iconText: "⋯"
                    tooltipText: profileRow.expanded ? "Hide profile details" : "Show profile details"
                    foreground: root.panelForeground
                    fontFamily: root.panelFont
                    onClicked: root.expandedProfileId = profileRow.expanded ? "" : profileRow.modelData.id
                  }
                }

                RowLayout {
                  width: parent.width
                  visible: profileRow.expanded
                  spacing: Style.spacing.controlGap

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: profileRow.isDefault ? "Default for unmatched monitor setups"
                      : profileRow.modelData.monitors.join("\n")
                    wrapMode: Text.Wrap
                    color: root.panelDim
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                  }

                  Button {
                    visible: profileRow.canDelete
                    text: "Delete profile"
                    bordered: true
                    focusable: true
                    foreground: root.bar ? root.bar.urgent : Color.urgent
                    fontFamily: root.panelFont
                    onClicked: if (root.service) {
                      root.expandedProfileId = ""
                      root.service.removeProfile(profileRow.modelData.id)
                    }
                  }
                }
              }
            }

            DisclosureButton {
              id: presetsToggle
              text: "Default profile presets"
            }

            Column {
              anchors.left: parent.left
              anchors.leftMargin: presetsToggle.labelInset
              anchors.right: parent.right
              spacing: Style.space(8)
              visible: presetsToggle.expanded

              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.service && root.service.monitorPresets.length > 0

                Repeater {
                  model: root.service ? root.service.monitorPresets : []

                  RowLayout {
                    required property var modelData
                    width: parent.width
                    spacing: Style.spacing.controlGap

                    Text {
                      Layout.fillWidth: true
                      Layout.alignment: Qt.AlignVCenter
                      textFormat: Text.PlainText
                      text: modelData.description + "  (" + modelData.workspaces.join(", ") + ")"
                        + (modelData.connected ? "" : "  — not connected")
                      color: root.panelDim
                      elide: Text.ElideRight
                      font.family: root.panelFont
                      font.pixelSize: Style.font.caption
                    }

                    PanelActionButton {
                      Layout.alignment: Qt.AlignVCenter
                      iconText: "󰆴"
                      tooltipText: "Forget this monitor's preset"
                      foreground: root.panelForeground
                      hoverColor: root.bar ? root.bar.urgent : Color.urgent
                      fontFamily: root.panelFont
                      onClicked: if (root.service) root.service.forgetMonitor(modelData.description)
                    }
                  }
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.spacing.controlGap

                TextField {
                  id: presetDescriptionEditor
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  placeholderText: "Monitor description"
                  foreground: root.panelForeground
                  accent: Color.accent
                  onAccepted: addPresetButton.clicked()
                  Keys.onPressed: function(event) {
                    if (event.matches(StandardKey.Paste)) {
                      root.pasteInto(presetDescriptionEditor)
                      event.accepted = true
                    }
                  }
                }

                Button {
                  id: addPresetButton
                  Layout.alignment: Qt.AlignVCenter
                  text: "Add preset"
                  bordered: true
                  tooltipText: "Chooses which workspaces a monitor shows, by description, before it is ever connected."
                  foreground: root.panelForeground
                  fontFamily: root.panelFont
                  onClicked: {
                    if (root.service && root.service.addMonitorPreset(presetDescriptionEditor.text)) {
                      presetDescriptionEditor.text = ""
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Process {
    id: pasteProcess
    command: ["wl-paste", "--no-newline"]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishPaste(text)
    }

    // An empty clipboard, one holding an image, or no wl-paste at all: nothing
    // to insert, and nothing to say about it either.
    onExited: function(exitCode) {
      if (exitCode !== 0) root.pasteTarget = null
    }
  }

  component DisclosureButton: Button {
    id: disclosure
    property bool expanded: false
    readonly property real labelInset: horizontalPadding + Style.normalBorderWidth

    width: parent.width
    horizontalPadding: Style.spacing.controlGap
    leftAlign: true
    focusable: true
    foreground: root.panelForeground
    background: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.09)
    fontFamily: root.panelFont
    onClicked: expanded = !expanded

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: disclosure.horizontalPadding
      anchors.verticalCenter: parent.verticalCenter
      text: "󰅀"
      rotation: disclosure.expanded ? 180 : 0
      color: root.panelDim
      font.family: disclosure.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // The insertion marker is painted inside each chip cell so the row
  // does not shift sideways while a drag is in flight.
  component MonitorCard: Rectangle {
    id: card
    required property var group

    readonly property string name: String(card.group.name)
    readonly property string description: String(card.group.description)
    readonly property string monitorModel: {
      var monitors = Hyprland.monitors.values
      for (var i = 0; i < monitors.length; i++) {
        if (monitors[i].name === card.group.name) {
          var info = monitors[i].lastIpcObject
          return String(info && info.model || "")
        }
      }
      return ""
    }
    readonly property int workspaceCount: card.group.workspaces.length
    readonly property bool dropActive: root.dropMonitor === card.description
    // Nothing in the config assigns this monitor: the default profile handed it
    // a block of workspaces so the bar is never empty on an unfamiliar screen.
    readonly property bool automatic: card.group.automatic === true
    // Another connected screen reports the same EDID description. Profiles are
    // keyed by it, so the two show the same chips, each in its own block.
    readonly property bool shared: card.group.shared === true
    // A renamed workspace prints its number under its chip. The whole row
    // reserves that line, not just the renamed chips, or the squares would end
    // up at different heights and stop lining up.
    readonly property bool anyRenamed: {
      var workspaces = card.group.workspaces
      for (var i = 0; i < workspaces.length; i++) {
        if (String(workspaces[i].label) !== String(workspaces[i].number)) return true
      }
      return false
    }
    readonly property int chipSize: Style.space(30)
    readonly property int captionHeight: card.anyRenamed ? Style.space(12) : 0

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
            text: "Shown automatically because no profile names this monitor. Editing it here saves the whole layout."
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
            text: "Another connected screen reports the same description, so a profile cannot tell them apart. Both show this row, each with workspaces of its own."
            fontFamily: root.panelFont
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: card.monitorModel
          color: root.panelDim
          elide: Text.ElideRight
          font.family: root.panelFont
          font.pixelSize: Style.font.caption

          HoverHandler { id: monitorHover }

          PanelToolTip {
            visible: monitorHover.hovered
            width: Math.min(implicitWidth, card.width)
            text: card.description
            fontFamily: root.panelFont
          }
        }

        PanelActionButton {
          Layout.alignment: Qt.AlignVCenter
          iconText: "+"
          tooltipText: "Show the next workspace of this monitor"
          foreground: root.panelForeground
          fontFamily: root.panelFont
          onClicked: {
            if (!root.service) return
            var slot = root.service.addSlot(card.description)
            if (slot > 0) {
              var number = ProfileLogic.slotNumber(slot)
              root.selectWorkspace({
                id: ProfileLogic.workspaceIdFor(card.group.block, slot),
                slot: slot,
                number: number,
                label: number
              }, card.description)
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
            // A name of its own hides which workspace this actually is, and the
            // number is the part that matters outside this panel: the keyboard
            // shortcuts follow it, not the name. So a renamed chip carries both.
            readonly property string number: String(chipCell.modelData.number)
            readonly property bool renamed: String(chipCell.modelData.label) !== chipCell.number
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

            Layout.preferredWidth: Math.max(
              card.chipSize,
              Math.max(chipLabel.implicitWidth, chipNumber.visible ? chipNumber.implicitWidth : 0) + Style.space(18))
            Layout.preferredHeight: card.chipSize + card.captionHeight
            Layout.alignment: Qt.AlignVCenter
            z: chipDrag.drag.active ? 100 : 1

            // Insertion markers. Drawn half inside the row gap so the target
            // slot reads as the seam between two chips.
            Rectangle {
              visible: chipCell.markBefore
              width: Style.space(2)
              height: card.chipSize
              x: -Style.space(4)
              radius: width / 2
              color: Color.accent
            }

            Rectangle {
              visible: chipCell.markAfter
              width: Style.space(2)
              height: card.chipSize
              x: parent.width + Style.space(2)
              radius: width / 2
              color: Color.accent
            }

            DropArea {
              anchors.fill: parent
              onPositionChanged: function(drag) {
                root.markDropTarget(
                  drag.source,
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
              readonly property int workspaceSlot: Number(chipCell.modelData.slot)
              readonly property string monitorDescription: card.description

              width: chipCell.width
              // The square keeps its own size; the cell may be taller to leave
              // room for the number underneath. No anchors — dragging moves this
              // by x/y, and an anchored item cannot be dragged.
              height: card.chipSize
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
                textFormat: Text.PlainText
                text: String(chipCell.modelData.label)
                color: root.panelForeground
                font.bold: chipCell.focused
                font.family: root.panelFont
                font.pixelSize: Style.font.body
              }

              // Below the square rather than inside it: two lines never fit a
              // 30px chip without crowding each other. A child of the chip, so
              // it travels along when the chip is dragged.
              Text {
                id: chipNumber
                visible: chipCell.renamed
                x: (parent.width - width) / 2
                y: parent.height + Style.space(2)
                text: chipCell.number
                color: root.panelDim
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }

              HoverHandler { id: chipHover }

              PanelToolTip {
                visible: chipHover.hovered && !chipDrag.drag.active
                text: "Click to rename · Drag to reorder"
                fontFamily: root.panelFont
              }

              MouseArea {
                id: chipDrag
                anchors.fill: parent
                cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                drag.target: chip
                drag.axis: Drag.XAndYAxis
                onClicked: root.selectWorkspace(chipCell.modelData, card.description)
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
          Layout.preferredHeight: card.chipSize
          Layout.alignment: Qt.AlignTop
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
            text: "Press + to show a workspace here"
            color: root.panelDim
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }

          DropArea {
            anchors.fill: parent
            onPositionChanged: function(drag) { root.markDropTarget(drag.source, card.description, card.workspaceCount) }
            onExited: if (card.dropActive && root.dropIndex === card.workspaceCount) root.clearDropTarget()
            onDropped: function(drop) {
              if (root.commitDrop(drop.source, card.description, card.workspaceCount)) drop.acceptProposedAction()
            }
          }
        }
      }

      RowLayout {
        id: strandedRow
        readonly property var stranded: root.strandedOn(card.name)
        visible: strandedRow.stranded.length > 0
        width: parent.width
        spacing: Style.space(6)

        Text {
          Layout.alignment: Qt.AlignVCenter
          text: "ALSO HERE"
          color: root.panelDim
          font.family: root.panelFont
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: strandedRow.stranded

          Rectangle {
            id: strandedChip
            required property var modelData

            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Math.max(Style.space(24), strandedLabel.implicitWidth + Style.space(14))
            Layout.preferredHeight: Style.space(24)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.panelForeground, Color.accent)
            border.width: Math.max(1, Style.normalBorderWidth)
            border.color: Color.accent

            Text {
              id: strandedLabel
              anchors.centerIn: parent
              text: String(strandedChip.modelData.number)
              color: root.panelForeground
              font.family: root.panelFont
              font.pixelSize: Style.font.body
            }

            HoverHandler { id: strandedHover }

            PanelToolTip {
              visible: strandedHover.hovered
              text: "Workspace " + strandedChip.modelData.number + " is on this monitor but this profile does not list it. Click to switch to it."
              fontFamily: root.panelFont
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.focusWorkspace(strandedChip.modelData)
            }
          }
        }

        Item { Layout.fillWidth: true }
      }
    }
  }
}
