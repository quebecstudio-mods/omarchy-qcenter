import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bell: the count comes from qCenter's state.json, Do Not Disturb from
// Omarchy's quiet.json. A click opens or closes the center.
BarWidget {
  id: root
  moduleName: "quebecstudio.qcenter"
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string home: Quickshell.env("HOME")
  property int count: 0
  property bool quiet: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/qcenter/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.count = Number(JSON.parse(text()).count || 0) } catch (e) { root.count = 0 }
    }
    onLoadFailed: root.count = 0
  }

  FileView {
    path: root.home + "/.local/state/omarchy/notifications/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.quiet = JSON.parse(text()).dnd === true } catch (e) {}
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.quiet ? "󰂛" : (root.count > 0 ? "󰂚" : "󰂜")
    tooltipText: root.quiet ? strings.t("bell.quiet") : strings.t("title")
    onPressed: { if (root.bar) root.bar.run("omarchy-shell -q quebecstudio.qcenter toggle") }
  }

  // The count sits on the bell's corner: as the button's label it would read
  // like a battery percentage.
  Rectangle {
    visible: root.count > 0 && !root.quiet
    height: Math.round(button.height * 0.42)
    width: Math.max(height, badgeText.implicitWidth + height * 0.5)
    radius: height / 2
    color: Color.accent
    x: button.width / 2 + Math.round(button.height * 0.05)
    y: Math.round(button.height * 0.12)
    Text {
      id: badgeText
      anchors.centerIn: parent
      text: root.count > 99 ? "99+" : String(root.count)
      color: Color.background
      font.pixelSize: Math.round(parent.height * 0.72)
      font.bold: true
    }
  }
}
