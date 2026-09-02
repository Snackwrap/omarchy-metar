import QtQuick
import "metar.js" as Met

// A station-model wind barb, drawn the way it is drawn on every surface chart.
//
// The staff points *from* the station *towards* where the wind is coming from —
// a 270 wind puts the staff out to the west — and the barbs hang off the far
// end. A pennant is 50 kt, a full barb 10, a half barb 5, and under 3 kt there
// is no staff at all, just the open circle that means calm.
//
// Everything is drawn in a local frame with the staff pointing straight up and
// then rotated, because that keeps the barb geometry to plain arithmetic.
Item {
  id: root

  property real direction: NaN     // degrees the wind is coming from
  property real speedKt: NaN
  property color stroke: "white"
  property real thickness: 1.6

  readonly property var barb: Met.windBarb(speedKt)
  readonly property bool variable: !isFinite(direction) || direction <= 0
  readonly property bool calm: barb.calm

  implicitWidth: 64
  implicitHeight: 64

  onDirectionChanged: canvas.requestPaint()
  onSpeedKtChanged: canvas.requestPaint()
  onStrokeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.strokeStyle = root.stroke
      ctx.fillStyle = root.stroke
      ctx.lineWidth = root.thickness
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      var cx = width / 2
      var cy = height / 2
      var dotR = Math.max(2.0, Math.min(width, height) * 0.055)

      // The station circle is always there; it is the whole symbol when calm.
      ctx.beginPath()
      ctx.arc(cx, cy, dotR, 0, Math.PI * 2)
      ctx.stroke()

      if (root.calm) {
        // Calm is conventionally a second ring around the station circle.
        ctx.beginPath()
        ctx.arc(cx, cy, dotR * 2.1, 0, Math.PI * 2)
        ctx.stroke()
        return
      }

      // A variable wind has no direction to point in, so draw the speed as a
      // bare barb pointing up with a dashed staff rather than implying north.
      var b = root.barb
      var staff = Math.min(width, height) * 0.40
      var barbLen = staff * 0.46
      var step = staff * 0.155        // spacing between barbs down the staff
      var lean = 0.42                 // how far the barbs rake back towards the station

      ctx.save()
      ctx.translate(cx, cy)
      // Canvas y grows downward and 0 degrees is north, so the rotation that
      // sends the staff towards the reported direction is simply the bearing.
      ctx.rotate((root.variable ? 0 : root.direction) * Math.PI / 180)

      // Staff, from the edge of the station circle outwards.
      ctx.beginPath()
      ctx.moveTo(0, -dotR)
      ctx.lineTo(0, -staff)
      ctx.stroke()

      // Barbs start at the far end and work back towards the station.
      var y = -staff
      var i

      for (i = 0; i < b.pennants; i++) {
        // A pennant is a filled triangle sitting on the staff.
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(barbLen, y + step * lean)
        ctx.lineTo(0, y + step)
        ctx.closePath()
        ctx.fill()
        y += step * 1.25
      }
      // A pennant butts against the next symbol; a small gap reads better.
      if (b.pennants > 0 && (b.barbs > 0 || b.half > 0)) y += step * 0.35

      for (i = 0; i < b.barbs; i++) {
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(barbLen, y + step * lean)
        ctx.stroke()
        y += step
      }

      if (b.half > 0) {
        // A half barb never sits at the very end of the staff — if it is the
        // only symbol it moves one step in, or it reads as a full barb.
        if (b.pennants === 0 && b.barbs === 0) y += step
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(barbLen * 0.5, y + step * lean * 0.5)
        ctx.stroke()
      }

      ctx.restore()
    }
  }

  // Variable winds get a label, since the staff direction is meaningless.
  Text {
    visible: root.variable && !root.calm
    text: "VRB"
    color: root.stroke
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    font.pixelSize: Math.max(8, root.height * 0.14)
    opacity: 0.75
  }
}
