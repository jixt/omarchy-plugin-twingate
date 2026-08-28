import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "Parsing.js" as Parsing

// Twingate VPN bar icon: real Twingate mark plus a small status-dot badge
// (green = online, amber = mid-transition, gray = anything else). Click
// opens Panel.qml, which shows the raw status text and a connect/disconnect
// toggle.
BarWidget {
  id: root
  moduleName: "jixt.twingate"

  // --- Trust-boundary limits for everything the `twingate` CLI hands back.
  // Nothing it prints is trusted: it's parsed defensively, capped, and
  // rendered as plain text, same as any other subprocess output.
  readonly property int maxOutputBytes: 65536      // small single-value probes
  readonly property int maxRows: 200                // accounts / resources per list
  readonly property int maxFieldLength: 256         // any single displayed field
  readonly property int maxLinesTotal: 4000         // hard stop regardless of validity
  readonly property int probeTimeoutMs: 10000       // periodic read-only probes
  readonly property int actionTimeoutMs: 20000      // switch/connect/sync (daemon restarts)
  readonly property var knownStatuses: ["online", "offline", "disconnected", "authenticating", "error"]
  readonly property int maxFavorites: 50            // sanity cap on the persisted favorites file

  // Thin wrappers over Parsing.js — kept on root since Panel.qml and QML
  // delegates call hostWidget.clip(...)/isValidHost(...) directly.
  function clip(value, maxLen) {
    return Parsing.clip(value, maxLen)
  }

  function isSafeCliToken(value) {
    return Parsing.isSafeCliToken(value, root.maxFieldLength)
  }

  function isValidHost(value) {
    return Parsing.isValidHost(value)
  }

  function isResourceLocked(authStatus) {
    return Parsing.isResourceLocked(authStatus)
  }

  // Raw `twingate status -v` output: online | offline | disconnected |
  // authenticating | error | uninitialized | unknown, plus whatever detail
  // follows the colon (confirmed live only for "Online: User" — other
  // states may have no detail at all).
  property string status: "uninitialized"
  property string statusDetail: ""
  property var statusExtraLines: []
  readonly property bool isOnline: status === "online"
  readonly property color statusColor: status === "online" ? "#3fb950"
    : (status === "authenticating" ? "#d29922" : "#8b949e")
  readonly property color foreground: bar ? bar.foreground : Color.foreground

  // Switching accounts (and connecting) stops and restarts the daemon
  // asynchronously — `twingate resources`/`account list` right after the
  // CLI call returns can still land before the daemon has reconnected,
  // coming back empty with nothing to ever retry. A value-change hook on
  // status isn't reliable here: a fast reconnect can flip not-running ->
  // online again entirely between two 5s polls, so "online" never actually
  // changes and no change notification ever fires. Schedule a guaranteed
  // follow-up refresh instead of relying on observing the transition.
  function scheduleSettledRefresh() {
    settledRefreshTimer.restart()
  }

  Timer {
    id: settledRefreshTimer
    interval: 4000
    repeat: false
    onTriggered: {
      // Last scheduled attempt: whatever resourcesProbe reports when this
      // one exits, stop waiting — there's nothing left to retry with.
      root.resourcesSettlingFinalAttempt = true
      root.refreshAccount()
      root.refreshAccounts()
      root.refreshResources()
    }
  }

  // Parsed from `twingate account`, e.g. "Currently signed in as
  // user@example.com - Acme Corp (twingate.com)".
  property string accountEmail: ""
  property string accountDomain: ""

  // Parsed from `twingate account list`: [{ email, network, current }, ...].
  property var accounts: []
  property bool switchingAccount: false
  property string switchError: ""

  // Parsed from `twingate resources --all`: [{ name, address, alias, authStatus }, ...],
  // split by the command's own "MAIN RESOURCES" / "KUBERNETES RESOURCES" /
  // "BACKGROUND RESOURCES" section headers. Empty (rather than an error)
  // whenever the daemon isn't connected yet.
  property var resources: []
  property var kubeResources: []
  property var backgroundResources: []
  property string kubeSyncingName: ""
  property string kubeSyncError: ""
  property string kubeSyncSuccess: ""
  property string authenticatingName: ""
  property string authError: ""
  property var favorites: []   // [{ name, kind }], kind: "main" | "kubernetes" | "background"

  // True continuously from the moment a switch/connect starts until actual
  // resources show up (or the final retry gives up) — spans the immediate
  // too-early attempt, the settle gap, and the retry, so "Loading resources…"
  // doesn't blink off in the gap between them the way tying it to the
  // probe's own running flag did.
  property bool resourcesSettling: false
  property bool resourcesSettlingFinalAttempt: false

  // Installed CLI version, e.g. "2026.190.6704 | 0.193.0".
  property string version: ""

  function refreshStatus() {
    if (!statusProbe.running) statusProbe.running = true
  }

  function refreshAccount() {
    if (!accountProbe.running) accountProbe.running = true
  }

  function refreshAccounts() {
    if (!accountListProbe.running) accountListProbe.running = true
  }

  function refreshResources() {
    if (!resourcesProbe.running) resourcesProbe.running = true
  }

  function isFavorited(name, kind) {
    return root.favorites.some(function(f) { return f.name === name && f.kind === kind })
  }

  function toggleFavorite(name, kind) {
    if (!root.isSafeCliToken(name)) return
    var next = root.favorites.filter(function(f) { return !(f.name === name && f.kind === kind) })
    if (next.length === root.favorites.length) {
      if (next.length >= root.maxFavorites) return
      next = next.concat([{ name: root.clip(name, root.maxFieldLength), kind: kind }])
    }
    // Reassign (not push/splice) — QML array properties don't notify
    // change on in-place mutation.
    root.favorites = next
    favoritesSaveTimer.restart()
  }

  function syncKubeResource(name) {
    if (root.kubeSyncingName !== "" || !root.isSafeCliToken(name)) return
    root.kubeSyncingName = name
    root.kubeSyncError = ""
    root.kubeSyncSuccess = ""
    // "--" stops option parsing so a resource name that merely looks like a
    // flag can never be read as one, in addition to the isSafeCliToken guard.
    kubeSyncProcess.command = ["twingate", "kube", "config", "sync", "--", name]
    kubeSyncProcess.running = true
    kubeSyncTimeout.restart()
  }

  // Doesn't restart the daemon (unlike switch/connect), so a plain
  // refreshResources() after it exits is enough — no scheduleSettledRefresh().
  function authenticateResource(name) {
    if (root.authenticatingName !== "" || !root.isSafeCliToken(name)) return
    root.authenticatingName = name
    root.authError = ""
    authProcess.command = ["twingate", "auth", "--", name]
    authProcess.running = true
    authTimeout.restart()
  }

  function refreshVersion() {
    if (!versionProbe.running) versionProbe.running = true
  }

  // Confirmation-gated: twingate prompts "Are you sure? [y/N]" on stdin
  // before it stops/restarts the daemon under the new identity.
  function switchAccount(email) {
    if (root.switchingAccount || email === root.accountEmail || !root.isSafeCliToken(email)) return
    root.switchingAccount = true
    root.switchError = ""
    root.resourcesSettling = true
    root.resourcesSettlingFinalAttempt = false
    switchProcess.command = ["twingate", "account", "switch", "--", email]
    switchProcess.running = true
    switchTimeout.restart()
  }

  // "" when no removal is in flight, otherwise the email being removed.
  property string removingAccount: ""
  property string removeError: ""
  property bool addingAccount: false

  // There is no `account delete` — removing an account locally is `account
  // logout`, which clears tokens on this device only. Confirmation-gated
  // the same way switchAccount() is (twingate prompts "Are you sure? [y/N]"
  // before logging out).
  function removeAccount(email) {
    if (root.removingAccount !== "" || root.switchingAccount || !root.isSafeCliToken(email)) return
    root.removingAccount = email
    root.removeError = ""
    logoutProcess.command = ["twingate", "account", "logout", "--", email]
    logoutProcess.running = true
    logoutTimeout.restart()
  }

  // Interactive browser OAuth flow — run detached so it can't block the
  // panel or the 5s poll loop. execDetached gives no exit code, so success
  // is never explicitly detected: the guidance message just self-clears
  // after a fixed window and the periodic account-list poll naturally
  // picks up the new account once sign-in completes.
  function addAccount() {
    if (root.addingAccount) return
    root.addingAccount = true
    Quickshell.execDetached(["twingate", "account", "add"])
    addAccountGuidanceTimer.restart()
  }

  Process {
    id: statusProbe
    command: ["twingate", "status", "-v"]
    onStarted: statusTimeout.restart()
    onExited: statusTimeout.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Parsing.parseStatusLine(String(text), root.knownStatuses, root.maxOutputBytes, root.maxFieldLength)
        root.status = result.status
        root.statusDetail = result.detail
        root.statusExtraLines = result.extraLines
      }
    }
  }

  Process {
    id: accountProbe
    command: ["twingate", "account"]
    onStarted: accountTimeout.restart()
    onExited: accountTimeout.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Parsing.parseAccountText(String(text), root.maxOutputBytes, root.maxFieldLength)
        if (result) {
          root.accountEmail = result.email
          root.accountDomain = result.domain
        }
      }
    }
  }

  Process {
    id: accountListProbe
    property var rows: []
    property int linesSeen: 0
    command: ["twingate", "account", "list"]
    onStarted: { rows = []; linesSeen = 0; accountListTimeout.restart() }
    stdout: SplitParser {
      // Producer-side cap: stop accepting data (and stop the process) once
      // either the row cap or a generous total-line ceiling is hit, instead
      // of buffering an unbounded amount of untrusted output before parsing.
      onRead: function(line) {
        accountListProbe.linesSeen += 1
        if (accountListProbe.linesSeen > root.maxLinesTotal) { accountListProbe.running = false; return }
        if (accountListProbe.rows.length >= root.maxRows) return
        var row = Parsing.parseAccountListRow(String(line), root.maxFieldLength)
        if (row) accountListProbe.rows.push(row)
      }
    }
    onExited: { accountListTimeout.stop(); root.accounts = rows }
  }

  Process {
    id: switchProcess
    stdinEnabled: true
    onStarted: write("y\n")
    onExited: function(exitCode) {
      switchTimeout.stop()
      root.switchingAccount = false
      root.switchError = exitCode !== 0 ? "Switch failed" : ""
      // The switch itself failed outright — no reconnect is coming, so
      // don't keep showing "Loading resources…" for one that'll never arrive.
      if (exitCode !== 0) root.resourcesSettling = false
      root.refreshStatus()
      root.refreshAccount()
      root.refreshAccounts()
      root.refreshResources()
      root.scheduleSettledRefresh()
    }
  }

  Process {
    id: logoutProcess
    stdinEnabled: true
    onStarted: write("y\n")
    onExited: function(exitCode) {
      logoutTimeout.stop()
      root.removingAccount = ""
      root.removeError = exitCode !== 0 ? "Remove failed" : ""
      // Removing the current account can change which account is active
      // (or leave none at all) — same full refresh dance as switchAccount().
      if (exitCode !== 0) root.resourcesSettling = false
      else root.resourcesSettling = true
      root.refreshStatus()
      root.refreshAccount()
      root.refreshAccounts()
      root.refreshResources()
      root.scheduleSettledRefresh()
    }
  }

  Process {
    id: resourcesProbe
    property var mainRows: []
    property var kubeRows: []
    property var backgroundRows: []
    property string section: "main"
    property int linesSeen: 0
    command: ["twingate", "resources", "--all"]
    onStarted: { mainRows = []; kubeRows = []; backgroundRows = []; section = "main"; linesSeen = 0; resourcesTimeout.restart() }
    stdout: SplitParser {
      onRead: function(line) {
        resourcesProbe.linesSeen += 1
        if (resourcesProbe.linesSeen > root.maxLinesTotal) { resourcesProbe.running = false; return }
        var result = Parsing.parseResourceLine(String(line), resourcesProbe.section, root.maxFieldLength)
        resourcesProbe.section = result.section
        if (!result.entry) return
        if (result.section === "kubernetes") {
          if (resourcesProbe.kubeRows.length < root.maxRows) resourcesProbe.kubeRows.push(result.entry)
        } else if (result.section === "main") {
          if (resourcesProbe.mainRows.length < root.maxRows) resourcesProbe.mainRows.push(result.entry)
        } else if (result.section === "background") {
          if (resourcesProbe.backgroundRows.length < root.maxRows) resourcesProbe.backgroundRows.push(result.entry)
        }
      }
    }
    onExited: {
      resourcesTimeout.stop()
      root.resources = mainRows
      root.kubeResources = kubeRows
      root.backgroundResources = backgroundRows
      // Stop waiting once resources actually showed up, or once this was
      // the last scheduled retry — whichever comes first — so the status
      // message can't get stuck forever if there's a real, lasting failure.
      if (root.resources.length > 0 || root.resourcesSettlingFinalAttempt) {
        root.resourcesSettling = false
        root.resourcesSettlingFinalAttempt = false
      }
    }
  }

  Process {
    id: kubeSyncProcess
    onExited: function(exitCode) {
      kubeSyncTimeout.stop()
      var name = root.kubeSyncingName
      if (exitCode !== 0) {
        root.kubeSyncError = "Sync failed: " + name
      } else {
        root.kubeSyncError = ""
        root.kubeSyncSuccess = "Synced " + name
        kubeSyncSuccessTimer.restart()
      }
      root.kubeSyncingName = ""
    }
  }

  Process {
    id: authProcess
    onExited: function(exitCode) {
      authTimeout.stop()
      if (exitCode !== 0) root.authError = "Authentication failed: " + root.authenticatingName
      root.authenticatingName = ""
      root.refreshResources()
    }
  }

  Process {
    id: versionProbe
    command: ["twingate", "--version"]
    onStarted: versionTimeout.restart()
    onExited: versionTimeout.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var version = Parsing.parseVersionText(String(text), root.maxOutputBytes, root.maxFieldLength)
        if (version !== null) root.version = version
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refreshStatus()
      root.refreshAccount()
    }
  }

  // Each periodic probe is skipped while its own process is still running,
  // so one that never exits — a hung or hostile `twingate` process — would
  // silently stop refreshing forever. Each gets its own deadline, started
  // when that specific probe starts and cleared when it exits, so a hung
  // resourcesProbe (for example) can't hide behind status/account refreshing
  // normally every 5s on a shared timer.
  Timer {
    id: statusTimeout
    interval: root.probeTimeoutMs
    repeat: false
    onTriggered: if (statusProbe.running) statusProbe.running = false
  }

  Timer {
    id: accountTimeout
    interval: root.probeTimeoutMs
    repeat: false
    onTriggered: if (accountProbe.running) accountProbe.running = false
  }

  Timer {
    id: accountListTimeout
    interval: root.probeTimeoutMs
    repeat: false
    onTriggered: if (accountListProbe.running) accountListProbe.running = false
  }

  Timer {
    id: resourcesTimeout
    interval: root.probeTimeoutMs
    repeat: false
    onTriggered: if (resourcesProbe.running) resourcesProbe.running = false
  }

  Timer {
    id: versionTimeout
    interval: root.probeTimeoutMs
    repeat: false
    onTriggered: if (versionProbe.running) versionProbe.running = false
  }

  Timer {
    id: switchTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (switchProcess.running) switchProcess.running = false
      root.switchingAccount = false
      root.switchError = "Switch timed out"
    }
  }

  Timer {
    id: logoutTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (logoutProcess.running) logoutProcess.running = false
      root.removingAccount = ""
      root.removeError = "Remove timed out"
    }
  }

  // Self-clears the "complete sign-in in your browser" guidance message —
  // execDetached gives no exit code, so there's no way to detect the OAuth
  // flow actually finishing; the periodic account-list poll picks up the
  // new account on its own once it does.
  Timer {
    id: addAccountGuidanceTimer
    interval: 60000
    repeat: false
    onTriggered: root.addingAccount = false
  }

  Timer {
    id: kubeSyncTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (kubeSyncProcess.running) kubeSyncProcess.running = false
      root.kubeSyncError = "Sync timed out: " + root.kubeSyncingName
      root.kubeSyncingName = ""
    }
  }

  Timer {
    id: kubeSyncSuccessTimer
    interval: 2500
    repeat: false
    onTriggered: root.kubeSyncSuccess = ""
  }

  Timer {
    id: authTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (authProcess.running) authProcess.running = false
      root.authError = "Authentication timed out: " + root.authenticatingName
      root.authenticatingName = ""
    }
  }

  // Favorites are plugin-owned UI state (changes on every star click), not
  // shell/plugin configuration a user would hand-edit — kept in a local
  // state file rather than shell.json, mirroring quickshell.spotify's
  // session-file pattern (~/.local/state/<plugin-id>/<file>.json).
  readonly property string favoritesStateDir: {
    var explicit = String(Quickshell.env("XDG_STATE_HOME") || "").trim()
    var base = explicit !== "" ? explicit : (Quickshell.env("HOME") + "/.local/state")
    return base + "/jixt.twingate"
  }
  readonly property string favoritesPath: root.favoritesStateDir + "/favorites.json"

  FileView {
    id: favoritesFile
    path: root.favoritesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.favorites = Parsing.parseFavoritesJson(text(), root.maxFavorites, root.maxFieldLength)
    onLoadFailed: root.favorites = []
    onSaveFailed: if (!ensureFavoritesDir.running) ensureFavoritesDir.running = true
  }

  Timer {
    id: favoritesSaveTimer
    interval: 200
    repeat: false
    onTriggered: favoritesFile.setText(JSON.stringify(root.favorites, null, 2) + "\n")
  }

  Process {
    id: ensureFavoritesDir
    command: ["mkdir", "-p", root.favoritesStateDir]
    onExited: favoritesFile.reload()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Twingate — " + root.status
    iconComponent: twingateIconComponent
    onPressed: function(b) { root.togglePanel() }
  }

  Component {
    id: twingateIconComponent

    Item {
      anchors.fill: parent
      readonly property real iconSize: Style.bar.iconCanvas

      TwingateGlyph {
        id: twingateGlyph
        anchors.centerIn: parent
        iconSize: parent.iconSize
        color: root.foreground
      }

      BorderSurface {
        width: Math.max(6, parent.iconSize * 0.4)
        height: width
        radius: width / 2
        color: root.statusColor
        borderSpec: Border.flat(Color.popups.background, 1)
        anchors.right: twingateGlyph.right
        anchors.bottom: twingateGlyph.bottom
        anchors.rightMargin: -1
        anchors.bottomMargin: -1
      }
    }
  }
}
