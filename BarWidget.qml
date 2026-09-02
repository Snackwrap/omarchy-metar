import QtQuick
import qs.Commons
import qs.Ui

// Bar pill: an aircraft glyph plus the flight category. All fetching and the
// popup itself live in Panel.qml; this is just the bar-slot button and the
// popout-identity shim the bar expects.
BarWidget {
  id: root
  moduleName: "com.leafbox.metar"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: the bar identifies a
  // panel by the widget mounted in its slot (this file), so open/close/opened
  // have to live here and forward to the nested Panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

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
    text: panelLoader.item ? panelLoader.item.label : ""
    slotSize: Style.bar.statusSlot
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : "Aviation Weather"
    // The pill carries the flight category as colour, which is the whole point
    // of it: green through magenta is the same scale every aviation chart uses,
    // so it reads without being read. Falls back to the bar's own foreground
    // when there is no observation to colour it with.
    foreground: (panelLoader.item && panelLoader.item.categoryColor !== "")
      ? panelLoader.item.categoryColor
      : (root.bar ? root.bar.barForeground : Color.foreground)

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
