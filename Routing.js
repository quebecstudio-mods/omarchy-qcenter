// Where a click on a notification goes, once its bubble is gone: the command
// Omarchy attached to it, the sender's window, its site, or the app itself.
//
// Adapted from Omarchy's notification service (MIT License,
// https://github.com/basecamp/omarchy), which began as Omapager, Copyright (c)
// 2026 Neil Jagdish Patel (https://github.com/omacom/omapager).
.pragma library

var MAX_SOURCE = 253, MAX_URL = 4096, MAX_ARGV = 32768

function canonicalHostname(raw) {
  if (typeof raw !== "string" || raw.length > MAX_SOURCE) return ""
  var h = raw.toLowerCase().replace(/\.$/, "")
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(h)) return ""
  // A numeric-looking last label parses as an IPv4 address.
  if (/^(?:0x[0-9a-f]*|[0-9]+)$/i.test(h.split(".").pop())) return ""
  return h
}

// An https link held to Omarchy's URL policy: a narrow ASCII grammar, no
// user info, no control characters, no nested or invalid escapes.
function safeHttpsUrl(raw) {
  if (typeof raw !== "string" || raw.length > MAX_URL || /[\x00-\x20\x7f-\x9f\\]/.test(raw)) return ""
  if (/%(?:0[0-9a-f]|1[0-9a-f]|7f|25|5c)/i.test(raw) || /[<>"']/.test(raw)) return ""
  var m = raw.match(/^https:\/\/([^/?#]+)([^]*)$/i)
  if (!m || /^[a-z]+:\/\/[^/?#]*@/i.test(raw)) return ""
  var a = m[1].match(/^([^:%@]+)(?::([0-9]{1,5}))?$/)
  if (!a) return ""
  var h = canonicalHostname(a[1])
  if (!h || (a[2] && (+a[2] < 1 || +a[2] > 65535))) return ""
  if (/%(?![0-9a-f]{2})/i.test(m[2])) return ""
  return "https://" + h + (a[2] ? ":" + String(+a[2]) : "") + (m[2] || "/")
}

// The omarchy-exec-argv hint, held to the same structural rules as Omarchy:
// a JSON list of strings, no leading-dash program, never a shell string.
function parseExecArgv(value) {
  var text = String(value || "")
  if (!text || text.length > MAX_ARGV) return null
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return null }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > 32) return null
  for (var i = 0; i < parsed.length; i++)
    if (typeof parsed[i] !== "string" || parsed[i].length > MAX_URL || parsed[i].indexOf("\u0000") >= 0) return null
  if (!parsed[0] || parsed[0].charAt(0) === "-") return null
  return parsed
}

// Whole words only: "slack" must not match "slackline".
function wordIn(text, word) {
  var at = text.indexOf(word)
  while (at >= 0) {
    var before = at === 0 ? "" : text.charAt(at - 1)
    var after = text.charAt(at + word.length)
    if (!/[a-z0-9]/.test(before) && !/[a-z0-9]/.test(after)) return true
    at = text.indexOf(word, at + 1)
  }
  return false
}

var BROWSER_CLASSES = /^(chrome|chromium|firefox|zen|brave|edge|vivaldi|helium)/
// Every Chrome title ends "- Google Chrome": left on, google.com would match them all.
var BROWSER_SUFFIX = /\s*[-–—|]\s*(google chrome|chromium|mozilla firefox|firefox|zen browser|brave origin|brave|microsoft edge|vivaldi|helium)\s*$/
var GENERIC_LABELS = { www: 1, app: 1, web: 1, my: 1, m: 1, mail: 1, com: 1, org: 1, net: 1,
                       io: 1, co: 1, dev: 1, ai: 1, so: 1, site: 1, uk: 1 }

// What to look for in a title: "app.slack.com" gives ["slack"].
function brandsOf(host) {
  var labels = String(host || "").toLowerCase().split(".")
  var out = []
  for (var i = 0; i < labels.length; i++)
    if (labels[i].length >= 4 && !GENERIC_LABELS[labels[i]]) { out.push(labels[i]); break }
  var registered = labels.length >= 2 ? labels[labels.length - 2] : ""
  if (registered.length >= 4 && !GENERIC_LABELS[registered] && out.indexOf(registered) < 0) out.push(registered)
  return out
}

// windows: [{ wmClass, title, address, pid, focusOrder }] from Hyprland.
function mostRecent(found) {
  if (!found.length) return null
  var best = found[0]
  for (var i = 1; i < found.length; i++) if (found[i].focusOrder < best.focusOrder) best = found[i]
  return best
}

function windowForPid(windows, pid) {
  var want = Number(pid || 0)
  if (!want) return null
  for (var i = 0; i < windows.length; i++) if (windows[i].pid === want) return windows[i]
  return null
}

function windowForSource(windows, source) {
  var name = String(source || "").toLowerCase()
  if (!name) return null
  var found = [], i
  if (name.indexOf(".") > 0) {
    for (i = 0; i < windows.length; i++)
      if (windows[i].wmClass.toLowerCase().indexOf(name) >= 0) found.push(windows[i])
    if (found.length) return mostRecent(found)
    // A browser tab, then: browsers only, since "slack" in an editor's title is a filename.
    var brands = brandsOf(name)
    for (var b = 0; b < brands.length; b++) {
      found = []
      for (i = 0; i < windows.length; i++) {
        if (!BROWSER_CLASSES.test(windows[i].wmClass.toLowerCase())) continue
        if (wordIn(windows[i].title.toLowerCase().replace(BROWSER_SUFFIX, ""), brands[b])) found.push(windows[i])
      }
      if (found.length) return mostRecent(found)
    }
    return null
  }
  // An app name: whole web-app host labels and native classes, four characters or more.
  var slug = name.replace(/[^a-z0-9]+/g, "")
  if (slug.length < 4) return null
  var words = name.split(/[^a-z0-9]+/).filter(function(w) { return w })
  var tail = words.length > 1 ? "." + words.join(".") : ""
  for (i = 0; i < windows.length; i++) {
    var lower = windows[i].wmClass.toLowerCase()
    if (lower === slug) { found.push(windows[i]); continue }
    var dotted = "." + lower.replace(/[^a-z0-9]+/g, ".")
    if (tail && dotted.slice(-tail.length) === tail) { found.push(windows[i]); continue }
    if (lower.indexOf("chrome-") !== 0) continue
    var labels = lower.substring(7).split("__")[0].split(".")
    for (var l = 0; l < labels.length; l++) if (labels[l] === slug) { found.push(windows[i]); break }
  }
  return mostRecent(found)
}
