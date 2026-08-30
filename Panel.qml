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
  readonly property string switchingToEmail: hostWidget ? hostWidget.switchingToEmail : ""
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

  readonly property bool kubeAutosyncEnabled: hostWidget ? hostWidget.kubeAutosyncEnabled : false
  readonly property bool kubeAutosyncBusy: hostWidget ? hostWidget.kubeAutosyncBusy : false
  readonly property bool kubeSyncingAll: hostWidget ? hostWidget.kubeSyncingAll : false

  function setKubeAutosync(enabled) {
    if (root.hostWidget && typeof root.hostWidget.setKubeAutosync === "function") root.hostWidget.setKubeAutosync(enabled)
  }

  function syncAllKubeResources() {
    if (root.hostWidget && typeof root.hostWidget.syncAllKubeResources === "function") root.hostWidget.syncAllKubeResources()
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
  // All favorites render (in a scrollable list capped at maxVisibleFavorites
  // rows tall) rather than truncating to a fixed count behind an
  // unclickable "+N more" message.
  readonly property int maxVisibleFavorites: 5
  readonly property var favoriteResourceRows: root.favoriteRows
    .filter(function(x) { return x.kind !== "kubernetes" })
    .map(function(x) { return { resource: x.resource, kind: x.kind } })
  readonly property var favoriteKubeRows: root.favoriteRows
    .filter(function(x) { return x.kind === "kubernetes" })
    .map(function(x) { return x.resource })

  // "main" | "kubernetes" | "background" — one tab visible at a time. Every
  // tab is filtered out of the chip row entirely while its own list is
  // empty (generalized from v1.2, which only did this for Hidden).
  property string currentTab: "main"

  readonly property var tabDefs: [
    { id: "main", label: "Main", tooltip: "Resources", count: root.resources.length },
    { id: "kubernetes", label: "Kubernetes", tooltip: "Kubernetes", count: root.kubeResources.length },
    { id: "background", label: "Hidden", tooltip: "Hidden resources", count: root.backgroundResources.length }
  ]
  readonly property var visibleTabDefs: root.tabDefs.filter(function(t) { return t.count > 0 })
  // A tab bar with exactly one chip is chrome with nowhere to go — show the
  // "RESOURCES" title and that list directly instead (roadmap's own
  // rationale for hiding a single tab).
  readonly property bool showTabBar: root.visibleTabDefs.length > 1
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

  // Any tab can disappear out from under the user (its list refreshes to
  // empty) — snap to whichever list still has items rather than leaving
  // currentTab pointed at a tab with no chip left to click back from.
  onVisibleTabDefsChanged: {
    if (root.visibleTabDefs.length === 0) return   // resourcesArea hides entirely via hasAnyResources
    if (!root.visibleTabDefs.some(function(t) { return t.id === root.currentTab })) {
      root.currentTab = root.visibleTabDefs[0].id
    }
  }

  // onVisibleTabDefsChanged only fires on a *change* after this item's own
  // creation — if the instant-open cache already has currentTab's default
  // ("main") list empty at construction time, nothing has "changed" yet to
  // trigger the snap above.
  Component.onCompleted: {
    if (root.visibleTabDefs.length > 0 && !root.visibleTabDefs.some(function(t) { return t.id === root.currentTab })) {
      root.currentTab = root.visibleTabDefs[0].id
    }
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

  // Tracks which resource's detail view is open, if any — null hides it and
  // shows the tab bar + list instead. Panel-local navigation state, like
  // currentTab — never round-trips through hostWidget.
  property var detailResource: null
  property string detailKind: ""

  function openResourceDetail(resource, kind) {
    root.detailResource = resource
    root.detailKind = kind
  }

  function closeResourceDetail() {
    root.detailResource = null
    root.detailKind = ""
  }

  readonly property string detailKindLabel: {
    var match = root.tabDefs.find(function(t) { return t.id === root.detailKind })
    return match ? match.label : ""
  }

  onOpenedChanged: {
    if (root.opened && root.hostWidget) {
      if (typeof root.hostWidget.refreshAccount === "function") root.hostWidget.refreshAccount()
      if (typeof root.hostWidget.refreshAccounts === "function") root.hostWidget.refreshAccounts()
      if (typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
      if (typeof root.hostWidget.refreshVersion === "function") root.hostWidget.refreshVersion()
    } else if (!root.opened) {
      activeListView.resetQuery()
      root.closeResourceDetail()
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
    focusTarget: keyCatcher
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

    // Escape-to-close only — no cursor navigation (moveRequested/tabRequested/
    // etc. deliberately left unbound). blocked while the search field has
    // focus, or PanelKeyCatcher would intercept every keystroke typed there
    // before it ever reaches the TextField (see its own doc comment).
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: activeListView.searchFieldFocused
      // Escape dismisses whatever's on top first — the confirm dialog, then
      // the details drill-down — before it closes the whole panel, same as
      // the dialog's own Cancel button / the drill-down's Back button.
      onCloseRequested: {
        if (root.pendingRemoveEmail !== "") root.pendingRemoveEmail = ""
        else if (root.detailResource !== null) root.closeResourceDetail()
        else root.close()
      }

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

        // Same Flickable-wraps-a-Column shape as ResourceListView's row
        // list, just height-capped to roughly maxVisibleFavorites rows
        // instead of filling a Layout — this Column isn't inside a Layout,
        // so nothing else constrains its height for us. The average-row-
        // height calc adapts to the rows' real rendered size (locked-badge
        // rows are taller) instead of guessing a fixed pixel height.
        Flickable {
          id: favoritesFlickable
          width: parent.width
          readonly property real averageRowHeight: root.favoriteRows.length > 0
            ? (favoritesColumn.implicitHeight + Style.space(4)) / root.favoriteRows.length
            : 0
          height: root.favoriteRows.length > root.maxVisibleFavorites
            ? Math.max(0, averageRowHeight * root.maxVisibleFavorites - Style.space(4))
            : favoritesColumn.implicitHeight
          contentWidth: width
          contentHeight: favoritesColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: favoritesColumn
            width: favoritesFlickable.width
            spacing: Style.space(4)

            Repeater {
              model: root.favoriteResourceRows
              delegate: ResourceRow {
                required property var modelData
                width: parent.width
                resource: modelData.resource
                kind: modelData.kind
                panelRoot: root
              }
            }

            Repeater {
              model: root.favoriteKubeRows
              delegate: KubeResourceRow {
                required property var modelData
                width: parent.width
                resource: modelData
                panelRoot: root
              }
            }
          }
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
        visible: root.showTabBar && root.detailResource === null
        spacing: Style.space(6)

        Repeater {
          model: root.visibleTabDefs
          delegate: Button {
            required property var modelData
            selected: root.currentTab === modelData.id
            text: modelData.label + " (" + modelData.count + ")"
            tooltipText: modelData.tooltip
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.currentTab = modelData.id
          }
        }
      }

      RowLayout {
        visible: root.currentTab === "kubernetes" && root.detailResource === null
        Layout.fillWidth: true
        spacing: Style.space(8)

        ToggleSwitch {
          id: autosyncSwitch
          trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.45))
          checked: root.kubeAutosyncEnabled
          busy: root.kubeAutosyncBusy
          foreground: root.foreground
          onToggled: root.setKubeAutosync(!root.kubeAutosyncEnabled)

          PanelToolTip {
            visible: autosyncSwitch.containsMouse
            text: root.kubeAutosyncEnabled ? "Autosync on" : "Autosync off"
            fontFamily: root.fontFamily
          }
        }

        Text {
          textFormat: Text.PlainText
          text: "Autosync"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Item { Layout.fillWidth: true }

        PanelActionButton {
          iconText: "\u{F0450}"
          tooltipText: "Sync all clusters"
          enabled: root.kubeSyncingName === "" && !root.kubeSyncingAll
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.syncAllKubeResources()
        }
      }

      ResourceListView {
        id: activeListView
        visible: root.detailResource === null
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
        visible: root.authError !== "" && (root.currentTab === "main" || root.currentTab === "background") && root.detailResource === null
        width: parent.width
        text: root.authError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        visible: root.kubeSyncError !== "" && root.currentTab === "kubernetes" && root.detailResource === null
        width: parent.width
        text: root.kubeSyncError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        visible: root.kubeSyncSuccess !== "" && root.currentTab === "kubernetes" && root.detailResource === null
        width: parent.width
        text: root.kubeSyncSuccess
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Column {
        id: detailView
        visible: root.detailResource !== null
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.space(10)

        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          PanelActionButton {
            iconText: "\u{F0141}"
            tooltipText: "Back"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.closeResourceDetail()
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.detailResource ? root.detailResource.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoPair { label: "Name"; value: root.detailResource ? root.detailResource.name : "" }
          InfoPair { label: "Address"; value: (root.detailResource && root.detailResource.address !== "") ? root.detailResource.address : "-" }
          InfoPair { label: "Alias"; value: (root.detailResource && root.detailResource.alias !== "") ? root.detailResource.alias : "-" }
          InfoPair { label: "Auth status"; value: (root.detailResource && root.detailResource.authStatus !== "") ? root.detailResource.authStatus : "-" }
          InfoPair { label: "Kind"; value: root.detailKindLabel }
        }
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
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property var panelRoot: null
    // While a switch is in flight, show the row the user actually clicked as
    // selected right away — waiting for accounts[].current to catch up (only
    // true once the switch finishes and the account list refreshes) makes
    // the click look like it did nothing for several seconds.
    readonly property bool pendingCurrent: panelRoot && panelRoot.switchingToEmail !== "" && account && account.email === panelRoot.switchingToEmail
    current: account ? (panelRoot && panelRoot.switchingToEmail !== "" ? pendingCurrent : account.current) : false
    foreground: panelRoot ? panelRoot.foreground : Color.foreground

    implicitHeight: accountContent.implicitHeight + Style.space(8)

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: accountRow.account && !accountRow.current && accountRow.panelRoot.removingAccount === "" && !accountRow.panelRoot.switchingAccount
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
        font.bold: accountRow.current
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

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel {
      Layout.alignment: Qt.AlignTop
      text: label
    }
    InfoValue {
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      text: value
    }
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
    // Genuinely bounded via Layout.fillWidth (unlike the old plain-Row
    // layout, where this never had an actual width to elide against and
    // long values — e.g. a resource's full address — simply overflowed the
    // panel). Wraps rather than elides: the Details view's whole point is
    // showing every field in full, not truncating them.
    wrapMode: Text.WrapAnywhere
  }
}
