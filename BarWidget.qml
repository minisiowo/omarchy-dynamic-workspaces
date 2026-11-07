import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.minisiowo.dynamic-workspaces"

  readonly property string widgetMode: String(setting("mode", "Control")).toLowerCase()
  readonly property bool opened: widgetLoader.item && widgetLoader.item.opened === true

  function open() { if (widgetLoader.item && typeof widgetLoader.item.open === "function") widgetLoader.item.open() }
  function close() { if (widgetLoader.item && typeof widgetLoader.item.close === "function") widgetLoader.item.close() }
  function togglePanel() { if (widgetLoader.item && typeof widgetLoader.item.togglePanel === "function") widgetLoader.item.togglePanel() }
  function closeForPopoutSwitch() { close() }

  function injectWidget() {
    var target = widgetLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("moduleName" in target) target.moduleName = root.moduleName
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: widgetLoader.item && widgetLoader.item.visible ? widgetLoader.item.implicitWidth : 0
  implicitHeight: widgetLoader.item && widgetLoader.item.visible ? widgetLoader.item.implicitHeight : 0

  onBarChanged: injectWidget()
  onSettingsChanged: injectWidget()

  Loader {
    id: widgetLoader
    anchors.fill: parent
    source: root.widgetMode === "workspaces"
      ? Qt.resolvedUrl("WorkspaceWidget.qml")
      : Qt.resolvedUrl("ControlWidget.qml")
    onLoaded: {
      root.injectWidget()
      Qt.callLater(root.injectWidget)
    }
  }
}
