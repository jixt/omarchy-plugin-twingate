import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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

  // Truncates to maxLen and strips control characters plus angle brackets —
  // the latter so this is still inert even where it ends up inside a shared
  // Ui component (e.g. Dropdown) whose Text elements aren't ours to mark
  // Text.PlainText directly.
  function clip(value, maxLen) {
    var s = value === undefined || value === null ? "" : String(value)
    if (s.length > maxLen) s = s.slice(0, maxLen)
    return s.replace(/[\x00-\x1f\x7f<>]/g, "")
  }

  // Rejects anything unsafe to hand to the CLI as a positional argument:
  // empty, oversized, option-shaped ("-..."), or containing control chars.
  function isSafeCliToken(value) {
    if (typeof value !== "string" || value.length === 0 || value.length > root.maxFieldLength) return false
    if (value.charAt(0) === "-") return false
    return !/[\x00-\x1f\x7f]/.test(value)
  }

  // Conservative hostname[:port] shape check before a CLI-derived string is
  // ever turned into a browser target.
  function isValidHost(value) {
    if (typeof value !== "string" || value.length === 0 || value.length > 255) return false
    if (/[\x00-\x1f\x7f]/.test(value)) return false
    return /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*(:[0-9]{1,5})?$/.test(value)
  }

  // Raw `twingate status` output: online | offline | disconnected |
  // authenticating | error | uninitialized | unknown.
  property string status: "uninitialized"
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
  readonly property bool resourcesLoading: resourcesProbe.running

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
    // "--" stops option parsing so a resource name that merely looks like a
    // flag can never be read as one, in addition to the isSafeCliToken guard.
    kubeSyncProcess.command = ["twingate", "kube", "config", "sync", "--", name]
    kubeSyncProcess.running = true
    kubeSyncTimeout.restart()
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
    switchProcess.command = ["twingate", "account", "switch", "--", email]
    switchProcess.running = true
    switchTimeout.restart()
  }

  Process {
    id: statusProbe
    command: ["twingate", "status"]
    onStarted: statusTimeout.restart()
    onExited: statusTimeout.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text)
        if (raw.length > root.maxOutputBytes) { root.status = "unknown"; return }
        var s = raw.trim().toLowerCase()
        root.status = root.knownStatuses.indexOf(s) !== -1 ? s : (s === "" ? "uninitialized" : "unknown")
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
        var raw = String(text)
        if (raw.length > root.maxOutputBytes) return
        var m = raw.match(/Currently signed in as (\S+) - (.+?) \(/)
        root.accountEmail = m ? root.clip(m[1], root.maxFieldLength) : ""
        root.accountDomain = m ? root.clip(m[2], root.maxFieldLength) : ""
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
        var cols = String(line).split("\t")
        if (cols.length < 3) return
        var email = root.clip(cols[0].trim(), root.maxFieldLength)
        if (email === "" || email === "EMAIL") return
        accountListProbe.rows.push({
          email: email,
          network: root.clip(cols[1].trim(), root.maxFieldLength),
          current: cols.length > 3 && cols[3].trim() === "*"
        })
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
        var trimmed = String(line).trim()
        if (trimmed === "MAIN RESOURCES") { resourcesProbe.section = "main"; return }
        if (trimmed === "KUBERNETES RESOURCES") { resourcesProbe.section = "kubernetes"; return }
        if (trimmed === "BACKGROUND RESOURCES") { resourcesProbe.section = "background"; return }
        var cols = String(line).split("\t")
        if (cols.length < 3) return
        var name = root.clip(cols[0].trim(), root.maxFieldLength)
        if (name === "" || name === "RESOURCE NAME") return
        var entry = {
          name: name,
          address: root.clip(cols[1].trim(), root.maxFieldLength),
          alias: root.clip(cols[2].trim(), root.maxFieldLength),
          authStatus: cols.length > 3 ? root.clip(cols[3].trim(), root.maxFieldLength) : ""
        }
        if (resourcesProbe.section === "kubernetes") {
          if (resourcesProbe.kubeRows.length < root.maxRows) resourcesProbe.kubeRows.push(entry)
        } else if (resourcesProbe.section === "main") {
          if (resourcesProbe.mainRows.length < root.maxRows) resourcesProbe.mainRows.push(entry)
        }
      }
    }
    onExited: {
      resourcesTimeout.stop()
      root.resources = mainRows
      root.kubeResources = kubeRows
    }
  }

  Process {
    id: kubeSyncProcess
    onExited: function(exitCode) {
      kubeSyncTimeout.stop()
      if (exitCode !== 0) root.kubeSyncError = "Sync failed: " + root.kubeSyncingName
      root.kubeSyncingName = ""
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
        var raw = String(text)
        if (raw.length > root.maxOutputBytes) return
        root.version = root.clip(raw.trim().replace(/^Twingate\s+/i, ""), root.maxFieldLength)
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
