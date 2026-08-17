import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.echograv.mailnotifier"

  readonly property var mailService: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property int unreadCount: mailService ? mailService.unreadCount : 0
  readonly property bool hasError: mailService ? mailService.connectionState === "error" : false
  readonly property bool checking: mailService ? mailService.checking : false
  readonly property string icon: hasError ? "󰀦" : "󰇮"
  readonly property string labelText: root.unreadCount > 0 ? (root.icon + " " + root.unreadCount) : root.icon

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: (root.unreadCount > 0 || root.hasError) ? button.implicitWidth : 0
  implicitHeight: (root.unreadCount > 0 || root.hasError) ? button.implicitHeight : 0

  visible: root.unreadCount > 0 || root.hasError
  enabled: root.unreadCount > 0 || root.hasError

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function reconnect(): void {
      if (root.mailService) root.mailService.forceReconnect()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    
    active: false
    
    foreground: root.hasError 
      ? (Color.urgent || "#ff3b30") 
      : (root.bar ? root.bar.foreground : "#ffffff")

    tooltipText: root.hasError
      ? (root.mailService && root.mailService.lastError ? root.mailService.lastError.message : "OmaFMail: connection error")
      : (root.unreadCount > 0
        ? root.unreadCount + " unread message" + (root.unreadCount === 1 ? "" : "s")
        : "OmaFMail: inbox zero")
    onPressed: function(b) {
      if (b === Qt.RightButton && root.mailService) root.mailService.forceReconnect()
      else root.toggle()
    }
  }
}
