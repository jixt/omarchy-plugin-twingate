import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons

// A single row in the Kubernetes resource list (and the favorites strip).
// `panelRoot` is Panel.qml's `root` — see ResourceRow.qml for why.
BorderSurface {
  id: kubeRow
  property var panelRoot: null
  property var resource: null
  readonly property string rowName: resource ? resource.name : ""
  readonly property bool syncing: panelRoot ? panelRoot.kubeSyncingName === rowName : false
  readonly property bool rowBusy: panelRoot ? (panelRoot.kubeSyncingName !== "" || panelRoot.kubeSyncingAll) : false
  readonly property bool rowFavorited: resource && panelRoot ? panelRoot.isFavorited(resource.name, "kubernetes") : false

  implicitHeight: kubeContent.implicitHeight + Style.space(8)
  radius: Style.cornerRadius
  color: "transparent"
  borderSpec: Border.none()
  opacity: rowBusy && !syncing ? 0.5 : 1.0

  RowLayout {
    id: kubeContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)

    Column {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: kubeRow.rowName
        color: kubeRow.panelRoot.foreground
        font.family: kubeRow.panelRoot.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: kubeRow.resource ? kubeRow.resource.alias : ""
        color: kubeRow.panelRoot.dim
        font.family: kubeRow.panelRoot.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: kubeRow.syncing
      text: "Syncing…"
      color: kubeRow.panelRoot.dim
      font.family: kubeRow.panelRoot.fontFamily
      font.pixelSize: Style.font.caption
    }

    PanelActionButton {
      id: favoriteAction
      anchors.verticalCenter: parent.verticalCenter
      iconText: kubeRow.rowFavorited ? "\u{F04CE}" : "\u{F04D2}"
      tooltipText: kubeRow.rowFavorited ? "Remove from favorites" : "Add to favorites"
      foreground: kubeRow.rowFavorited ? Color.accent : kubeRow.panelRoot.foreground
      fontFamily: kubeRow.panelRoot.fontFamily
      onClicked: kubeRow.panelRoot.toggleFavorite(kubeRow.resource.name, "kubernetes")
    }

    PanelActionButton {
      id: syncAction
      anchors.verticalCenter: parent.verticalCenter
      visible: !kubeRow.syncing
      enabled: !kubeRow.rowBusy
      iconText: "\u{F0450}"
      tooltipText: "Sync kubeconfig"
      foreground: kubeRow.panelRoot.foreground
      fontFamily: kubeRow.panelRoot.fontFamily
      onClicked: kubeRow.panelRoot.syncKubeResource(kubeRow.resource)
    }

    PanelActionButton {
      id: detailsAction
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{F02FD}"
      tooltipText: "Details"
      foreground: kubeRow.panelRoot.foreground
      fontFamily: kubeRow.panelRoot.fontFamily
      onClicked: kubeRow.panelRoot.openResourceDetail(kubeRow.resource, "kubernetes")
    }
  }
}
