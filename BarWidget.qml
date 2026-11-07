import QtQuick
import QtQuick.Layouts
import qs.Ui

// One entry on the bar, in the place of Omarchy's own workspace widget, so that
// Omarchy can swap the two: a second entry would survive disabling the plugin
// and keep it enabled. See `omarchy.clonedFrom` in manifest.json.
BarWidget {
  id: root
  moduleName: "io.github.minisiowo.dynamic-workspaces"

  readonly property bool opened: control.opened === true

  function open() { control.open() }
  function close() { control.close() }
  function togglePanel() { control.togglePanel() }
  function closeForPopoutSwitch() { control.close() }

  implicitWidth: layout.implicitWidth
  implicitHeight: layout.implicitHeight

  GridLayout {
    id: layout
    anchors.fill: parent
    columns: root.vertical ? 1 : 2
    columnSpacing: 0
    rowSpacing: 0

    WorkspaceWidget {
      bar: root.bar
      settings: root.settings
      Layout.preferredWidth: implicitWidth
      Layout.preferredHeight: implicitHeight
    }

    ControlWidget {
      id: control
      bar: root.bar
      settings: root.settings
      hostWidget: root
      Layout.preferredWidth: implicitWidth
      Layout.preferredHeight: implicitHeight
    }
  }
}
