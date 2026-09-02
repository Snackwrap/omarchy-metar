import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "metar.js" as Met

// Pulls the current observation and terminal forecast for one airfield from
// aviationweather.gov, decodes them, exposes a `label`/`tooltip`/`categoryColor`
// for the bar pill, and renders the tabbed popup.
//
// The station is either named outright in the settings or resolved as the
// nearest reporting field to the viewer's location — the same location the
// built-in weather widget uses, so it needs no separate setup.
Panel {
  id: root
  moduleName: "com.leafbox.metar"
  ipcTarget: "com.leafbox.metar"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Live clock tick, so the age of the observation advances without refetching.
  property double nowMs: Date.now()

  // Which popup tab is showing: now | forecast | nearby | raw. `view` is
  // derived rather than latched at startup: the settings object is handed to
  // this panel before its values are populated, so anything that samples a
  // setting once on the way up reads the default and never corrects itself.
  property string chosenView: ""
  readonly property string defaultTab: {
    var t = String(setting("defaultTab", "now"))
    return (t === "forecast" || t === "nearby" || t === "raw") ? t : "now"
  }
  readonly property string view: chosenView !== "" ? chosenView : defaultTab

  // nf-fa-plane. Written as an escape rather than the literal character: it
  // lives in the Unicode private use area, where plenty of editors and
  // pipelines quietly drop it.
  readonly property string glyph: "\uf072"

  readonly property string api: "https://aviationweather.gov/api/data/"
  readonly property string ua: "omarchy-metar/0.1"

  // ---- Settings ---------------------------------------------------------
  function boolSetting(name, dflt) { var v = setting(name, dflt); return v === true || v === "true" || v === 1 }
  readonly property string wantedStation: String(setting("station", "")).toUpperCase().replace(/[^A-Z0-9]/g, "")
  readonly property bool zulu: String(setting("timeFormat", "local")) === "zulu"
  readonly property bool fahrenheit: String(setting("temperature", "C")) === "F"
  readonly property string pillContent: String(setting("pillContent", "category"))
  readonly property int runwayHeading: {
    var v = parseInt(String(setting("runwayHeading", "")).replace(/[^0-9]/g, ""), 10)
    return (isFinite(v) && v > 0 && v <= 360) ? v : -1
  }
  readonly property string alertCategory: String(setting("alertCategory", "off"))

  // ---- Location ---------------------------------------------------------
  // Inherited from the built-in weather widget, which stores whatever the user
  // set with `omarchy-weather-location`. That may be only a name, so a bare
  // name gets geocoded through the same service the weather panel uses.
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property string geocodedFor: ""
  property double geocodedLat: NaN
  property double geocodedLon: NaN

  FileView {
    id: weatherFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var d = JSON.parse(text())
        root.weatherLocation = {
          name: typeof d.name === "string" ? d.name : "",
          latitude: parseFloat(d.latitude),
          longitude: parseFloat(d.longitude)
        }
      } catch (e) { /* leave the fallback in place */ }
    }
    onLoadFailed: root.weatherLocation = ({ name: "", latitude: null, longitude: null })
  }

  // The first read can race shell startup, the same way the weather widget's does.
  Timer { interval: 1500; running: true; onTriggered: weatherFile.reload() }

  readonly property string weatherName: String(weatherLocation.name || "").replace(/^\s+|\s+$/g, "")
  readonly property double ownLat: parseFloat(String(setting("latitude", "")))
  readonly property double ownLon: parseFloat(String(setting("longitude", "")))
  readonly property bool hasOwnCoords: isFinite(ownLat) && isFinite(ownLon) &&
                                       Math.abs(ownLat) <= 90 && Math.abs(ownLon) <= 180
  readonly property double weatherLat: parseFloat(String(weatherLocation.latitude))
  readonly property double weatherLon: parseFloat(String(weatherLocation.longitude))
  readonly property bool weatherHasCoords: isFinite(weatherLat) && isFinite(weatherLon)

  readonly property double siteLat: hasOwnCoords ? ownLat : (weatherHasCoords ? weatherLat : geocodedLat)
  readonly property double siteLon: hasOwnCoords ? ownLon : (weatherHasCoords ? weatherLon : geocodedLon)
  readonly property bool hasSite: isFinite(siteLat) && isFinite(siteLon)
  readonly property bool needsGeocode: !hasOwnCoords && !weatherHasCoords && weatherName !== ""

  onNeedsGeocodeChanged: if (needsGeocode && weatherName !== geocodedFor) geocodeProc.running = true
  onWeatherNameChanged: if (needsGeocode && weatherName !== geocodedFor) geocodeProc.running = true

  Process {
    id: geocodeProc
    command: ["curl", "-fsS", "-A", root.ua, "--max-time", "8",
              "https://geocoding-api.open-meteo.com/v1/search?name="
              + encodeURIComponent(root.weatherName) + "&count=1&language=en&format=json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var r = JSON.parse(String(text || "")).results
          if (r && r.length) {
            root.geocodedLat = parseFloat(r[0].latitude)
            root.geocodedLon = parseFloat(r[0].longitude)
            // Remember which name these came from, so a later rename refetches
            // and a failed lookup is not mistaken for a good one.
            root.geocodedFor = root.weatherName
          }
        } catch (e) { /* leave the location unresolved */ }
      }
    }
  }

  // ---- Fetched state ----------------------------------------------------
  property var obs: null              // the chosen station's observation
  property var nearby: []             // every station in the box, nearest first
  property var tafPeriodList: []
  property string rawTaf: ""
  property double tafIssuedMs: 0
  property string tafFor: ""          // which station the loaded TAF belongs to
  property bool loading: false
  property string lastError: ""

  readonly property string stationId: obs ? String(obs.icaoId || "") : ""
  readonly property string stationName: obs ? String(obs.name || "") : ""

  // ---- Derived observation ----------------------------------------------
  readonly property double visSM: obs ? Met.visibilitySM(obs.visib) : NaN
  readonly property bool visPlus: obs ? Met.visibilityIsPlus(obs.visib) : false
  readonly property var ceilFt: obs ? Met.ceilingFt(obs.clouds, obs.vertVis) : null
  // The API publishes its own category; ours is computed so the same rule can
  // colour the forecast, which does not come categorised. They are checked
  // against each other in tools/test-metar.mjs — prefer ours so the panel is
  // internally consistent, and fall back to theirs if a field is missing.
  readonly property string category: {
    if (!obs) return ""
    var c = Met.flightCategory(visSM, ceilFt)
    return c !== "" ? c : String(obs.fltCat || "")
  }
  readonly property double observedMs: obs ? Number(obs.obsTime) * 1000 : NaN
  readonly property double ageMin: obs ? Met.ageMinutes(observedMs, nowMs) : NaN
  readonly property bool stale: obs ? Met.isStale(observedMs, nowMs) : false

  readonly property double windDir: obs && obs.wdir !== null && obs.wdir !== undefined ? Number(obs.wdir) : NaN
  readonly property double windKt: obs ? Number(obs.wspd) : NaN
  readonly property double gustKt: obs && obs.wgst !== null && obs.wgst !== undefined ? Number(obs.wgst) : NaN
  readonly property var crosswind: (runwayHeading > 0 && isFinite(windDir) && isFinite(windKt))
    ? Met.crosswindKt(windDir, windKt, runwayHeading) : null

  readonly property var densityAlt: obs
    ? Met.densityAltitudeFt(obs.elev !== null ? Number(obs.elev) * 3.28084 : NaN, Number(obs.altim), Number(obs.temp))
    : null

  // Category colours are the ones every aviation chart uses. They are held
  // fixed rather than themed, because the mapping green/blue/red/magenta is
  // the convention a pilot already reads without thinking.
  function colorFor(cat) {
    switch (String(cat || "").toUpperCase()) {
    case "VFR": return "#3fb950"
    case "MVFR": return "#4d9fff"
    case "IFR": return "#f0563f"
    case "LIFR": return "#d972e8"
    }
    return String(Color.muted)
  }
  readonly property string categoryColor: category !== "" && !stale ? colorFor(category) : ""

  // ---- Bar pill ---------------------------------------------------------
  readonly property string label: {
    if (!obs) return glyph
    if (pillContent === "station") return glyph + "  " + stationId
    if (pillContent === "both") return glyph + "  " + stationId + " " + category
    if (pillContent === "wind") {
      if (!isFinite(windKt) || windKt === 0) return glyph + "  calm"
      return glyph + "  " + (isFinite(windDir) && windDir > 0 ? Met.cardinal(windDir) : "VRB")
             + " " + Math.round(windKt)
    }
    return glyph + "  " + category
  }

  readonly property string tooltip: {
    if (lastError !== "") return "Aviation weather — " + lastError
    if (!obs) return "Aviation weather — loading"
    var parts = [stationId + (stationName !== "" ? " · " + stationName : "")]
    parts.push(Met.categoryName(category) + " — " + Met.formatVisibility(visSM, visPlus)
               + ", ceiling " + Met.formatCeiling(ceilFt))
    parts.push(Met.formatWind(windDir, windKt, gustKt))
    if (stale) parts.push("No report for " + Met.formatAge(ageMin))
    return parts.join("\n")
  }

  // ---- Notification -----------------------------------------------------
  // Opt-in, and only on the transition into the bad category, so a foggy
  // morning does not fire once a minute until it lifts.
  property string notifiedCategory: ""
  Process { id: notifyProc; command: ["true"] }

  onCategoryChanged: {
    if (alertCategory === "off" || category === "" || stale) return
    if (Met.categoryRank(category) > Met.categoryRank(alertCategory)) {
      // Back above the threshold — arm the alert again.
      notifiedCategory = ""
      return
    }
    if (notifiedCategory === category) return
    notifiedCategory = category
    notifyProc.command = ["omarchy-notification-send", "-g", glyph, "-u", "normal",
                          stationId + " is " + category,
                          Met.formatVisibility(visSM, visPlus) + ", ceiling " + Met.formatCeiling(ceilFt)]
    notifyProc.running = true
  }

  // ---- Networking -------------------------------------------------------
  // The bar routes shell.summon/toggle to the widget, which forwards to this
  // name — without it the pill still opens on a click but IPC does nothing.
  function openFromHotkey() { open() }

  function curlTo(url, seconds) {
    return ["curl", "-fsS", "-A", ua, "--max-time", String(seconds), url]
  }

  function refresh() {
    if (loading) return
    if (wantedStation !== "") {
      loading = true
      stationProc.command = curlTo(api + "metar?ids=" + wantedStation + "&format=json", 15)
      stationProc.running = true
      return
    }
    var box = bboxString()
    if (box === "") return          // no location resolved yet; onHasSiteChanged retries
    loading = true
    boxProc.command = curlTo(api + "metar?bbox=" + box + "&format=json", 20)
    boxProc.running = true
  }

  function fetchTaf() {
    if (stationId === "" || tafProc.running) return
    tafProc.command = curlTo(api + "taf?ids=" + stationId + "&format=json", 15)
    tafProc.running = true
  }

  Component.onCompleted: refresh()

  // Refetch when the resolved location or the named station changes.
  onHasSiteChanged: if (hasSite && !obs) refresh()
  onWantedStationChanged: { obs = null; tafFor = ""; refresh() }

  // Observations are issued about hourly, with unscheduled specials in
  // between, so ten minutes keeps the pill honest without hammering a public
  // government service. The forecast is reissued every six hours.
  Timer { interval: 600000; running: true; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

  // Opening the panel is a good moment to be current.
  onOpenedChanged: if (opened) refresh()

  function applyObs(list) {
    if (!list || !list.length) { lastError = "no observation"; return }
    lastError = ""
    if (hasSite) {
      // Order by distance so the nearest is first and the Nearby tab is sorted.
      for (var i = 0; i < list.length; i++) {
        list[i]._nm = Met.distanceNm(siteLat, siteLon, Number(list[i].lat), Number(list[i].lon))
        list[i]._brg = Met.bearingDeg(siteLat, siteLon, Number(list[i].lat), Number(list[i].lon))
      }
      list.sort(function (a, b) { return a._nm - b._nm })
    }
    nearby = list
    obs = list[0]
    // The forecast belongs to a station, so refetch it whenever that changes.
    if (stationId !== "" && tafFor !== stationId) fetchTaf()
  }

  Process {
    id: stationProc
    command: ["true"]               // replaced in refresh(), see bboxString()
    onExited: root.loading = false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.applyObs(JSON.parse(String(text || "")))
        } catch (e) { root.lastError = "could not read the observation" }
      }
    }
  }

  // One box query gives the nearest reporting field *and* the neighbours, so
  // resolving the station costs nothing extra over filling the Nearby tab.
  // A function rather than a bound property: refresh() runs from inside the
  // change handler for the location, and a property depending on that same
  // location still reads its previous value at that point — which built the
  // URL with an empty box and quietly fetched nothing.
  function bboxString() {
    if (!hasSite) return ""
    var pad = 1.1                                   // degrees of latitude, ~66 nm
    var lonPad = pad / Math.max(0.2, Math.cos(siteLat * Math.PI / 180))
    return [(siteLat - pad).toFixed(3), (siteLon - lonPad).toFixed(3),
            (siteLat + pad).toFixed(3), (siteLon + lonPad).toFixed(3)].join(",")
  }

  Process {
    id: boxProc
    command: ["true"]               // replaced in refresh(), see bboxString()
    onExited: root.loading = false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var list = JSON.parse(String(text || ""))
          if (!list || !list.length) { root.lastError = "no station reporting nearby"; return }
          root.applyObs(list)
        } catch (e) { root.lastError = "could not read the observations" }
      }
    }
  }

  Process {
    id: tafProc
    command: ["true"]               // replaced in fetchTaf()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || ""))
          if (!arr || !arr.length) {
            // Plenty of fields report a METAR and no TAF at all; that is normal
            // and the tab says so rather than looking broken.
            root.tafPeriodList = []
            root.rawTaf = ""
            root.tafFor = root.stationId
            return
          }
          var t = arr[0]
          root.rawTaf = String(t.rawTAF || "")
          root.tafIssuedMs = Number(t.issueTime ? Date.parse(t.issueTime) : 0)
          root.tafPeriodList = Met.tafPeriods(t.fcsts)
          root.tafFor = root.stationId
        } catch (e) { root.tafPeriodList = []; root.rawTaf = "" }
      }
    }
  }

  readonly property var deterioration: tafPeriodList.length
    ? Met.nextDeterioration(tafPeriodList, nowMs, category) : null

  // ---- Formatting -------------------------------------------------------
  function clock(ms) {
    var d = new Date(ms)
    if (!isFinite(ms)) return "--"
    var h = zulu ? d.getUTCHours() : d.getHours()
    var m = zulu ? d.getUTCMinutes() : d.getMinutes()
    return (h < 10 ? "0" + h : h) + ":" + (m < 10 ? "0" + m : m) + (zulu ? "Z" : "")
  }

  function dayClock(ms) {
    var d = new Date(ms)
    if (!isFinite(ms)) return "--"
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return days[zulu ? d.getUTCDay() : d.getDay()] + " " + clock(ms)
  }

  function temp(c) {
    var v = Number(c)
    if (!isFinite(v)) return "--"
    return fahrenheit ? (Math.round(Met.cToF(v)) + "°F") : (Math.round(v) + "°C")
  }

  function skyText() {
    if (!obs) return "--"
    var layers = obs.clouds || []
    if (!layers.length) return "clear"
    var out = []
    for (var i = 0; i < layers.length; i++) {
      var l = layers[i]
      var name = Met.cloudLabel(l.cover)
      if (l.base === null || l.base === undefined) out.push(name)
      else out.push(name + " " + Number(l.base).toLocaleString() + " ft")
    }
    return out.join(", ")
  }

  function periodSummary(p) {
    var bits = []
    bits.push(Met.formatVisibility(p.visSM, p.visPlus))
    bits.push(p.ceilFt === null ? "no ceiling" : Met.formatCeiling(p.ceilFt))
    if (isFinite(p.wspd) && p.wspd > 0) {
      bits.push((p.wdir !== null && isFinite(p.wdir) && p.wdir > 0 ? Met.cardinal(p.wdir) : "VRB")
                + " " + Math.round(p.wspd) + (p.wgst ? "G" + Math.round(p.wgst) : ""))
    }
    var wx = Met.decodeWx(p.wx)
    if (wx !== "") bits.push(wx)
    return bits.join(" · ")
  }

  // ---- Popup ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: String(root.setting("popupPosition", "icon")) === "center"
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // Masthead: glyph and wordmark, with the station on the right.
        Item {
          width: parent.width
          height: brandRow.implicitHeight

          Row {
            id: brandRow
            spacing: Style.space(7)
            anchors.left: parent.left
            Text {
              text: root.glyph
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "AVIATION WEATHER"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(11)
              font.bold: true
              font.letterSpacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.obs ? (root.stationId + (root.obs._nm !== undefined
                  ? "  ·  " + Math.round(root.obs._nm) + " nm " + Met.cardinal(root.obs._brg) : "")) : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
          }
        }

        // Headline: the category, at the size it deserves, plus the field name.
        Column {
          width: parent.width
          spacing: Style.space(1)

          Row {
            spacing: Style.space(9)
            Text {
              text: root.category !== "" ? root.category : "—"
              color: root.category !== "" ? root.colorFor(root.category) : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(26)
              font.bold: true
              anchors.bottom: parent.bottom
            }
            Text {
              text: root.category !== "" ? Met.categoryName(root.category) : (root.lastError !== "" ? root.lastError : "loading")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.space(14)
              anchors.bottom: parent.bottom
              bottomPadding: Style.space(4)
            }
          }

          Text {
            width: parent.width
            text: root.stationName
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(12)
            elide: Text.ElideRight
          }

          // A report that has stopped arriving is worse than no report, because
          // it still looks like weather. Say it plainly.
          Text {
            visible: root.stale && root.obs
            width: parent.width
            text: "No report for " + Met.formatAge(root.ageMin) + " — this may be out of date"
            color: root.colorFor("IFR")
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
            wrapMode: Text.WordWrap
          }
        }

        ButtonGroup {
          options: [
            { value: "now", label: "Now" },
            { value: "forecast", label: "Forecast" },
            { value: "nearby", label: "Nearby" },
            { value: "raw", label: "Raw" }
          ]
          value: root.view
          focusable: false
          foreground: Color.popups.text
          background: Color.popups.background
          accent: Color.accent
          fontSize: Style.space(12)
          onChanged: function (v) { root.chosenView = v }
        }

        // ---- Now ----
        Column {
          visible: root.view === "now"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "OBSERVED " + root.clock(root.observedMs)
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          // Wind barb beside the wind in words: the symbol for the glance, the
          // sentence for the detail.
          Row {
            width: parent.width
            spacing: Style.space(12)

            WindBarb {
              width: Style.space(72)
              height: Style.space(72)
              direction: root.windDir
              speedKt: root.windKt
              stroke: Color.popups.text
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.space(84)
              spacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                text: Met.formatWind(root.windDir, root.windKt, root.gustKt)
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(14)
                wrapMode: Text.WordWrap
              }
              Text {
                visible: root.crosswind !== null
                text: "Crosswind " + (root.crosswind !== null ? Math.round(root.crosswind) : 0)
                      + " kt on runway " + Math.round(root.runwayHeading / 10)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
              }
              Text {
                visible: Met.decodeWx(root.obs ? root.obs.wxString : "") !== ""
                width: parent.width
                text: Met.decodeWx(root.obs ? root.obs.wxString : "")
                color: root.colorFor("MVFR")
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
                wrapMode: Text.WordWrap
              }
            }
          }

          PanelSeparator { foreground: Color.popups.text }

          Column {
            width: parent.width
            spacing: Style.space(3)
            StatRow {
              label: "Visibility"
              value: Met.formatVisibility(root.visSM, root.visPlus)
              highlight: isFinite(root.visSM) && root.visSM <= 5
            }
            StatRow {
              label: "Ceiling"
              value: Met.formatCeiling(root.ceilFt)
              highlight: root.ceilFt !== null && root.ceilFt <= 3000
            }
            StatRow {
              label: "Temp / dewpoint"
              value: root.obs ? (root.temp(root.obs.temp) + " / " + root.temp(root.obs.dewp)) : "--"
              note: {
                var rh = root.obs ? Met.relativeHumidity(root.obs.temp, root.obs.dewp) : null
                return rh === null ? "" : Math.round(rh) + "% humidity"
              }
            }
            StatRow {
              label: "Altimeter"
              value: root.obs && isFinite(Number(root.obs.altim))
                ? Met.hPaToInHg(root.obs.altim).toFixed(2) + " inHg" : "--"
              note: root.obs && isFinite(Number(root.obs.altim))
                ? Math.round(Number(root.obs.altim)) + " hPa" : ""
            }
            StatRow {
              visible: root.densityAlt !== null
              label: "Density altitude"
              value: root.densityAlt !== null ? Number(root.densityAlt).toLocaleString() + " ft" : "--"
              note: root.obs && root.obs.elev !== null
                ? "field " + Math.round(Number(root.obs.elev) * 3.28084).toLocaleString() + " ft" : ""
            }

            // Sky gets a full-width row of its own: three or four layers do not
            // fit the note column, and truncating them loses the ceiling.
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: Style.space(150)
                text: "Sky"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(13)
              }
              Text {
                width: parent.width - Style.space(158)
                text: root.skyText()
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(13)
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---- Forecast ----
        Column {
          visible: root.view === "forecast"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.rawTaf !== "" ? "TAF ISSUED " + root.clock(root.tafIssuedMs) : "TERMINAL FORECAST"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          Text {
            visible: root.tafPeriodList.length === 0
            width: parent.width
            text: root.tafFor === root.stationId
              ? root.stationId + " does not publish a terminal forecast. Most fields that issue one are towered airports; the Nearby tab will show which."
              : "Loading the forecast…"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(12)
            wrapMode: Text.WordWrap
          }

          TafTimeline {
            visible: root.tafPeriodList.length > 0
            width: parent.width
            periods: root.tafPeriodList
            nowMs: root.nowMs
            categoryColor: root.colorFor
            gridColor: Color.muted
            labelColor: Color.muted
            fontFamily: Style.font.family
            labelSize: Style.space(10)
            zulu: root.zulu
          }

          // The one line a pilot actually scans a TAF for.
          Text {
            visible: root.deterioration !== null
            width: parent.width
            text: root.deterioration
              ? ("Deteriorating to " + root.deterioration.category + " from "
                 + root.dayClock(root.deterioration.from))
              : ""
            color: root.deterioration ? root.colorFor(root.deterioration.category) : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(13)
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.space(5)

            Repeater {
              model: root.tafPeriodList
              Row {
                id: pr
                required property var modelData
                width: parent ? parent.width : 0
                spacing: Style.space(8)

                Rectangle {
                  width: Style.space(3)
                  height: Style.space(28)
                  radius: Style.space(2)
                  color: root.colorFor(pr.modelData.category)
                  opacity: pr.modelData.transient ? 0.55 : 1.0
                }
                Column {
                  width: pr.width - Style.space(14)
                  spacing: Style.space(1)
                  Text {
                    text: root.dayClock(pr.modelData.from) + "  "
                          + (pr.modelData.transient
                             ? (pr.modelData.probability ? "PROB" + pr.modelData.probability : "TEMPO")
                             : pr.modelData.category)
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.space(12)
                  }
                  Text {
                    width: parent.width
                    text: root.periodSummary(pr.modelData)
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.space(11)
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }

        // ---- Nearby ----
        Column {
          visible: root.view === "nearby"
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: root.hasSite ? "REPORTING WITHIN ~66 NM" : "NEARBY STATIONS"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          Text {
            visible: root.nearby.length <= 1
            width: parent.width
            text: root.wantedStation !== ""
              ? "Set the station back to blank, or set a latitude and longitude, to see neighbouring fields."
              : "No other station is reporting nearby."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(12)
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.nearby.slice(0, 12)
            Row {
              id: nr
              required property var modelData
              width: parent ? parent.width : 0
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(3)
                height: Style.space(15)
                radius: Style.space(2)
                color: root.colorFor(Met.flightCategory(
                  Met.visibilitySM(nr.modelData.visib),
                  Met.ceilingFt(nr.modelData.clouds, nr.modelData.vertVis)))
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                width: Style.space(46)
                text: String(nr.modelData.icaoId || "")
                color: nr.modelData.icaoId === root.stationId ? Color.accent : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
                font.bold: nr.modelData.icaoId === root.stationId
              }
              Text {
                width: Style.space(52)
                text: nr.modelData._nm !== undefined ? (Math.round(nr.modelData._nm) + " nm") : ""
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
                horizontalAlignment: Text.AlignRight
              }
              Text {
                width: nr.width - Style.space(120)
                text: String(nr.modelData.name || "")
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
                elide: Text.ElideRight
              }
            }
          }
        }

        // ---- Raw ----
        Column {
          visible: root.view === "raw"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "METAR"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }
          Text {
            width: parent.width
            text: root.obs ? String(root.obs.rawOb || "") : "—"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
            wrapMode: Text.WrapAnywhere
          }

          PanelSectionHeader {
            visible: root.rawTaf !== ""
            text: "TAF"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }
          Text {
            visible: root.rawTaf !== ""
            width: parent.width
            text: root.rawTaf
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
            wrapMode: Text.WrapAnywhere
          }

          Text {
            width: parent.width
            text: "Source: NOAA / NWS Aviation Weather Center. For situational awareness only — not for flight planning."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.space(10)
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component StatRow: Row {
    id: sr
    property string label: ""
    property string value: ""
    property string note: ""
    property bool highlight: false
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      width: Style.space(150)
      text: sr.label
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      elide: Text.ElideRight
    }
    Text {
      width: Style.space(104)
      text: sr.value
      color: sr.highlight ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      font.bold: sr.highlight
    }
    Text {
      width: Math.max(Style.space(20), sr.width - Style.space(150 + 104 + 16))
      text: sr.note
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: Style.space(12)
    }
  }
}
