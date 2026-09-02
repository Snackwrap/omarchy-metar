import QtQuick

// The terminal forecast as one strip: time runs left to right across the whole
// valid period, each block coloured by the flight category it forecasts.
//
// TEMPO and PROB groups describe a temporary deviation *inside* another period
// rather than a period of their own, so they are drawn as a thin band under the
// main strip. Letting a thirty-minute TEMPO recolour a six-hour block would
// make the forecast look far worse than it is.
Item {
  id: root

  property var periods: []            // from Met.tafPeriods()
  property double nowMs: 0
  property var categoryColor: function (c) { return "#888" }
  property color gridColor: "#555"
  property color labelColor: "#888"
  property string fontFamily: "monospace"
  property real labelSize: 10
  property bool zulu: false
  property bool animate: true

  // The strip is revealed left to right when the tab opens, which reads as the
  // forecast being laid down along its own time axis. One wipe over the whole
  // strip rather than per-block animations: the blocks are a continuous run of
  // time and animating them separately breaks that.
  property real reveal: 1.0
  function play() {
    if (!animate) { reveal = 1.0; return }
    reveal = 0
    wipe.restart()
  }
  NumberAnimation {
    id: wipe
    target: root
    property: "reveal"
    to: 1.0
    duration: 620
    easing.type: Easing.OutCubic
  }

  readonly property var solid: periods.filter(function (p) { return !p.transient })
  readonly property var transient_: periods.filter(function (p) { return p.transient })

  readonly property double fromMs: solid.length ? solid[0].from : 0
  readonly property double toMs: solid.length ? solid[solid.length - 1].to : 0
  readonly property double spanMs: Math.max(1, toMs - fromMs)

  implicitHeight: strip.height + tempoRow.height + axis.height + 10

  function xFor(ms) {
    return Math.max(0, Math.min(width, (ms - fromMs) / spanMs * width))
  }

  // Rectangles for the solid periods.
  Item {
    id: strip
    width: parent.width
    height: 26

    // The reveal happens by clipping this layer, so the blocks keep their real
    // positions and only the visible extent grows.
    Item {
      width: parent.width * root.reveal
      height: parent.height
      clip: true

      Repeater {
        model: root.solid
        Rectangle {
          x: root.xFor(modelData.from)
          width: Math.max(1, root.xFor(modelData.to) - root.xFor(modelData.from))
          height: parent.height
          color: root.categoryColor(modelData.category)
          // Hairline gaps between blocks so adjacent periods of the same
          // category still read as two forecast groups, not one.
          border.width: 1
          border.color: Qt.rgba(0, 0, 0, 0.35)
        }
      }
    }

    // Now marker, only while it is actually inside the forecast window — and
    // outside the clip layer, since it overhangs the strip top and bottom.
    Rectangle {
      visible: root.nowMs >= root.fromMs && root.nowMs <= root.toMs
               && root.xFor(root.nowMs) <= root.width * root.reveal
      x: root.xFor(root.nowMs) - 1
      width: 2
      height: parent.height + 5
      y: -3
      color: root.labelColor
    }
  }

  // Transient groups hang below the strip they qualify.
  Item {
    id: tempoRow
    anchors.top: strip.bottom
    anchors.topMargin: 2
    width: parent.width
    height: root.transient_.length ? 6 : 0

    Item {
      width: parent.width * root.reveal
      height: parent.height
      clip: true
      Repeater {
        model: root.transient_
        Rectangle {
          x: root.xFor(modelData.from)
          width: Math.max(2, root.xFor(modelData.to) - root.xFor(modelData.from))
          height: parent.height
          color: root.categoryColor(modelData.category)
          opacity: 0.55
        }
      }
    }
  }

  // Hour ticks. Six-hour spacing keeps a 30-hour TAF legible at panel width.
  Item {
    id: axis
    anchors.top: tempoRow.bottom
    anchors.topMargin: 3
    width: parent.width
    height: root.labelSize + 4

    Repeater {
      model: root.tickTimes()
      Text {
        textFormat: Text.PlainText
        x: Math.min(root.width - implicitWidth, Math.max(0, root.xFor(modelData) - implicitWidth / 2))
        text: root.tickLabel(modelData)
        color: root.labelColor
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
      }
    }
  }

  function tickTimes() {
    if (!solid.length) return []
    var out = []
    var stepMs = 6 * 3600000
    // Start from the first whole six-hour boundary inside the window.
    var t = Math.ceil(fromMs / stepMs) * stepMs
    // At most six labels, or they collide at panel width.
    while (t <= toMs && out.length < 6) {
      out.push(t)
      t += stepMs
    }
    return out
  }

  function tickLabel(ms) {
    var d = new Date(ms)
    var h = zulu ? d.getUTCHours() : d.getHours()
    return (h < 10 ? "0" + h : String(h)) + (zulu ? "Z" : "")
  }
}
