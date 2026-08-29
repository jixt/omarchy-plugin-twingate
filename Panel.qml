import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

import "Parsing.js" as Parsing

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
  readonly property string statusDetail: hostWidget ? hostWidget.statusDetail : ""
  readonly property var statusExtraLines: hostWidget ? hostWidget.statusExtraLines : []
  readonly property string heroMeta: root.statusDetail !== "" ? root.statusLabel + " — " + root.statusDetail : root.statusLabel
  readonly property string accountEmail: hostWidget ? hostWidget.accountEmail : ""
  readonly property string accountDomain: hostWidget ? hostWidget.accountDomain : ""
  readonly property var accounts: hostWidget ? hostWidget.accounts : []
  readonly property bool switchingAccount: hostWidget ? hostWidget.switchingAccount : false
  readonly property string switchError: hostWidget ? hostWidget.switchError : ""
  readonly property var accountOptions: root.accounts.map(function(a) {
    return { value: a.email, label: a.email + " — " + a.network }
  })
  readonly property bool resourcesLoading: hostWidget ? hostWidget.resourcesSettling : false

  // One status line, shown in the footer next to the version — errors win,
  // then whichever background activity is actually in flight.
  readonly property bool footerStatusIsError: root.switchError !== ""
  readonly property string footerStatus: root.switchError !== "" ? root.switchError
    : root.switchingAccount ? "Switching…"
    : root.resourcesLoading ? "Loading resources…"
    : ""

  readonly property var resources: hostWidget ? hostWidget.resources : []

  function openResource(resource) {
    if (!resource) return
    var host = (resource.alias && resource.alias !== "-") ? resource.alias : resource.address
    if (!host) return
    // Refuse anything that isn't a plausible hostname[:port] before it's
    // ever turned into a URL and handed to the launcher as an argument —
    // resource/address/alias all come straight from the CLI's output.
    if (!root.hostWidget || typeof root.hostWidget.isValidHost !== "function" || !root.hostWidget.isValidHost(host)) return
    Quickshell.execDetached(["omarchy-launch-browser", "https://" + host])
  }

  function copyResourceValue(resource) {
    if (!resource) return
    var value = (resource.alias && resource.alias !== "-") ? resource.alias : resource.address
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  readonly property string authenticatingName: hostWidget ? hostWidget.authenticatingName : ""
  readonly property string authError: hostWidget ? hostWidget.authError : ""

  function authenticateResource(resource) {
    if (!resource || root.authenticatingName !== "") return
    if (root.hostWidget && typeof root.hostWidget.authenticateResource === "function") root.hostWidget.authenticateResource(resource.name)
  }

  function isResourceLocked(authStatus) {
    if (!root.hostWidget || typeof root.hostWidget.isResourceLocked !== "function") return false
    return root.hostWidget.isResourceLocked(authStatus)
  }

  readonly property var favorites: hostWidget ? hostWidget.favorites : []

  function isFavorited(name, kind) {
    if (!root.hostWidget || typeof root.hostWidget.isFavorited !== "function") return false
    return root.hostWidget.isFavorited(name, kind)
  }

  function toggleFavorite(name, kind) {
    if (root.hostWidget && typeof root.hostWidget.toggleFavorite === "function") root.hostWidget.toggleFavorite(name, kind)
  }

  readonly property var kubeResources: hostWidget ? hostWidget.kubeResources : []
  readonly property string kubeSyncingName: hostWidget ? hostWidget.kubeSyncingName : ""
  readonly property string kubeSyncError: hostWidget ? hostWidget.kubeSyncError : ""
  readonly property string kubeSyncSuccess: hostWidget ? hostWidget.kubeSyncSuccess : ""

  function syncKubeResource(resource) {
    if (!resource || root.kubeSyncingName !== "") return
    if (root.hostWidget && typeof root.hostWidget.syncKubeResource === "function") root.hostWidget.syncKubeResource(resource.name)
  }

  readonly property var backgroundResources: hostWidget ? hostWidget.backgroundResources : []

  // Cross-references persisted favorites against the resources currently
  // reported by the CLI. A favorite whose resource isn't currently present
  // (renamed, removed, or just a transient empty poll) is soft-hidden here
  // rather than pruned from the persisted list — see BarWidget.qml's
  // favorites comment for why eager pruning is deliberately avoided.
  readonly property var favoriteRows: root.favorites.map(function(f) {
    var list = f.kind === "kubernetes" ? root.kubeResources : f.kind === "background" ? root.backgroundResources : root.resources
    var match = list.find(function(r) { return r.name === f.name })
    return match ? { resource: match, kind: f.kind } : null
  }).filter(function(x) { return x !== null })
  readonly property var visibleFavoriteRows: root.favoriteRows.slice(0, 4)
  readonly property int hiddenFavoriteCount: Math.max(0, root.favoriteRows.length - root.visibleFavoriteRows.length)
  readonly property var visibleFavoriteResourceRows: root.visibleFavoriteRows
    .filter(function(x) { return x.kind !== "kubernetes" })
    .map(function(x) { return { resource: x.resource, kind: x.kind } })
  readonly property var visibleFavoriteKubeRows: root.visibleFavoriteRows
    .filter(function(x) { return x.kind === "kubernetes" })
    .map(function(x) { return x.resource })

  // "main" | "kubernetes" | "background" — one tab visible at a time.
  // "background" (Hidden) is filtered out of the tab bar's model entirely
  // while empty rather than shown disabled, per the roadmap spec.
  property string currentTab: "main"
  readonly property var tabDefs: [
    { id: "main", label: "Main", tooltip: "Resources" },
    { id: "kubernetes", label: "Kubernetes", tooltip: "Kubernetes" },
    { id: "background", label: "Hidden", tooltip: "Hidden resources" }
  ]
  readonly property var visibleTabDefs: root.tabDefs.filter(function(t) {
    return t.id !== "background" || root.backgroundResources.length > 0
  })
  readonly property bool hasAnyResources: root.resources.length > 0 || root.kubeResources.length > 0 || root.backgroundResources.length > 0

  // A single shared ResourceListView is driven by whichever tab is active
  // (rather than one instance per tab) — its query resets on every tab
  // switch anyway, so there's no per-tab state worth keeping three
  // instances (and three scroll regions) around for.
  readonly property var activeItems: root.currentTab === "kubernetes" ? root.kubeResources
    : root.currentTab === "background" ? root.backgroundResources
    : root.resources
  readonly property Component activeDelegateComponent: root.currentTab === "kubernetes" ? kubeRowComponent
    : root.currentTab === "background" ? backgroundRowComponent
    : resourceRowComponent
  readonly property string activePlaceholderText: root.currentTab === "kubernetes" ? "Search clusters…"
    : root.currentTab === "background" ? "Search hidden resources…"
    : "Search resources…"
  readonly property string activeEmptyText: root.currentTab === "kubernetes" ? "No matching clusters." : "No matching resources."

  // The Hidden tab can disappear out from under the user (background
  // resources refresh to empty) — snap back to Main rather than leaving
  // currentTab pointed at a tab with no chip left to click back from.
  onVisibleTabDefsChanged: {
    if (!root.visibleTabDefs.some(function(t) { return t.id === root.currentTab })) root.currentTab = "main"
  }

  onCurrentTabChanged: activeListView.resetQuery()

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

  readonly property string removingAccount: hostWidget ? hostWidget.removingAccount : ""
  readonly property string removeError: hostWidget ? hostWidget.removeError : ""
  readonly property bool addingAccount: hostWidget ? hostWidget.addingAccount : false

  function removeAccount(email) {
    if (root.hostWidget && typeof root.hostWidget.removeAccount === "function") root.hostWidget.removeAccount(email)
  }

  function addAccount() {
    if (root.hostWidget && typeof root.hostWidget.addAccount === "function") root.hostWidget.addAccount()
  }

  // Tracks a single pending removal for the ConfirmDialog overlay — only
  // one can be in flight at a time, so this needs no per-row state.
  property string pendingRemoveEmail: ""
  property string pendingRemoveNetwork: ""

  function openRemoveConfirm(email, network) {
    root.pendingRemoveEmail = email
    root.pendingRemoveNetwork = network
  }

  onOpenedChanged: {
    if (root.opened && root.hostWidget) {
      if (typeof root.hostWidget.refreshAccount === "function") root.hostWidget.refreshAccount()
      if (typeof root.hostWidget.refreshAccounts === "function") root.hostWidget.refreshAccounts()
      if (typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
      if (typeof root.hostWidget.refreshVersion === "function") root.hostWidget.refreshVersion()
    } else if (!root.opened) {
      activeListView.resetQuery()
    }
  }

  // Same producer-side byte cap as every other twingate invocation
  // (BarWidget.qml) — connect/disconnect normally print little to nothing,
  // but a broken or malicious twingate binary shouldn't get a free pass
  // just because this one call happens to live in Panel.qml.
  readonly property int maxOutputBytes: hostWidget ? hostWidget.maxOutputBytes : 65536
  readonly property int maxStderrBytes: hostWidget ? hostWidget.maxStderrBytes : 8192

  function toggleConnection() {
    var connecting = !root.isOnline
    root.actionStatus = connecting ? "Connecting…" : "Disconnecting…"
    if (connecting && root.hostWidget) root.hostWidget.resourcesSettling = true
    toggleProcess.command = Parsing.buildCappedTwingateCommand(
      [root.isOnline ? "disconnect" : "connect"], root.maxOutputBytes, root.maxStderrBytes)
    toggleProcess.running = true
  }

  Process {
    id: toggleProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.actionStatus = "Command failed"
        if (root.hostWidget) root.hostWidget.resourcesSettling = false
      }
      if (root.hostWidget && typeof root.hostWidget.refreshStatus === "function") root.hostWidget.refreshStatus()
      if (root.hostWidget && typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
      // Connecting starts the daemon asynchronously — the immediate refresh
      // above can still land before it's actually online, so also schedule
      // a guaranteed follow-up once it's had time to settle.
      if (root.hostWidget && typeof root.hostWidget.scheduleSettledRefresh === "function") root.hostWidget.scheduleSettledRefresh()
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
    // Only the resource rows scroll (inside resourcesArea's ResourceListView);
    // the header and footer are fixed siblings, so their heights have to be
    // added back in here since neither is inside a Flickable whose
    // implicitHeight would otherwise account for them automatically.
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight
        + (root.hasAnyResources ? resourcesArea.implicitHeight + outerLayout.spacing : 0)
        + footerLayout.implicitHeight
        + outerLayout.spacing,
      Style.space(1000))

    ColumnLayout {
      id: outerLayout
      anchors.fill: parent
      spacing: Style.space(12)

    Column {
      id: headerColumn
      Layout.fillWidth: true
      spacing: Style.space(12)

      PanelHero {
        id: hero
        width: parent.width
        title: "Twingate"
        meta: root.heroMeta
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

      Repeater {
        model: root.statusExtraLines
        delegate: Text {
          required property var modelData
          textFormat: Text.PlainText
          width: column.width
          text: modelData
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.actionStatus !== ""
        width: parent.width
        text: root.actionStatus
        color: root.actionStatus === "Command failed" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        visible: root.accountEmail !== "" || root.accounts.length > 0
        foreground: root.foreground
      }

      Column {
        visible: root.accountEmail !== "" || root.accounts.length > 0
        width: parent.width
        spacing: Style.space(10)

        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: root.accountOptions.length > 1 ? "ACCOUNTS" : "ACCOUNT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item { Layout.fillWidth: true }

          PanelActionButton {
            enabled: !root.addingAccount
            iconText: "\u{F0014}"
            tooltipText: root.addingAccount ? "Continue in the terminal window…" : "Add account"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.addAccount()
          }
        }

        Column {
          visible: root.accountOptions.length <= 1
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoPair { label: "Account"; value: root.accountEmail }
          InfoPair { label: "Domain"; value: root.accountDomain }
        }

        Column {
          visible: root.accountOptions.length > 1
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.accounts
            delegate: AccountRow {
              required property var modelData
              width: parent.width
              account: modelData
              panelRoot: root
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.addingAccount
          width: parent.width
          text: "Continue in the terminal window…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: root.accountOptions.length === 1
          width: parent.width
          text: "Log out"
          enabled: root.removingAccount === ""
          leftAlign: true
          bordered: true
          foreground: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.openRemoveConfirm(root.accounts[0].email, root.accounts[0].network)
        }

        Text {
          textFormat: Text.PlainText
          visible: root.removeError !== ""
          width: parent.width
          text: root.removeError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator {
        visible: root.favoriteRows.length > 0
        foreground: root.foreground
      }

      Column {
        visible: root.favoriteRows.length > 0
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "FAVORITES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.visibleFavoriteResourceRows
            delegate: ResourceRow {
              required property var modelData
              width: parent.width
              resource: modelData.resource
              kind: modelData.kind
              panelRoot: root
            }
          }

          Repeater {
            model: root.visibleFavoriteKubeRows
            delegate: KubeResourceRow {
              required property var modelData
              width: parent.width
              resource: modelData
              panelRoot: root
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.hiddenFavoriteCount > 0
          width: parent.width
          text: "+ " + root.hiddenFavoriteCount + " more favorites"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }

    Component {
      id: resourceRowComponent
      ResourceRow {
        required property var modelData
        width: parent ? parent.width : 0
        resource: modelData
        panelRoot: root
        kind: "main"
      }
    }

    Component {
      id: backgroundRowComponent
      ResourceRow {
        required property var modelData
        width: parent ? parent.width : 0
        resource: modelData
        panelRoot: root
        kind: "background"
      }
    }

    Component {
      id: kubeRowComponent
      KubeResourceRow {
        required property var modelData
        width: parent ? parent.width : 0
        resource: modelData
        panelRoot: root
      }
    }

    // Only this area scrolls (via ResourceListView's internal Flickable) —
    // the header above and footer below are fixed siblings in outerLayout.
    ColumnLayout {
      id: resourcesArea
      visible: root.hasAnyResources
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Style.space(10)

      PanelSeparator {
        Layout.fillWidth: true
        foreground: root.foreground
      }

      PanelSectionHeader {
        text: "RESOURCES"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Row {
        spacing: Style.space(6)

        Repeater {
          model: root.visibleTabDefs
          delegate: Button {
            required property var modelData
            selected: root.currentTab === modelData.id
            text: modelData.label
            tooltipText: modelData.tooltip
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.currentTab = modelData.id
          }
        }
      }

      ResourceListView {
        id: activeListView
        Layout.fillWidth: true
        Layout.fillHeight: true
        panelRoot: root
        items: root.activeItems
        delegateComponent: root.activeDelegateComponent
        placeholderText: root.activePlaceholderText
        emptyText: root.activeEmptyText
        foreground: root.foreground
        dim: root.dim
        fontFamily: root.fontFamily
      }

      Text {
        textFormat: Text.PlainText
        visible: root.authError !== "" && (root.currentTab === "main" || root.currentTab === "background")
        width: parent.width
        text: root.authError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        visible: root.kubeSyncError !== "" && root.currentTab === "kubernetes"
        width: parent.width
        text: root.kubeSyncError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        visible: root.kubeSyncSuccess !== "" && root.currentTab === "kubernetes"
        width: parent.width
        text: root.kubeSyncSuccess
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Pinned footer — a sibling of the Flickable (not inside its scrolled
    // Column), so the version/status line stays visible regardless of
    // scroll position instead of getting lost below a long resource list.
    ColumnLayout {
      id: footerLayout
      Layout.fillWidth: true
      spacing: Style.space(12)

      PanelSeparator {
        visible: root.version !== ""
        Layout.fillWidth: true
        foreground: root.foreground
      }

      RowLayout {
        visible: root.version !== ""
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Twingate " + root.version
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: root.footerStatus !== ""
          text: root.footerStatus
          color: root.footerStatusIsError ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
    }

    ConfirmDialog {
      anchors.fill: parent
      z: 10
      opened: root.pendingRemoveEmail !== ""
      message: "Log out of " + root.pendingRemoveEmail + " (" + root.pendingRemoveNetwork + ") on this device? You can add it again later."
      confirmText: "Log out"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onCanceled: root.pendingRemoveEmail = ""
      onConfirmed: {
        root.removeAccount(root.pendingRemoveEmail)
        root.pendingRemoveEmail = ""
      }
    }
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property var panelRoot: null
    current: account ? account.current : false
    foreground: panelRoot ? panelRoot.foreground : Color.foreground

    implicitHeight: accountContent.implicitHeight + Style.space(8)

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: accountRow.account && !accountRow.account.current && accountRow.panelRoot.removingAccount === ""
      onClicked: accountRow.panelRoot.selectAccount(accountRow.account.email)
    }

    RowLayout {
      id: accountContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: accountRow.account ? accountRow.account.email + " — " + accountRow.account.network : ""
        color: accountRow.panelRoot.foreground
        font.family: accountRow.panelRoot.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: accountRow.account ? accountRow.account.current : false
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: accountRow.account && accountRow.panelRoot.removingAccount === accountRow.account.email
        text: "Logging out…"
        color: accountRow.panelRoot.dim
        font.family: accountRow.panelRoot.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        visible: !accountRow.account || accountRow.panelRoot.removingAccount !== accountRow.account.email
        iconText: "\u{F0343}"
        tooltipText: "Log out"
        foreground: accountRow.panelRoot.foreground
        hoverColor: accountRow.panelRoot.urgent
        fontFamily: accountRow.panelRoot.fontFamily
        enabled: accountRow.panelRoot.removingAccount === ""
        onClicked: accountRow.panelRoot.openRemoveConfirm(accountRow.account.email, accountRow.account.network)
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
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
