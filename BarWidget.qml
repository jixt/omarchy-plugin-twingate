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
  readonly property int maxAccountListBytes: 1048576  // 1 MB producer-side cap: account list (maxRows=200 bounds it further)
  readonly property int maxResourcesBytes: 4194304    // 4 MB producer-side cap: full `resources --all` listing
  readonly property int maxStderrBytes: 8192          // 8 KB producer-side cap: diagnostic stderr, every invocation
  readonly property int maxRows: 200                // accounts / resources per list
  readonly property int maxFieldLength: 256         // any single displayed field
  readonly property int maxLinesTotal: 4000         // hard stop regardless of validity
  readonly property int probeTimeoutMs: 10000       // periodic read-only probes
  readonly property int actionTimeoutMs: 20000      // switch/connect/sync (daemon restarts)
  readonly property var knownStatuses: ["online", "offline", "disconnected", "authenticating", "error"]
  readonly property int maxFavorites: 50            // sanity cap on the persisted favorites file
  readonly property int maxFavoritesFileBytes: 65536   // guard on favorites.json's raw text, before JSON.parse ever runs on it
  readonly property int maxSnapshotFileBytes: 2097152  // guard on snapshot.json's raw text, before JSON.parse ever runs on it

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

  // True only during the specific, already-instrumented gap between a
  // switch/connect/logout kicking off a daemon restart and that restart
  // being confirmed settled — the one window where a probe coming back
  // empty is expected and must not be trusted as "genuinely empty."
  function isSettlingGap() {
    return root.resourcesSettling && !root.resourcesSettlingFinalAttempt
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
  // The account a switch is currently targeting, so the UI can show it as
  // "selected" the instant the user clicks it — rather than waiting for the
  // switch to actually finish and account list to refresh with the new
  // `current` flags, which visibly lags the click by several seconds.
  property string switchingToEmail: ""

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
    if (!root.isSafeCliToken(name) || !Parsing.isValidFavoriteKind(kind)) return
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
    if (root.kubeSyncingName !== "" || root.kubeSyncingAll || !root.isSafeCliToken(name)) return
    root.kubeSyncingName = name
    root.kubeSyncError = ""
    root.kubeSyncSuccess = ""
    // "--" stops option parsing so a resource name that merely looks like a
    // flag can never be read as one, in addition to the isSafeCliToken guard.
    kubeSyncProcess.command = Parsing.buildCappedTwingateCommand(
      ["kube", "config", "sync", "--", name], root.maxOutputBytes, root.maxStderrBytes)
    kubeSyncProcess.running = true
    kubeSyncTimeout.restart()
  }

  // No `kube config autosync` *read* command exists — this optimistically
  // reflects the last toggle this shell session made (the same idiom
  // ToggleSwitch's own doc comment describes for a service that tracks a
  // desired state, e.g. Tailscale's `_desired`). Resets to false on shell
  // restart; deliberately NOT part of the instant-open snapshot, which is
  // scoped to CLI-read state, not an unconfirmable guess.
  property bool kubeAutosyncEnabled: false
  property bool kubeAutosyncBusy: false
  property bool kubeSyncingAll: false

  function setKubeAutosync(enabled) {
    if (root.kubeAutosyncBusy) return
    root.kubeAutosyncBusy = true
    kubeAutosyncProcess.pendingEnabled = enabled
    kubeAutosyncProcess.command = Parsing.buildCappedTwingateCommand(
      ["kube", "config", "autosync", enabled ? "on" : "off"], root.maxOutputBytes, root.maxStderrBytes)
    kubeAutosyncProcess.running = true
    kubeAutosyncTimeout.restart()
  }

  // Reuses kubeSyncError/kubeSyncSuccess — the same Kubernetes-tab status
  // line already used for per-cluster sync, not a new one.
  function syncAllKubeResources() {
    if (root.kubeSyncingName !== "" || root.kubeSyncingAll) return
    root.kubeSyncingAll = true
    root.kubeSyncError = ""
    root.kubeSyncSuccess = ""
    kubeSyncAllProcess.command = Parsing.buildCappedTwingateCommand(
      ["kube", "config", "sync"], root.maxOutputBytes, root.maxStderrBytes)
    kubeSyncAllProcess.running = true
    kubeSyncAllTimeout.restart()
  }

  // Doesn't restart the daemon (unlike switch/connect), so a plain
  // refreshResources() after it exits is enough — no scheduleSettledRefresh().
  function authenticateResource(name) {
    if (root.authenticatingName !== "" || !root.isSafeCliToken(name)) return
    root.authenticatingName = name
    root.authError = ""
    authProcess.command = Parsing.buildCappedTwingateCommand(
      ["auth", "--", name], root.maxOutputBytes, root.maxStderrBytes)
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
    root.switchingToEmail = email
    switchingToEmailTimeout.restart()
    root.switchError = ""
    root.resourcesSettling = true
    root.resourcesSettlingFinalAttempt = false
    // The old account's resources/favorites are about to be wrong — hide
    // them immediately rather than leaving them on screen (looking current)
    // until the new account's daemon reconnect finishes and overwrites them.
    root.resources = []
    root.kubeResources = []
    root.backgroundResources = []
    switchProcess.command = Parsing.buildCappedTwingateCommand(
      ["account", "switch", "--", email], root.maxOutputBytes, root.maxStderrBytes)
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
    // Same staleness risk as switchAccount(): removing the *current* account
    // changes (or clears) the active identity, so its resources/favorites
    // are about to be wrong — hide them immediately instead of leaving them
    // on screen until logout finishes and the next probe replaces them.
    if (email === root.accountEmail) {
      root.resourcesSettling = true
      root.resourcesSettlingFinalAttempt = false
      root.resources = []
      root.kubeResources = []
      root.backgroundResources = []
    }
    logoutProcess.command = Parsing.buildCappedTwingateCommand(
      ["account", "logout", "--", email], root.maxOutputBytes, root.maxStderrBytes)
    logoutProcess.running = true
    logoutTimeout.restart()
  }

  // `account add` prompts on stdin from its very first step (confirm/change
  // network, confirm switching to the new account, confirm a daemon restart)
  // before it ever gets to browser sign-in — confirmed live that with no
  // stdin attached at all, it hits EOF on the first prompt and exits
  // immediately, which is why running it via plain execDetached silently
  // did nothing. Launch it in a real terminal instead, via Omarchy's own
  // launcher, so the user can answer those prompts and reach sign-in.
  // There's still no exit code to key off once the terminal is open, so
  // the guidance message just self-clears after a fixed window and the
  // periodic account-list poll naturally picks up the new account.
  function addAccount() {
    if (root.addingAccount) return
    root.addingAccount = true
    Quickshell.execDetached(["omarchy-launch-terminal", "twingate", "account", "add"])
    addAccountGuidanceTimer.restart()
  }

  Process {
    id: statusProbe
    command: Parsing.buildCappedTwingateCommand(["status", "-v"], root.maxOutputBytes, root.maxStderrBytes)
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
    command: Parsing.buildCappedTwingateCommand(["account"], root.maxOutputBytes, root.maxStderrBytes)
    onStarted: accountTimeout.restart()
    onExited: accountTimeout.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Parsing.parseAccountText(String(text), root.maxOutputBytes, root.maxFieldLength)
        if (result && result.email !== "") {
          root.accountEmail = result.email
          root.accountDomain = result.domain
          root.saveSnapshot()
          // The switch actually landed — the "selected" account row no
          // longer needs to be pinned ahead of accounts[].current.
          if (root.switchingToEmail === result.email) root.switchingToEmail = ""
        } else if (result && !root.isSettlingGap()) {
          // Not oversized, not mid-restart — genuinely signed out. Clear
          // resources/favorites-backing data too, same as switchAccount()/
          // removeAccount(), so nothing from the old identity lingers on
          // screen or in the disk snapshot until the next probe replaces it.
          root.accountEmail = ""
          root.accountDomain = ""
          root.resources = []
          root.kubeResources = []
          root.backgroundResources = []
          root.clearSnapshot()
        }
      }
    }
  }

  Process {
    id: accountListProbe
    property var rows: []
    property int linesSeen: 0
    command: Parsing.buildCappedTwingateCommand(["account", "list"], root.maxAccountListBytes, root.maxStderrBytes)
    onStarted: { rows = []; linesSeen = 0; accountListTimeout.restart() }
    stdout: SplitParser {
      // Consumer-side cap: stop accepting rows (and stop the process) once
      // either the row cap or a generous total-line ceiling is hit. The
      // real producer-side cap is the `head -c` in buildCappedTwingateCommand
      // above, which bounds the total bytes SplitParser can ever see in the
      // first place; this just bounds how many of those bytes turn into
      // JS objects/array entries.
      onRead: function(line) {
        accountListProbe.linesSeen += 1
        if (accountListProbe.linesSeen > root.maxLinesTotal) { accountListProbe.running = false; return }
        if (accountListProbe.rows.length >= root.maxRows) return
        var row = Parsing.parseAccountListRow(String(line), root.maxFieldLength)
        if (row) accountListProbe.rows.push(row)
      }
    }
    onExited: {
      accountListTimeout.stop()
      if (rows.length > 0) {
        root.accounts = rows
        root.saveSnapshot()
      } else if (!root.isSettlingGap()) {
        root.accounts = rows
        root.clearSnapshot()
      }
    }
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
      // don't keep showing "Loading resources…" for one that'll never arrive,
      // and stop showing the target account as selected since it never took.
      // On success, switchingToEmail stays set until accountProbe actually
      // confirms the new account is current — clearing it here instead would
      // open a gap where account.current still reflects the OLD account
      // (accounts list hasn't refreshed yet), flickering the highlight back.
      if (exitCode !== 0) {
        root.resourcesSettling = false
        root.switchingToEmail = ""
      }
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
      root.removeError = exitCode !== 0 ? "Log out failed" : ""
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
    command: Parsing.buildCappedTwingateCommand(["resources", "--all"], root.maxResourcesBytes, root.maxStderrBytes)
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
      var parsedEmpty = mainRows.length === 0 && kubeRows.length === 0 && backgroundRows.length === 0
      // Don't let a probe that landed mid-daemon-restart wipe a known-good
      // snapshot with a transient empty result — same settling window
      // scheduleSettledRefresh()/resourcesSettlingFinalAttempt already exist
      // to guard against.
      if (!(root.isSettlingGap() && parsedEmpty)) {
        root.resources = mainRows
        root.kubeResources = kubeRows
        root.backgroundResources = backgroundRows
        if (!parsedEmpty) root.saveSnapshot()
      }
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
    id: kubeAutosyncProcess
    property bool pendingEnabled: false
    onExited: function(exitCode) {
      kubeAutosyncTimeout.stop()
      if (exitCode === 0) {
        root.kubeAutosyncEnabled = kubeAutosyncProcess.pendingEnabled
        root.kubeSyncError = ""
        root.kubeSyncSuccess = root.kubeAutosyncEnabled ? "Autosync on" : "Autosync off"
        kubeSyncSuccessTimer.restart()
      } else {
        root.kubeSyncError = "Autosync toggle failed"
      }
      root.kubeAutosyncBusy = false
    }
  }

  Process {
    id: kubeSyncAllProcess
    onExited: function(exitCode) {
      kubeSyncAllTimeout.stop()
      if (exitCode !== 0) {
        root.kubeSyncError = "Sync all failed"
      } else {
        root.kubeSyncError = ""
        root.kubeSyncSuccess = "Synced all clusters"
        kubeSyncSuccessTimer.restart()
      }
      root.kubeSyncingAll = false
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
    command: Parsing.buildCappedTwingateCommand(["--version"], root.maxOutputBytes, root.maxStderrBytes)
    onStarted: versionTimeout.restart()
    onExited: versionTimeout.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var version = Parsing.parseVersionText(String(text), root.maxOutputBytes, root.maxFieldLength)
        if (version !== null && version !== "") {
          root.version = version
          root.saveSnapshot()
        }
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
      root.switchingToEmail = ""
      root.switchError = "Switch timed out"
    }
  }

  // Pure safety net: if the switch process exits 0 but the account somehow
  // never actually becomes current (accountProbe keeps reporting the old
  // email), don't leave the wrong row pinned as "selected" forever. Set well
  // beyond actionTimeoutMs + the settling retry chain, so it never fires
  // during a normal successful switch.
  Timer {
    id: switchingToEmailTimeout
    interval: 25000
    repeat: false
    onTriggered: root.switchingToEmail = ""
  }

  Timer {
    id: logoutTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (logoutProcess.running) logoutProcess.running = false
      root.removingAccount = ""
      root.removeError = "Log out timed out"
    }
  }

  // Self-clears the in-panel guidance message. execDetached gives no exit
  // code, so there's no way to detect the terminal flow actually finishing;
  // the periodic account-list poll picks up the new account on its own
  // once it does. 90s covers the network/switch/restart prompts plus
  // browser sign-in without leaving the button stuck disabled too long.
  Timer {
    id: addAccountGuidanceTimer
    interval: 90000
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
    id: kubeAutosyncTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (kubeAutosyncProcess.running) kubeAutosyncProcess.running = false
      root.kubeSyncError = "Autosync toggle timed out"
      root.kubeAutosyncBusy = false
    }
  }

  Timer {
    id: kubeSyncAllTimeout
    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (kubeSyncAllProcess.running) kubeSyncAllProcess.running = false
      root.kubeSyncError = "Sync all timed out"
      root.kubeSyncingAll = false
    }
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
    onLoaded: root.favorites = Parsing.parseFavoritesJson(text(), root.maxFavorites, root.maxFieldLength, root.maxFavoritesFileBytes)
    onLoadFailed: root.favorites = []
    onSaveFailed: if (!ensureFavoritesDir.running) ensureFavoritesDir.running = true
  }

  Timer {
    id: favoritesSaveTimer
    interval: 200
    repeat: false
    onTriggered: favoritesFile.setText(JSON.stringify(root.favorites, null, 2) + "\n")
  }

  // Instant-open cache: the last successful account/account-list/resources/
  // version snapshot, persisted next to favorites.json so the first panel
  // open after a shell restart paints immediately instead of blanking while
  // probes run. Untrusted on load — same byte-cap-before-parse/clip()/
  // row-cap discipline as favorites.json, via Parsing.parseSnapshotJson.
  readonly property string snapshotPath: root.favoritesStateDir + "/snapshot.json"

  FileView {
    id: snapshotFile
    path: root.snapshotPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var snap = Parsing.parseSnapshotJson(text(), root.maxRows, root.maxFieldLength, root.maxSnapshotFileBytes)
      if (!snap) return
      // Never overwrite anything a live probe already answered first —
      // defensive against this file's load racing a fast probe.
      if (root.accountEmail === "" && root.accounts.length === 0) {
        root.accountEmail = snap.accountEmail
        root.accountDomain = snap.accountDomain
        root.accounts = snap.accounts
      }
      if (root.resources.length === 0 && root.kubeResources.length === 0 && root.backgroundResources.length === 0) {
        root.resources = snap.resources
        root.kubeResources = snap.kubeResources
        root.backgroundResources = snap.backgroundResources
      }
      if (root.version === "") root.version = snap.version
    }
    onLoadFailed: {}   // no cache yet, or unreadable — first open just probes normally
    onSaveFailed: if (!ensureFavoritesDir.running) ensureFavoritesDir.running = true
  }

  Timer {
    id: snapshotSaveTimer
    interval: 500
    repeat: false
    onTriggered: snapshotFile.setText(JSON.stringify(root.buildSnapshot(), null, 2) + "\n")
  }

  function buildSnapshot() {
    return {
      accountEmail: root.accountEmail,
      accountDomain: root.accountDomain,
      accounts: root.accounts,
      resources: root.resources,
      kubeResources: root.kubeResources,
      backgroundResources: root.backgroundResources,
      version: root.version
    }
  }

  function saveSnapshot() {
    snapshotSaveTimer.restart()
  }

  function clearSnapshot() {
    snapshotSaveTimer.stop()
    snapshotFile.setText("")
  }

  Process {
    id: ensureFavoritesDir
    command: ["mkdir", "-p", root.favoritesStateDir]
    onExited: { favoritesFile.reload(); snapshotFile.reload() }
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
