import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "jixt.twingate"
  ipcTarget: "jixt.twingate"

  property Item anchorItem: null
  property var hostWidget: null
  property string actionStatus: ""

  readonly property string status: hostWidget ? hostWidget.status : "uninitialized"
  readonly property bool isOnline: status === "online"
  readonly property color statusColor: hostWidget ? hostWidget.statusColor : "#8b949e"
  readonly property string statusLabel: status.length > 0
    ? status.charAt(0).toUpperCase() + status.slice(1)
    : "Unknown"
  readonly property string accountEmail: hostWidget ? hostWidget.accountEmail : ""
  readonly property string accountDomain: hostWidget ? hostWidget.accountDomain : ""
  readonly property var accounts: hostWidget ? hostWidget.accounts : []
  readonly property bool switchingAccount: hostWidget ? hostWidget.switchingAccount : false
  readonly property string switchError: hostWidget ? hostWidget.switchError : ""
  readonly property var accountOptions: root.accounts.map(function(a) {
    return { value: a.email, label: a.email + " — " + a.network }
  })

  readonly property var resources: hostWidget ? hostWidget.resources : []
  property string resourceQuery: ""
  readonly property var filteredResources: {
    var q = root.resourceQuery.trim().toLowerCase()
    if (q === "") return root.resources
    return root.resources.filter(function(r) {
      return r.name.toLowerCase().indexOf(q) >= 0
        || r.alias.toLowerCase().indexOf(q) >= 0
        || r.address.toLowerCase().indexOf(q) >= 0
    })
  }
  readonly property var visibleResources: root.filteredResources.slice(0, 3)
  readonly property int hiddenResourceCount: Math.max(0, root.filteredResources.length - root.visibleResources.length)

  function openResource(resource) {
    if (!resource) return
    var host = (resource.alias && resource.alias !== "-") ? resource.alias : resource.address
    if (!host) return
    Quickshell.execDetached(["omarchy-launch-browser", "https://" + host])
  }

  readonly property var kubeResources: hostWidget ? hostWidget.kubeResources : []
  property string kubeResourceQuery: ""
  readonly property var filteredKubeResources: {
    var q = root.kubeResourceQuery.trim().toLowerCase()
    if (q === "") return root.kubeResources
    return root.kubeResources.filter(function(r) {
      return r.name.toLowerCase().indexOf(q) >= 0
        || r.alias.toLowerCase().indexOf(q) >= 0
        || r.address.toLowerCase().indexOf(q) >= 0
    })
  }
  readonly property var visibleKubeResources: root.filteredKubeResources.slice(0, 3)
  readonly property int hiddenKubeResourceCount: Math.max(0, root.filteredKubeResources.length - root.visibleKubeResources.length)
  readonly property string kubeSyncingName: hostWidget ? hostWidget.kubeSyncingName : ""
  readonly property string kubeSyncError: hostWidget ? hostWidget.kubeSyncError : ""

  function syncKubeResource(resource) {
    if (!resource || root.kubeSyncingName !== "") return
    if (root.hostWidget && typeof root.hostWidget.syncKubeResource === "function") root.hostWidget.syncKubeResource(resource.name)
  }

  readonly property string version: hostWidget ? hostWidget.version : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool busy: toggleProcess.running || root.switchingAccount
  readonly property string toggleHint: isOnline ? "Disconnect" : "Connect"

  function selectAccount(email) {
    if (root.hostWidget && typeof root.hostWidget.switchAccount === "function") root.hostWidget.switchAccount(email)
  }

  onOpenedChanged: {
    if (root.opened && root.hostWidget) {
      if (typeof root.hostWidget.refreshAccount === "function") root.hostWidget.refreshAccount()
      if (typeof root.hostWidget.refreshAccounts === "function") root.hostWidget.refreshAccounts()
      if (typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
      if (typeof root.hostWidget.refreshVersion === "function") root.hostWidget.refreshVersion()
    } else if (!root.opened) {
      root.resourceQuery = ""
      resourceSearch.text = ""
      root.kubeResourceQuery = ""
      kubeResourceSearch.text = ""
    }
  }

  // The dropdown updates its own value optimistically the instant an option
  // is clicked, ahead of the switch actually completing. Force it back to
  // the real current account whenever that's known to be authoritative — a
  // successful switch changes accountEmail; a failed one leaves it exactly
  // as it was, so the error signal alone has to trigger the resync.
  onAccountEmailChanged: accountDropdown.value = root.accountEmail
  onSwitchErrorChanged: if (root.switchError !== "") accountDropdown.value = root.accountEmail

  function toggleConnection() {
    root.actionStatus = root.isOnline ? "Disconnecting…" : "Connecting…"
    toggleProcess.command = ["twingate", root.isOnline ? "disconnect" : "connect"]
    toggleProcess.running = true
  }

  Process {
    id: toggleProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) root.actionStatus = "Command failed"
      if (root.hostWidget && typeof root.hostWidget.refreshStatus === "function") root.hostWidget.refreshStatus()
      if (root.hostWidget && typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
      statusClearTimer.restart()
    }
  }

  Timer {
    id: statusClearTimer
    interval: 2500
    onTriggered: root.actionStatus = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: column
      width: panelFlick.width
      spacing: Style.space(12)

      PanelHero {
        id: hero
        width: parent.width
        title: "Twingate"
        meta: root.statusLabel
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconOpacity: root.isOnline ? 1.0 : 0.6
        iconComponent: Component {
          Item {
            implicitWidth: Style.font.display
            implicitHeight: Style.font.display

            TwingateGlyph {
              id: heroGlyph
              anchors.centerIn: parent
              iconSize: Style.font.display
              color: root.foreground
            }

            BorderSurface {
              width: Math.max(8, parent.width * 0.34)
              height: width
              radius: width / 2
              color: root.statusColor
              borderSpec: Border.flat(Color.popups.background, 1)
              anchors.right: heroGlyph.right
              anchors.bottom: heroGlyph.bottom
              anchors.rightMargin: -1
              anchors.bottomMargin: -1
            }
          }
        }

        trailingControl: Component {
          ToggleSwitch {
            id: powerSwitch
            checked: root.isOnline
            busy: root.busy
            foreground: hero.foreground
            onToggled: root.toggleConnection()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.toggleHint
              fontFamily: hero.fontFamily
            }
          }
        }
      }

      Text {
        visible: root.actionStatus !== ""
        width: parent.width
        text: root.actionStatus
        color: root.actionStatus === "Command failed" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        visible: root.accountEmail !== ""
        foreground: root.foreground
      }

      Column {
        visible: root.accountEmail !== ""
        width: parent.width
        spacing: Style.spacing.labelGap

        InfoPair { label: "Account"; value: root.accountEmail }
        InfoPair { label: "Domain"; value: root.accountDomain }
      }

      PanelSeparator {
        visible: root.accountOptions.length > 1
        foreground: root.foreground
      }

      Column {
        visible: root.accountOptions.length > 1
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "SWITCH ACCOUNT"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Dropdown {
          id: accountDropdown
          width: parent.width
          showLabel: false
          fontFamily: root.fontFamily
          foreground: root.foreground
          enabled: !root.busy
          opacity: enabled ? 1.0 : 0.6
          options: root.accountOptions
          value: root.accountEmail
          onChanged: function(v) { root.selectAccount(v) }
        }

        Text {
          visible: root.switchingAccount || root.switchError !== ""
          width: parent.width
          text: root.switchingAccount ? "Switching…" : root.switchError
          color: root.switchError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator {
        visible: root.resources.length > 0
        foreground: root.foreground
      }

      Column {
        visible: root.resources.length > 0
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "RESOURCES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        TextField {
          id: resourceSearch
          width: parent.width
          foreground: root.foreground
          placeholderText: "Search resources…"
          text: root.resourceQuery
          onTextChanged: root.resourceQuery = text
        }

        Text {
          visible: root.visibleResources.length === 0
          width: parent.width
          text: "No matching resources."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.visibleResources
            delegate: ResourceRow {
              required property var modelData
              width: parent.width
              resource: modelData
            }
          }
        }

        Text {
          visible: root.hiddenResourceCount > 0
          width: parent.width
          text: "+ " + root.hiddenResourceCount + " more — refine your search"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }
      }

      PanelSeparator {
        visible: root.kubeResources.length > 0
        foreground: root.foreground
      }

      Column {
        visible: root.kubeResources.length > 0
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "KUBERNETES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        TextField {
          id: kubeResourceSearch
          width: parent.width
          foreground: root.foreground
          placeholderText: "Search clusters…"
          text: root.kubeResourceQuery
          onTextChanged: root.kubeResourceQuery = text
        }

        Text {
          visible: root.visibleKubeResources.length === 0
          width: parent.width
          text: "No matching clusters."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.visibleKubeResources
            delegate: KubeResourceRow {
              required property var modelData
              width: parent.width
              resource: modelData
            }
          }
        }

        Text {
          visible: root.hiddenKubeResourceCount > 0
          width: parent.width
          text: "+ " + root.hiddenKubeResourceCount + " more — refine your search"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          visible: root.kubeSyncError !== ""
          width: parent.width
          text: root.kubeSyncError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator {
        visible: root.version !== ""
        foreground: root.foreground
      }

      Text {
        visible: root.version !== ""
        width: parent.width
        text: "Twingate " + root.version
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    }
  }

  component ResourceRow: BorderSurface {
    id: resourceRow
    property var resource: null
    readonly property string rowAlias: resource ? resource.alias : ""
    readonly property string rowHost: (rowAlias !== "" && rowAlias !== "-") ? rowAlias : (resource ? resource.address : "")

    implicitHeight: resourceContent.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: rowArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.none()

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openResource(resourceRow.resource)
    }

    Column {
      id: resourceContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: resourceRow.resource ? resourceRow.resource.name : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: resourceRow.rowHost
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component KubeResourceRow: BorderSurface {
    id: kubeRow
    property var resource: null
    readonly property string rowName: resource ? resource.name : ""
    readonly property bool syncing: root.kubeSyncingName === rowName
    readonly property bool rowBusy: root.kubeSyncingName !== ""

    implicitHeight: kubeContent.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: rowArea.containsMouse && !rowBusy ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.none()
    opacity: rowBusy && !syncing ? 0.5 : 1.0

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: !kubeRow.rowBusy
      cursorShape: Qt.PointingHandCursor
      onClicked: root.syncKubeResource(kubeRow.resource)

      PanelToolTip {
        visible: rowArea.containsMouse && !kubeRow.rowBusy
        text: "Sync kubeconfig"
        fontFamily: root.fontFamily
      }
    }

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
          width: parent.width
          text: kubeRow.rowName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: kubeRow.resource ? kubeRow.resource.alias : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: kubeRow.syncing
        text: "Syncing…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
