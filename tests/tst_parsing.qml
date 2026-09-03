import QtQuick
import QtTest

import "../Parsing.js" as Parsing

TestCase {
  name: "TwingateParsing"

  function test_clip_truncatesAndStripsControlAndAngleChars() {
    compare(Parsing.clip("hello", 10), "hello")
    compare(Parsing.clip("hello world", 5), "hello")
    compare(Parsing.clip(undefined, 10), "")
    compare(Parsing.clip(null, 10), "")
    compare(Parsing.clip("a\x01b<script>c\x7f", 20), "abscriptc")
  }

  function test_clip_stripsZeroWidthCharacters() {
    compare(Parsing.clip("a\u200Bb\u200Cc\u200Dd\uFEFFe", 20), "abcde")
  }

  function test_clip_stripsBidiControlCharacters() {
    compare(Parsing.clip("a\u202Ab\u202Cc\u2066d\u2069e", 20), "abcde")
  }

  function test_clip_stripsTagCharacters() {
    compare(Parsing.clip("a\u{E0001}b\u{E007F}c", 20), "abc")
  }

  function test_utf8ByteLength_countsMultiByteCharactersCorrectly() {
    compare(Parsing.utf8ByteLength(""), 0)
    compare(Parsing.utf8ByteLength("hello"), 5)
    compare(Parsing.utf8ByteLength("é"), 2)       // 2-byte: é
    compare(Parsing.utf8ByteLength("中"), 3)        // 3-byte: 中
    compare(Parsing.utf8ByteLength("\u{1F600}"), 4)     // 4-byte astral: 😀
    compare(Parsing.utf8ByteLength(undefined), 0)
    compare(Parsing.utf8ByteLength(null), 0)
  }

  function test_isLikelyClipped_trueOnlyAtOrAboveTheByteCeiling() {
    verify(!Parsing.isLikelyClipped(99, 100))
    verify(Parsing.isLikelyClipped(100, 100))
    verify(Parsing.isLikelyClipped(150, 100))
    verify(!Parsing.isLikelyClipped(150, 0))
  }

  function test_isSafeCliToken_rejectsEmptyOversizedFlagLikeOrControlChars() {
    verify(Parsing.isSafeCliToken("my-resource", 256))
    verify(!Parsing.isSafeCliToken("", 256))
    verify(!Parsing.isSafeCliToken("x".repeat(300), 256))
    verify(!Parsing.isSafeCliToken("-rf", 256))
    verify(!Parsing.isSafeCliToken("bad\x01token", 256))
    verify(!Parsing.isSafeCliToken(42, 256))
  }

  function test_isValidHost_acceptsHostnamesAndPortsRejectsGarbage() {
    verify(Parsing.isValidHost("resource.example.com"))
    verify(Parsing.isValidHost("resource.example.com:8443"))
    verify(Parsing.isValidHost("localhost"))
    verify(!Parsing.isValidHost(""))
    verify(!Parsing.isValidHost("has a space"))
    verify(!Parsing.isValidHost("evil\x01host"))
    verify(!Parsing.isValidHost("x".repeat(300)))
    verify(!Parsing.isValidHost("-leading-dash.example.com"))
  }

  // Real CLI wording (confirmed against the live `twingate` binary's strings
  // and a live `resources --all` run): locked rows read "Not authenticated";
  // authenticated rows read "Auth expires in …". Free text, not an enum —
  // matched defensively via a lowercase substring.
  function test_isResourceLocked_matchesNotAuthenticatedAndPending() {
    verify(Parsing.isResourceLocked("Not authenticated"))
    verify(Parsing.isResourceLocked("not authenticated"))
    verify(Parsing.isResourceLocked("Pending"))
    verify(Parsing.isResourceLocked("pending"))
    verify(!Parsing.isResourceLocked("Auth expires in 3 days"))
    verify(!Parsing.isResourceLocked("Auth expires in over a week"))
    verify(!Parsing.isResourceLocked("Auth expires in under 1 minute"))
    verify(!Parsing.isResourceLocked(""))
    verify(!Parsing.isResourceLocked(null))
  }

  function test_parsePrefsJson_missingOrEmptyReturnsDefaults() {
    compare(Parsing.parsePrefsJson("", 4096).useTerminalForPrivilegedActions, false)
    compare(Parsing.parsePrefsJson(null, 4096).useTerminalForPrivilegedActions, false)
    compare(Parsing.parsePrefsJson("   ", 4096).useTerminalForPrivilegedActions, false)
  }

  function test_parsePrefsJson_malformedJsonReturnsDefaults() {
    compare(Parsing.parsePrefsJson("{not json", 4096).useTerminalForPrivilegedActions, false)
    compare(Parsing.parsePrefsJson("[1,2,3]", 4096).useTerminalForPrivilegedActions, false)
    compare(Parsing.parsePrefsJson("\"just a string\"", 4096).useTerminalForPrivilegedActions, false)
  }

  function test_parsePrefsJson_oversizedReturnsDefaults() {
    var huge = '{"useTerminalForPrivilegedActions": true, "padding": "' + "x".repeat(5000) + '"}'
    compare(Parsing.parsePrefsJson(huge, 4096).useTerminalForPrivilegedActions, false)
  }

  function test_parsePrefsJson_readsTrueAndRejectsNonBoolean() {
    compare(Parsing.parsePrefsJson('{"useTerminalForPrivilegedActions": true}', 4096).useTerminalForPrivilegedActions, true)
    compare(Parsing.parsePrefsJson('{"useTerminalForPrivilegedActions": "true"}', 4096).useTerminalForPrivilegedActions, false)
    compare(Parsing.parsePrefsJson('{"useTerminalForPrivilegedActions": 1}', 4096).useTerminalForPrivilegedActions, false)
  }

  function test_parseStatusLine_splitsWordAndDetailOnColon() {
    var r = Parsing.parseStatusLine("Online: User", ["online", "offline", "disconnected", "authenticating", "error"], 65536, 256)
    compare(r.status, "online")
    compare(r.detail, "User")
    compare(r.extraLines.length, 0)
  }

  function test_parseStatusLine_fallsBackToPlainSingleWord() {
    var known = ["online", "offline", "disconnected", "authenticating", "error"]
    var r = Parsing.parseStatusLine("offline", known, 65536, 256)
    compare(r.status, "offline")
    compare(r.detail, "")
  }

  function test_parseStatusLine_emptyIsUninitializedUnknownWordIsUnknown() {
    var known = ["online", "offline", "disconnected", "authenticating", "error"]
    compare(Parsing.parseStatusLine("", known, 65536, 256).status, "uninitialized")
    compare(Parsing.parseStatusLine("   \n  ", known, 65536, 256).status, "uninitialized")
    compare(Parsing.parseStatusLine("gibberish", known, 65536, 256).status, "unknown")
  }

  function test_parseStatusLine_oversizedIsUnknown() {
    var known = ["online"]
    var r = Parsing.parseStatusLine("x".repeat(100), known, 10, 256)
    compare(r.status, "unknown")
    compare(r.detail, "")
    compare(r.extraLines.length, 0)
  }

  function test_parseStatusLine_capsExtraLinesAtFive() {
    var known = ["online"]
    var raw = "Online: User\n" + Array.from({ length: 8 }, function(_, i) { return "line" + i }).join("\n")
    var r = Parsing.parseStatusLine(raw, known, 65536, 256)
    compare(r.status, "online")
    compare(r.extraLines.length, 5)
    compare(r.extraLines[0], "line0")
  }

  function test_parseStatusLine_prefixMatchesGluedProseWithNoColon() {
    var known = ["online", "offline", "disconnected", "authenticating", "error"]
    var r = Parsing.parseStatusLine("onlineA resource you attempted to reach is not available", known, 65536, 256)
    compare(r.status, "online")
    compare(r.detail, "")
  }

  function test_parseStatusLine_prefixMatchIsLongestFirst() {
    var known = ["on", "online"]
    var r = Parsing.parseStatusLine("onlinefoo", known, 65536, 256)
    compare(r.status, "online")
  }

  function test_parseStatusLine_oversizedByUtf8BytesNotJustUtf16Length() {
    var known = ["online"]
    // 10 UTF-16 code units, but 20 UTF-8 bytes — under a byte cap measured
    // by .length, over the same cap measured correctly.
    var raw = "é".repeat(10)
    compare(raw.length, 10)
    var r = Parsing.parseStatusLine(raw, known, 15, 256)
    compare(r.status, "unknown")
  }

  function test_parseAccountText_extractsEmailAndDomain() {
    var r = Parsing.parseAccountText("Currently signed in as user@example.com - Acme Corp (twingate.com)", 65536, 256)
    compare(r.email, "user@example.com")
    compare(r.domain, "Acme Corp")
  }

  function test_parseAccountText_noMatchReturnsEmptyStrings() {
    var r = Parsing.parseAccountText("not signed in", 65536, 256)
    compare(r.email, "")
    compare(r.domain, "")
  }

  function test_parseAccountText_oversizedReturnsNull() {
    compare(Parsing.parseAccountText("x".repeat(100), 10, 256), null)
  }

  function test_parseAccountListRow_parsesRowAndSkipsHeaderAndMalformed() {
    var row = Parsing.parseAccountListRow("user@example.com\tAcme Corp\tignored\t*", 256)
    compare(row.email, "user@example.com")
    compare(row.network, "Acme Corp")
    compare(row.current, true)

    var notCurrent = Parsing.parseAccountListRow("other@example.com\tAcme Corp\tignored", 256)
    compare(notCurrent.current, false)

    compare(Parsing.parseAccountListRow("EMAIL\tNETWORK", 256), null)
    compare(Parsing.parseAccountListRow("only-one-column", 256), null)
  }

  function test_parseResourceLine_sectionHeadersFlipSectionWithNoEntry() {
    var main = Parsing.parseResourceLine("MAIN RESOURCES", "kubernetes", 256)
    compare(main.section, "main")
    compare(main.entry, null)

    var kube = Parsing.parseResourceLine("KUBERNETES RESOURCES", "main", 256)
    compare(kube.section, "kubernetes")
    compare(kube.entry, null)

    var background = Parsing.parseResourceLine("BACKGROUND RESOURCES", "main", 256)
    compare(background.section, "background")
    compare(background.entry, null)
  }

  function test_parseResourceLine_parsesDataRowAgainstCurrentSection() {
    var r = Parsing.parseResourceLine("db-prod\t10.0.0.5\tdb.internal\tAuth expires in 3 days", "main", 256)
    compare(r.section, "main")
    compare(r.entry.name, "db-prod")
    compare(r.entry.address, "10.0.0.5")
    compare(r.entry.alias, "db.internal")
    compare(r.entry.authStatus, "Auth expires in 3 days")
  }

  function test_parseResourceLine_lockedRowAuthStatusRoundTripsThroughIsResourceLocked() {
    var r = Parsing.parseResourceLine("staging-api\t10.0.1.9\t-\tNot authenticated", "main", 256)
    verify(Parsing.isResourceLocked(r.entry.authStatus))
  }

  function test_parseResourceLine_skipsHeaderRowAndMalformedRows() {
    var header = Parsing.parseResourceLine("RESOURCE NAME\tADDRESS\tALIAS\tAUTH STATUS", "main", 256)
    compare(header.entry, null)
    compare(header.section, "main")

    var tooShort = Parsing.parseResourceLine("only-one-column", "kubernetes", 256)
    compare(tooShort.entry, null)
    compare(tooShort.section, "kubernetes")
  }

  function test_parseResourceLine_missingAuthStatusColumnDefaultsToEmpty() {
    var r = Parsing.parseResourceLine("legacy-row\t10.0.0.1\talias-only", "main", 256)
    compare(r.entry.authStatus, "")
  }

  function test_parseVersionText_stripsTwingatePrefix() {
    compare(Parsing.parseVersionText("Twingate 2026.190.6704 | 0.193.0\n", 65536, 256), "2026.190.6704 | 0.193.0")
  }

  function test_parseVersionText_oversizedReturnsNull() {
    compare(Parsing.parseVersionText("x".repeat(100), 10, 256), null)
  }

  function test_filterResourceRows_emptyQueryReturnsAll() {
    var rows = [{ name: "a", alias: "-", address: "a.example.com" }, { name: "b", alias: "-", address: "b.example.com" }]
    compare(Parsing.filterResourceRows(rows, ""), rows)
    compare(Parsing.filterResourceRows(rows, "   "), rows)
  }

  function test_filterResourceRows_matchesCaseInsensitivelyOnAnyField() {
    var rows = [
      { name: "prod-db", alias: "-", address: "db.internal" },
      { name: "staging-api", alias: "API-Alias", address: "api.internal" }
    ]
    compare(Parsing.filterResourceRows(rows, "PROD").length, 1)
    compare(Parsing.filterResourceRows(rows, "alias").length, 1)
    compare(Parsing.filterResourceRows(rows, "internal").length, 2)
  }

  function test_filterResourceRows_noMatchReturnsEmpty() {
    var rows = [{ name: "a", alias: "-", address: "a.example.com" }]
    compare(Parsing.filterResourceRows(rows, "nonexistent").length, 0)
  }

  function test_parseFavoritesJson_validRoundTrip() {
    var json = JSON.stringify([{ name: "prod-db", kind: "main" }, { name: "cluster-a", kind: "kubernetes" }])
    var favorites = Parsing.parseFavoritesJson(json, 50, 256)
    compare(favorites.length, 2)
    compare(favorites[0].name, "prod-db")
    compare(favorites[0].kind, "main")
    compare(favorites[1].kind, "kubernetes")
  }

  function test_parseFavoritesJson_malformedOrNonArrayReturnsEmpty() {
    compare(Parsing.parseFavoritesJson("not json", 50, 256), [])
    compare(Parsing.parseFavoritesJson("{}", 50, 256), [])
    compare(Parsing.parseFavoritesJson("", 50, 256), [])
    compare(Parsing.parseFavoritesJson("42", 50, 256), [])
  }

  function test_parseFavoritesJson_dropsEntriesWithBadOrMissingKind() {
    var json = JSON.stringify([
      { name: "a", kind: "main" },
      { name: "b", kind: "exit-node" },
      { name: "c" },
      { kind: "main" },
      { name: "", kind: "main" }
    ])
    var favorites = Parsing.parseFavoritesJson(json, 50, 256)
    compare(favorites.length, 1)
    compare(favorites[0].name, "a")
  }

  function test_parseFavoritesJson_truncatesAtMaxCount() {
    var entries = []
    for (var i = 0; i < 10; i++) entries.push({ name: "r" + i, kind: "main" })
    var favorites = Parsing.parseFavoritesJson(JSON.stringify(entries), 3, 256)
    compare(favorites.length, 3)
  }

  function test_parseFavoritesJson_clipsOversizedName() {
    var json = JSON.stringify([{ name: "x".repeat(20), kind: "main" }])
    var favorites = Parsing.parseFavoritesJson(json, 50, 10)
    compare(favorites[0].name.length, 10)
  }

  function test_parseFavoritesJson_oversizedTextIsRejectedBeforeParsing() {
    var json = JSON.stringify([{ name: "a", kind: "main" }])
    // Valid JSON, well under maxCount/maxFieldLength — but the raw text
    // itself exceeds maxTextBytes, so it must be rejected outright rather
    // than parsed and then filtered down.
    compare(Parsing.parseFavoritesJson(json, 50, 256, json.length - 1), [])
    compare(Parsing.parseFavoritesJson(json, 50, 256, json.length).length, 1)
  }

  function test_isValidFavoriteKind_acceptsOnlyKnownKinds() {
    verify(Parsing.isValidFavoriteKind("main"))
    verify(Parsing.isValidFavoriteKind("kubernetes"))
    verify(Parsing.isValidFavoriteKind("background"))
    verify(!Parsing.isValidFavoriteKind("exit-node"))
    verify(!Parsing.isValidFavoriteKind(""))
    verify(!Parsing.isValidFavoriteKind(undefined))
  }

  function test_parseSnapshotJson_validRoundTrip() {
    var json = JSON.stringify({
      accountEmail: "user@example.com",
      accountDomain: "Acme Corp",
      accounts: [{ email: "user@example.com", network: "Acme Corp", current: true }],
      resources: [{ name: "prod-db", address: "10.0.0.1", alias: "db", authStatus: "" }],
      kubeResources: [{ name: "cluster-a", address: "", alias: "", authStatus: "" }],
      backgroundResources: [],
      version: "2026.190.6704"
    })
    var snap = Parsing.parseSnapshotJson(json, 200, 256)
    verify(snap !== null)
    compare(snap.accountEmail, "user@example.com")
    compare(snap.accounts.length, 1)
    compare(snap.resources[0].name, "prod-db")
    compare(snap.kubeResources[0].name, "cluster-a")
    compare(snap.backgroundResources.length, 0)
    compare(snap.version, "2026.190.6704")
  }

  function test_parseSnapshotJson_malformedOrNonObjectReturnsNull() {
    compare(Parsing.parseSnapshotJson("not json", 200, 256), null)
    compare(Parsing.parseSnapshotJson("[]", 200, 256), null)
    compare(Parsing.parseSnapshotJson("42", 200, 256), null)
    compare(Parsing.parseSnapshotJson("", 200, 256), null)
    compare(Parsing.parseSnapshotJson("   ", 200, 256), null)
  }

  function test_parseSnapshotJson_sanitizesResourceListsDropsInvalidCapsAtMaxRows() {
    var resources = [{ name: "", address: "x" }, { address: "no-name" }]
    for (var i = 0; i < 5; i++) resources.push({ name: "r" + i, address: "", alias: "", authStatus: "" })
    var json = JSON.stringify({ resources: resources })
    var snap = Parsing.parseSnapshotJson(json, 3, 256)
    compare(snap.resources.length, 3)
    compare(snap.resources[0].name, "r0")
  }

  function test_parseSnapshotJson_sanitizesAccountsDropsMissingEmail() {
    var json = JSON.stringify({ accounts: [{ email: "a@x.com", network: "N" }, { network: "no-email" }, {}] })
    var snap = Parsing.parseSnapshotJson(json, 200, 256)
    compare(snap.accounts.length, 1)
    compare(snap.accounts[0].email, "a@x.com")
  }

  function test_parseSnapshotJson_clipsOversizedFields() {
    var json = JSON.stringify({ accountEmail: "x".repeat(20), version: "y".repeat(20) })
    var snap = Parsing.parseSnapshotJson(json, 200, 10)
    compare(snap.accountEmail.length, 10)
    compare(snap.version.length, 10)
  }

  function test_parseSnapshotJson_oversizedTextIsRejectedBeforeParsing() {
    var json = JSON.stringify({ version: "1.0" })
    compare(Parsing.parseSnapshotJson(json, 200, 256, json.length - 1), null)
    verify(Parsing.parseSnapshotJson(json, 200, 256, json.length) !== null)
  }

  function test_parseSnapshotJson_missingArrayFieldsDefaultToEmpty() {
    var snap = Parsing.parseSnapshotJson("{}", 200, 256)
    verify(snap !== null)
    compare(snap.accounts, [])
    compare(snap.resources, [])
    compare(snap.kubeResources, [])
    compare(snap.backgroundResources, [])
    compare(snap.accountEmail, "")
  }

  function test_shellQuote_escapesEmbeddedSingleQuotes() {
    compare(Parsing.shellQuote("it's"), "'it'\\''s'")
    compare(Parsing.shellQuote(""), "''")
    compare(Parsing.shellQuote(null), "''")
    compare(Parsing.shellQuote(undefined), "''")
  }

  function test_cappedScript_wrapsPipefailAndNormalizesSigpipeExit() {
    var script = Parsing.cappedScript("twingate 'status'", 0)
    verify(script.indexOf("set -o pipefail; twingate 'status'") !== -1)
    verify(script.indexOf('case "$__rc" in 141) __rc=0 ;; esac') !== -1)
    verify(script.indexOf("exec 2>") === -1)
  }

  function test_cappedScript_addsStderrCapWhenRequested() {
    var script = Parsing.cappedScript("twingate 'status'", 8192)
    verify(script.indexOf("exec 2> >(head -c 8192 >&2); set -o pipefail;") !== -1)
  }

  function test_buildCappedTwingateCommand_wrapsInBashWithHeadCAndStderrCap() {
    var result = Parsing.buildCappedTwingateCommand(["status", "-v"], 65536, 8192, 10)
    compare(result[8], "bash")
    compare(result[9], "-c")
    var script = result[10]
    verify(script.indexOf("/usr/bin/twingate 'status' '-v' | head -c 65536") !== -1)
    verify(script.indexOf("exec 2> >(head -c 8192 >&2);") !== -1)
  }

  function test_buildCappedTwingateCommand_omitsHeadCWithoutStdoutCap() {
    var result = Parsing.buildCappedTwingateCommand(["account"], 0, 0, 10)
    var script = result[result.length - 1]
    verify(script.indexOf("head -c") === -1)
    verify(script.indexOf("/usr/bin/twingate 'account'") !== -1)
  }

  // The whole point of this function: an argument that looks like it could
  // break out of the command (quotes, semicolons, subshells) must only
  // ever appear inside its own single-quoted, escaped token.
  function test_buildCappedTwingateCommand_singleQuotesArgsWithShellMetacharacters() {
    var dangerous = "a'; rm -rf ~ #@example.com"
    var result = Parsing.buildCappedTwingateCommand(["account", "switch", "--", dangerous], 1024, 0, 20)
    var script = result[result.length - 1]
    verify(script.indexOf(Parsing.shellQuote(dangerous)) !== -1)
  }

  // `timeout --signal=KILL` (no `-f`) puts bash in its own process group and
  // kills the whole group on expiry, reaching descendants a plain
  // Process.running = false never could; `env -u` clears both shell
  // startup-file hooks before bash ever runs.
  function test_buildCappedTwingateCommand_wrapsWithEnvUnsetAndTimeoutKill() {
    var result = Parsing.buildCappedTwingateCommand(["status"], 0, 0, 10)
    compare(result[0], "env")
    compare(result[1], "-u")
    compare(result[2], "BASH_ENV")
    compare(result[3], "-u")
    compare(result[4], "ENV")
    compare(result[5], "timeout")
    compare(result[6], "--signal=KILL")
    compare(result[7], "10s")
    compare(result[8], "bash")
    compare(result[9], "-c")
    compare(result.length, 11)
  }

  function test_buildCappedTwingateCommand_timeoutSecondsFloorsToAtLeastOneSecond() {
    compare(Parsing.buildCappedTwingateCommand(["status"], 0, 0, 0)[7], "1s")
    compare(Parsing.buildCappedTwingateCommand(["status"], 0, 0, 0.2)[7], "1s")
    compare(Parsing.buildCappedTwingateCommand(["status"], 0, 0, 20)[7], "20s")
  }
}
