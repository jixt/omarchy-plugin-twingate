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

  // Raw `twingate status` output: online | offline | disconnected |
  // authenticating | error | uninitialized.
  property string status: "uninitialized"
  readonly property bool isOnline: status === "online"
  readonly property color statusColor: status === "online" ? "#3fb950"
    : (status === "authenticating" ? "#d29922" : "#8b949e")
  readonly property color foreground: bar ? bar.foreground : Color.foreground

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
    if (root.kubeSyncingName !== "" || !name) return
    root.kubeSyncingName = name
    root.kubeSyncError = ""
    kubeSyncProcess.command = ["twingate", "kube", "config", "sync", name]
    kubeSyncProcess.running = true
  }

  function refreshVersion() {
    if (!versionProbe.running) versionProbe.running = true
  }

  // Confirmation-gated: twingate prompts "Are you sure? [y/N]" on stdin
  // before it stops/restarts the daemon under the new identity.
  function switchAccount(email) {
    if (root.switchingAccount || !email || email === root.accountEmail) return
    root.switchingAccount = true
    root.switchError = ""
    switchProcess.command = ["twingate", "account", "switch", email]
    switchProcess.running = true
  }

  Process {
    id: statusProbe
    command: ["twingate", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var s = String(text).trim().toLowerCase()
        root.status = s || "uninitialized"
      }
    }
  }

  Process {
    id: accountProbe
    command: ["twingate", "account"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text).match(/Currently signed in as (\S+) - (.+?) \(/)
        root.accountEmail = m ? m[1] : ""
        root.accountDomain = m ? m[2] : ""
      }
    }
  }

  Process {
    id: accountListProbe
    command: ["twingate", "account", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n")
        var next = []
        for (var i = 0; i < lines.length; i++) {
          var cols = lines[i].split("\t")
          if (cols.length < 3) continue
          var email = cols[0].trim()
          if (email === "" || email === "EMAIL") continue
          next.push({
            email: email,
            network: cols[1].trim(),
            current: cols.length > 3 && cols[3].trim() === "*"
          })
        }
        root.accounts = next
      }
    }
  }

  Process {
    id: switchProcess
    stdinEnabled: true
    onStarted: write("y\n")
    onExited: function(exitCode) {
      root.switchingAccount = false
      root.switchError = exitCode !== 0 ? "Switch failed" : ""
      root.refreshStatus()
      root.refreshAccount()
      root.refreshAccounts()
      root.refreshResources()
    }
  }

  Process {
    id: resourcesProbe
    command: ["twingate", "resources"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n")
        var mainList = []
        var kubeList = []
        var section = "main"
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          var trimmed = line.trim()
          if (trimmed === "MAIN RESOURCES") { section = "main"; continue }
          if (trimmed === "KUBERNETES RESOURCES") { section = "kubernetes"; continue }
          if (trimmed === "BACKGROUND RESOURCES") { section = "background"; continue }
          var cols = line.split("\t")
          if (cols.length < 3) continue
          var name = cols[0].trim()
          if (name === "" || name === "RESOURCE NAME") continue
          var entry = {
            name: name,
            address: cols[1].trim(),
            alias: cols[2].trim(),
            authStatus: cols.length > 3 ? cols[3].trim() : ""
          }
          if (section === "kubernetes") kubeList.push(entry)
          else if (section === "main") mainList.push(entry)
        }
        root.resources = mainList
        root.kubeResources = kubeList
      }
    }
  }

  Process {
    id: kubeSyncProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) root.kubeSyncError = "Sync failed: " + root.kubeSyncingName
      root.kubeSyncingName = ""
    }
  }

  Process {
    id: versionProbe
    command: ["twingate", "--version"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.version = String(text).trim().replace(/^Twingate\s+/i, "")
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
