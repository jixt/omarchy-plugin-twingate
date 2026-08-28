.pragma library

// Pure parsing/validation helpers for everything the `twingate` CLI hands
// back. Nothing it prints is trusted: every function here is a plain
// input->output transform with no QML/root dependency, so it can be unit
// tested directly (see tests/tst_parsing.qml) without spinning up a real
// `twingate` process or a live Process/root item.

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
// Match defensively: a lowercase substring, never an exact string.
function isResourceLocked(authStatus) {
  if (typeof authStatus !== "string" || authStatus === "") return false
  return authStatus.toLowerCase().indexOf("not authenticated") !== -1
}

// `twingate status -v` output. Confirmed live (online state) to be one line
// shaped "<Capitalized status>: <detail>", e.g. "Online: User" — other
// states' verbose shape is unverified, so a line with no colon degrades to
// the old plain single-word behavior instead of erroring.
function parseStatusLine(raw, knownStatuses, maxOutputBytes, maxFieldLength) {
  var text = raw === undefined || raw === null ? "" : String(raw)
  if (text.length > maxOutputBytes) return { status: "unknown", detail: "", extraLines: [] }
  var lines = text.split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l.length > 0 })
  var first = lines.length > 0 ? lines[0] : ""
  var colonIdx = first.indexOf(":")
  var word = (colonIdx === -1 ? first : first.slice(0, colonIdx)).trim().toLowerCase()
  var detail = colonIdx === -1 ? "" : first.slice(colonIdx + 1).trim()
  var status = knownStatuses.indexOf(word) !== -1 ? word : (word === "" ? "uninitialized" : "unknown")
  var extraLines = lines.slice(1, 6).map(function(l) { return clip(l, maxFieldLength) })
  return { status: status, detail: clip(detail, maxFieldLength), extraLines: extraLines }
}

// `twingate account`, e.g. "Currently signed in as user@example.com - Acme
// Corp (twingate.com)". Returns null (meaning: leave the previous value in
// place) when the output is oversized, matching the probe's original
// early-return-without-clearing behavior.
function parseAccountText(raw, maxOutputBytes, maxFieldLength) {
  var text = raw === undefined || raw === null ? "" : String(raw)
  if (text.length > maxOutputBytes) return null
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
  if (text.length > maxOutputBytes) return null
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

// Sanitizes the plugin's own persisted favorites.json — treated with the
// same defensive discipline as untrusted CLI output, since a corrupted
// write, a hand edit, or a future format change are all real failure modes
// for a file this plugin reads back on every panel load.
function parseFavoritesJson(text, maxCount, maxFieldLength) {
  var validKinds = ["main", "kubernetes", "background"]
  var parsed
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return []
  }
  if (!Array.isArray(parsed)) return []
  var result = []
  for (var i = 0; i < parsed.length && result.length < maxCount; i++) {
    var entry = parsed[i]
    if (!entry || typeof entry.name !== "string" || entry.name === "") continue
    if (validKinds.indexOf(entry.kind) === -1) continue
    result.push({ name: clip(entry.name, maxFieldLength), kind: entry.kind })
  }
  return result
}
