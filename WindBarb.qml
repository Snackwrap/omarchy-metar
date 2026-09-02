import QtQuick
import "metar.js" as Met

// A station-model wind barb inside a compass rose.
//
// The staff points *from* the station *towards* where the wind is coming from —
// a 270 wind puts the staff out to the west — and the barbs hang off the far
// end. A pennant is 50 kt, a full barb 10, a half barb 5, and under 3 kt there
// is no staff at all, just the open circle that means calm.
//
// The rose is not decoration. A barb with no reference frame is a stick at an
// arbitrary angle; with the cardinal ticks behind it the direction is readable
// without going to the text beside it.
//
// The barb is drawn pointing north in its own layer and rotated, so a shifting
// wind is a transform rather than a repaint, and so the rose stays upright.
Item {
  id: root

  property real direction: NaN     // degrees the wind is coming from
  property real speedKt: NaN
  property real gustKt: NaN
  property color stroke: "white"
  property color roseColor: stroke
  property real thickness: 1.6
  property bool animate: true

  readonly property var barb: Met.windBarb(speedKt)
  readonly property bool variable: !isFinite(direction) || direction <= 0
  readonly property bool calm: barb.calm

  // Gusts are the wind being unsteady, so the barb is unsteady too — the sway
  // is proportional to the spread between the lull and the peak. It is a real
  // quantity being shown, not an idle flourish, and it stops when the wind is
  // steady.
  readonly property real gustSpread: (isFinite(gustKt) && isFinite(speedKt) && gustKt > speedKt)
    ? Math.min(12, gustKt - speedKt) : 0

  implicitWidth: 64
  implicitHeight: 64

  // Rotation has to take the short way round: a wind backing from 350 to 010 is
  // a twenty degree shift, not a three hundred and forty degree spin.
  property real renderDir: 0
  property bool dirInitialised: false

  function retarget() {
    var target = variable ? 0 : direction
    if (!isFinite(target)) target = 0
    if (!dirInitialised) {
      dirInitialised = true
      renderDir = target
      return
    }
    var delta = ((target - renderDir) % 360 + 540) % 360 - 180
    renderDir += delta
  }

  onDirectionChanged: retarget()
  onVariableChanged: retarget()
  Component.onCompleted: retarget()

  Behavior on renderDir {
    enabled: root.animate
    NumberAnimation { duration: 800; easing.type: Easing.OutCubic }
  }

  property real sway: 0
  SequentialAnimation on sway {
    running: root.animate && root.gustSpread > 0 && !root.calm
    loops: Animation.Infinite
    NumberAnimation { to: root.gustSpread; duration: 1600; easing.type: Easing.InOutSine }
    NumberAnimation { to: -root.gustSpread * 0.6; duration: 2100; easing.type: Easing.InOutSine }
  }

  onStrokeChanged: { rose.requestPaint(); barbCanvas.requestPaint() }
  onSpeedKtChanged: barbCanvas.requestPaint()

  // ---- The rose, which never turns ----
  Canvas {
    id: rose
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = width / 2, cy = height / 2
      var r = Math.min(width, height) * 0.44

      ctx.strokeStyle = root.roseColor
      ctx.lineWidth = 1
      ctx.globalAlpha = 0.18
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.stroke()

      // Cardinal ticks, with north given a longer one so the rose has a
      // top without needing a letter.
      for (var i = 0; i < 4; i++) {
        var a = i * Math.PI / 2 - Math.PI / 2
        var inner = r * (i === 0 ? 0.74 : 0.85)
        ctx.globalAlpha = i === 0 ? 0.42 : 0.22
        ctx.beginPath()
        ctx.moveTo(cx + Math.cos(a) * inner, cy + Math.sin(a) * inner)
        ctx.lineTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r)
        ctx.stroke()
      }

      // Intercardinals, fainter still.
      ctx.globalAlpha = 0.12
      for (var j = 0; j < 4; j++) {
        var b = j * Math.PI / 2 + Math.PI / 4 - Math.PI / 2
        ctx.beginPath()
        ctx.moveTo(cx + Math.cos(b) * r * 0.92, cy + Math.sin(b) * r * 0.92)
        ctx.lineTo(cx + Math.cos(b) * r, cy + Math.sin(b) * r)
        ctx.stroke()
      }
    }
  }

  // ---- The barb, drawn pointing north and rotated into place ----
  Item {
    id: barbLayer
    anchors.fill: parent
    rotation: root.variable ? 0 : (root.renderDir + root.sway)

    Canvas {
      id: barbCanvas
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

        var cx = width / 2, cy = height / 2
        var dotR = Math.max(2.0, Math.min(width, height) * 0.05)

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

        var b = root.barb
        var staff = Math.min(width, height) * 0.40
        var barbLen = staff * 0.46
        var step = staff * 0.155        // spacing between barbs down the staff
        var lean = 0.42                 // how far the barbs rake back to the staff

        ctx.translate(cx, cy)

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
      }
    }
  }

  // Variable winds get a label, since the staff direction is meaningless.
  Text {
    textFormat: Text.PlainText
    visible: root.variable && !root.calm
    text: "VRB"
    color: root.stroke
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    font.pixelSize: Math.max(8, root.height * 0.14)
    opacity: 0.75
  }
}
