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
  function test_isResourceLocked_matchesNotAuthenticatedOnly() {
    verify(Parsing.isResourceLocked("Not authenticated"))
    verify(Parsing.isResourceLocked("not authenticated"))
    verify(!Parsing.isResourceLocked("Auth expires in 3 days"))
    verify(!Parsing.isResourceLocked("Auth expires in over a week"))
    verify(!Parsing.isResourceLocked("Auth expires in under 1 minute"))
    verify(!Parsing.isResourceLocked(""))
    verify(!Parsing.isResourceLocked(null))
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
}
