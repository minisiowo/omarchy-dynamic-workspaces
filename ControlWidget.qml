import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
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
        if (Number(workspaces[w].id) === id) return String(workspaces[w].label) !== String(id)
      }
    }
    return false
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
                onClicked: if (root.service) root.service.setWorkspaceLabel(root.selectedWorkspaceId, labelEditor.text)
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
                  if (root.service) root.service.setWorkspaceLabel(root.selectedWorkspaceId, "")
                  labelEditor.text = String(root.selectedWorkspaceId)
                }
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

            Text {
              width: parent.width
              // The lesson of a workspace named "4" that nothing on the keyboard
              // reaches: the name is decoration, the number is the address.
              text: "Keyboard shortcuts follow the workspace number, not the name shown here."
                + (root.selectedWorkspaceId === 10
                  ? " Omarchy binds workspace 10 to SUPER + 0."
                  : "")
              color: root.panelDim
              wrapMode: Text.WordWrap
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
            }
          }

          // The bar only draws a divider between two groups, so with a single
          // screen there is nothing for this to divide.
          PanelSeparator {
            foreground: root.panelForeground
            visible: dividerSection.visible
          }

          Column {
            id: dividerSection
            width: parent.width
            spacing: Style.spacing.labelGap
            visible: root.service && root.service.populatedGroupCount > 1

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
                text: "Color"
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
                text: focusSection.mark === "" ? "Replace" : focusSection.mark
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

            Text {
              width: parent.width
              text: "The workspace you are looking at is drawn in the bar's own color, the ones holding windows in the accent. Replace shows a character in place of its number instead — click it again to change the character to any text, emoji, or Nerd Font glyph."
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
            // A name of its own hides which workspace this actually is, and the
            // number is the part that matters outside this panel: the keyboard
            // shortcuts follow it, not the name. So a renamed chip carries both.
            readonly property bool renamed: String(chipCell.modelData.label) !== String(chipCell.workspaceId)
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
              Style.space(30),
              Math.max(chipLabel.implicitWidth, chipNumber.visible ? chipNumber.implicitWidth : 0) + Style.space(18))
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

              Column {
                anchors.centerIn: parent
                spacing: 0

                Text {
                  id: chipLabel
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: String(chipCell.modelData.label)
                  color: root.panelForeground
                  font.bold: chipCell.focused
                  font.family: root.panelFont
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: chipNumber
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: chipCell.renamed
                  text: String(chipCell.workspaceId)
                  color: root.panelDim
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                }
              }

              HoverHandler { id: chipHover }

              PanelToolTip {
                visible: chipHover.hovered && chipCell.renamed
                text: "Workspace " + chipCell.workspaceId + " \u2014 shown as \"" + chipCell.modelData.label + "\""
                fontFamily: root.panelFont
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
