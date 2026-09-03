.pragma library

// Pure parsing/validation helpers for everything the `twingate` CLI hands
// back. Nothing it prints is trusted: every function here is a plain
// input->output transform with no QML/root dependency, so it can be unit
// tested directly (see tests/tst_parsing.qml) without spinning up a real
// `twingate` process or a live Process/root item.

// Truncates to maxLen and strips control characters plus angle brackets —
// the latter so this is still inert even where it ends up inside a shared
// Ui component (e.g. Dropdown) whose Text elements aren't ours to mark
// Text.PlainText directly. Also strips zero-width/bidi-control characters
// and Unicode TAG characters, which can otherwise hide or reorder text
// invisibly in a rendered row without tripping the C0/angle-bracket strip.
function clip(value, maxLen) {
  var s = value === undefined || value === null ? "" : String(value)
  if (s.length > maxLen) s = s.slice(0, maxLen)
  s = s
    .replace(/[\x00-\x1f\x7f<>]/g, "")
    .replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, "")
  // TAG characters (U+E0000-U+E007F) are outside the BMP, so a regex
  // \u{...} range with the `u` flag is the natural way to match them \u2014
  // but that construct is handled inconsistently across QML JS engine
  // versions (confirmed: silently fails to strip on Qt 6.4, works on Qt
  // 6.11). codePointAt()/surrogate-pair-aware scanning is portable across
  // both, so filter manually instead of trusting the regex here.
  var out = ""
  for (var i = 0; i < s.length; ) {
    var code = s.codePointAt(i)
    var charLen = code > 0xFFFF ? 2 : 1
    if (code < 0xE0000 || code > 0xE007F) out += s.substr(i, charLen)
    i += charLen
  }
  return out
}

// text.length counts UTF-16 code units, not bytes — a string well under a
// byte cap by .length can still exceed it once encoded, hiding a real
// truncation for any non-ASCII payload. Used wherever a raw CLI string is
// checked against a `head -c`-style byte ceiling.
function utf8ByteLength(value) {
  var s = value === undefined || value === null ? "" : String(value)
  var bytes = 0
  for (var i = 0; i < s.length; i++) {
    var code = s.codePointAt(i)
    if (code > 0xFFFF) i++   // consumed a surrogate pair
    if (code <= 0x7F) bytes += 1
    else if (code <= 0x7FF) bytes += 2
    else if (code <= 0xFFFF) bytes += 3
    else bytes += 4
  }
  return bytes
}

// Heuristic only: a byte count landing at or above the producer-side cap
// means the stream was probably cut off mid-list, not that it happened to
// end exactly on the boundary.
function isLikelyClipped(bytesSeen, maxBytes) {
  return maxBytes > 0 && bytesSeen >= maxBytes
}

// Rejects anything unsafe to hand to the CLI as a positional argument:
// empty, oversized, option-shaped ("-..."), or containing control chars.
function isSafeCliToken(value, maxLen) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLen) return false
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

// `authStatus` (the resource list's 4th column) is free text, not an enum —
// authenticated rows read "Auth expires in …", the locked state reads
// "Not authenticated" (confirmed against the real CLI's binary strings).
// "Pending" is a second, distinct locked state seen live on a resource that
// requires its own auth policy: without this, such a row is treated as
// ready, so activating it opens the browser straight to a host Twingate is
// still blocking, and the tab just hangs instead of running the resource's
// own auth flow. Match defensively: a lowercase substring, never an exact
// string, since more of these free-text states likely exist unconfirmed.
function isResourceLocked(authStatus) {
  if (typeof authStatus !== "string" || authStatus === "") return false
  var s = authStatus.toLowerCase()
  return s.indexOf("not authenticated") !== -1 || s.indexOf("pending") !== -1
}

// `twingate status -v` output. Confirmed live (online state) to be one line
// shaped "<Capitalized status>: <detail>", e.g. "Online: User" — other
// states' verbose shape is unverified, so a line with no colon degrades to
// the old plain single-word behavior instead of erroring. The live CLI can
// also glue trailing prose directly onto the status word with no colon and
// no newline (e.g. "onlineA resource you attempted…") — an exact match on
// `word` would report that as "unknown", so a failed exact match falls back
// to a longest-first prefix match instead. When that fallback is what
// actually matched (no colon to reliably delimit a detail), detail is "".
function parseStatusLine(raw, knownStatuses, maxOutputBytes, maxFieldLength) {
  var text = raw === undefined || raw === null ? "" : String(raw)
  if (utf8ByteLength(text) > maxOutputBytes) return { status: "unknown", detail: "", extraLines: [] }
  var lines = text.split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l.length > 0 })
  var first = lines.length > 0 ? lines[0] : ""
  var colonIdx = first.indexOf(":")
  var word = (colonIdx === -1 ? first : first.slice(0, colonIdx)).trim().toLowerCase()
  var detail = colonIdx === -1 ? "" : first.slice(colonIdx + 1).trim()
  var status
  if (knownStatuses.indexOf(word) !== -1) {
    status = word
  } else if (word === "") {
    status = "uninitialized"
  } else {
    var sorted = knownStatuses.slice().sort(function(a, b) { return b.length - a.length })
    var prefixMatch = sorted.find(function(s) { return word.indexOf(s) === 0 })
    if (prefixMatch) {
      status = prefixMatch
      if (colonIdx === -1) detail = ""
    } else {
      status = "unknown"
    }
  }
  var extraLines = lines.slice(1, 6).map(function(l) { return clip(l, maxFieldLength) })
  return { status: status, detail: clip(detail, maxFieldLength), extraLines: extraLines }
}

// `twingate account`, e.g. "Currently signed in as user@example.com - Acme
// Corp (twingate.com)". Returns null (meaning: leave the previous value in
// place) when the output is oversized, matching the probe's original
// early-return-without-clearing behavior.
function parseAccountText(raw, maxOutputBytes, maxFieldLength) {
  var text = raw === undefined || raw === null ? "" : String(raw)
  if (utf8ByteLength(text) > maxOutputBytes) return null
  var m = text.match(/Currently signed in as (\S+) - (.+?) \(/)
  return {
    email: m ? clip(m[1], maxFieldLength) : "",
    domain: m ? clip(m[2], maxFieldLength) : ""
  }
}

// One line of `twingate account list` output. Returns null for the header
// row, blank lines, or anything too short to be a real row.
function parseAccountListRow(line, maxFieldLength) {
  var cols = String(line).split("\t")
  if (cols.length < 3) return null
  var email = clip(cols[0].trim(), maxFieldLength)
  if (email === "" || email === "EMAIL") return null
  return {
    email: email,
    network: clip(cols[1].trim(), maxFieldLength),
    current: cols.length > 3 && cols[3].trim() === "*"
  }
}

// One line of `twingate resources` output. Section-header lines ("MAIN
// RESOURCES" etc) flip `section` and return no entry; data rows are
// returned against whatever `currentSection` was passed in, so the caller
// can bucket them by section without this function needing to hold state.
function parseResourceLine(line, currentSection, maxFieldLength) {
  var trimmed = String(line).trim()
  if (trimmed === "MAIN RESOURCES") return { section: "main", entry: null }
  if (trimmed === "KUBERNETES RESOURCES") return { section: "kubernetes", entry: null }
  if (trimmed === "BACKGROUND RESOURCES") return { section: "background", entry: null }
  var cols = String(line).split("\t")
  if (cols.length < 3) return { section: currentSection, entry: null }
  var name = clip(cols[0].trim(), maxFieldLength)
  if (name === "" || name === "RESOURCE NAME") return { section: currentSection, entry: null }
  var entry = {
    name: name,
    address: clip(cols[1].trim(), maxFieldLength),
    alias: clip(cols[2].trim(), maxFieldLength),
    authStatus: cols.length > 3 ? clip(cols[3].trim(), maxFieldLength) : ""
  }
  return { section: currentSection, entry: entry }
}

// `twingate --version`, e.g. "Twingate 2026.190.6704 | 0.193.0". Returns
// null (leave the previous value in place) when oversized, matching the
// probe's original early-return-without-clearing behavior.
function parseVersionText(raw, maxOutputBytes, maxFieldLength) {
  var text = raw === undefined || raw === null ? "" : String(raw)
  if (utf8ByteLength(text) > maxOutputBytes) return null
  return clip(text.trim().replace(/^Twingate\s+/i, ""), maxFieldLength)
}

// Case-insensitive substring match on name/alias/address, shared by every
// per-tab resource list (Main/Kubernetes/Hidden all filter the same way).
function filterResourceRows(rows, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return rows || []
  return (rows || []).filter(function(r) {
    return r.name.toLowerCase().indexOf(q) >= 0
      || r.alias.toLowerCase().indexOf(q) >= 0
      || r.address.toLowerCase().indexOf(q) >= 0
  })
}

// Single source of truth for what a favorite's `kind` is allowed to be —
// shared by parseFavoritesJson (reading the file back) and toggleFavorite
// (writing to it), so an invalid kind is rejected at both boundaries
// instead of only being silently dropped on the next reload.
var VALID_FAVORITE_KINDS = ["main", "kubernetes", "background"]

function isValidFavoriteKind(kind) {
  return VALID_FAVORITE_KINDS.indexOf(kind) !== -1
}

// Sanitizes the plugin's own persisted favorites.json — treated with the
// same defensive discipline as untrusted CLI output, since a corrupted
// write, a hand edit, or a future format change are all real failure modes
// for a file this plugin reads back on every panel load. maxTextBytes is a
// coarse guard on the raw file text itself, checked before JSON.parse ever
// runs on it — this file is normally written only by this plugin's own
// atomic FileView writes (bounded by maxCount favorites), so an oversized
// file only happens via tampering or corruption, and is rejected outright
// rather than parsed.
function parseFavoritesJson(text, maxCount, maxFieldLength, maxTextBytes) {
  var raw = String(text || "")
  if (maxTextBytes && raw.length > maxTextBytes) return []
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return []
  }
  if (!Array.isArray(parsed)) return []
  var result = []
  for (var i = 0; i < parsed.length && result.length < maxCount; i++) {
    var entry = parsed[i]
    if (!entry || typeof entry.name !== "string" || entry.name === "") continue
    if (!isValidFavoriteKind(entry.kind)) continue
    result.push({ name: clip(entry.name, maxFieldLength), kind: entry.kind })
  }
  return result
}

// Sanitizes the plugin's own persisted instant-open snapshot. Same posture
// as parseFavoritesJson: byte cap on raw text before JSON.parse, structural
// validation, per-field clip(), per-list row cap. Returns null on anything
// malformed/empty so the caller's existing in-memory state is left alone.
function parseSnapshotJson(text, maxRows, maxFieldLength, maxTextBytes) {
  var raw = String(text || "").trim()
  if (raw === "") return null
  if (maxTextBytes && raw.length > maxTextBytes) return null
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null

  function sanitizeResourceList(list) {
    if (!Array.isArray(list)) return []
    var out = []
    for (var i = 0; i < list.length && out.length < maxRows; i++) {
      var e = list[i]
      if (!e || typeof e.name !== "string" || e.name === "") continue
      out.push({
        name: clip(e.name, maxFieldLength),
        address: clip(e.address, maxFieldLength),
        alias: clip(e.alias, maxFieldLength),
        authStatus: clip(e.authStatus, maxFieldLength)
      })
    }
    return out
  }

  function sanitizeAccountList(list) {
    if (!Array.isArray(list)) return []
    var out = []
    for (var i = 0; i < list.length && out.length < maxRows; i++) {
      var e = list[i]
      if (!e || typeof e.email !== "string" || e.email === "") continue
      out.push({ email: clip(e.email, maxFieldLength), network: clip(e.network, maxFieldLength), current: e.current === true })
    }
    return out
  }

  return {
    accountEmail: clip(parsed.accountEmail, maxFieldLength),
    accountDomain: clip(parsed.accountDomain, maxFieldLength),
    accounts: sanitizeAccountList(parsed.accounts),
    resources: sanitizeResourceList(parsed.resources),
    kubeResources: sanitizeResourceList(parsed.kubeResources),
    backgroundResources: sanitizeResourceList(parsed.backgroundResources),
    version: clip(parsed.version, maxFieldLength)
  }
}

// Single-quotes a string for bash — same escaping as qs.Commons.Util's
// shellQuote, duplicated here (not imported) so this file stays
// dependency-free and testable on its own, matching its existing design.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// `head -c` reads exactly N bytes from its stdin and then closes it,
// delivering SIGPIPE/EPIPE to whatever's still writing past that point —
// the byte ceiling is enforced by the kernel pipe/`head` itself, before
// Quickshell's own Process/StdioCollector/SplitParser layer ever sees more
// than N bytes. That's what makes buildCappedTwingateCommand's cap a real
// producer-side boundary, unlike checking a collected string's length only
// after StdioCollector has buffered the whole stream, or counting rows
// only after SplitParser has already buffered one (possibly huge)
// unterminated line — both of which merely check a limit after the fact
// rather than stopping the data before it accumulates.
//
// `head -c` itself exits 0 the moment it's read its share, even if the
// command upstream of it was killed by SIGPIPE mid-write — `pipefail`
// re-surfaces that command's real exit status instead, except for exit
// code 141 (SIGPIPE), which is the cap doing its job on an
// otherwise-healthy stream and must not be reported as a failure.
function cappedScript(innerCommand, maxStderrBytes) {
  var script = ""
  if (maxStderrBytes) {
    script += "exec 2> >(head -c " + Number(maxStderrBytes) + " >&2); "
  }
  script += "set -o pipefail; " + innerCommand
  script += "\n__rc=$?\ncase \"$__rc\" in 141) __rc=0 ;; esac\nexit \"$__rc\""
  return script
}

// Every `twingate` invocation in this plugin should build its Process
// `command` through this, rather than a plain argv array, so stdout (and
// stderr, when a cap is given) is bounded on the producer side instead of
// trusting QML's own StdioCollector/SplitParser to stop buffering in time.
// The existing maxRows/maxLinesTotal row caps and per-field clip() stay in
// place on top of this as the consumer-side boundary.
//
// Every argument is single-quoted, including fixed literals like "status"
// (harmless — quoting a plain word changes nothing) — nothing handed to
// bash here is assumed free of shell metacharacters just because it's a
// value that already passed isSafeCliToken(), which rejects empty/
// oversized/flag-shaped/control-character values but not shell syntax.
//
// The whole script runs under `env -u BASH_ENV -u ENV` (so bash's own
// non-interactive startup-file hooks can't inject anything) wrapped in
// `timeout --signal=KILL <timeoutSeconds>s` — `timeout` (without `-f`) puts
// bash in its own new process group and SIGKILLs the whole group on expiry,
// which is what actually reaches `twingate`/`head`/the stderr subshell as
// descendants of the wrapper. Setting a QML Process's `running` to false
// only ever stopped tracking the *wrapper*; it never signaled anything
// underneath it.
function buildCappedTwingateCommand(args, maxStdoutBytes, maxStderrBytes, timeoutSeconds) {
  var inner = "/usr/bin/twingate"
  for (var i = 0; i < args.length; i++) {
    inner += " " + shellQuote(args[i])
  }
  if (maxStdoutBytes) inner += " | head -c " + Number(maxStdoutBytes)
  var script = cappedScript(inner, maxStderrBytes)
  var seconds = Math.max(1, Math.ceil(Number(timeoutSeconds) || 0))
  return ["env", "-u", "BASH_ENV", "-u", "ENV", "timeout", "--signal=KILL", seconds + "s", "bash", "-c", script]
}
