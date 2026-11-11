import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

import "Routing.js" as Routing

// The panel: it slides in from the right, today's agenda on top, then the
// notifications grouped by app or site, newest first.
PanelWindow {
  id: panel

  property var service: null
  property var strings: null
  property bool open: false
  property var targetScreen: null

  // Expanded groups (group key → true); folded, a group shows three cards.
  property var expandedGroups: ({})
  readonly property int foldedCount: 3

  property date now: new Date()

  // "mac" (default): a frosted pane with round corners; "omarchy": opaque,
  // with the theme's corners and popup border, like Omarchy's bubbles.
  readonly property bool macStyle: !service || service.settings.style !== "omarchy"
  readonly property int sheetRadius: macStyle ? Math.max(Style.cornerRadius, Style.space(16)) : Style.cornerRadius
  readonly property int tileRadius: macStyle ? Style.space(12) : Style.cornerRadius

  readonly property var locale: Qt.locale(String(I18n.formatLocale || "en-US").replace("-", "_"))

  function t(key) { return panel.strings ? panel.strings.t(key) : key }

  readonly property var rows: service ? service.rows : []
  readonly property var groups: {
    var byKey = {}, out = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var key = panel.groupKeyOf(row)
      if (!byKey[key]) {
        byKey[key] = { key: key, label: panel.labelOf(row), rows: [] }
        out.push(byKey[key])
      }
      byKey[key].rows.push(row)
    }
    return out
  }

  // ---- Opening -------------------------------------------------------------
  function show() {
    var name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    panel.targetScreen = null
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === name) panel.targetScreen = Quickshell.screens[i]
    if (!panel.targetScreen && Quickshell.screens.length > 0) panel.targetScreen = Quickshell.screens[0]
    panel.now = new Date()
    if (service) service.syncAgenda()
    panel.open = true
    slide.restart()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function hide() { panel.open = false }

  // A click on the bell first clears the focus grab, which closes the panel,
  // then asks for a toggle: that toggle must not reopen it.
  property double closedByGrab: 0
  function toggle() {
    if (panel.open) hide()
    else if (Date.now() - panel.closedByGrab > 400) show()
  }

  // ---- How a notification reads --------------------------------------------
  // Browsers send every web notification under their own name: tell them
  // apart by site.
  readonly property var siteNames: ({
    "outlook.office.com": "Outlook", "outlook.office365.com": "Outlook", "outlook.live.com": "Outlook",
    "teams.microsoft.com": "Teams", "teams.cloud.microsoft": "Teams", "teams.live.com": "Teams",
    "mail.google.com": "Gmail", "calendar.google.com": "Google Calendar", "messages.google.com": "Google Messages",
    "app.slack.com": "Slack", "app.basecamp.com": "Basecamp", "app.hey.com": "HEY", "discord.com": "Discord",
    "web.whatsapp.com": "WhatsApp"
  })

  function hostOf(row) { return Routing.canonicalHostname(row.source || "") }

  function groupKeyOf(row) {
    var host = panel.hostOf(row)
    return host ? "site:" + host : "app:" + panel.labelOf(row)
  }

  function labelOf(row) {
    var host = panel.hostOf(row)
    if (host) return panel.siteNames[host] || host
    var app = String(row.app || "")
    if (app === "omarchy-action" || app === "notify-send") return "Omarchy"
    if (!app) return panel.t("notification")
    var entry = DesktopEntries.heuristicLookup(app)
    if (entry && entry.name) return String(entry.name)
    return app.charAt(0).toUpperCase() + app.slice(1)
  }

  // Omarchy stores a notification that carried a code as a placeholder, in
  // English; show it in the user's language, as Omarchy's bubbles do.
  function isRedacted(row) {
    return row.summary === "Verification notification" && row.body === "[redacted]"
  }
  function summaryOf(row) {
    return panel.isRedacted(row) ? I18n.t("notifications.redactedSummary") : panel.plain(row.summary)
  }
  function bodyOf(row) {
    return panel.isRedacted(row) ? I18n.t("notifications.redactedBody") : panel.plain(row.body)
  }

  function iconOf(row) {
    // Omarchy keeps only bare icon names.
    var icon = String(row.appIcon || "")
    return icon ? (Quickshell.iconPath(icon, true) || "") : ""
  }

  function plain(text) {
    return String(text || "").replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, "")
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&")
      .replace(/\s+/g, " ").trim()
  }

  function ago(ts) {
    var s = Math.max(0, Math.round(panel.now.getTime() / 1000 - Number(ts || 0)))
    if (s < 60) return panel.t("time.now")
    if (s < 3600) return panel.t("time.minutes").arg(Math.floor(s / 60))
    if (s < 86400) return panel.t("time.hours").arg(Math.floor(s / 3600))
    return new Date(Number(ts) * 1000).toLocaleDateString(panel.locale, "d MMM")
  }

  // ---- Today's agenda ------------------------------------------------------
  // An all-day date ("2026-11-11") is a local day, not UTC midnight.
  function parseWhen(value, allDay) {
    var text = String(value || "")
    var day = text.match(/^(\d{4})-(\d{2})-(\d{2})$/)
    if (day) return new Date(Number(day[1]), Number(day[2]) - 1, Number(day[3]))
    var d = new Date(text)
    if (allDay && !isNaN(d.getTime())) return new Date(d.getFullYear(), d.getMonth(), d.getDate())
    return d
  }

  readonly property var agenda: {
    var list = service ? service.events : []
    var now = panel.now
    var dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    var dayEnd = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
    var allDay = [], timed = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i] || {}
      var start = panel.parseWhen(e.start, e.allDay), stop = panel.parseWhen(e.end || e.start, e.allDay)
      if (isNaN(start.getTime())) continue
      if (isNaN(stop.getTime()) || stop <= start) stop = new Date(start.getTime() + (e.allDay ? 86400000 : 0))
      var row = { title: String(e.title || ""), color: String(e.color || "") || String(Commons.Color.accent),
                  join: Routing.safeHttpsUrl(String(e.join || "")) }
      if (e.allDay) {
        if (start < dayEnd && stop > dayStart) allDay.push(Object.assign(row, { when: panel.t("agenda.allDay"), live: false }))
      } else if (stop > now && start < dayEnd) {
        timed.push(Object.assign(row, { at: start.getTime(), live: start <= now,
                                        when: start <= now ? panel.t("agenda.now") : start.toLocaleTimeString(panel.locale, Locale.ShortFormat) }))
      }
    }
    timed.sort(function(a, b) { return a.at - b.at })
    return allDay.concat(timed).slice(0, 6)
  }

  Timer {
    interval: 30000
    repeat: true
    running: panel.open
    onTriggered: panel.now = new Date()
  }

  // ---- Window --------------------------------------------------------------
  screen: targetScreen
  visible: open && !!targetScreen
  color: "transparent"
  WlrLayershell.namespace: "qcenter"
  WlrLayershell.layer: WlrLayer.Overlay
  // OnDemand, not Exclusive: Exclusive keeps the keyboard on the panel, so a
  // click outside never clears the focus grab and the panel never closes.
  // The grab itself hands the keyboard to the panel, so Escape still works.
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
  // Below the bar, like the bubbles.
  exclusionMode: ExclusionMode.Normal
  anchors { top: true; bottom: true; right: true }
  implicitWidth: sheet.width + Style.space(16) * 2

  HyprlandFocusGrab {
    active: panel.visible
    windows: [panel]
    onCleared: {
      panel.closedByGrab = Date.now()
      panel.hide()
    }
  }

  property real reveal: 0
  NumberAnimation { id: slide; target: panel; property: "reveal"; from: 0; to: 1; duration: Style.duration(220); easing.type: Easing.OutCubic }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: panel.hide()
  }

  Rectangle {
    id: sheet
    width: Style.space(400)
    x: Style.space(16) + (1 - panel.reveal) * (width + Style.space(16))
    y: Style.space(10)
    height: parent.height - Style.space(10) * 2
    opacity: panel.reveal
    radius: panel.sheetRadius
    color: panel.macStyle ? Util.alpha(Commons.Color.popups.background, 0.9) : Commons.Color.popups.background
    border.width: Style.normalBorderWidth
    border.color: panel.macStyle ? Util.alpha(Commons.Color.popups.text, 0.14) : Commons.Color.popups.border

    // A click on the pane's empty space keeps it open.
    MouseArea { anchors.fill: parent }

    Flickable {
      id: scroller
      anchors.fill: parent
      anchors.margins: Style.space(14)
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: content
        width: scroller.width
        spacing: Style.space(14)

        Item {
          width: parent.width
          height: Style.space(32)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: panel.t("title")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 1.35)
            font.bold: true
          }

          Pill {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: panel.t("clearAll")
            visible: panel.rows.length > 0
            onClicked: panel.service.clearAll()
          }
        }

        Rectangle {
          id: quietRow
          readonly property bool on: !!panel.service && panel.service.doNotDisturb
          width: parent.width
          height: Style.space(40)
          radius: panel.tileRadius
          color: on ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, quietMouse.containsMouse ? 0.1 : 0.06)
          Behavior on color { ColorAnimation { duration: Style.duration(150) } }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: quietRow.on ? "󰂛   " + panel.t("quiet.on") : "󰂜   " + panel.t("quiet.off")
            color: quietRow.on ? Commons.Color.background : Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: quietRow.on
          }

          Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            height: Style.space(20)
            radius: height / 2
            color: quietRow.on ? Commons.Color.background : Util.alpha(Commons.Color.popups.text, 0.25)
            Rectangle {
              width: parent.height - Style.space(4)
              height: width
              radius: width / 2
              y: Style.space(2)
              x: quietRow.on ? parent.width - width - Style.space(2) : Style.space(2)
              color: quietRow.on ? Commons.Color.accent : Commons.Color.popups.background
              Behavior on x { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
            }
          }

          MouseArea {
            id: quietMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: panel.service.setDoNotDisturb(!quietRow.on)
          }
        }

        Rectangle {
          visible: panel.agenda.length > 0
          width: parent.width
          height: visible ? agendaColumn.implicitHeight + Style.space(12) * 2 : 0
          radius: panel.tileRadius
          color: Util.alpha(Commons.Color.popups.text, 0.06)

          Column {
            id: agendaColumn
            x: Style.space(12)
            y: Style.space(12)
            width: parent.width - Style.space(24)
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: panel.t("agenda.today")
              color: Util.alpha(Commons.Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.body * 0.85)
              font.bold: true
            }

            Repeater {
              model: panel.agenda
              delegate: Item {
                id: event
                required property var modelData
                width: agendaColumn.width
                height: Math.max(eventTitle.implicitHeight, joinPill.visible ? joinPill.height : 0)

                Rectangle {
                  id: eventBar
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(4)
                  height: eventTitle.implicitHeight
                  radius: width / 2
                  color: event.modelData.color
                }
                Text {
                  id: eventWhen
                  anchors.left: eventBar.right
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(76)
                  textFormat: Text.PlainText
                  text: event.modelData.when
                  elide: Text.ElideRight
                  color: event.modelData.live ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.7)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  id: eventTitle
                  anchors.left: eventWhen.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: joinPill.visible ? joinPill.left : parent.right
                  anchors.rightMargin: joinPill.visible ? Style.space(6) : 0
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: event.modelData.title
                  elide: Text.ElideRight
                  color: Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Pill {
                  id: joinPill
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: event.modelData.join !== ""
                  small: true
                  text: panel.t("agenda.join")
                  onClicked: {
                    Qt.openUrlExternally(event.modelData.join)
                    panel.hide()
                  }
                }
              }
            }
          }
        }

        Text {
          visible: panel.rows.length === 0
          width: parent.width
          topPadding: Style.space(40)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: panel.t("empty")
          color: Util.alpha(Commons.Color.popups.text, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: panel.groups

          delegate: Column {
            id: group
            required property var modelData
            readonly property bool expanded: !!panel.expandedGroups[modelData.key]
            width: content.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Style.space(24)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: group.modelData.label + (group.modelData.rows.length > 1 ? "  ·  " + group.modelData.rows.length : "")
                color: Util.alpha(Commons.Color.popups.text, 0.7)
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.body * 0.9)
                font.bold: true
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Pill {
                  visible: group.modelData.rows.length > panel.foldedCount
                  small: true
                  text: group.expanded ? panel.t("group.less") : panel.t("group.all")
                  onClicked: {
                    var next = Object.assign({}, panel.expandedGroups)
                    if (group.expanded) delete next[group.modelData.key]
                    else next[group.modelData.key] = true
                    panel.expandedGroups = next
                  }
                }
                Pill {
                  small: true
                  text: "✕"
                  onClicked: panel.service.clear(group.modelData.rows)
                }
              }
            }

            Repeater {
              model: group.expanded ? group.modelData.rows : group.modelData.rows.slice(0, panel.foldedCount)

              delegate: Rectangle {
                id: card
                required property var modelData
                required property int index
                width: group.width
                height: cardColumn.implicitHeight + Style.space(10) * 2
                radius: panel.tileRadius
                color: Util.alpha(Commons.Color.popups.text, cardMouse.containsMouse ? 0.12 : 0.07)
                // A bubble still on screen.
                border.width: card.modelData.live ? Style.normalBorderWidth : 0
                border.color: Util.alpha(Commons.Color.accent, 0.5)

                opacity: 0
                Component.onCompleted: fadeIn.start()
                SequentialAnimation {
                  id: fadeIn
                  PauseAnimation { duration: Style.duration(Math.min(8, card.index) * 25) }
                  NumberAnimation { target: card; property: "opacity"; to: 1; duration: Style.duration(180); easing.type: Easing.OutCubic }
                }

                MouseArea {
                  id: cardMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    panel.service.activate(card.modelData)
                    panel.hide()
                  }
                }

                Image {
                  id: cardIcon
                  x: Style.space(10)
                  y: Style.space(10)
                  width: Style.space(32)
                  height: width
                  sourceSize: Qt.size(width * 2, height * 2)
                  source: panel.iconOf(card.modelData)
                  visible: status === Image.Ready
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                  mipmap: true
                }

                // No icon: the app's initial in a dot.
                Rectangle {
                  visible: !cardIcon.visible
                  x: cardIcon.x
                  y: cardIcon.y
                  width: cardIcon.width
                  height: width
                  radius: width / 2
                  color: Util.alpha(Commons.Color.accent, 0.25)
                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: panel.labelOf(card.modelData).charAt(0).toUpperCase()
                    color: Commons.Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                Column {
                  id: cardColumn
                  x: cardIcon.x + cardIcon.width + Style.space(10)
                  y: Style.space(10)
                  width: card.width - x - Style.space(10)
                  spacing: Style.space(2)

                  Item {
                    width: parent.width
                    height: summary.implicitHeight

                    Text {
                      id: summary
                      width: parent.width - when.width - Style.space(8)
                      textFormat: Text.PlainText
                      text: panel.summaryOf(card.modelData) || panel.labelOf(card.modelData)
                      elide: Text.ElideRight
                      color: Commons.Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      id: when
                      anchors.right: parent.right
                      visible: !cardMouse.containsMouse && !closeMouse.containsMouse
                      textFormat: Text.PlainText
                      text: panel.ago(card.modelData.ts)
                      color: Util.alpha(Commons.Color.popups.text, 0.5)
                      font.family: Style.font.family
                      font.pixelSize: Math.round(Style.font.body * 0.85)
                    }
                    // On hover, the time gives way to a button to remove the card.
                    Text {
                      anchors.right: parent.right
                      visible: !when.visible
                      textFormat: Text.PlainText
                      text: "✕"
                      color: Commons.Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.service.clear([card.modelData])
                      }
                    }
                  }

                  Text {
                    visible: text !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: panel.bodyOf(card.modelData)
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    color: Util.alpha(Commons.Color.popups.text, 0.8)
                    font.family: Style.font.family
                    font.pixelSize: Math.round(Style.font.body * 0.92)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property bool small: false
    signal clicked()

    width: pillText.implicitWidth + Style.space(small ? 10 : 14) * 2
    height: Style.space(small ? 22 : 28)
    radius: height / 2
    color: Util.alpha(Commons.Color.popups.text, pillMouse.containsMouse ? 0.16 : 0.08)

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: pill.text
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * (pill.small ? 0.82 : 0.9))
    }

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }
}
