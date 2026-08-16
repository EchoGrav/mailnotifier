import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.keithnyc.omafmail"
  ipcTarget: "io.github.keithnyc.omafmail"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var mailService: bar && bar.shell
    ? bar.shell.serviceFor("io.github.keithnyc.omafmail")
    : null
  readonly property var rows: mailService ? mailService.messages : []
  readonly property int unreadCount: mailService ? mailService.unreadCount : 0
  readonly property string connectionState: mailService ? mailService.connectionState : "disconnected"
  readonly property var lastError: mailService ? mailService.lastError : null
  readonly property string configError: mailService ? mailService.configError : ""
  property double now: Date.now()

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function openInbox() {
    Quickshell.execDetached(["xdg-open", "https://app.fastmail.com/mail/Inbox"])
  }

  component MessageRow: CursorSurface {
    id: card
    required property var modelData // auto-populated per item by Repeater on an array model
    required property var bar
    required property double now

    readonly property color rowForeground: bar ? bar.foreground : Color.foreground
    readonly property string rowFontFamily: bar ? bar.fontFamily : Style.font.family

    // modelData can be evaluated once before the Repeater assigns it; every
    // binding below reads through this fallback so it stays reactive instead
    // of freezing on the first (undefined) evaluation.
    readonly property var msg: card.modelData || {}
    readonly property string fromName: card.msg.fromName || "(unknown sender)"
    readonly property string avatarKey: card.msg.fromAddress || card.msg.fromName || ""
    readonly property string subjectText: card.msg.subject || ""
    readonly property string snippetText: card.msg.snippet || ""
    readonly property double receivedAt: card.msg.receivedAt || 0

    signal activated()

    hasCursor: rowMouse.containsMouse
    foreground: card.rowForeground
    implicitHeight: rowLayout.implicitHeight + Style.space(20)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.activated()
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(12)

      BorderSurface {
        Layout.preferredWidth: Style.space(34)
        Layout.preferredHeight: Style.space(34)
        Layout.alignment: Qt.AlignTop
        radius: width / 2
        color: Model.avatarColor(card.avatarKey)

        Text {
          anchors.centerIn: parent
          text: Model.initials(card.fromName)
          color: "#ffffff"
          font.family: card.rowFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: card.fromName
            elide: Text.ElideRight
            color: card.rowForeground
            font.family: card.rowFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: Model.relativeTime(card.receivedAt, card.now)
            color: Qt.darker(card.rowForeground, 1.35)
            font.family: card.rowFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          Layout.fillWidth: true
          text: card.subjectText
          elide: Text.ElideRight
          color: card.rowForeground
          font.family: card.rowFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          Layout.fillWidth: true
          text: card.snippetText
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: Qt.darker(card.rowForeground, 1.35)
          font.family: card.rowFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width - refreshButton.width - parent.spacing
              text: root.unreadCount > 0
                ? root.unreadCount + " unread message" + (root.unreadCount === 1 ? "" : "s")
                : "Inbox zero"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: refreshButton
              iconText: "󰑐"
              tooltipText: "Reconnect now"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              iconSpinning: root.connectionState === "connecting"
              onClicked: if (root.mailService) root.mailService.forceReconnect()
            }
          }

          Text {
            visible: root.configError !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: root.configError
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.configError === "" && root.connectionState === "error" && root.lastError
            width: parent.width
            wrapMode: Text.Wrap
            text: root.lastError ? Model.errorSummary(root.lastError) : ""
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator {
            visible: root.rows.length > 0
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.rows

              MessageRow {
                width: content.width
                bar: root.bar
                now: root.now
                onActivated: root.openInbox()
              }
            }
          }

          Text {
            visible: root.rows.length === 0 && root.configError === ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.connectionState === "connecting" ? "Connecting…" : "No unread messages"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "Click a message to open Fastmail · right-click the bar icon to reconnect"
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
