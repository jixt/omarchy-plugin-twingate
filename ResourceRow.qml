import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons

// A single row in the Main/Hidden resource lists (and the favorites strip).
// `panelRoot` is Panel.qml's `root` — extracted components can't resolve it
// by lexical scoping, so every action/style value is read through this one
// facade property instead of a signal per action.
BorderSurface {
  id: resourceRow
  property var panelRoot: null
  property var resource: null
  property string kind: "main"   // "main" | "background" — ResourceRow is shared by both tabs
  readonly property string rowAlias: resource ? resource.alias : ""
  readonly property string rowHost: (rowAlias !== "" && rowAlias !== "-") ? rowAlias : (resource ? resource.address : "")
  readonly property bool rowLocked: panelRoot ? panelRoot.isResourceLocked(resource ? resource.authStatus : "") : false
  readonly property bool rowAuthenticating: resource && panelRoot ? panelRoot.authenticatingName === resource.name : false
  readonly property bool rowFavorited: resource && panelRoot ? panelRoot.isFavorited(resource.name, kind) : false

  implicitHeight: resourceContent.implicitHeight + Style.space(8)
  radius: Style.cornerRadius
  color: openArea.containsMouse ? Style.hoverFillFor(panelRoot.foreground, Color.accent) : "transparent"
  borderSpec: Border.none()

  RowLayout {
    id: resourceContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)

    MouseArea {
      id: openArea
      Layout.fillWidth: true
      Layout.fillHeight: true
      implicitHeight: nameColumn.implicitHeight
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: resourceRow.panelRoot.openResource(resourceRow.resource)

      Column {
        id: nameColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: resourceRow.resource ? resourceRow.resource.name : ""
          color: resourceRow.panelRoot.foreground
          font.family: resourceRow.panelRoot.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: resourceRow.rowHost
          color: resourceRow.panelRoot.dim
          font.family: resourceRow.panelRoot.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: resourceRow.rowLocked
          text: resourceRow.rowAuthenticating ? "Authenticating…" : "Locked"
          color: resourceRow.panelRoot.urgent
          font.family: resourceRow.panelRoot.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    PanelActionButton {
      id: favoriteAction
      anchors.verticalCenter: parent.verticalCenter
      iconText: resourceRow.rowFavorited ? "\u{F04CE}" : "\u{F04D2}"
      tooltipText: resourceRow.rowFavorited ? "Remove from favorites" : "Add to favorites"
      foreground: resourceRow.rowFavorited ? Color.accent : resourceRow.panelRoot.foreground
      fontFamily: resourceRow.panelRoot.fontFamily
      onClicked: resourceRow.panelRoot.toggleFavorite(resourceRow.resource.name, resourceRow.kind)
    }

    Text {
      id: authAction
      textFormat: Text.PlainText
      visible: resourceRow.rowLocked && !resourceRow.rowAuthenticating
      text: "Auth"
      color: resourceRow.panelRoot.foreground
      font.family: resourceRow.panelRoot.fontFamily
      font.pixelSize: Style.font.caption

      MouseArea {
        id: authArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: resourceRow.panelRoot.authenticateResource(resourceRow.resource)

        PanelToolTip {
          visible: authArea.containsMouse
          text: "Authenticate this resource"
          fontFamily: resourceRow.panelRoot.fontFamily
        }
      }
    }

    PanelActionButton {
      id: copyAction
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{F018F}"
      tooltipText: "Copy " + resourceRow.rowHost
      foreground: resourceRow.panelRoot.foreground
      fontFamily: resourceRow.panelRoot.fontFamily
      onClicked: resourceRow.panelRoot.copyResourceValue(resourceRow.resource)
    }

    PanelActionButton {
      id: detailsAction
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{F02FD}"
      tooltipText: "Details"
      foreground: resourceRow.panelRoot.foreground
      fontFamily: resourceRow.panelRoot.fontFamily
      onClicked: resourceRow.panelRoot.openResourceDetail(resourceRow.resource, resourceRow.kind)
    }
  }
}
