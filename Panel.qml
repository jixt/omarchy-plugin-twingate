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
  manageIpc: false

  property Item anchorItem: null
  property var hostWidget: null
  property string actionStatus: ""

  // True while a connect/disconnect is in flight in the terminal
  // omarchy-launch-terminal opened. execDetached gives no exit code, so
  // completion is isOnline matching togglingConnecting (or the guidance
  // timer giving up).
  property bool togglingConnection: false
  property bool togglingConnecting: false

  // Full-panel notice while a sudo prompt is pending for connect/disconnect/
  // switch — either a terminal (terminal mode) or a native polkit dialog
  // (pkexec mode). Dismissing it (Escape) only hides the notice — the
  // underlying action keeps running until it finishes. Reset whenever a
  // new toggle/switch starts.
  property bool authOverlayDismissed: false
  readonly property bool authOverlayActive: (root.togglingConnection || root.switchingAccount) && !root.authOverlayDismissed
  readonly property string authOverlayActionLabel: root.switchingAccount ? "Switching accounts"
    : root.togglingConnecting ? "Connecting" : "Disconnecting"
  // Which mode the currently-active attempt is actually using — tells
  // AuthWaitView whether to point at a terminal or at the native prompt.
  readonly property bool authOverlayViaPkexec: root.switchingAccount ? root.switchingViaPkexec : root.togglingViaPkexec

  onTogglingConnectionChanged: {
    if (root.togglingConnection) {
      root.authOverlayDismissed = false
      if (!root.opened) root.open()
    }
  }
  onSwitchingAccountChanged: {
    if (root.switchingAccount) {
      root.authOverlayDismissed = false
      if (!root.opened) root.open()
    }
  }

  // Fallback true: never flash the not-installed empty state before
  // hostWidget is actually wired up (injectPanel() runs a beat after load).
  readonly property bool installed: hostWidget ? hostWidget.installed : true

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
  readonly property bool useTerminalForPrivilegedActions: hostWidget ? hostWidget.useTerminalForPrivilegedActions : false
  readonly property bool switchingViaPkexec: hostWidget ? hostWidget.switchingViaPkexec : false
  readonly property bool notificationsEnabled: hostWidget ? hostWidget.notificationsEnabled : false
  readonly property bool notificationsStateKnown: hostWidget ? hostWidget.notificationsStateKnown : false
  readonly property bool notificationsToggleBusy: hostWidget ? hostWidget.notificationsToggleBusy : false
  // Which path *this* toggle attempt actually used — snapshotted once at
  // the start of toggleConnection(), same reasoning as switchingViaPkexec.
  property bool togglingViaPkexec: false
  readonly property var accountOptions: root.accounts.map(function(a) {
    return { value: a.email, label: a.email + " — " + a.network }
  })
  readonly property bool resourcesLoading: hostWidget ? hostWidget.resourcesSettling : false

  // One status line, shown in the footer next to the version — errors win,
  // then whichever background activity is actually in flight.
  readonly property bool footerStatusIsError: root.switchError !== ""
  readonly property string footerStatus: root.switchError !== "" ? root.switchError
    : root.switchingAccount ? "Switching…"
    : root.togglingConnection ? (root.togglingConnecting ? "Connecting…" : "Disconnecting…")
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

  // Tracks the most recently copied row centrally rather than as a per-row
  // property — resources/kubeResources are plain JS arrays reassigned
  // wholesale on every probe, which recreates every delegate, so any local
  // "just copied" state on a row would silently reset mid-confirmation on a
  // badly-timed poll. Same reasoning as kubeSyncingName/authenticatingName.
  property string copiedResourceName: ""
  property string copiedResourceKind: ""

  function copyResourceValue(resource, kind) {
    if (!resource) return
    var value = (resource.alias && resource.alias !== "-") ? resource.alias : resource.address
    if (!value) return
    Quickshell.execDetached(["wl-copy", "--", value])
    root.copiedResourceName = resource.name
    root.copiedResourceKind = kind || ""
    copiedClearTimer.restart()
  }

  Timer {
    id: copiedClearTimer
    interval: 1400
    repeat: false
    onTriggered: { root.copiedResourceName = ""; root.copiedResourceKind = "" }
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

  onCurrentTabChanged: { activeListView.resetQuery(); root.listIndex = 0 }

  readonly property string version: hostWidget ? hostWidget.version : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool busy: root.togglingConnection || root.switchingAccount
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

  // Full-panel keyboard-shortcuts reference, toggled from the hero's "?"
  // button. An overlay (like ConfirmDialog) rather than a tab-area
  // drill-down, since it's a reference for the whole panel, not just the
  // resource list.
  property bool showHelp: false

  // Full-panel settings view (currently just the pkexec/terminal toggle),
  // toggled from the hero's gear button. Same overlay treatment as
  // showHelp, and mutually exclusive with it.
  property bool showSettings: false

  readonly property string detailKindLabel: {
    var match = root.tabDefs.find(function(t) { return t.id === root.detailKind })
    return match ? match.label : ""
  }

  // Shared by "panel just opened" and the keyboard `r` / IPC `refresh` verb —
  // one place owns what a manual refresh actually kicks off.
  function refreshAll() {
    if (!root.hostWidget) return
    if (typeof root.hostWidget.refreshAccount === "function") root.hostWidget.refreshAccount()
    if (typeof root.hostWidget.refreshAccounts === "function") root.hostWidget.refreshAccounts()
    if (typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
    if (typeof root.hostWidget.refreshVersion === "function") root.hostWidget.refreshVersion()
  }

  // Shared by the hero's "?" button and the `h` key binding below.
  function toggleHelp() {
    root.showHelp = !root.showHelp
    if (root.showHelp) root.showSettings = false
  }

  // Shared by the hero's gear button.
  function toggleSettings() {
    root.showSettings = !root.showSettings
    if (root.showSettings) root.showHelp = false
  }

  // The notifications toggle reflects real, external systemd state — only
  // worth probing while the settings view is actually visible.
  onShowSettingsChanged: {
    if (root.showSettings && root.hostWidget && typeof root.hostWidget.refreshNotificationsEnabled === "function") {
      root.hostWidget.refreshNotificationsEnabled()
    }
  }

  // --- Keyboard cursor -------------------------------------------------
  // Three navigable regions, top to bottom: the account list, the
  // favorites strip, and whichever resource list the current tab shows.
  // `cursorActive` stays false (no visible highlight) until the first key
  // press or mouse hover, mouse-first the rest of the time.
  property string focusSection: "list"   // "account" | "favorites" | "list"
  property bool cursorActive: false
  property int accountIndex: 0
  property int favoriteIndex: 0
  property int listIndex: 0

  // Only regions that are actually visible right now — mirrors
  // visibleTabDefs' own "don't offer chrome for an empty list" rule. The
  // resource list is excluded while the details drill-down covers it.
  readonly property var navRegions: {
    var r = []
    if (root.accountOptions.length > 1) r.push("account")
    if (root.favoriteRows.length > 0) r.push("favorites")
    if (root.hasAnyResources && root.detailResource === null) r.push("list")
    return r
  }

  // Flattens the favorites Column's two Repeaters into one indexable list,
  // in the same top-to-bottom order they actually render (resource
  // favorites first, then Kubernetes favorites).
  readonly property var orderedFavoriteRows: root.favoriteResourceRows.concat(
    root.favoriteKubeRows.map(function(r) { return { resource: r, kind: "kubernetes" } }))

  readonly property var activeFilteredItems: activeListView ? activeListView.filteredItems : []

  function regionLength(region) {
    if (region === "account") return root.accounts.length
    if (region === "favorites") return root.orderedFavoriteRows.length
    if (region === "list") return root.activeFilteredItems.length
    return 0
  }

  function clampIndex(i, len) {
    return len <= 0 ? 0 : Math.max(0, Math.min(i, len - 1))
  }

  // Re-clamps every index and, if the focused region just disappeared
  // (its list went empty, or the region itself is no longer offered),
  // moves focus to the first region that's still around. Called after
  // every navigation and whenever the underlying data changes.
  function ensureCursor() {
    if (root.navRegions.indexOf(root.focusSection) === -1) {
      root.focusSection = root.navRegions.length > 0 ? root.navRegions[0] : "list"
    }
    root.accountIndex = root.clampIndex(root.accountIndex, root.accounts.length)
    root.favoriteIndex = root.clampIndex(root.favoriteIndex, root.orderedFavoriteRows.length)
    root.listIndex = root.clampIndex(root.listIndex, root.activeFilteredItems.length)
  }

  // `dx` (h/l, Left/Right) has nothing to move between within a region —
  // every region here is a single vertical list — so only `dy` matters.
  // Walking past either end of a region rolls the cursor into the
  // adjacent one instead of stopping dead at the edge.
  function moveCursor(dx, dy) {
    if (root.showHelp || root.showSettings) return
    root.cursorActive = true
    root.ensureCursor()
    if (dy === 0) return
    var regions = root.navRegions
    var ri = regions.indexOf(root.focusSection)
    if (ri === -1) { root.focusSection = regions.length > 0 ? regions[0] : "list"; return }
    var len = root.regionLength(root.focusSection)
    var idx = root.focusSection === "account" ? root.accountIndex
      : root.focusSection === "favorites" ? root.favoriteIndex : root.listIndex
    idx += dy > 0 ? 1 : -1
    if (idx < 0) {
      if (ri > 0) { root.focusSection = regions[ri - 1]; idx = root.regionLength(root.focusSection) - 1 }
      else idx = 0
    } else if (idx >= len) {
      if (ri < regions.length - 1) { root.focusSection = regions[ri + 1]; idx = 0 }
      else idx = Math.max(0, len - 1)
    }
    if (root.focusSection === "account") root.accountIndex = idx
    else if (root.focusSection === "favorites") root.favoriteIndex = idx
    else root.listIndex = idx
    root.ensureCursor()
    root.scrollCursorIntoView()
  }

  // Mouse hover calls this too, so keyboard and mouse always agree on one
  // highlighted row regardless of which one moved it last.
  function setCursor(region, index) {
    root.cursorActive = true
    root.focusSection = region
    if (region === "account") root.accountIndex = index
    else if (region === "favorites") root.favoriteIndex = index
    else root.listIndex = index
  }

  // Called by ResourceListView's search field on Down — jumps straight
  // into the (just-filtered) list, handing focus back to the main panel
  // so the same key then continues moving the cursor down as usual.
  function jumpToFirstListItem() {
    root.setCursor("list", 0)
    root.ensureCursor()
    root.scrollCursorIntoView()
    root.focusMainPanel()
  }

  // Hands keyboard focus back to the panel's own key handling — used once
  // Down (jumpToFirstListItem) or a second Escape (search field, with the
  // query already empty) are done with the search field.
  function focusMainPanel() {
    keyCatcher.forceActiveFocus()
  }

  function isCursored(region, index) {
    if (!root.cursorActive || root.focusSection !== region) return false
    if (region === "account") return root.accountIndex === index
    if (region === "favorites") return root.favoriteIndex === index
    return root.listIndex === index
  }

  // Resolves to { resource, kind } for whatever's currently cursored in
  // the favorites strip or the active resource list — null over the
  // account region (accounts have no address/auth to act on).
  function selectedResource() {
    if (root.focusSection === "favorites") {
      var favs = root.orderedFavoriteRows
      return (root.favoriteIndex >= 0 && root.favoriteIndex < favs.length) ? favs[root.favoriteIndex] : null
    }
    if (root.focusSection === "list") {
      var items = root.activeFilteredItems
      if (root.listIndex < 0 || root.listIndex >= items.length) return null
      var kind = root.currentTab === "kubernetes" ? "kubernetes" : root.currentTab === "background" ? "background" : "main"
      return { resource: items[root.listIndex], kind: kind }
    }
    return null
  }

  // Enter/Space: the same action a click on the cursored row would take.
  function activateCursor() {
    if (root.showHelp || root.showSettings) return
    root.ensureCursor()
    if (root.focusSection === "account") {
      var acc = root.accounts
      if (root.accountIndex >= 0 && root.accountIndex < acc.length) root.selectAccount(acc[root.accountIndex].email)
      return
    }
    var sel = root.selectedResource()
    if (!sel) return
    if (sel.kind === "kubernetes") root.syncKubeResource(sel.resource)
    // Same reasoning as ResourceRow.qml's openArea click handler: a locked
    // resource can't actually be opened, so route to authentication instead
    // of silently hanging a browser tab with no feedback in the panel.
    else if (root.isResourceLocked(sel.resource.authStatus)) root.authenticateResource(sel.resource)
    else root.openResource(sel.resource)
  }

  // Single-letter global actions, matching each row kind's existing click
  // affordances: copy/authenticate are main/background-only (no address to
  // copy or auth status on a cluster row), while details/favorite apply to
  // every resource kind, same as their star/info buttons. All are no-ops
  // over the account region, where selectedResource() returns null.
  function handleTextKey(t) {
    if (root.showHelp || root.showSettings) return
    var lower = String(t).toLowerCase()
    if (lower === "t") {
      root.toggleConnection()
    } else if (lower === "r") {
      root.refreshAll()
    } else if (lower === "c") {
      var sel = root.selectedResource()
      if (sel && sel.kind !== "kubernetes") root.copyResourceValue(sel.resource, sel.kind)
    } else if (lower === "a") {
      var sel2 = root.selectedResource()
      if (sel2 && sel2.kind !== "kubernetes" && root.isResourceLocked(sel2.resource.authStatus)) root.authenticateResource(sel2.resource)
    } else if (lower === "i") {
      var sel3 = root.selectedResource()
      if (sel3) root.openResourceDetail(sel3.resource, sel3.kind)
    } else if (lower === "f") {
      var sel4 = root.selectedResource()
      if (sel4) root.toggleFavorite(sel4.resource.name, sel4.kind)
    } else if (lower === "s") {
      // Only when the resource list is actually visible (a tab's showing,
      // not the details drill-down) — matches "list" region's own
      // navRegions condition, so there's nothing to search into otherwise.
      if (root.navRegions.indexOf("list") !== -1) activeListView.focusSearch()
    }
  }

  function scrollCursorIntoView() {
    if (root.focusSection === "favorites") root.scrollFavoriteIntoView(root.favoriteIndex)
    else if (root.focusSection === "list") activeListView.scrollIndexIntoView(root.listIndex)
  }

  // Favorites-side twin of ResourceListView.scrollIndexIntoView — this
  // component owns favoritesFlickable/favoritesColumn directly, so it
  // doesn't need the same self-contained wrapper.
  function scrollFavoriteIntoView(index) {
    if (index < 0 || index >= favoritesColumn.children.length) return
    Qt.callLater(function() {
      var item = favoritesColumn.children[index]
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(favoritesFlickable.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = favoritesFlickable.contentY
      var viewBottom = viewTop + favoritesFlickable.height
      var maxY = Math.max(0, favoritesFlickable.contentHeight - favoritesFlickable.height)
      if (top < viewTop + margin) favoritesFlickable.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) favoritesFlickable.contentY = Math.min(maxY, bottom + margin - favoritesFlickable.height)
    })
  }

  onAccountsChanged: root.ensureCursor()
  onFavoriteRowsChanged: root.ensureCursor()
  onActiveItemsChanged: root.ensureCursor()

  Connections {
    target: activeListView
    function onQueryChanged() { root.listIndex = 0; root.ensureCursor() }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.cursorActive = false
      root.ensureCursor()
      root.refreshAll()
    } else {
      activeListView.resetQuery()
      root.closeResourceDetail()
      root.showHelp = false
      root.showSettings = false
    }
  }

  function toggleConnection() {
    if (root.busy || !root.installed) return
    var connecting = !root.isOnline
    root.togglingConnecting = connecting
    root.togglingConnection = true
    root.togglingViaPkexec = !root.useTerminalForPrivilegedActions
    root.actionStatus = connecting ? "Connecting…" : "Disconnecting…"
    if (connecting && root.hostWidget) root.hostWidget.resourcesSettling = true

    if (root.togglingViaPkexec) {
      // pkexec elevates the whole invocation to root via PolicyKit's own
      // native prompt, so twingate's internal sudo re-exec becomes a no-op
      // (root escalating to root doesn't prompt) — no TTY needed at all.
      // Unlike the terminal path, this is a genuinely tracked Process: a
      // real exit code lets finishToggle() react to Cancel/failure
      // instantly. Bare argv, no env/timeout/bash wrapper, so polkit's
      // dialog names twingate itself rather than a wrapper script.
      pkexecToggleProcess.command = ["pkexec", "/usr/bin/twingate", connecting ? "connect" : "disconnect"]
      pkexecToggleProcess.running = true
    } else {
      // Same terminal path as account switch: twingate re-execs through
      // sudo, and a typed password needs a TTY. Fingerprint/FIDO still
      // work in that window too. execDetached gives no exit code —
      // finishToggle() runs once isOnline matches the requested direction,
      // or the timer gives up. org.omarchy.terminal is Omarchy's own
      // floating-terminal app-id (see system.lua's "floating-window" tag
      // rule) — used directly here instead of omarchy-launch-terminal so
      // this prompt floats centered rather than opening tiled in the
      // background where it's easy to miss.
      Quickshell.execDetached([
        "setsid", "uwsm-app", "--",
        "xdg-terminal-exec", "--app-id=org.omarchy.terminal", "--title=Twingate",
        "bash", "-c",
        "twingate \"$1\"; ec=$?; if [ \"$ec\" -ne 0 ]; then echo; echo 'Command failed. Press Enter to close.'; read; fi",
        "twingate-toggle",
        connecting ? "connect" : "disconnect"
      ])
    }
    toggleGuidanceTimer.restart()
  }

  // Success detection is untouched (onIsOnlineChanged below) — the CLI
  // returning doesn't mean the daemon has actually finished reconnecting.
  // Only failure/cancel gets a fast path here: pkexec exits non-zero
  // immediately if the user hits Cancel in the polkit dialog, so there's
  // no reason to wait out the full 90s guidance timer for that case.
  Process {
    id: pkexecToggleProcess
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.togglingConnection && root.togglingViaPkexec) root.finishToggle(false)
    }
  }

  function finishToggle(ok) {
    toggleGuidanceTimer.stop()
    root.togglingConnection = false
    if (!ok) {
      root.actionStatus = "Command failed"
      if (root.hostWidget) root.hostWidget.resourcesSettling = false
    } else if (!root.togglingConnecting && root.hostWidget) {
      root.hostWidget.resourcesSettling = false
    }
    if (root.hostWidget && typeof root.hostWidget.refreshStatus === "function") root.hostWidget.refreshStatus()
    if (root.hostWidget && typeof root.hostWidget.refreshResources === "function") root.hostWidget.refreshResources()
    if (ok && root.togglingConnecting && root.hostWidget && typeof root.hostWidget.scheduleSettledRefresh === "function") {
      root.hostWidget.scheduleSettledRefresh()
    }
    statusClearTimer.restart()
  }

  onIsOnlineChanged: {
    if (!root.togglingConnection) return
    if (root.isOnline === root.togglingConnecting) root.finishToggle(true)
  }

  Timer {
    id: toggleGuidanceTimer
    interval: 90000
    repeat: false
    onTriggered: {
      if (pkexecToggleProcess.running) pkexecToggleProcess.running = false
      root.finishToggle(false)
    }
  }

  Timer {
    id: statusClearTimer
    interval: 2500
    onTriggered: root.actionStatus = ""
  }

  // Honest verbs for `omarchy-shell jixt.twingate <verb>`: report what
  // actually happened instead of always claiming success. Idempotent — a
  // connect while already online (or disconnect while already offline) is
  // reported "ok" without re-running the command.
  function ipcConnect() {
    if (!root.installed) return "not-installed"
    if (root.isOnline) return "ok"
    if (root.busy) return "busy"
    root.toggleConnection()
    return "ok"
  }

  function ipcDisconnect() {
    if (!root.installed) return "not-installed"
    if (!root.isOnline) return "ok"
    if (root.busy) return "busy"
    root.toggleConnection()
    return "ok"
  }

  // manageIpc: false above disables the base Panel's default open/close/
  // show/hide/toggle handler, so this reimplements those five plus the
  // extra verbs this plugin actually supports.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshAll(); return "ok" }
    function connect(): string { return root.ipcConnect() }
    function disconnect(): string { return root.ipcDisconnect() }
    function status(): string { return root.statusLabel }
    function diagnostics(): string {
      return JSON.stringify(root.hostWidget && typeof root.hostWidget.buildDiagnostics === "function"
        ? root.hostWidget.buildDiagnostics() : {})
    }
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
      Math.max(
        headerColumn.implicitHeight
          + (root.hasAnyResources ? resourcesArea.implicitHeight + outerLayout.spacing : 0)
          + footerLayout.implicitHeight
          + outerLayout.spacing,
        root.authOverlayActive ? authWaitView.minContentHeight : 0,
        root.showSettings ? settingsOverlay.minContentHeight : 0),
      Style.space(1000))

    // blocked while the search field has focus, or PanelKeyCatcher would
    // intercept every keystroke typed there before it ever reaches the
    // TextField (see its own doc comment). tabRequested/returnRequested/
    // deleteRequested stay unbound — no delete/rename action exists to wire
    // to x/X, and returnRequested already implicitly triggers
    // activateRequested inside PanelKeyCatcher itself for Enter.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: activeListView.searchFieldFocused
      // PanelKeyCatcher hardcodes h/l to moveRequested(∓1, 0) rather than
      // firing textKey for them (see its own doc comment) — every region
      // here is a single vertical list, so horizontal movement (dx) was
      // already a no-op, making `h` free to repurpose as the toggle for
      // the keyboard-shortcuts overlay instead. `l` stays a no-op.
      onMoveRequested: function(dx, dy) {
        if (dy === 0 && dx < 0) root.toggleHelp()
        else root.moveCursor(dx, dy)
      }
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) { root.handleTextKey(t) }
      // Escape dismisses whatever's on top first — the confirm dialog, then
      // the terminal-auth notice, then the help overlay, then the details
      // drill-down — before it closes the whole panel.
      onCloseRequested: {
        if (root.pendingRemoveEmail !== "") root.pendingRemoveEmail = ""
        else if (root.authOverlayActive) root.authOverlayDismissed = true
        else if (root.showHelp) root.showHelp = false
        else if (root.showSettings) root.showSettings = false
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
          Row {
            spacing: Style.space(6)

            PanelActionButton {
              id: settingsAction
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{F0493}"
              tooltipText: "Settings"
              foreground: hero.foreground
              fontFamily: hero.fontFamily
              onClicked: root.toggleSettings()
            }

            PanelActionButton {
              id: helpAction
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{F02D7}"
              tooltipText: "Keyboard shortcuts"
              foreground: hero.foreground
              fontFamily: hero.fontFamily
              onClicked: root.toggleHelp()
            }

            ToggleSwitch {
              id: powerSwitch
              anchors.verticalCenter: parent.verticalCenter
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
      }

      Text {
        textFormat: Text.PlainText
        visible: !root.installed
        width: parent.width
        text: "Twingate CLI is not installed or not on PATH."
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
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
              required property int index
              width: parent.width
              account: modelData
              panelRoot: root
              rowIndex: index
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          // addingAccount always uses a terminal (account add isn't part of
          // the pkexec/terminal toggle); switch/toggle only show this for
          // whichever attempts are actually running in a terminal.
          visible: root.addingAccount
            || (root.switchingAccount && !root.switchingViaPkexec)
            || (root.togglingConnection && !root.togglingViaPkexec)
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
                required property int index
                width: parent.width
                resource: modelData.resource
                kind: modelData.kind
                panelRoot: root
                regionName: "favorites"
                rowIndex: index
              }
            }

            Repeater {
              model: root.favoriteKubeRows
              delegate: KubeResourceRow {
                required property var modelData
                required property int index
                width: parent.width
                resource: modelData
                panelRoot: root
                regionName: "favorites"
                rowIndex: root.favoriteResourceRows.length + index
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
        required property int index
        width: parent ? parent.width : 0
        resource: modelData
        panelRoot: root
        kind: "main"
        regionName: "list"
        rowIndex: index
      }
    }

    Component {
      id: backgroundRowComponent
      ResourceRow {
        required property var modelData
        required property int index
        width: parent ? parent.width : 0
        resource: modelData
        panelRoot: root
        kind: "background"
        regionName: "list"
        rowIndex: index
      }
    }

    Component {
      id: kubeRowComponent
      KubeResourceRow {
        required property var modelData
        required property int index
        width: parent ? parent.width : 0
        resource: modelData
        panelRoot: root
        regionName: "list"
        rowIndex: index
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

    KeyboardHelpView {
      anchors.fill: parent
      z: 9
      visible: root.showHelp
      foreground: root.foreground
      dim: root.dim
      fontFamily: root.fontFamily
      onClosed: root.showHelp = false
    }

    SettingsView {
      id: settingsOverlay
      anchors.fill: parent
      z: 9
      visible: root.showSettings
      foreground: root.foreground
      dim: root.dim
      fontFamily: root.fontFamily
      useTerminal: root.useTerminalForPrivilegedActions
      busy: root.busy
      notificationsEnabled: root.notificationsEnabled
      notificationsKnown: root.notificationsStateKnown
      notificationsBusy: root.notificationsToggleBusy
      onClosed: root.showSettings = false
      onToggledUseTerminal: function(value) {
        if (root.hostWidget && typeof root.hostWidget.setUseTerminalForPrivilegedActions === "function") {
          root.hostWidget.setUseTerminalForPrivilegedActions(value)
        }
      }
      onToggledNotifications: function(value) {
        if (root.hostWidget && typeof root.hostWidget.setNotificationsEnabled === "function") {
          root.hostWidget.setNotificationsEnabled(value)
        }
      }
    }

    AuthWaitView {
      id: authWaitView
      anchors.fill: parent
      z: 11
      visible: root.authOverlayActive
      actionLabel: root.authOverlayActionLabel
      viaPkexec: root.authOverlayViaPkexec
      foreground: root.foreground
      dim: root.dim
      fontFamily: root.fontFamily
      onDismissed: root.authOverlayDismissed = true
    }
    }
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property var panelRoot: null
    property int rowIndex: -1
    // While a switch is in flight, show the row the user actually clicked as
    // selected right away — waiting for accounts[].current to catch up (only
    // true once the switch finishes and the account list refreshes) makes
    // the click look like it did nothing for several seconds.
    readonly property bool pendingCurrent: panelRoot && panelRoot.switchingToEmail !== "" && account && account.email === panelRoot.switchingToEmail
    current: account ? (panelRoot && panelRoot.switchingToEmail !== "" ? pendingCurrent : account.current) : false
    hasCursor: panelRoot ? panelRoot.isCursored("account", rowIndex) : false
    foreground: panelRoot ? panelRoot.foreground : Color.foreground

    implicitHeight: accountContent.implicitHeight + Style.space(8)

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: accountRow.account && !accountRow.current && accountRow.panelRoot.removingAccount === "" && !accountRow.panelRoot.switchingAccount
      onClicked: accountRow.panelRoot.selectAccount(accountRow.account.email)
      onContainsMouseChanged: if (containsMouse) accountRow.panelRoot.setCursor("account", accountRow.rowIndex)
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

  // Full-panel reference card for the keyboard/mouse shortcuts, opened via
  // the hero's "?" button. An opaque cover (not a translucent scrim) since
  // it's meant to fully replace the view, not dim what's behind it — plus a
  // MouseArea so clicks don't fall through to hidden rows underneath.
  component KeyboardHelpView: Item {
    id: helpView
    property color foreground: Color.foreground
    property color dim: Qt.darker(foreground, 1.55)
    property string fontFamily: Style.font.family
    signal closed()

    readonly property var keyRows: [
      { key: "j / k, ↑ / ↓", action: "Move cursor" },
      { key: "Enter / Space", action: "Activate (open / sync)" },
      { key: "t", action: "Toggle connection" },
      { key: "r", action: "Refresh" },
      { key: "c", action: "Copy address" },
      { key: "a", action: "Authenticate" },
      { key: "i", action: "Show details" },
      { key: "f", action: "Toggle favorite" },
      { key: "s", action: "Focus search" },
      { key: "h", action: "Toggle this help" },
      { key: "Esc", action: "Close / back" }
    ]
    readonly property var mouseRows: [
      { key: "Left-click", action: "Open panel" },
      { key: "Right-click", action: "Toggle connection" },
      { key: "Middle-click", action: "Refresh resources" }
    ]

    Rectangle {
      anchors.fill: parent
      color: Color.popups.background
    }

    MouseArea { anchors.fill: parent }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(12)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelActionButton {
          iconText: "\u{F0141}"
          tooltipText: "Back"
          foreground: helpView.foreground
          fontFamily: helpView.fontFamily
          onClicked: helpView.closed()
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Keyboard Shortcuts"
          color: helpView.foreground
          font.family: helpView.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Flickable {
        id: helpFlick
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: width
        contentHeight: helpColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: helpColumn
          width: helpFlick.width
          spacing: Style.space(14)

          Column {
            id: panelSection
            width: helpColumn.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "PANEL"
              foreground: helpView.foreground
              fontFamily: helpView.fontFamily
            }

            Repeater {
              model: helpView.keyRows
              delegate: RowLayout {
                required property var modelData
                width: panelSection.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  Layout.preferredWidth: Style.space(130)
                  text: modelData.key
                  color: helpView.foreground
                  font.family: helpView.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.action
                  color: helpView.dim
                  font.family: helpView.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Column {
            id: mouseSection
            width: helpColumn.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "BAR ICON"
              foreground: helpView.foreground
              fontFamily: helpView.fontFamily
            }

            Repeater {
              model: helpView.mouseRows
              delegate: RowLayout {
                required property var modelData
                width: mouseSection.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  Layout.preferredWidth: Style.space(130)
                  text: modelData.key
                  color: helpView.foreground
                  font.family: helpView.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.action
                  color: helpView.dim
                  font.family: helpView.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }
    }
  }

  // Full-panel settings view, opened via the hero's gear button. Opaque
  // like KeyboardHelpView, for the same reason: meant to replace the view,
  // not dim it. Currently a single toggle — grows in place if more
  // plugin-local preferences show up later.
  component SettingsView: Item {
    id: settingsView
    property color foreground: Color.foreground
    property color dim: Qt.darker(foreground, 1.55)
    property string fontFamily: Style.font.family
    property bool useTerminal: false
    property bool busy: false
    property bool notificationsEnabled: false
    property bool notificationsKnown: false
    property bool notificationsBusy: false
    signal closed()
    signal toggledUseTerminal(bool value)
    signal toggledNotifications(bool value)
    readonly property real minContentHeight: settingsColumn.implicitHeight

    Rectangle {
      anchors.fill: parent
      color: Color.popups.background
    }

    MouseArea { anchors.fill: parent }

    ColumnLayout {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(12)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        PanelActionButton {
          iconText: "\u{F0141}"
          tooltipText: "Back"
          foreground: settingsView.foreground
          fontFamily: settingsView.fontFamily
          onClicked: settingsView.closed()
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Settings"
          color: settingsView.foreground
          font.family: settingsView.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Use terminal for connect/disconnect/switch"
          color: settingsView.foreground
          font.family: settingsView.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        ToggleSwitch {
          checked: settingsView.useTerminal
          busy: settingsView.busy
          foreground: settingsView.foreground
          onToggled: settingsView.toggledUseTerminal(!settingsView.useTerminal)
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "Off: a native password/fingerprint prompt, no terminal. On: opens a terminal instead, showing twingate's own output — useful for seeing connection errors live."
        color: settingsView.dim
        font.family: settingsView.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Twingate desktop notifications"
          color: settingsView.foreground
          font.family: settingsView.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        ToggleSwitch {
          checked: settingsView.notificationsEnabled
          busy: !settingsView.notificationsKnown || settingsView.notificationsBusy
          foreground: settingsView.foreground
          onToggled: settingsView.toggledNotifications(!settingsView.notificationsEnabled)
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "Off: silences Twingate's own status/auth notifications — resource authentication still works, falling back to a terminal for the sign-in link."
        color: settingsView.dim
        font.family: settingsView.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Item { Layout.fillHeight: true }
    }
  }

  // Shown while connect/disconnect/account-switch is waiting on sudo —
  // either a terminal (terminal mode) or a native polkit prompt (pkexec
  // mode, viaPkexec). Opaque like KeyboardHelpView — meant to replace the
  // view, not dim it. Escape dismisses this notice; the underlying action
  // keeps running either way.
  component AuthWaitView: Item {
    id: authView
    property color foreground: Color.foreground
    property color dim: Qt.darker(foreground, 1.55)
    property string fontFamily: Style.font.family
    property string actionLabel: "Connecting"
    property bool viaPkexec: false
    readonly property real minContentHeight: authColumn.implicitHeight
    signal dismissed()

    Rectangle {
      anchors.fill: parent
      color: Color.popups.background
    }

    MouseArea { anchors.fill: parent }

    Column {
      id: authColumn
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(48), Style.space(280))
      spacing: Style.space(16)

      Item {
        width: parent.width
        height: Style.font.display * 2.2

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "\u{F0498}"
          font.family: authView.fontFamily
          font.pixelSize: parent.height
          color: Color.accent
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: authView.viaPkexec ? "Authentication needed" : "Check the terminal"
        color: authView.foreground
        font.family: authView.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: authView.actionLabel + (authView.viaPkexec
          ? " needs your approval — enter your password, touch your security key, or scan your fingerprint using the prompt that just appeared."
          : " needs your approval in the terminal that just opened — enter your password, touch your security key, or scan your fingerprint if prompted.")
        color: authView.dim
        font.family: authView.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // Replaces the old "Hide" button — there can be a real delay between
      // the underlying action actually finishing and this overlay noticing
      // (guidance-timer/polling-driven, not instant), so an animated
      // "Waiting…" makes clear it's still actively waiting rather than stuck.
      // Always renders exactly 3 dots (toggling color, not the text itself)
      // so "Waiting" never shifts as the visible dot count cycles.
      Item {
        width: parent.width
        height: waitingRow.implicitHeight

        Row {
          id: waitingRow
          anchors.centerIn: parent
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: "Waiting"
            color: authView.dim
            font.family: authView.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            id: dotsRow
            spacing: 0
            property int activeDots: 1

            Repeater {
              model: 3
              delegate: Text {
                required property int index
                textFormat: Text.PlainText
                text: "."
                font.family: authView.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: index < dotsRow.activeDots ? authView.dim : "transparent"
              }
            }

            Timer {
              interval: 400
              running: true
              repeat: true
              onTriggered: dotsRow.activeDots = (dotsRow.activeDots % 3) + 1
            }
          }
        }
      }
    }
  }
}
