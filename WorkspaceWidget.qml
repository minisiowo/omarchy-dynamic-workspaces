import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "minisiowo.dynamic-workspaces"

  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property var items: displayItems()
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)
  // How the focused workspace is marked, and with what. Kept in the plugin's
  // config rather than in the widget's bar settings, so both bars agree and the
  // choice is made in the same panel as everything else.
  readonly property string focusStyle: root.service ? String(root.service.focusStyle) : "color"
  readonly property string focusMark: root.service ? String(root.service.focusMark) : "\u25cf"

  function liveWorkspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].id === id) return values[i]
    }
    return null
  }

  function displayItems() {
    if (!root.service) return []

    var result = []
    var groups = root.service.groups
    var visibleGroups = []

    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      if (groups[groupIndex].workspaces.length > 0) visibleGroups.push(groups[groupIndex])
    }

    for (var visibleIndex = 0; visibleIndex < visibleGroups.length; visibleIndex++) {
      var group = visibleGroups[visibleIndex]
      if (visibleIndex > 0) {
        result.push({
          type: "divider",
          label: root.service.activeDivider,
          monitor: ""
        })
      }

      for (var workspaceIndex = 0; workspaceIndex < group.workspaces.length; workspaceIndex++) {
        var workspace = group.workspaces[workspaceIndex]
        result.push({
          type: "workspace",
          id: workspace.id,
          label: workspace.label,
          monitor: group.name
        })
      }
    }

    return result
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
    columns: root.vertical ? 1 : Math.max(1, root.items.length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.items

      WidgetButton {
        id: chip
        required property var modelData

        readonly property bool isDivider: chip.modelData.type === "divider"
        // Live state stays out of the service's model so that focusing a
        // workspace does not rebuild every chip on the bar. Each chip watches
        // Hyprland for itself instead.
        readonly property bool chipFocused: !chip.isDivider
          && Hyprland.focusedWorkspace !== null
          && Hyprland.focusedWorkspace.id === chip.modelData.id
        readonly property bool chipOccupied: {
          if (chip.isDivider) return false
          var live = root.liveWorkspaceById(chip.modelData.id)
          return live !== null && live.toplevels ? live.toplevels.values.length > 0 : false
        }

        // Every chip reserves room for the mark, focused or not, so the bar does
        // not reflow as the focus moves from one workspace to the next.
        readonly property real slotWidth: root.focusStyle === "replace"
          ? Math.max(labelMetrics.width, markMetrics.width)
          : labelMetrics.width

        bar: root.bar
        text: chip.chipFocused && root.focusStyle === "replace"
          ? root.focusMark
          : chip.modelData.label
        labelVisible: !chip.isDivider
        tooltipText: chip.isDivider
          ? ""
          : "Workspace " + chip.modelData.id + " · " + chip.modelData.monitor
        // The accent marks the workspaces that hold windows; the workspace you
        // are actually looking at keeps the bar's own foreground. That way round
        // because there is only ever one focused workspace among several
        // occupied ones, and plain white is what the eye finds first when
        // scanning the bar — accent on the one and white on the many read
        // backwards. (WidgetButton's default active role is `urgent`, which
        // every theme sets to its red and `shell.toml.tpl` documents as the
        // color for alerts. Neither of these states is an alert.)
        active: chip.chipOccupied && !chip.chipFocused
        activeColor: Color.accent
        // The divider is chrome, so it sits at the same weight as an idle
        // workspace rather than competing with the live ones.
        opacity: chip.isDivider ? 0.5 : (chip.chipOccupied || chip.chipFocused ? 1.0 : 0.5)
        verticalPadding: 6
        // Intrinsic width with a floor rather than a hard fixed width: plain
        // numbers keep the uniform slot they had, while a longer label —
        // "1: ", an emoji, a word — grows its own slot instead of painting
        // over the neighbouring workspace. Measured from the model rather than
        // read off the painted label, because in `replace` the mark stands in
        // for the number and the slot must not follow it.
        fixedWidth: root.vertical
          ? root.barSize
          : (chip.isDivider
            ? Math.max(Style.space(14), dividerGlyph.tightWidth + Style.spaceReal(10))
            : Math.max(Style.space(20), chip.slotWidth + Style.spaceReal(12)))
        fixedHeight: root.barSize
        // The divider is decoration, not a target: no tooltip, no pointer
        // cursor, no click.
        pressable: !chip.isDivider
        interactive: !chip.isDivider

        TextMetrics {
          id: labelMetrics
          font.family: chip.fontFamily
          font.pixelSize: chip.fontSize
          text: chip.modelData.label
        }

        TextMetrics {
          id: markMetrics
          font.family: chip.fontFamily
          font.pixelSize: chip.fontSize
          text: root.focusMark
        }

        DividerGlyph {
          id: dividerGlyph
          anchors.fill: parent
          visible: chip.isDivider
          label: chip.modelData.label
          fontFamily: chip.fontFamily
          fontSize: chip.fontSize
          color: chip.foreground
        }

        onPressed: function() {
          if (!chip.isDivider) root.focusWorkspace(chip.modelData.id)
        }
      }
    }
  }

  // The divider is the one mark on the bar that is not a workspace, so it has
  // to be aligned to the workspaces rather than to its own line box.
  //
  // A plain centered Text centers the *box* the glyph is laid out in, not the
  // ink inside it, and "|" is neither centered in its advance width nor as
  // tall as a digit: at 12px it paints 12px tall against the digits' 9px, and
  // sits 2px above and 1px below their band. That reads as a bar that is too
  // tall and hung too high, which is exactly what it looked like.
  //
  // So measure both: shrink the glyph until its ink is no taller than a digit
  // (only ever shrink — a small mark like "·" keeps its size), then place that
  // ink centered on the ink band of a digit rendered the way the neighbouring
  // workspace labels are. Horizontal centering follows the same rule, on the
  // painted bounds instead of the advance width.
  component DividerGlyph: Item {
    id: dividerRoot

    property string label: ""
    property string fontFamily: Style.font.family
    property real fontSize: Style.font.body
    property color color: Color.foreground

    readonly property int baseSize: Math.max(1, Math.round(fontSize))
    readonly property real referenceInkHeight: Math.max(1, referenceMetrics.tightBoundingRect.height)
    readonly property real rawInkHeight: Math.max(1, rawMetrics.tightBoundingRect.height)
    readonly property int glyphSize: Math.max(1, Math.round(
      baseSize * Math.min(1, referenceInkHeight / rawInkHeight)))
    readonly property real tightWidth: Math.max(1, glyphMetrics.tightBoundingRect.width)

    // Vertical center of the ink a workspace number paints in this slot.
    // TextMetrics reports tight bounds relative to the pen origin, so the
    // baseline the reference Text lands on carries the conversion.
    readonly property real referenceInkCenter: reference.y + reference.baselineOffset
      + referenceMetrics.tightBoundingRect.y + referenceMetrics.tightBoundingRect.height / 2

    TextMetrics {
      id: referenceMetrics
      font.family: dividerRoot.fontFamily
      font.pixelSize: dividerRoot.baseSize
      text: "0"
    }

    TextMetrics {
      id: rawMetrics
      font.family: dividerRoot.fontFamily
      font.pixelSize: dividerRoot.baseSize
      text: dividerRoot.label
    }

    TextMetrics {
      id: glyphMetrics
      font.family: dividerRoot.fontFamily
      font.pixelSize: dividerRoot.glyphSize
      text: dividerRoot.label
    }

    // Never painted: it only reproduces the geometry of a workspace label in
    // this slot so the divider has something concrete to align to.
    Text {
      id: reference
      visible: false
      anchors.centerIn: parent
      text: "0"
      font.family: dividerRoot.fontFamily
      font.pixelSize: dividerRoot.baseSize
    }

    Text {
      id: glyph
      x: Math.round(dividerRoot.width / 2
        - (glyphMetrics.tightBoundingRect.x + dividerRoot.tightWidth / 2))
      y: Math.round(dividerRoot.referenceInkCenter
        - (glyphMetrics.tightBoundingRect.y + glyphMetrics.tightBoundingRect.height / 2)
        - glyph.baselineOffset)
      text: dividerRoot.label
      color: dividerRoot.color
      font.family: dividerRoot.fontFamily
      font.pixelSize: dividerRoot.glyphSize
      renderType: Text.NativeRendering
    }
  }
}
