import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "Routing.js" as Routing

// qCenter's settings, in a window of their own, drawn with Omarchy's controls
// like qDock's: the sections on the left (Appearance, Notifications, Left out,
// Apps for sites, Agenda, About), the section's settings on the right. Esc or
// a click outside closes it. Everything is written to qCenter's entry in
// shell.json.
Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var service: null
  property bool opened: false
  property string section: "appearance"

  readonly property var sections: [
    { id: "appearance", label: strings.t("settings.appearance"), glyph: "\u{f03d8}" },
    { id: "notifications", label: strings.t("settings.notifications"), glyph: "\u{f009a}" },
    { id: "hidden", label: strings.t("settings.hiddenApps"), glyph: "\u{f0209}" },
    { id: "sites", label: strings.t("settings.webApps"), glyph: "\u{f059f}" },
    { id: "agenda", label: strings.t("settings.agenda"), glyph: "\u{f00ed}" },
    { id: "about", label: strings.t("settings.about"), glyph: "\u{f02fd}" }
  ]

  readonly property var settings: service ? service.settings : ({})
  readonly property string styleName: service ? service.style : "cupertino"
  readonly property int cardRadius: Style.cornerRadius

  readonly property color foreground: Commons.Color.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property var manifest: service && service.manifest ? service.manifest : ({})

  function open(name) {
    root.section = name && sections.some(function(s) { return s.id === name }) ? name : sections[0].id
    root.opened = true
  }
  function close() { root.opened = false }
  function toggle(name) {
    if (root.opened && (!name || name === root.section)) root.close()
    else root.open(name)
  }
  onOpenedChanged: if (!opened) root.resetForms()

  function resetForms() {
    siteField.text = ""
    root.siteApp = ""
    calendarName.text = ""
    calendarUrl.text = ""
    root.calendarColor = ""
  }

  // ---- Apps for sites (webApps) ----
  readonly property var webApps: settings.webApps && typeof settings.webApps === "object" && !Array.isArray(settings.webApps)
    ? settings.webApps : ({})
  readonly property var webAppSites: Object.keys(webApps).sort()
  property string siteApp: ""

  // Every app in the launcher, by name; the value is its desktop file id.
  readonly property var appOptions: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++)
      if (values[i].name && !values[i].noDisplay) out.push({ value: String(values[i].id), label: String(values[i].name) })
    out.sort(function(a, b) { return a.label.localeCompare(b.label) })
    return out
  }

  // A saved app, by id or by name, as the launcher shows it.
  function appLabel(saved) {
    var entry = DesktopEntries.byId(String(saved).replace(/\.desktop$/, ""))
    return entry && entry.name ? String(entry.name) : String(saved)
  }

  // Sites that sent a notification and have no app chosen: one click fills
  // the field.
  readonly property var suggestedSites: {
    var rows = service ? service.rows : []
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var host = Routing.canonicalHostname(rows[i].source)
      if (host && out.indexOf(host) < 0 && root.webApps[host] === undefined) out.push(host)
    }
    return out.slice(0, 6)
  }

  readonly property string siteToAdd: Routing.canonicalHostname(siteField.text.trim().replace(/^https?:\/\//i, "").replace(/\/.*$/, ""))

  function addWebApp() {
    if (!root.siteToAdd || !root.siteApp) return
    var next = Object.assign({}, root.webApps)
    next[root.siteToAdd] = root.siteApp
    root.service.setSetting("webApps", next, {})
    siteField.text = ""
    root.siteApp = ""
  }

  function removeWebApp(site) {
    var next = Object.assign({}, root.webApps)
    delete next[site]
    root.service.setSetting("webApps", next, {})
  }

  // ---- Apps left out (hiddenApps) ----
  readonly property var hiddenApps: Array.isArray(settings.hiddenApps) ? settings.hiddenApps : []

  // An app's name as its notifications give it, by its key.
  readonly property var appNames: {
    var out = {}
    if (!service) return out
    var entries = service.liveEntries.concat(service.historyEntries)
    for (var i = 0; i < entries.length; i++) {
      var row = service.rowOf(entries[i] || {}, false)
      out[service.appKeyOf(row)] = row.app
    }
    return out
  }

  function appName(key) {
    if (key === "omarchy") return "Omarchy"
    if (key.indexOf(".") > 0) return key
    var entry = DesktopEntries.heuristicLookup(key)
    if (entry && entry.name) return String(entry.name)
    var seen = String(root.appNames[key] || key)
    return seen.charAt(0).toUpperCase() + seen.slice(1)
  }

  // Every app and site in Omarchy's notifications, those already left out aside.
  readonly property var appsSeen: {
    if (!service) return []
    var entries = service.liveEntries.concat(service.historyEntries)
    var hidden = {}
    for (var h = 0; h < root.hiddenApps.length; h++) hidden[String(root.hiddenApps[h]).toLowerCase()] = true
    var out = []
    for (var i = 0; i < entries.length; i++) {
      var key = service.appKeyOf(service.rowOf(entries[i] || {}, false))
      if (key && !hidden[key] && out.indexOf(key) < 0) out.push(key)
    }
    return out.sort()
  }

  function hideApp(key) {
    root.service.setSetting("hiddenApps", root.hiddenApps.concat([key]), [])
  }

  function showApp(index) {
    var next = root.hiddenApps.slice()
    next.splice(index, 1)
    root.service.setSetting("hiddenApps", next, [])
  }

  // ---- Calendars ----
  readonly property var calendars: service ? service.calendars : []
  readonly property var swatches: ["#7aa2f7", "#9ece6a", "#e0af68", "#f7768e", "#bb9af7", "#7dcfff", "#ff9e64"]
  property string calendarColor: ""

  // A link (https or webcal) or the path of a file, never plain http: the
  // same rule as the agenda script.
  function calendarSource(text) {
    var t = String(text || "").trim()
    if (/^(https|webcal):\/\/[^\s]+$/i.test(t)) return t
    if (/^(~\/|\/)[^\0]+\.ics$/i.test(t)) return t
    return ""
  }
  readonly property string urlToAdd: calendarSource(calendarUrl.text)

  // Where a calendar comes from, without its secret: the site, or the file's name.
  function calendarOrigin(url) {
    var m = String(url || "").match(/^[a-z]+:\/\/([^/?#]+)/i)
    if (m) return m[1]
    return String(url || "").split("/").pop()
  }

  function addCalendar() {
    if (!root.urlToAdd) return
    var entry = { name: calendarName.text.trim() || root.calendarOrigin(root.urlToAdd), url: root.urlToAdd }
    if (root.calendarColor) entry.color = root.calendarColor
    root.service.setSetting("calendars", root.calendars.concat([entry]), [])
    calendarName.text = ""
    calendarUrl.text = ""
    root.calendarColor = ""
  }

  function removeCalendar(index) {
    var next = root.calendars.slice()
    next.splice(index, 1)
    root.service.setSetting("calendars", next, [])
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "qcenter-settings"

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Math.min(Style.space(720), keyCatcher.width - Style.space(32))
        height: Math.min(Style.space(540), keyCatcher.height - Style.space(32))
        radius: root.cardRadius
        color: Util.alpha(Commons.Color.popups.background, 1)
        borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
        padding: Style.spacing.md

        // Swallow clicks so only the scrim outside the card closes it.
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

        Column {
          id: sidebar
          x: card.contentLeftInset
          y: card.contentTopInset
          width: Style.space(180)
          height: card.height - card.contentTopInset - card.contentBottomInset
          spacing: Style.spacing.xs

          Row {
            spacing: Style.spacing.sm
            leftPadding: Style.spacing.controlPaddingX
            bottomPadding: Style.spacing.md
            topPadding: Style.spacing.xs

            Image {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(28)
              height: width
              source: Qt.resolvedUrl("assets/logo.png")
              sourceSize: Qt.size(width * 2, height * 2)
              fillMode: Image.PreserveAspectFit
              smooth: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.manifest.name || "qCenter"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }

          Repeater {
            model: root.sections
            delegate: Rectangle {
              id: navRow
              required property var modelData
              readonly property bool current: root.section === modelData.id

              width: sidebar.width
              height: Style.spacing.popupRowHeight
              radius: Math.min(height / 2, root.cardRadius)
              color: current ? Commons.Color.menu.selectedBackground : (navMouse.containsMouse ? Style.hoverFill : "transparent")

              Text {
                id: navGlyph
                anchors.verticalCenter: parent.verticalCenter
                x: Style.spacing.controlPaddingX
                width: Style.space(20)
                textFormat: Text.PlainText
                text: navRow.modelData.glyph
                color: navRow.current ? Commons.Color.accent : root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: navGlyph.right
                anchors.leftMargin: Style.spacing.sm
                textFormat: Text.PlainText
                text: navRow.modelData.label
                color: navRow.current ? Commons.Color.menu.selectedText : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: navRow.current
              }

              MouseArea {
                id: navMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.section = navRow.modelData.id
              }
            }
          }
        }

        // What the window leaves out (agendaFile) is in shell.json: a quiet
        // link to it in the bottom left corner.
        Item {
          anchors.left: sidebar.left
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.bottom: parent.bottom
          anchors.bottomMargin: card.contentBottomInset + Style.spacing.xs
          width: editRow.implicitWidth
          height: editRow.implicitHeight

          readonly property color tint: editMouse.containsMouse ? root.foreground : Util.alpha(root.foreground, 0.4)

          Row {
            id: editRow
            spacing: Style.spacing.xs

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "shell.json"
              color: editRow.parent.tint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.underline: editMouse.containsMouse
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "\u{f03cc}"
              color: editRow.parent.tint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: editMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.close(); if (root.service) root.service.editSettings() }
          }
        }

        Button {
          visible: root.section === "about" && !!root.manifest.homepage
          anchors.right: parent.right
          anchors.rightMargin: card.contentRightInset
          anchors.bottom: parent.bottom
          anchors.bottomMargin: card.contentBottomInset
          text: strings.t("about.homepage")
          iconText: "\u{f02a4}"
          bordered: true
          foreground: root.foreground
          onClicked: { root.close(); Util.execArgv(["xdg-open", root.manifest.homepage]) }
        }

        Rectangle {
          id: divider
          x: sidebar.x + sidebar.width + Style.spacing.md
          y: card.contentTopInset
          width: 1
          height: sidebar.height
          color: Util.alpha(root.foreground, 0.12)
        }

        Flickable {
          id: pane
          x: divider.x + divider.width + Style.spacing.lg
          y: card.contentTopInset
          width: card.width - x - card.contentRightInset - Style.spacing.sm
          height: sidebar.height
          contentWidth: width
          contentHeight: page.implicitHeight
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Connections {
            target: root
            function onSectionChanged() { pane.contentY = 0 }
          }

          Column {
            id: page
            width: pane.width
            spacing: Style.spacing.xl
            topPadding: Style.spacing.xs
            bottomPadding: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: {
                for (var i = 0; i < root.sections.length; i++)
                  if (root.sections[i].id === root.section) return root.sections[i].label
                return ""
              }
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            // ---- Appearance ----
            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.style")
              description: strings.t("settings.styleHelp")
              ButtonGroup {
                options: [
                  { value: "omarchy", label: strings.t("settings.styleOmarchy") },
                  { value: "cupertino", label: strings.t("settings.styleCupertino") },
                  { value: "redmond", label: strings.t("settings.styleRedmond") },
                  { value: "plasma", label: strings.t("settings.stylePlasma") }
                ]
                value: root.styleName
                foreground: root.foreground
                onChanged: v => root.service.setSetting("style", v, "cupertino")
              }
            }

            // ---- Notifications ----
            Toggle {
              visible: root.section === "notifications"
              width: page.width
              label: strings.t("quiet.off")
              description: strings.t("settings.quietHelp")
              foreground: root.foreground
              checked: !!root.service && root.service.doNotDisturb
              onClicked: root.service.setDoNotDisturb(!root.service.doNotDisturb)
            }

            Toggle {
              visible: root.section === "notifications"
              width: page.width
              label: strings.t("settings.lowUrgency")
              description: strings.t("settings.lowUrgencyHelp")
              foreground: root.foreground
              checked: !!root.service && root.service.keepLowUrgency
              onClicked: root.service.setSetting("lowUrgency", !root.service.keepLowUrgency, false)
            }

            Setting {
              visible: root.section === "hidden"
              description: strings.t("settings.hiddenAppsHelp")

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.hiddenApps

                  ListRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    title: root.appName(String(modelData).toLowerCase())
                    detail: String(modelData)
                    onRemove: root.showApp(index)
                  }
                }

                Flow {
                  visible: root.appsSeen.length > 0
                  width: parent.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: root.appsSeen
                    Button {
                      required property string modelData
                      text: root.appName(modelData)
                      iconText: "\u{f0415}"
                      bordered: true
                      fontSize: Style.font.caption
                      foreground: root.foreground
                      onClicked: root.hideApp(modelData)
                    }
                  }
                }
              }
            }

            Setting {
              visible: root.section === "sites"
              description: strings.t("settings.webAppsHelp")

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.webAppSites

                  ListRow {
                    required property string modelData
                    width: parent.width
                    title: modelData
                    detail: root.appLabel(root.webApps[modelData])
                    onRemove: root.removeWebApp(modelData)
                  }
                }

                Row {
                  spacing: Style.spacing.sm

                  TextField {
                    id: siteField
                    width: Style.space(200)
                    foreground: root.foreground
                    placeholderText: "teams.microsoft.com"
                    onAccepted: root.addWebApp()
                  }

                  SearchableDropdown {
                    width: Style.space(170)
                    showLabel: false
                    options: root.appOptions
                    value: root.siteApp
                    triggerLabel: root.siteApp ? root.appLabel(root.siteApp) : strings.t("settings.webAppsPick")
                    onChanged: v => root.siteApp = v
                  }

                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.add")
                    bordered: true
                    enabled: !!root.siteToAdd && !!root.siteApp
                    opacity: enabled ? 1 : 0.4
                    foreground: root.foreground
                    onClicked: root.addWebApp()
                  }
                }

                // Sites that already sent you something.
                Flow {
                  visible: root.suggestedSites.length > 0
                  width: parent.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: root.suggestedSites
                    Button {
                      required property string modelData
                      text: modelData
                      fontSize: Style.font.caption
                      foreground: root.dim
                      onClicked: siteField.text = modelData
                    }
                  }
                }
              }
            }

            // ---- Agenda ----
            Text {
              visible: root.section === "agenda" && !!root.settings.agendaFile
              width: page.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: strings.t("settings.agendaFileUsed").arg(String(root.settings.agendaFile || ""))
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Setting {
              visible: root.section === "agenda"
              label: strings.t("settings.calendars")
              description: strings.t("settings.calendarsHelp")

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.calendars

                  ListRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    swatch: String(modelData && modelData.color || "") || String(Commons.Color.accent)
                    title: String(modelData && modelData.name || "") || root.calendarOrigin(modelData && modelData.url)
                    detail: root.calendarOrigin(modelData && modelData.url)
                    onRemove: root.removeCalendar(index)
                  }
                }

                TextField {
                  id: calendarName
                  width: Style.space(380)
                  foreground: root.foreground
                  placeholderText: strings.t("settings.calendarName")
                }

                // The link is a secret: masked, like a password.
                TextField {
                  id: calendarUrl
                  width: Style.space(380)
                  password: true
                  foreground: root.foreground
                  placeholderText: strings.t("settings.calendarUrl")
                  onAccepted: root.addCalendar()
                }

                Text {
                  visible: calendarUrl.text.trim() !== "" && !root.urlToAdd
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: strings.t("settings.calendarUrlBad")
                  color: Commons.Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Row {
                  spacing: Style.spacing.xs

                  // The theme's accent first, which keeps no color of its own.
                  Repeater {
                    model: [""].concat(root.swatches)
                    Rectangle {
                      required property string modelData
                      readonly property bool chosen: root.calendarColor === modelData
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(22)
                      height: width
                      radius: width / 2
                      color: modelData || Commons.Color.accent
                      border.width: chosen ? Style.space(2) : 0
                      border.color: root.foreground
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(2)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.calendarColor = parent.modelData
                      }
                    }
                  }

                  Item { width: Style.spacing.md; height: 1 }

                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.add")
                    bordered: true
                    enabled: !!root.urlToAdd
                    opacity: enabled ? 1 : 0.4
                    foreground: root.foreground
                    onClicked: root.addCalendar()
                  }

                  Button {
                    visible: root.calendars.length > 0 && !root.settings.agendaFile
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.syncNow")
                    iconText: "\u{f0450}"
                    foreground: root.foreground
                    onClicked: root.service.syncAgenda()
                  }
                }
              }
            }

            // ---- About ----
            Row {
              visible: root.section === "about"
              width: page.width
              spacing: Style.spacing.lg

              Image {
                id: aboutLogo
                width: Style.space(80)
                height: width
                source: Qt.resolvedUrl("assets/logo.png")
                sourceSize: Qt.size(width * 2, height * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

              Column {
                anchors.verticalCenter: aboutLogo.verticalCenter
                width: page.width - aboutLogo.width - Style.spacing.lg
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: root.manifest.name || "qCenter"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Math.round(Style.font.heading * 1.3)
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("about.version").arg(root.manifest.version || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("about.credits").arg(root.manifest.author || "").arg(root.manifest.license || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              visible: root.section === "about"
              width: page.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: strings.t("about.description")
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }

  // A setting's name and an optional line of help over its control.
  component Setting: Column {
    id: setting
    property string label: ""
    property string description: ""
    default property alias control: holder.data

    width: parent ? parent.width : 0
    height: visible ? implicitHeight : 0
    spacing: Style.spacing.xs

    Text {
      visible: setting.label !== ""
      textFormat: Text.PlainText
      font.bold: true
      text: setting.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      visible: setting.description !== ""
      width: setting.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: setting.description
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Item { width: 1; height: Style.spacing.xs }

    Item {
      id: holder
      width: setting.width
      height: childrenRect.height
    }
  }

  // One saved entry: an optional color dot, its name and a detail, and a
  // button to remove it.
  component ListRow: Rectangle {
    id: listRow
    property string swatch: ""
    property string title: ""
    property string detail: ""
    signal remove()

    height: Style.spacing.popupRowHeight
    radius: Math.min(height / 2, root.cardRadius)
    color: Util.alpha(root.foreground, rowMouse.containsMouse ? 0.09 : 0.05)

    MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true }

    Rectangle {
      id: dot
      visible: listRow.swatch !== ""
      x: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(10)
      height: width
      radius: width / 2
      color: listRow.swatch || "transparent"
    }

    Text {
      id: rowTitle
      x: dot.visible ? dot.x + dot.width + Style.spacing.sm : Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width * 0.5)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: listRow.title
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.left: rowTitle.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: removeButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: listRow.detail
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      id: removeButton
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{f0156}"
      tooltipText: strings.t("settings.remove")
      foreground: root.foreground
      onClicked: listRow.remove()
    }
  }
}
