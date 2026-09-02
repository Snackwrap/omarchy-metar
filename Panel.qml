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
  property var panelFrame: null
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
  readonly property string ua: "omarchy-metar/0.2"

  // ---- Settings ---------------------------------------------------------
  function boolSetting(name, dflt) { var v = setting(name, dflt); return v === true || v === "true" || v === 1 }
  // Becomes part of a request URL, so it is held to the shape and length an
  // ICAO identifier actually has rather than trusted to be one.
  readonly property string wantedStation:
    String(setting("station", "")).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6)
  readonly property bool zulu: String(setting("timeFormat", "local")) === "zulu"
  readonly property bool fahrenheit: String(setting("temperature", "C")) === "F"
  readonly property string pillContent: String(setting("pillContent", "category"))
  readonly property int runwayHeading: {
    var v = parseInt(String(setting("runwayHeading", "")).replace(/[^0-9]/g, ""), 10)
    return (isFinite(v) && v > 0 && v <= 360) ? v : -1
  }
  readonly property string alertCategory: String(setting("alertCategory", "off"))
  // One switch for every flourish: the barb's turn and gust sway, the forecast
  // wipe, and the colour fades. Off leaves the panel completely still.
  readonly property bool animOn: boolSetting("animations", true)
  // Screenshot helper. The popup is drawn inside a fullscreen layer surface, so
  // nothing outside the shell can work out its rectangle — the compositor only
  // sees the surface. With this on the panel prints its own rect on open, which
  // is what tools/capture-preview.sh crops to. Exact, and immune to whatever
  // else happens to be moving on the desktop.
  readonly property bool debugGeometry: boolSetting("debugGeometry", false)

  // ---- Location ---------------------------------------------------------
  // Inherited from the built-in weather widget, which stores whatever the user
  // set with `omarchy-weather-location`. That may be only a name, so a bare
  // name gets geocoded through the same service the weather panel uses.
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property string geocodedFor: ""
  property double geocodedLat: NaN
  property double geocodedLon: NaN

  // The location file is small and predictable, but it is still a path anything
  // can write. FileView has no size cap and no regular-file check, and calling
  // text() on a planted FIFO would block a long-lived shell forever, so it is
  // kept purely as a watcher and the read goes through a reader that is bounded
  // in both directions: `head -c` caps the bytes, `timeout` caps the wait.
  readonly property string weatherPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"

  FileView {
    id: weatherFile
    path: root.weatherPath
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: weatherReadTimer.restart()
  }

  // Coalesce bursts of writes into one read.
  Timer { id: weatherReadTimer; interval: 250; onTriggered: weatherReader.running = true }

  // The first read can race shell startup, the same way the weather widget's does.
  Timer { interval: 1500; running: true; onTriggered: weatherReader.running = true }

  Process {
    id: weatherReader
    command: ["timeout", "2", "head", "-c", "8192", "--", root.weatherPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.length === 0 || raw.length > 8192) return
        try {
          var d = JSON.parse(raw)
          root.weatherLocation = {
            name: typeof d.name === "string" ? root.safe(d.name, 80) : "",
            latitude: parseFloat(d.latitude),
            longitude: parseFloat(d.longitude)
          }
        } catch (e) { /* leave the fallback in place */ }
      }
    }
  }

  // Also becomes part of a request URL.
  readonly property string weatherName:
    String(weatherLocation.name || "").replace(/^\s+|\s+$/g, "").slice(0, 80)
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
          var parsed = root.parseBounded(text)
          var r = parsed ? parsed.results : null
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

  // Both come from the API and both are displayed; the identifier also goes
  // into a URL, so it is held to the shape an ICAO code actually has.
  readonly property string stationId: obs ? String(obs.icaoId || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6) : ""
  readonly property string stationName: obs ? safe(obs.name, 48) : ""

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
    if (pillContent === "station") return glyph + "  " + safeBare(stationId, 6)
    if (pillContent === "both") return glyph + "  " + safeBare(stationId, 6) + " " + category
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
                          safe(stationId, 6) + " is " + category,
                          safe(Met.formatVisibility(visSM, visPlus) + ", ceiling " + Met.formatCeiling(ceilFt), 80)]
    notifyProc.running = true
  }

  // ---- Networking -------------------------------------------------------
  // Station identifiers are ours or the API's, but the URL still gets built
  // from remote data, so it goes to Qt.openUrlExternally behind a scheme check
  // rather than through a shell.
  function openLink(u) {
    var t = String(u || "")
    if (t.indexOf("https://") !== 0) return
    Qt.openUrlExternally(t)
  }

  readonly property var resources: {
    var id = stationId
    if (id === "") return []
    return [
      { label: "Full report at the Aviation Weather Center",
        url: "https://aviationweather.gov/data/metar/?id=" + id + "&taf=true" },
      { label: "Graphical forecast for the area",
        url: "https://aviationweather.gov/gfa/" },
      { label: id + " on SkyVector",
        url: "https://skyvector.com/airport/" + id }
    ]
  }

  // The bar routes shell.summon/toggle to the widget, which forwards to this
  // name — without it the pill still opens on a click but IPC does nothing.
  function openFromHotkey() { open() }

  // ---- Remote data hygiene ----------------------------------------------
  // Everything below arrives from a public API and ends up in a Text element or
  // a notification. Two ceilings rather than one: curl refuses to download more
  // than maxResponseBytes (the producer side, which also covers a server that
  // simply never stops sending), and parseBounded rejects anything that got
  // past it — a chunked response has no Content-Length for curl to check.
  readonly property int maxResponseBytes: 262144
  readonly property int maxFieldChars: 72

  function curlTo(url, seconds) {
    return ["curl", "-fsS", "-A", ua,
            "--proto", "=https",                 // refuse anything but https
            "--max-time", String(seconds),
            "--max-filesize", String(maxResponseBytes),
            url]
  }

  function parseBounded(raw) {
    var text = String(raw || "")
    if (text.length === 0 || text.length > maxResponseBytes) return null
    return JSON.parse(text)
  }

  // Qt's Text defaults to AutoText, which renders a string as *rich* text when
  // it looks like markup. Every remote value is therefore forced through here:
  // control characters out, length clamped, and the Text elements that show
  // them are pinned to PlainText besides.
  // For the bar pill and its tooltip: those render in Text elements the shell
  // owns, so `textFormat` is not ours to set and the markup has to come out of
  // the string instead of being neutralised at the sink.
  function safeBare(v, limit) {
    return safe(v, limit).replace(/[<>&]/g, " ")
  }

  function safe(v, limit) {
    var text = String(v === null || v === undefined ? "" : v)
    text = text.replace(/[\u0000-\u001F\u007F]+/g, " ").replace(/^\s+|\s+$/g, "")
    var cap = limit || maxFieldChars
    return text.length > cap ? text.slice(0, cap) + "\u2026" : text
  }

  // An array from a remote payload is capped before anything walks it, so a
  // hostile or broken response cannot turn into tens of thousands of delegates.
  function boundedList(v, cap) {
    if (!v || !v.length) return []
    return v.length > cap ? v.slice(0, cap) : v
  }

  // Every request is stamped with the generation and the station it was made
  // for, and a completion whose stamp no longer matches is discarded. Without
  // this a forecast that was in flight when the station changed would be
  // accepted and then marked as belonging to the *new* airfield — stale data
  // wearing the right label, which is worse than no data.
  property int fetchGen: 0
  property int stationGen: -1
  property int boxGen: -1
  property int tafGen: -1
  property string tafRequestedFor: ""

  function invalidate() {
    fetchGen += 1
    // Reap anything still in flight for the previous generation rather than
    // letting it land late.
    if (stationProc.running) stationProc.running = false
    if (boxProc.running) boxProc.running = false
    if (tafProc.running) tafProc.running = false
    loading = false
  }

  function refresh() {
    if (loading) return
    if (wantedStation !== "") {
      loading = true
      stationGen = fetchGen
      stationProc.command = curlTo(api + "metar?ids=" + wantedStation + "&format=json", 15)
      stationProc.running = true
      return
    }
    var box = bboxString()
    if (box === "") return          // no location resolved yet; onHasSiteChanged retries
    loading = true
    boxGen = fetchGen
    boxProc.command = curlTo(api + "metar?bbox=" + box + "&format=json", 20)
    boxProc.running = true
  }

  function fetchTaf() {
    if (stationId === "") return
    // A forecast already in flight for a different station is superseded, not
    // a reason to skip: the previous behaviour refused the new request and then
    // stamped the old answer with the new station's id.
    if (tafProc.running) {
      if (tafRequestedFor === stationId) return
      tafProc.running = false
    }
    tafGen = fetchGen
    tafRequestedFor = stationId
    tafProc.command = curlTo(api + "taf?ids=" + stationId + "&format=json", 15)
    tafProc.running = true
  }

  Component.onCompleted: refresh()

  // Refetch when the resolved location or the named station changes.
  onHasSiteChanged: if (hasSite && !obs) refresh()
  onWantedStationChanged: { invalidate(); obs = null; tafFor = ""; tafPeriodList = []; rawTaf = ""; refresh() }
  onSiteLatChanged: if (wantedStation === "") invalidate()
  onSiteLonChanged: if (wantedStation === "") invalidate()

  // Observations are issued about hourly, with unscheduled specials in
  // between, so ten minutes keeps the pill honest without hammering a public
  // government service. The forecast is reissued every six hours.
  Timer { interval: 600000; running: true; repeat: true; onTriggered: root.refresh() }

  // curl's --max-time is curl's to honour, and it is the only clock the
  // subprocess has. This is an independent one: any fetch still alive past its
  // own limit plus a grace period is terminated from here, which also unsticks
  // `loading` if a process wedges without ever exiting.
  readonly property var guardedProcs: [stationProc, boxProc, tafProc, geocodeProc]
  readonly property var guardLimits: [15, 20, 15, 8]
  property var guardStarted: [0, 0, 0, 0]

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      var started = root.guardStarted
      for (var i = 0; i < root.guardedProcs.length; i++) {
        var proc = root.guardedProcs[i]
        if (!proc.running) { started[i] = 0; continue }
        if (!started[i]) { started[i] = now; continue }
        if (now - started[i] > (root.guardLimits[i] + 5) * 1000) {
          proc.running = false      // Quickshell terminates the child
          started[i] = 0
          root.loading = false
        }
      }
      root.guardStarted = started
    }
  }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

  // Opening the panel is a good moment to be current.
  onOpenedChanged: {
    if (!opened) return
    refresh()
    Qt.callLater(playForView)
    if (debugGeometry) geometryTimer.restart()
  }

  // Wait for the layout to settle before measuring: text wrapping and the
  // opening animations both change the panel's height, and a rect reported on
  // the first frame crops the bottom off. The panel also grows again when a
  // second request lands — the forecast arrives after the observation that
  // names its station — so any resize re-arms this and the caller takes the
  // last rect reported.
  Timer {
    id: geometryTimer
    interval: 1200
    onTriggered: root.reportGeometry()
  }

  Connections {
    target: root.debugGeometry ? root.panelFrame : null
    function onHeightChanged() { geometryTimer.restart() }
  }

  function reportGeometry() {
    if (!panelFrame) return
    // The layer surface is the whole screen, so a point mapped out of the
    // panel's own item is already in screen coordinates. What that item covers
    // is the *content*, though; the popup people see also has the panel's
    // padding and its border around it, so grow the rect by both rather than
    // cropping through the frame. Taken from the panel itself so it stays right
    // under a different theme or scale.
    var inset = panel.padding + Math.max(1, Style.space(2))
    var origin = panelFrame.mapToGlobal(0, 0)
    console.log("METAR_GEOMETRY "
                + Math.round(origin.x - inset) + " " + Math.round(origin.y - inset) + " "
                + Math.round(panelFrame.width + inset * 2) + " "
                + Math.round(panelFrame.height + inset * 2))
  }

  function playForecast() { if (timeline) timeline.play() }
  function playNow() { if (skyProfile) skyProfile.play() }
  function playForView() {
    if (view === "forecast") playForecast()
    else if (view === "now") playNow()
  }
  onViewChanged: if (opened) Qt.callLater(playForView)
  onTafPeriodListChanged: if (view === "forecast" && opened) Qt.callLater(playForecast)
  onObsChanged: if (view === "now" && opened) Qt.callLater(playNow)

  function applyObs(raw) {
    var list = boundedList(raw, 60)
    if (!list.length) { lastError = "no observation"; return }
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
        if (root.stationGen !== root.fetchGen) return      // superseded
        try {
          root.applyObs(root.parseBounded(text))
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
        if (root.boxGen !== root.fetchGen) return          // superseded
        try {
          var list = root.parseBounded(text)
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
        // The forecast belongs to the station it was requested for, never to
        // whichever station happens to be selected when it lands.
        var forStation = root.tafRequestedFor
        if (root.tafGen !== root.fetchGen || forStation !== root.stationId) return
        try {
          var arr = root.parseBounded(text)
          if (!arr || !arr.length) {
            // Plenty of fields report a METAR and no TAF at all; that is normal
            // and the tab says so rather than looking broken.
            root.tafPeriodList = []
            root.rawTaf = ""
            root.tafFor = forStation
            return
          }
          var t = arr[0]
          root.rawTaf = String(t.rawTAF || "")
          root.tafIssuedMs = Number(t.issueTime ? Date.parse(t.issueTime) : 0)
          root.tafPeriodList = Met.tafPeriods(root.boundedList(t.fcsts, 48))
          root.tafFor = forStation
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
    var layers = boundedList(obs.clouds, 8)
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
    var wx = safe(Met.decodeWx(p.wx), 60)
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
      Component.onCompleted: root.panelFrame = keyCatcher
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
              textFormat: Text.PlainText
              text: root.glyph
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              text: root.category !== "" ? root.category : "—"
              color: root.category !== "" ? root.colorFor(root.category) : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(26)
              font.bold: true
              anchors.bottom: parent.bottom
              // Conditions change between categories, not to them, so the
              // colour crosses rather than cuts.
              Behavior on color {
                enabled: root.animOn
                ColorAnimation { duration: 450; easing.type: Easing.InOutQuad }
              }
            }
            Text {
              textFormat: Text.PlainText
              text: root.category !== "" ? Met.categoryName(root.category) : (root.lastError !== "" ? root.lastError : "loading")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.space(14)
              anchors.bottom: parent.bottom
              bottomPadding: Style.space(4)
            }
          }

          Text {
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
              width: Style.space(76)
              height: Style.space(76)
              direction: root.windDir
              speedKt: root.windKt
              gustKt: root.gustKt
              stroke: Color.popups.text
              roseColor: Color.muted
              animate: root.animOn
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.space(88)
              spacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: Met.formatWind(root.windDir, root.windKt, root.gustKt)
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(14)
                wrapMode: Text.WordWrap
              }
              Text {
                textFormat: Text.PlainText
                visible: root.crosswind !== null
                text: "Crosswind " + (root.crosswind !== null ? Math.round(root.crosswind) : 0)
                      + " kt on runway " + Math.round(root.runwayHeading / 10)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
              }
              Text {
                textFormat: Text.PlainText
                visible: Met.decodeWx(root.obs ? root.obs.wxString : "") !== ""
                width: parent.width
                text: root.safe(Met.decodeWx(root.obs ? root.obs.wxString : ""), 80)
                color: root.colorFor("MVFR")
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
                wrapMode: Text.WordWrap
              }
            }

          }

          SkyProfile {
            id: skyProfile
            width: parent.width
            height: Style.space(126)
            clouds: root.obs ? root.boundedList(root.obs.clouds, 8) : []
            ceiling: root.ceilFt
            ceilingColor: root.category !== "" ? root.colorFor(root.category) : Color.muted
            inkColor: Color.popups.text
            fontFamily: Style.font.family
            labelSize: Style.space(10)
            animate: root.animOn
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

          }
        }

        // ---- Forecast ----
        Column {
          visible: root.view === "forecast"
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.safe(root.rawTaf, 900) !== "" ? "TAF ISSUED " + root.clock(root.tafIssuedMs) : "TERMINAL FORECAST"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          Text {
            textFormat: Text.PlainText
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
            id: timeline
            visible: root.tafPeriodList.length > 0
            width: parent.width
            animate: root.animOn
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
            textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    text: root.dayClock(pr.modelData.from) + "  "
                          + (pr.modelData.transient
                             ? (pr.modelData.probability ? "PROB" + pr.modelData.probability : "TEMPO")
                             : pr.modelData.category)
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.space(12)
                  }
                  Text {
                    textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                width: Style.space(46)
                text: root.safe(nr.modelData.icaoId, 6)
                color: nr.modelData.icaoId === root.stationId ? Color.accent : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(12)
                font.bold: nr.modelData.icaoId === root.stationId
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(52)
                text: nr.modelData._nm !== undefined ? (Math.round(nr.modelData._nm) + " nm") : ""
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
                horizontalAlignment: Text.AlignRight
              }
              Text {
                textFormat: Text.PlainText
                width: nr.width - Style.space(120)
                text: root.safe(nr.modelData.name, 40)
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
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            visible: root.rawTaf !== ""
            width: parent.width
            text: root.safe(root.rawTaf, 900)
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.space(11)
            wrapMode: Text.WrapAnywhere
          }

          PanelSectionHeader {
            visible: root.resources.length > 0
            text: "GO DEEPER"
            foreground: Color.popups.text
            font.letterSpacing: Style.space(2)
          }

          // A bar pill is the wrong place to plan a flight from, so the honest
          // move is to hand the reader straight to the places that are right.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.resources
              Rectangle {
                id: linkRow
                required property var modelData
                width: parent ? parent.width : 0
                height: linkText.implicitHeight + Style.space(6)
                radius: Style.space(4)
                color: linkArea.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                Behavior on color {
                  enabled: root.animOn
                  ColorAnimation { duration: 130 }
                }

                Text {
                  textFormat: Text.PlainText
                  id: linkText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(8)
                  text: "\u2197  " + linkRow.modelData.label
                  color: linkArea.containsMouse ? Color.accent : Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.space(12)
                  elide: Text.ElideRight
                }

                MouseArea {
                  id: linkArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openLink(linkRow.modelData.url)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
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
      textFormat: Text.PlainText
      width: Style.space(150)
      text: sr.label
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      width: Style.space(104)
      text: sr.value
      color: sr.highlight ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.space(13)
      font.bold: sr.highlight
    }
    Text {
      textFormat: Text.PlainText
      width: Math.max(Style.space(20), sr.width - Style.space(150 + 104 + 16))
      text: sr.note
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: Style.space(12)
    }
  }
}
