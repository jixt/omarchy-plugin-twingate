import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons

// A single row in the Main/Hidden resource lists (and the favorites strip).
// `panelRoot` is Panel.qml's `root` — extracted components can't resolve it
// by lexical scoping, so every action/style value is read through this one
// facade property instead of a signal per action.
CursorSurface {
  id: resourceRow
  property var panelRoot: null
  property var resource: null
  property string kind: "main"   // "main" | "background" — ResourceRow is shared by both tabs
  // Where this row lives in the keyboard cursor's region model — "favorites"
  // or "list" — and its index within that region. Set by whichever
  // Repeater/Component instantiates this row in Panel.qml.
  property string regionName: "list"
  property int rowIndex: -1
  readonly property string rowAlias: resource ? resource.alias : ""
  readonly property string rowHost: (rowAlias !== "" && rowAlias !== "-") ? rowAlias : (resource ? resource.address : "")
  readonly property bool rowLocked: panelRoot ? panelRoot.isResourceLocked(resource ? resource.authStatus : "") : false
  readonly property bool rowAuthenticating: resource && panelRoot ? panelRoot.authenticatingName === resource.name : false
  readonly property bool rowFavorited: resource && panelRoot ? panelRoot.isFavorited(resource.name, kind) : false
  readonly property bool showCopied: resource && panelRoot
    && panelRoot.copiedResourceName === resource.name && panelRoot.copiedResourceKind === kind

  implicitHeight: resourceContent.implicitHeight + Style.space(8)
  hasCursor: panelRoot ? panelRoot.isCursored(regionName, rowIndex) : false
  foreground: panelRoot ? panelRoot.foreground : Color.foreground

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
      onContainsMouseChanged: if (containsMouse) resourceRow.panelRoot.setCursor(resourceRow.regionName, resourceRow.rowIndex)

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
          text: resourceRow.showCopied ? "Copied" : resourceRow.rowHost
          color: resourceRow.showCopied ? Color.accent : resourceRow.panelRoot.dim
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
      onClicked: resourceRow.panelRoot.copyResourceValue(resourceRow.resource, resourceRow.kind)
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
