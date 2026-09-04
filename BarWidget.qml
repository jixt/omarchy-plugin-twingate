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
  // `twingate auth` blocks until the resource's own OAuth flow finishes in
  // the browser (confirmed live: it prints the auth URL, fires a desktop
  // notification, then waits) — a human has to notice the notification,
  // switch to the browser, and sign in, possibly through 2FA. actionTimeoutMs
  // killed it after 20s, long before that could ever finish, which is why
  // clicking "Authenticate" looked like it did nothing.
  readonly property int authActionTimeoutMs: 120000
  // Headroom subtracted from authActionTimeoutMs when computing the
  // terminal fallback's own internal `timeout --signal=KILL` deadline, so
  // that kill fires (and the terminal closes) strictly before
  // authGuidanceTimer gives up and re-enables the row's Auth button.
  // Without this margin, terminal spawn latency (setsid/uwsm-app/
  // xdg-terminal-exec) could leave the widget thinking the attempt is over
  // while the underlying `twingate auth` child is still alive — which is
  // what made a same-resource retry behave unpredictably.
  readonly property int authTerminalKillMarginMs: 5000
  // Exit-code marker the terminal-fallback script writes on completion —
  // execDetached gives no exit code of its own, so authTerminalPollTimer
  // polls for this file instead of waiting out the full authGuidanceTimer
  // give-up window on every attempt, success included.
  readonly property string authTerminalMarkerPath: root.favoritesStateDir + "/auth-terminal-result"
  readonly property var knownStatuses: ["online", "offline", "disconnected", "authenticating", "error"]
  readonly property int maxFavorites: 50            // sanity cap on the persisted favorites file
  readonly property int maxFavoritesFileBytes: 65536   // guard on favorites.json's raw text, before JSON.parse ever runs on it
  readonly property int maxSnapshotFileBytes: 2097152  // guard on snapshot.json's raw text, before JSON.parse ever runs on it

  // Clamps a user-configured integer setting into [min, max], falling back
  // to `fallback` if it's missing or not a finite number.
  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(root.setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // Matches manifest.json's schema default (5s) exactly, so nobody who
  // never opens settings sees a behavior change.
  readonly property int refreshIntervalSec: root.intSetting("refreshIntervalSec", 5, 5, 3600)

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
  // Mirrors of the three lists above, but only ever updated on a genuinely
  // non-empty resourcesProbe result — never on a transient empty one (daemon
  // hiccup, settling gap). buildSnapshot() persists these instead of the
  // live lists, so a momentary empty read can't clobber the on-disk
  // instant-open cache with nothing. Reset alongside `resources` itself
  // wherever the active identity changes (switch/remove/sign-out), since a
  // stale "last good" list from the old account is worse than an empty one.
  property var lastGoodResources: []
  property var lastGoodKubeResources: []
  property var lastGoodBackgroundResources: []
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
      ["kube", "config", "sync", "--", name], root.maxOutputBytes, root.maxStderrBytes, root.actionTimeoutMs / 1000)
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
      ["kube", "config", "autosync", enabled ? "on" : "off"], root.maxOutputBytes, root.maxStderrBytes, root.actionTimeoutMs / 1000)
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
      ["kube", "config", "sync"], root.maxOutputBytes, root.maxStderrBytes, root.actionTimeoutMs / 1000)
    kubeSyncAllProcess.running = true
    kubeSyncAllTimeout.restart()
  }

  // `twingate auth` prints the OAuth URL, fires a desktop notification, and
  // blocks until that's completed. Whether that notification actually
  // reaches the user depends on twingate-desktop-notifier, a separate user
  // service that can die independently of this plugin (confirmed live this
  // session) — so every attempt re-probes that service fresh, never
  // cached, before picking a path: see startAuthAttempt().
  function authenticateResource(name) {
    if (root.authenticatingName !== "" || !root.isSafeCliToken(name)) return
    root.authenticatingName = name
    root.authError = ""
    authErrorClearTimer.stop()
    authTimeout.stop()
    authGuidanceTimer.stop()
    authTerminalPollTimer.stop()
    authNotifierProbe.pendingName = name
    authNotifierProbe.running = true
    authNotifierTimeout.restart()
  }

  // Dispatches to whichever path authNotifierProbe (or its timeout
  // backstop) decided on.
  //  - notifierActive: run headless via a tracked Process, so a real exit
  //    code decides success/failure the instant it happens.
  //  - otherwise: the same floating terminal as before, but now with the
  //    inner `twingate auth` wrapped in `timeout --signal=KILL` so the
  //    child process — and the terminal hosting it — is guaranteed dead
  //    well before authGuidanceTimer gives up on the row.
  function startAuthAttempt(name, notifierActive) {
    if (notifierActive) {
      authProcess.command = Parsing.buildCappedTwingateCommand(
        ["auth", "--", name], root.maxOutputBytes, root.maxStderrBytes, root.authActionTimeoutMs / 1000)
      authProcess.running = true
      authTimeout.restart()
    } else {
      var killSeconds = Math.max(1, Math.ceil((root.authActionTimeoutMs - root.authTerminalKillMarginMs) / 1000))
      // org.omarchy.terminal — see switchAccount() for why this bypasses
      // omarchy-launch-terminal. No trailing prompt: the script (and the
      // terminal) exits the moment `timeout`/`twingate auth` returns. Writes
      // the real exit code to authTerminalMarkerPath unconditionally
      // (success, failure, or the `timeout` kill) so authTerminalPollTimer
      // can react promptly instead of waiting out authGuidanceTimer.
      Quickshell.execDetached([
        "setsid", "uwsm-app", "--",
        "xdg-terminal-exec", "--app-id=org.omarchy.terminal", "--title=Twingate",
        "bash", "-c",
        "mkdir -p \"" + root.favoritesStateDir + "\"; rm -f \"" + root.authTerminalMarkerPath + "\"; " +
        "timeout --signal=KILL " + killSeconds + "s twingate auth -- \"$1\"; " +
        "echo $? > \"" + root.authTerminalMarkerPath + "\"",
        "twingate-auth",
        name
      ])
      authTerminalPollTimer.restart()
      authGuidanceTimer.restart()
    }
  }

  function refreshVersion() {
    if (!versionProbe.running) versionProbe.running = true
  }

  // Whether the `twingate` CLI is on PATH at all — distinct from `status`,
  // which reports "unknown"/"error" just as readily for a missing binary as
  // for a real daemon problem. Once true, never re-probed: this only needs
  // to self-heal a later install, not detect a later uninstall.
  property bool installed: false

  function refreshInstalled() {
    if (root.installed || whichProcess.running) return
    whichProcess.running = true
  }

  Process {
    id: whichProcess
    command: ["which", "twingate"]
    onExited: function(exitCode) { root.installed = exitCode === 0 }
  }

  // Whether Twingate's own desktop-notification pipeline is actually usable
  // right now. Probed fresh on every authenticateResource() call, never
  // cached — the whole reason this exists is that the service can flip from
  // healthy to dead mid-session (confirmed live this session). `is-active
  // --quiet` needs no stdout parsing: exit 0 means active, anything else
  // (inactive, failed, unit missing, systemctl itself missing) means "don't
  // trust the notification path." Checking this exact unit rather than a
  // generic "is some notification daemon present" check matters: the
  // confirmed failure mode is this specific relay dying while everything
  // else, including a perfectly healthy notification daemon, stays up.
  Process {
    id: authNotifierProbe
    property string pendingName: ""
    command: ["systemctl", "--user", "is-active", "--quiet", "twingate-desktop-notifier.service"]
    onExited: function(exitCode) {
      authNotifierTimeout.stop()
      var name = authNotifierProbe.pendingName
      authNotifierProbe.pendingName = ""
      // Stale/duplicate signal, or the in-flight attempt was already
      // resolved by the timeout backstop below — nothing to dispatch.
      if (name === "" || name !== root.authenticatingName) return
      root.startAuthAttempt(name, exitCode === 0)
    }
  }

  // Backstop for a hung or entirely-missing `systemctl` — the probe must
  // never be able to silently strand an attempt in the "authenticating…"
  // state. If it hasn't reported back promptly, default to the
  // always-working terminal fallback rather than trusting a possibly-dead
  // notification pipeline.
  Timer {
    id: authNotifierTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      if (authNotifierProbe.running) authNotifierProbe.running = false
      var name = authNotifierProbe.pendingName
      authNotifierProbe.pendingName = ""
      if (name === "" || name !== root.authenticatingName) return
      root.startAuthAttempt(name, false)
    }
  }

  // Live display state for the settings panel's notifications toggle — kept
  // separate from authNotifierProbe above, which is scoped to a single
  // in-flight auth attempt. Not persisted anywhere: this reflects real,
  // external systemd state that can change via any means (a terminal,
  // another tool), so it's re-probed fresh every time the settings view
  // opens rather than cached, same philosophy as authNotifierProbe.
  property bool notificationsEnabled: false
  property bool notificationsStateKnown: false   // true once the first probe has resolved — avoids flashing a guessed default
  property bool notificationsToggleBusy: false

  function refreshNotificationsEnabled() {
    if (notificationsProbe.running) return
    notificationsProbe.running = true
  }

  Process {
    id: notificationsProbe
    command: ["systemctl", "--user", "is-active", "--quiet", "twingate-desktop-notifier.service"]
    onExited: function(exitCode) {
      root.notificationsEnabled = exitCode === 0
      root.notificationsStateKnown = true
    }
  }

  // twingate's own desktop-start/desktop-stop (confirmed live: each maps to
  // `systemctl --user start/stop twingate-desktop-notifier`, completes
  // headlessly with a plain exit code, no interactive confirmation of its
  // own) — going through the CLI Twingate provides for this rather than
  // reaching around it with systemctl directly. Purely --user-level; no
  // sudo/pkexec involved, unrelated to useTerminalForPrivilegedActions.
  function setNotificationsEnabled(enabled) {
    if (root.notificationsToggleBusy) return
    root.notificationsToggleBusy = true
    notificationsToggleProcess.command = ["twingate", enabled ? "desktop-start" : "desktop-stop"]
    notificationsToggleProcess.running = true
  }

  Process {
    id: notificationsToggleProcess
    onExited: function(exitCode) {
      root.notificationsToggleBusy = false
      // Re-probe rather than trust exitCode/assume success — confirms the
      // real resulting state instead of guessing.
      root.refreshNotificationsEnabled()
    }
  }

  // Confirmation-gated: twingate prompts "Are you sure? [y/N]" on stdin
  // before it stops/restarts the daemon under the new identity — and that
  // restart re-execs through sudo, which needs a TTY if the prompt is a
  // typed password. Headless Process (used for connect/disconnect, where a
  // touch/scan still works) would swallow a password prompt, so this
  // opens a real terminal, same as addAccount(). printf feeds the y/N so
  // the user only has to handle sudo; sudo itself reads /dev/tty, not the
  // pipe. execDetached gives no exit code, so completion is the account
  // probe seeing the new email (or switchGuidanceTimer giving up).
  function switchAccount(email) {
    if (root.switchingAccount || email === root.accountEmail || !root.isSafeCliToken(email)) return
    root.switchingAccount = true
    root.switchingToEmail = email
    root.switchingViaPkexec = !root.useTerminalForPrivilegedActions
    switchingToEmailTimeout.stop()
    root.switchError = ""
    root.resourcesSettling = true
    root.resourcesSettlingFinalAttempt = false
    // The old account's resources/favorites are about to be wrong — hide
    // them immediately rather than leaving them on screen (looking current)
    // until the new account's daemon reconnect finishes and overwrites them.
    root.resources = []
    root.kubeResources = []
    root.backgroundResources = []
    root.lastGoodResources = []
    root.lastGoodKubeResources = []
    root.lastGoodBackgroundResources = []

    if (root.switchingViaPkexec) {
      // pkexec elevates the whole invocation to root via PolicyKit's own
      // native prompt, so twingate's internal sudo re-exec becomes a no-op
      // (root escalating to root doesn't prompt). The "Are you sure?"
      // confirmation is unrelated to sudo and still needs answering —
      // stdinEnabled/write mirrors logoutProcess exactly (same prompt,
      // `account logout`). Bare argv, no env/timeout/bash wrapper: polkit's
      // dialog names argv[1], so wrapping this would make the prompt show
      // a wrapper script instead of twingate.
      pkexecSwitchProcess.command = ["pkexec", "/usr/bin/twingate", "account", "switch", "--", email]
      pkexecSwitchProcess.running = true
    } else {
      // org.omarchy.terminal is Omarchy's own floating-terminal app-id (see
      // system.lua's "floating-window" tag rule) — used directly here
      // instead of omarchy-launch-terminal so this dialog-like prompt
      // floats centered rather than opening tiled in the background where
      // it's easy to miss.
      Quickshell.execDetached([
        "setsid", "uwsm-app", "--",
        "xdg-terminal-exec", "--app-id=org.omarchy.terminal", "--title=Twingate",
        "bash", "-c",
        "printf 'y\\n' | twingate account switch -- \"$1\"; ec=$?; if [ \"$ec\" -ne 0 ]; then echo; echo 'Account switch failed. Press Enter to close.'; read; fi",
        "twingate-account-switch",
        email
      ])
    }
    switchGuidanceTimer.restart()
  }

  // Headless, tracked (unlike the terminal path's execDetached) — pkexec
  // needs no TTY at all, so there's no reason to fire-and-forget it. A real
  // exit code only replaces failure/cancel detection: clicking Cancel in
  // the polkit dialog is reported instantly instead of waiting out the
  // full switchGuidanceTimer. Success detection is untouched — still the
  // existing account-probe polling — since the CLI returning doesn't mean
  // the daemon has actually finished restarting under the new identity.
  Process {
    id: pkexecSwitchProcess
    stdinEnabled: true
    onStarted: write("y\n")
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.switchingAccount && root.switchingViaPkexec) {
        switchGuidanceTimer.stop()
        root.switchingAccount = false
        root.switchingToEmail = ""
        root.resourcesSettling = false
        root.switchError = "Account switch failed"
      }
    }
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
      root.lastGoodResources = []
      root.lastGoodKubeResources = []
      root.lastGoodBackgroundResources = []
    }
    logoutProcess.command = Parsing.buildCappedTwingateCommand(
      ["account", "logout", "--", email], root.maxOutputBytes, root.maxStderrBytes, root.actionTimeoutMs / 1000)
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
    // See switchAccount() for why this bypasses omarchy-launch-terminal.
    Quickshell.execDetached([
      "setsid", "uwsm-app", "--",
      "xdg-terminal-exec", "--app-id=org.omarchy.terminal", "--title=Twingate",
      "twingate", "account", "add"
    ])
    addAccountGuidanceTimer.restart()
  }

  Process {
    id: statusProbe
    command: Parsing.buildCappedTwingateCommand(["status", "-v", "-d"], root.maxOutputBytes, root.maxStderrBytes, root.probeTimeoutMs / 1000)
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
    command: Parsing.buildCappedTwingateCommand(["account"], root.maxOutputBytes, root.maxStderrBytes, root.probeTimeoutMs / 1000)
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
          // longer needs to be pinned ahead of accounts[].current, and
          // the in-flight terminal switch can be marked done.
          if (root.switchingToEmail === result.email) {
            root.switchingToEmail = ""
            if (root.switchingAccount) {
              root.switchingAccount = false
              switchGuidanceTimer.stop()
              root.refreshAccounts()
              root.refreshResources()
              root.scheduleSettledRefresh()
            }
          }
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
          root.lastGoodResources = []
          root.lastGoodKubeResources = []
          root.lastGoodBackgroundResources = []
          root.clearSnapshot()
        }
      }
    }
  }

  Process {
    id: accountListProbe
    property var rows: []
    property int linesSeen: 0
    command: Parsing.buildCappedTwingateCommand(["account", "list", "-d"], root.maxAccountListBytes, root.maxStderrBytes, root.probeTimeoutMs / 1000)
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

  // Headless `twingate auth`, used only when twingate-desktop-notifier is
  // confirmed active — its own notification does the user-facing work, and
  // this Process's real exit code (not a fixed timer) decides success vs.
  // failure. buildCappedTwingateCommand's own `timeout --signal=KILL`
  // wrapper is what actually guarantees this can't hang forever; authTimeout
  // below is only the same kind of backstop every other capped Process in
  // this file already has.
  Process {
    id: authProcess
    onExited: function(exitCode) {
      authTimeout.stop()
      var name = root.authenticatingName
      root.authenticatingName = ""
      if (exitCode !== 0) {
        root.authError = "Authentication failed: " + name
        authErrorClearTimer.restart()
      } else {
        root.authError = ""
      }
      root.refreshResources()
    }
  }

  Process {
    id: resourcesProbe
    property var mainRows: []
    property var kubeRows: []
    property var backgroundRows: []
    property string section: "main"
    property int linesSeen: 0
    command: Parsing.buildCappedTwingateCommand(["resources", "--all", "-d"], root.maxResourcesBytes, root.maxStderrBytes, root.probeTimeoutMs / 1000)
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
        if (!parsedEmpty) {
          root.lastGoodResources = mainRows
          root.lastGoodKubeResources = kubeRows
          root.lastGoodBackgroundResources = backgroundRows
          root.saveSnapshot()
        }
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
    id: versionProbe
    command: Parsing.buildCappedTwingateCommand(["--version"], root.maxOutputBytes, root.maxStderrBytes, root.probeTimeoutMs / 1000)
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
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refreshStatus()
      root.refreshAccount()
      if (!root.installed) root.refreshInstalled()
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

  // Self-clears if the terminal switch never lands. execDetached gives no
  // exit code; 90s matches addAccountGuidanceTimer — long enough to type a
  // sudo password without leaving the row stuck "switching" forever.
  Timer {
    id: switchGuidanceTimer
    interval: 90000
    repeat: false
    onTriggered: {
      if (pkexecSwitchProcess.running) pkexecSwitchProcess.running = false
      root.switchingAccount = false
      root.switchingToEmail = ""
      root.resourcesSettling = false
      root.switchError = "Switch timed out"
    }
  }

  // Pure safety net: if a switch was started but switchingToEmail was
  // never cleared (accountProbe never saw the new email). Account switch
  // itself now times out via switchGuidanceTimer; this just unpins the
  // row highlight if that somehow races.
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

  // Backstop for authProcess (headless path): buildCappedTwingateCommand's
  // own `timeout --signal=KILL` should always make onExited fire at or
  // before this deadline; this only protects against QML losing track of
  // an already-dead wrapper, same as statusTimeout/resourcesTimeout/etc.
  Timer {
    id: authTimeout
    interval: root.authActionTimeoutMs
    repeat: false
    onTriggered: {
      if (authProcess.running) authProcess.running = false
      root.authenticatingName = ""
      root.authError = "Authentication timed out"
      authErrorClearTimer.restart()
      root.refreshResources()
    }
  }

  // Terminal-fallback path only: the true give-up mechanism — same tradeoff
  // as switchGuidanceTimer — for the rare case authTerminalPollTimer never
  // sees a marker at all (e.g. the terminal was force-closed before the
  // script's last line ran). authTerminalKillMarginMs guarantees the
  // terminal (and the `twingate auth` it hosts) is already gone by the time
  // this fires, so a retry right after doesn't race a still-running attempt.
  Timer {
    id: authGuidanceTimer
    interval: root.authActionTimeoutMs
    repeat: false
    onTriggered: {
      authTerminalPollTimer.stop()
      root.authenticatingName = ""
      root.authError = "Authentication timed out"
      authErrorClearTimer.restart()
      root.refreshResources()
    }
  }

  // Terminal-fallback path only: polls for the exit-code marker the launched
  // script writes on completion (success, failure, or its own `timeout`
  // kill) so the row's Auth button and error state update within a second
  // or two, instead of waiting out authGuidanceTimer's full give-up window
  // on every attempt.
  Timer {
    id: authTerminalPollTimer
    interval: 500
    repeat: true
    onTriggered: if (!authTerminalPollProcess.running) authTerminalPollProcess.running = true
  }

  Process {
    id: authTerminalPollProcess
    command: ["cat", root.authTerminalMarkerPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = String(text).trim()
        if (result === "") return   // marker not written yet — keep polling
        authTerminalPollTimer.stop()
        authGuidanceTimer.stop()
        var name = root.authenticatingName
        root.authenticatingName = ""
        if (result !== "0") {
          root.authError = "Authentication failed: " + name
          authErrorClearTimer.restart()
        } else {
          root.authError = ""
        }
        root.refreshResources()
      }
    }
  }

  // authError otherwise persists indefinitely once set. Longer than the
  // codebase's transient-success timers (copiedClearTimer,
  // kubeSyncSuccessTimer — 1400-2500ms), since a failure message needs
  // more time to actually be read.
  Timer {
    id: authErrorClearTimer
    interval: 5000
    repeat: false
    onTriggered: root.authError = ""
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

  readonly property int maxPrefsFileBytes: 4096   // guard on prefs.json's raw text, before JSON.parse ever runs on it — tiny today, headroom for future prefs

  // false = pkexec (default: a native polkit password/fingerprint prompt,
  // no terminal). true = the floating-terminal path, for whoever wants to
  // see twingate's own live output. Persisted locally, not in shell.json —
  // there's no proven write-back path from a live widget into that file,
  // and this plugin already owns favorites.json/snapshot.json the same way.
  property bool useTerminalForPrivilegedActions: false
  // Which path *this* switch attempt actually used — snapshotted once at
  // the start of switchAccount(), so a mid-flight settings change can't
  // retroactively change what an in-flight attempt is waited on/reported as.
  property bool switchingViaPkexec: false

  readonly property string prefsPath: root.favoritesStateDir + "/prefs.json"

  FileView {
    id: prefsFile
    path: root.prefsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.useTerminalForPrivilegedActions = Parsing.parsePrefsJson(text(), root.maxPrefsFileBytes).useTerminalForPrivilegedActions
    onLoadFailed: {}   // no prefs file yet (first run) — property already defaults to pkexec
    onSaveFailed: if (!ensureFavoritesDir.running) ensureFavoritesDir.running = true
  }

  Timer {
    id: prefsSaveTimer
    interval: 200
    repeat: false
    onTriggered: prefsFile.setText(JSON.stringify({ useTerminalForPrivilegedActions: root.useTerminalForPrivilegedActions }, null, 2) + "\n")
  }

  // Sole write path — mirrors toggleFavorite() — so save-on-change stays
  // owned in one place instead of every caller remembering to restart the
  // save timer itself.
  function setUseTerminalForPrivilegedActions(value) {
    var v = value === true
    if (v === root.useTerminalForPrivilegedActions) return
    root.useTerminalForPrivilegedActions = v
    prefsSaveTimer.restart()
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
        // Seed lastGood* too — otherwise an unrelated probe (account,
        // version) succeeding before resourcesProbe's first run this
        // session would save a snapshot with lastGood* still empty,
        // clobbering the very cache this load just restored.
        root.lastGoodResources = snap.resources
        root.lastGoodKubeResources = snap.kubeResources
        root.lastGoodBackgroundResources = snap.backgroundResources
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

  // Persists lastGood*, not the live resources/kubeResources/
  // backgroundResources — a probe unrelated to resources (account,
  // account list, version) can trigger a snapshot save at any time, and
  // must not bake a transiently empty live resources read into the
  // on-disk instant-open cache.
  function buildSnapshot() {
    return {
      accountEmail: root.accountEmail,
      accountDomain: root.accountDomain,
      accounts: root.accounts,
      resources: root.lastGoodResources,
      kubeResources: root.lastGoodKubeResources,
      backgroundResources: root.lastGoodBackgroundResources,
      version: root.version
    }
  }

  function saveSnapshot() {
    snapshotSaveTimer.restart()
  }

  // Backing data for `omarchy-shell jixt.twingate diagnostics`. lastError
  // collapses this plugin's several independent error surfaces (switch,
  // remove, auth, kube sync) into one string by a fixed priority — good
  // enough for a support report, not meant to distinguish which one fired.
  function buildDiagnostics() {
    return {
      installed: root.installed,
      state: root.status,
      resourceCount: root.resources.length + root.kubeResources.length + root.backgroundResources.length,
      lastError: root.switchError || root.removeError || root.authError || root.kubeSyncError || "",
      settings: { refreshIntervalSec: root.refreshIntervalSec }
    }
  }

  function clearSnapshot() {
    snapshotSaveTimer.stop()
    snapshotFile.setText("")
  }

  Process {
    id: ensureFavoritesDir
    command: ["mkdir", "-p", root.favoritesStateDir]
    onExited: { favoritesFile.reload(); snapshotFile.reload(); prefsFile.reload() }
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

  // Bar.qml's findPanelWidget() (used by `omarchy-shell shell toggle
  // <id>`, the monitor-aware routing every keyboard-summoned panel should
  // use — see BarWidget.qml's `requestToggleConnection` doc comment)
  // requires open()/close()/opened directly on the bar-widget root. Plugins
  // that register Panel.qml itself as the barWidget entry point get these
  // for free from the base Panel type; this plugin's BarWidget.qml +
  // inner Panel Loader needs to forward them explicitly. close()/opened
  // already existed (used by togglePanel()'s own callers) — open() was
  // the missing piece.
  function open() {
    if (panelLoader.item && typeof panelLoader.item.open === "function") panelLoader.item.open()
  }

  // Right-click toggles the tunnel without opening the panel; the panel
  // owns the actual connect/disconnect (it needs resourcesSettling already
  // wired there), so this just forwards to it — which works whether or
  // not the panel is currently open. A terminal is opened for sudo.
  function requestToggleConnection() {
    if (panelLoader.item && typeof panelLoader.item.toggleConnection === "function") panelLoader.item.toggleConnection()
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
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.requestToggleConnection()
      else if (buttonCode === Qt.MiddleButton) root.refreshResources()
      else root.togglePanel()
    }
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
