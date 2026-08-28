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

  // Parsed from `twingate resources`: [{ name, address, alias, authStatus }, ...],
  // split by the command's own "MAIN RESOURCES" / "KUBERNETES RESOURCES"
  // section headers ("BACKGROUND RESOURCES" only appears with --all, which
  // we don't pass, so it never shows up here). Empty (rather than an error)
  // whenever the daemon isn't connected yet.
  property var resources: []
  property var kubeResources: []
  property string kubeSyncingName: ""
  property string kubeSyncError: ""
  property string kubeSyncSuccess: ""
  property string authenticatingName: ""
  property string authError: ""

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
    id: resourcesProbe
    property var mainRows: []
    property var kubeRows: []
    property string section: "main"
    property int linesSeen: 0
    command: ["twingate", "resources"]
    onStarted: { mainRows = []; kubeRows = []; section = "main"; linesSeen = 0; resourcesTimeout.restart() }
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
        }
      }
    }
    onExited: {
      resourcesTimeout.stop()
      root.resources = mainRows
      root.kubeResources = kubeRows
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
