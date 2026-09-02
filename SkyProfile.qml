import QtQuick
import "metar.js" as Met

// The sky above the field, drawn to height.
//
// The reported layers are already in the panel as text — "few 2,200 ft,
// scattered 3,400 ft" — but text puts them in a list when what they actually
// are is a stack. Drawn at their real heights, with the ceiling marked in the
// category colour, a glance says how much room there is underneath.
//
// The height axis is compressed with a square root so the low layers, which are
// the ones that decide the category, keep most of the space, and its top
// follows the highest reported layer: a scale fixed at twelve thousand feet
// squashes a low overcast day into the bottom two pixels.
Item {
  id: root

  property var clouds: []
  property var ceiling: null          // ft, or null for unlimited
  property color ceilingColor: "white"
  property color inkColor: "white"
  property string fontFamily: "monospace"
  property real labelSize: 10
  property bool animate: true

  implicitWidth: 320
  implicitHeight: 132

  readonly property real labelGutter: labelSize * 9
  readonly property real groundInset: labelSize + 6
  readonly property real floorY: height - groundInset
  readonly property real skyY: labelSize + 8
  readonly property real plotWidth: Math.max(10, width - labelGutter)

  // Layers that can actually be drawn, lowest first.
  readonly property var layers: {
    var out = []
    var list = clouds || []
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || c.base === null || c.base === undefined) continue
      var base = Number(c.base)
      if (!isFinite(base) || base <= 0) continue
      out.push({ cover: String(c.cover || "").toUpperCase(), base: base })
    }
    out.sort(function (a, b) { return a.base - b.base })
    return out
  }

  readonly property real topFt: {
    var highest = 0
    for (var i = 0; i < layers.length; i++) highest = Math.max(highest, layers[i].base)
    if (ceiling !== null && isFinite(Number(ceiling))) highest = Math.max(highest, Number(ceiling))
    // Round up so the top layer is not pinned against the frame.
    return Math.max(4000, Math.ceil(highest * 1.35 / 1000) * 1000)
  }

  function yFor(ft) {
    var h = Math.max(0, Math.min(topFt, Number(ft) || 0))
    return floorY - Math.sqrt(h / topFt) * (floorY - skyY)
  }

  // How solid a layer looks is how much of the sky it covers, and the dash
  // pattern says the same thing again — the two together read faster than
  // either alone.
  function inkFor(cover) {
    switch (cover) {
    case "FEW": return 0.32
    case "SCT": return 0.55
    case "BKN": return 0.80
    case "OVC": case "OVX": case "VV": return 0.95
    }
    return 0.4
  }

  function dashFor(cover) {
    switch (cover) {
    case "FEW": return [4, 13]
    case "SCT": return [9, 9]
    case "BKN": return [20, 6]
    case "OVC": case "OVX": case "VV": return []
    }
    return [6, 6]
  }

  property real reveal: 1.0
  function play() {
    if (!animate) { reveal = 1.0; return }
    reveal = 0
    rise.restart()
  }
  NumberAnimation {
    id: rise
    target: root
    property: "reveal"
    to: 1.0
    duration: 560
    easing.type: Easing.OutCubic
  }

  onRevealChanged: canvas.requestPaint()
  onLayersChanged: canvas.requestPaint()
  onCeilingChanged: canvas.requestPaint()
  onInkColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.lineCap = "butt"

      var w = root.plotWidth
      var grown = w * root.reveal          // layers draw in from the left

      // Ground.
      ctx.strokeStyle = root.inkColor
      ctx.globalAlpha = 0.45
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, root.floorY + 0.5)
      ctx.lineTo(w, root.floorY + 0.5)
      ctx.stroke()

      // Cloud layers.
      ctx.lineWidth = 4
      for (var i = 0; i < root.layers.length; i++) {
        var layer = root.layers[i]
        var y = Math.round(root.yFor(layer.base)) + 0.5
        ctx.globalAlpha = root.inkFor(layer.cover) * root.reveal
        ctx.setLineDash(root.dashFor(layer.cover))
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(grown, y)
        ctx.stroke()
      }
      ctx.setLineDash([])

      // The ceiling gets the category colour and a solid rule: it is the
      // number the category came from.
      if (root.ceiling !== null && isFinite(Number(root.ceiling))) {
        ctx.strokeStyle = root.ceilingColor
        ctx.globalAlpha = 0.9 * root.reveal
        ctx.lineWidth = 1
        var cy = Math.round(root.yFor(root.ceiling)) + 0.5
        ctx.beginPath()
        ctx.moveTo(0, cy)
        ctx.lineTo(grown, cy)
        ctx.stroke()
      }
    }
  }

  Text {
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.ceiling === null ? "SKY  ·  no ceiling" : "SKY"
    color: root.inkColor
    opacity: 0.4
    font.family: root.fontFamily
    font.pixelSize: root.labelSize
    font.letterSpacing: 1.4
  }

  // Labels sit in the gutter to the right of the plot. Two layers a few hundred
  // feet apart would print on top of each other, so each is pushed clear of the
  // one below it.
  readonly property var labelYs: {
    var out = []
    var minGap = labelSize + 3
    for (var i = 0; i < layers.length; i++) {
      var want = yFor(layers[i].base) - labelSize / 2
      // Layers are sorted lowest first, so walk upwards and push each label
      // above the previous one when they would collide.
      if (i > 0 && out[i - 1] - want < minGap) want = out[i - 1] - minGap
      out.push(want)
    }
    return out
  }

  Repeater {
    model: root.layers
    Text {
      required property var modelData
      required property int index
      x: root.plotWidth + 7
      y: root.labelYs[index] !== undefined ? root.labelYs[index] : 0
      opacity: 0.62 * root.reveal
      text: Met.cloudLabel(modelData.cover) + " " + Number(modelData.base).toLocaleString()
      color: root.inkColor
      font.family: root.fontFamily
      font.pixelSize: root.labelSize
    }
  }

  Text {
    x: root.plotWidth + 7
    y: root.floorY - root.labelSize / 2
    text: "field"
    color: root.inkColor
    opacity: 0.4
    font.family: root.fontFamily
    font.pixelSize: root.labelSize
  }

  Text {
    visible: root.layers.length === 0
    x: 0
    y: root.floorY - (root.floorY - root.skyY) * 0.5
    text: "clear"
    color: root.inkColor
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: root.labelSize
  }
}
