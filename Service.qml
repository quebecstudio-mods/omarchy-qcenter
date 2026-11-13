// qCenter: a Mac-style notification center for Omarchy, on top of Omarchy's
// own notifications rather than in their place.
//
// Omarchy's notification service keeps its state in
// ~/.local/state/omarchy/notifications: live.json (bubbles on screen),
// history.json (closed ones, with the reason, kept 24 hours) and quiet.json
// (Do Not Disturb). qCenter reads those files and shows the bubbles still on
// screen plus those that timed out or that Do Not Disturb kept off the
// screen. A notification you clicked or closed by hand does not come back.
// It talks back to Omarchy only through its IPC.
//
// What qCenter itself remembers (what you cleared, the count for the bell) is
// in ~/.local/state/qcenter/state.json; the agenda and its calendar copies
// sit next to it.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons

import "Routing.js" as Routing

Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var shell: null
  property var manifest: null

  readonly property string pluginId: root.manifest && root.manifest.id ? root.manifest.id : "quebecstudio.qcenter"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/qcenter"

  function expand(path) {
    var p = String(path || "")
    return p.indexOf("~/") === 0 ? root.home + p.slice(1) : p
  }

  // ---- Settings ------------------------------------------------------------
  // Read from the plugin's entry in shell.json: the shell hands settings only
  // to bar widgets.
  property var settings: ({})
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var found = {}
      try {
        var list = JSON.parse(text()).plugins || []
        for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === root.pluginId) { found = list[i]; break }
      } catch (e) {}
      root.settings = found
    }
  }

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string userShellJson: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/omarchy/shell.json"

  // Writes one setting to shell.json; the default removes it.
  function setSetting(key, value, defaultValue) {
    var json = JSON.stringify(value) === JSON.stringify(defaultValue) ? "null" : JSON.stringify(value)
    Util.execArgv([root.pluginDir + "bin/qcenter-config", key, json])
  }

  function editSettings() {
    Util.execArgv(["omarchy-launch-config-editor", root.userShellJson])
  }

  // The style, qDock's four: "cupertino" (the default, "mac" before 1.1), a
  // frosted pane with round corners; "omarchy", opaque, with the theme's
  // corners and popup border; "redmond" and "plasma", Windows' and KDE's
  // notification centers.
  readonly property string style: {
    var s = root.settings.style === "mac" ? "cupertino" : root.settings.style
    return ["omarchy", "redmond", "plasma"].indexOf(s) >= 0 ? s : "cupertino"
  }

  // demoDir (undocumented) shows notifications from another folder, for
  // screenshots. Its rows are for show: clicks, Clear all and Do Not Disturb
  // never reach Omarchy, and no command from it ever runs.
  readonly property string demoDir: root.expand(root.settings.demoDir)
  readonly property bool demo: root.demoDir !== ""
  readonly property string omarchyState: root.demo ? root.demoDir : root.home + "/.local/state/omarchy/notifications"

  // ---- Omarchy's notifications ---------------------------------------------
  property var liveEntries: []
  property var historyEntries: []
  property bool doNotDisturb: false

  function readList(file) {
    try {
      var list = JSON.parse(file.text())
      return Array.isArray(list) ? list : []
    } catch (e) {
      return []
    }
  }

  FileView {
    path: root.omarchyState + "/live.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.liveEntries = root.readList(this)
    onLoadFailed: root.liveEntries = []
  }

  FileView {
    path: root.omarchyState + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.historyEntries = root.readList(this)
    onLoadFailed: root.historyEntries = []
  }

  // The switch follows this file, so it never shows a state Omarchy is not in.
  FileView {
    path: root.omarchyState + "/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.doNotDisturb = JSON.parse(text()).dnd === true } catch (e) { root.doNotDisturb = false }
    }
    onLoadFailed: root.doNotDisturb = false
  }

  function omarchy(args) {
    if (!root.demo) Util.execArgv(["omarchy-shell", "-q", "notifications"].concat(args))
  }

  function setDoNotDisturb(value) {
    root.omarchy(["setDnd", value ? "on" : "off"])
  }

  // ---- What the center shows -----------------------------------------------
  readonly property var unseenReasons: ({ "expired": true, "silenced": true })
  // What you cleared: everything up to "before", and single rows by key, up
  // to the time they had. Omarchy reuses a key when a sender replaces its
  // notification, and the update has a newer time, so it shows again.
  property var cleared: ({ before: 0, keys: ({}) })
  property bool stateLoaded: false

  function rowOf(entry, live) {
    return { key: String(entry.key || ""), live: live,
             app: String(entry.app || ""), appIcon: String(entry.appIcon || ""),
             summary: String(entry.summary || ""), body: String(entry.body || ""),
             source: String(entry.source || ""), execArgv: String(entry.execArgv || ""),
             senderPid: Number(entry.senderPid || 0), ts: Number(entry.ts || 0),
             urgency: entry.urgency === undefined ? 1 : Number(entry.urgency) }
  }

  // What a notification is filed under for "hiddenApps": its site, else its
  // app's name in lower case; Omarchy's own messages are all "omarchy".
  function appKeyOf(row) {
    var host = Routing.canonicalHostname(row.source)
    if (host) return host
    var app = String(row.app || "").toLowerCase()
    return app === "omarchy-action" || app === "notify-send" ? "omarchy" : app
  }

  // Apps and sites left out of the center (setting "hiddenApps"); their
  // bubbles still show.
  readonly property var hiddenApps: {
    var list = Array.isArray(root.settings.hiddenApps) ? root.settings.hiddenApps : []
    var out = {}
    for (var i = 0; i < list.length; i++) out[String(list[i]).toLowerCase()] = true
    return out
  }

  // Low-urgency notifications are confirmations (a screenshot saved, a
  // layout changed, copied to the clipboard): their bubble says it, the
  // center leaves them out unless "lowUrgency" is on.
  readonly property bool keepLowUrgency: root.settings.lowUrgency === true

  readonly property var rows: {
    var gone = root.cleared.keys
    var before = root.cleared.before
    var out = [], seen = {}
    function take(entry, live) {
      var key = String(entry && entry.key || "")
      var ts = Number(entry && entry.ts || 0)
      if (!key || seen[key] || key.indexOf("placeholder") === 0) return
      if (ts <= before || (gone[key] !== undefined && ts <= gone[key])) return
      var row = root.rowOf(entry, live)
      if (root.hiddenApps[root.appKeyOf(row)]) return
      if (row.urgency === 0 && !root.keepLowUrgency) return
      seen[key] = true
      out.push(row)
    }
    for (var i = root.liveEntries.length - 1; i >= 0; i--) take(root.liveEntries[i], true)
    for (var h = 0; h < root.historyEntries.length; h++) {
      var entry = root.historyEntries[h]
      if (entry && root.unseenReasons[entry.closed_reason]) take(entry, false)
    }
    out.sort(function(a, b) { return b.ts - a.ts })
    return out
  }

  // The bubble Omarchy considers newest: the last one in live.json.
  readonly property string newestLiveKey: {
    var list = root.liveEntries
    return list.length ? String(list[list.length - 1].key || "") : ""
  }

  // Clearing hides rows here; a bubble still on screen stays until it times
  // out or you close it.
  function clear(rowsToClear) {
    var next = Object.assign({}, root.cleared.keys)
    for (var i = 0; i < rowsToClear.length; i++) next[rowsToClear[i].key] = rowsToClear[i].ts
    // Keep the newest 300.
    var keys = Object.keys(next).sort(function(a, b) { return next[b] - next[a] }).slice(0, 300)
    var kept = {}
    for (var k = 0; k < keys.length; k++) kept[keys[k]] = next[keys[k]]
    root.cleared = { before: root.cleared.before, keys: kept }
  }

  function clearAll() {
    root.omarchy(["dismissAll"])
    root.cleared = { before: Date.now() / 1000, keys: {} }
  }

  function openWindows() {
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var ipc = list[i].lastIpcObject || {}
      if (!ipc["class"]) continue
      out.push({ wmClass: String(ipc["class"]), title: String(ipc.title || ""), address: String(ipc.address || ""),
                 pid: Number(ipc.pid || 0),
                 focusOrder: ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 9999 })
    }
    return out
  }

  // A site with no window open: the app chosen for it in "webApps", else its
  // web app when one is installed, else the browser.
  function openSite(host) {
    var values = DesktopEntries.applications.values
    var entries = []
    for (var i = 0; i < values.length; i++)
      entries.push({ id: values[i].id, name: values[i].name, execString: values[i].execString })
    var id = Routing.appForHost(entries, host, root.settings.webApps)
    var entry = id ? DesktopEntries.byId(id) : null
    if (entry) entry.execute()
    else Qt.openUrlExternally("https://" + host + "/")
  }

  // A click. The newest bubble still on screen is clicked through Omarchy,
  // exactly as on the bubble (the sender's own action included). Otherwise:
  // Omarchy's --exec command, the sender's window, its site, or the app.
  function activate(row) {
    if (!row) return
    if (root.demo) {
      root.clear([row])
      return
    }
    if (row.live && row.key === root.newestLiveKey) {
      root.omarchy(["invokeLast"])
    } else {
      var argv = Routing.parseExecArgv(row.execArgv)
      if (argv) {
        Util.execArgv(argv)
      } else {
        var windows = root.openWindows()
        var win = Routing.windowForPid(windows, row.senderPid) || Routing.windowForSource(windows, row.source)
        var host = Routing.canonicalHostname(row.source)
        if (win && /^0x[0-9a-f]+$/i.test(win.address))
          Hyprland.dispatch('hl.dsp.focus({window = hl.get_window("address:' + win.address + '")})')
        else if (host) root.openSite(host)
        else if (row.app) Util.execArgv(["omarchy-hyprland-focus-app", row.app])
      }
    }
    root.clear([row])
  }

  // ---- qCenter's own state -------------------------------------------------
  Process {
    running: true
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var read = JSON.parse(text())
        var keys = {}
        var stored = read.cleared
        if (stored && typeof stored === "object" && !Array.isArray(stored))
          for (var k in stored) keys[k] = Number(stored[k] || 0)
        root.cleared = { before: Number(read.clearedBefore || 0), keys: keys }
      } catch (e) {}
      root.stateLoaded = true
      saveTimer.restart()
    }
    onLoadFailed: {
      root.stateLoaded = true
      saveTimer.restart()
    }
  }

  property int savedCount: -1
  onClearedChanged: if (root.stateLoaded) saveTimer.restart()
  // The count is for the bell, which reads this file.
  onRowsChanged: if (root.stateLoaded && root.rows.length !== root.savedCount) saveTimer.restart()

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: {
      root.savedCount = root.rows.length
      stateFile.setText(JSON.stringify({ clearedBefore: root.cleared.before, cleared: root.cleared.keys,
                                         count: root.rows.length }) + "\n")
    }
  }

  // ---- Agenda --------------------------------------------------------------
  // Two sources, both optional: "agendaFile", a JSON file you keep up to date
  // yourself, or "calendars", ICS links or files that agenda/qcenter-agenda.py
  // turns into the same JSON every ten minutes. Without either, no section.
  readonly property var calendars: Array.isArray(root.settings.calendars) ? root.settings.calendars : []
  readonly property string generatedAgenda: root.stateDir + "/agenda.json"
  readonly property string agendaPath: {
    var own = root.expand(root.settings.agendaFile)
    if (own) return own
    return root.calendars.length ? root.generatedAgenda : ""
  }
  property var events: []

  FileView {
    path: root.agendaPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var list = JSON.parse(text()).events
        root.events = Array.isArray(list) ? list : []
      } catch (e) {
        root.events = []
      }
    }
    onLoadFailed: root.events = []
  }
  onAgendaPathChanged: if (!root.agendaPath) root.events = []

  // The links can hold a private token, so they go through stdin, never argv.
  Process {
    id: sync
    stdinEnabled: true
    command: ["python3", "-I", decodeURIComponent(Qt.resolvedUrl("agenda/qcenter-agenda.py").toString().replace(/^file:\/\//, "")),
              "--output", root.generatedAgenda]
    onStarted: {
      write(JSON.stringify({ calendars: root.calendars }) + "\n")
      stdinEnabled = false
    }
    onExited: stdinEnabled = true
    stderr: StdioCollector { onStreamFinished: if (text) console.warn("qcenter agenda:", text.trim()) }
  }

  function syncAgenda() {
    if (root.calendars.length && !root.settings.agendaFile && !sync.running) sync.running = true
  }

  onCalendarsChanged: syncAgenda()

  Timer {
    interval: 10 * 60 * 1000
    repeat: true
    running: root.calendars.length > 0
    onTriggered: root.syncAgenda()
  }

  // ---- Panel and IPC -------------------------------------------------------
  Center {
    id: center
    service: root
    strings: strings
  }

  SettingsWindow {
    id: settingsWindow
    service: root
  }

  function openSettings(section) {
    center.hide()
    settingsWindow.toggle(section)
  }

  ShellIpc {
    target: "quebecstudio.qcenter"

    function toggle(): void { center.toggle() }
    function open(): void { center.show() }
    function close(): void { center.hide() }
    function count(): string { return String(root.rows.length) }
    function syncAgenda(): void { root.syncAgenda() }
    function settings(): void { root.openSettings("") }
    function settingsAt(section: string): void { root.openSettings(section) }
    function about(): void { root.openSettings("about") }
  }
}
