.pragma library

// Everything that turns an observation into words, a category or a symbol.
// No Qt types in here, so tools/test-metar.mjs can run the same code under node
// and check it against the FAA's own definitions and real published reports.

// ---- Flight category -------------------------------------------------------

// The four categories are defined on ceiling and visibility together, and the
// worse of the two decides (AIM 7-1-7 / the AWC legend):
//
//   LIFR   ceiling below 500 ft      or visibility below 1 sm
//   IFR    ceiling 500 to 999 ft     or visibility 1 to under 3 sm
//   MVFR   ceiling 1000 to 3000 ft   or visibility 3 to 5 sm
//   VFR    ceiling above 3000 ft    and visibility above 5 sm
//
// The boundaries are inclusive at the top of each band: exactly 3000 ft is
// MVFR, exactly 5 sm is MVFR. Getting that wrong shifts a marginal day into
// the wrong colour, which is the whole point of the pill.
var CATEGORIES = ["LIFR", "IFR", "MVFR", "VFR"]

function categoryRank(cat) {
  var i = CATEGORIES.indexOf(String(cat || "").toUpperCase())
  return i < 0 ? 3 : i
}

// No ceiling reported means nothing at or below broken — unlimited, for this
// purpose. No visibility reported is the genuinely unknown case and we say so
// rather than guessing VFR.
function flightCategory(visSM, ceilFt) {
  var v = (visSM === null || visSM === undefined) ? NaN : Number(visSM)
  var c = (ceilFt === null || ceilFt === undefined) ? Infinity : Number(ceilFt)
  if (!isFinite(v) && !isFinite(c)) return ""
  if (!isFinite(v)) v = Infinity

  var byVis = v < 1 ? "LIFR" : v < 3 ? "IFR" : v <= 5 ? "MVFR" : "VFR"
  var byCeil = c < 500 ? "LIFR" : c < 1000 ? "IFR" : c <= 3000 ? "MVFR" : "VFR"
  return categoryRank(byVis) < categoryRank(byCeil) ? byVis : byCeil
}

function categoryName(cat) {
  switch (String(cat || "").toUpperCase()) {
  case "VFR": return "Visual"
  case "MVFR": return "Marginal visual"
  case "IFR": return "Instrument"
  case "LIFR": return "Low instrument"
  }
  return "Unknown"
}

// ---- Ceiling and visibility ------------------------------------------------

// A ceiling is the lowest broken or overcast layer, or an obscured sky with a
// vertical visibility. Few and scattered are not ceilings however low they sit.
var CEILING_COVERS = ["BKN", "OVC", "OVX", "VV"]

function ceilingFt(clouds, vertVis) {
  var best = null
  var list = clouds || []
  for (var i = 0; i < list.length; i++) {
    var layer = list[i] || {}
    var cover = String(layer.cover || "").toUpperCase()
    if (CEILING_COVERS.indexOf(cover) < 0) continue
    // An obscured layer reports no base at all, and Number(null) is 0 — which
    // would read as a ceiling on the ground and colour the station LIFR.
    if (layer.base === null || layer.base === undefined || layer.base === "") continue
    var base = Number(layer.base)
    if (!isFinite(base)) continue
    if (best === null || base < best) best = base
  }
  // An obscured sky reports vertical visibility instead of a layer base. The
  // API sends this field as an explicit null whenever the sky is not obscured,
  // and Number(null) is 0 — which put a ceiling on the ground and turned every
  // clear forecast period LIFR.
  if (vertVis !== null && vertVis !== undefined && vertVis !== "") {
    var vv = Number(vertVis)
    if (isFinite(vv) && (best === null || vv < best)) best = vv
  }
  return best
}

// Visibility arrives in several shapes: a plain number, "10+" for ten or more,
// the fractions used below a mile ("1 1/2", "1/2"), and "M1/4" for less than a
// quarter. Treat "10+" as exactly 10 — it means at least ten, and the category
// boundaries are all well below it.
function visibilitySM(raw) {
  if (raw === null || raw === undefined) return null
  if (typeof raw === "number") return isFinite(raw) ? raw : null

  var s = String(raw).trim().toUpperCase().replace(/SM$/, "").trim()
  if (s === "") return null

  var lessThan = false
  if (s.charAt(0) === "M") { lessThan = true; s = s.slice(1) }
  s = s.replace(/\+$/, "")

  var total = 0
  var parts = s.split(/\s+/)
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i]
    if (p === "") continue
    var frac = p.split("/")
    var value = frac.length === 2 ? Number(frac[0]) / Number(frac[1]) : Number(p)
    if (!isFinite(value)) return null
    total += value
  }
  // "M1/4" is *below* a quarter mile; nudge it under so it cannot round up
  // into the wrong side of the 1 sm boundary.
  return lessThan ? total * 0.99 : total
}

function visibilityIsPlus(raw) {
  return String(raw === null || raw === undefined ? "" : raw).indexOf("+") >= 0
}

function formatVisibility(visSM, orMore) {
  var v = Number(visSM)
  if (!isFinite(v)) return "—"
  var plus = orMore ? "+" : ""
  if (v >= 10) return "10+ sm"
  if (v >= 1) return (Math.round(v * 10) / 10) + plus + " sm"
  // Below a mile pilots read quarters, not decimals.
  var quarters = Math.round(v * 4)
  var names = ["0", "1/4", "1/2", "3/4"]
  return (quarters >= 4 ? "1" : names[quarters]) + " sm"
}

function formatCeiling(ceilFt) {
  if (ceilFt === null || ceilFt === undefined) return "unlimited"
  var c = Number(ceilFt)
  if (!isFinite(c)) return "unlimited"
  return c.toLocaleString ? c.toLocaleString() + " ft" : c + " ft"
}

// ---- Wind ------------------------------------------------------------------

// A station-model wind barb: a pennant is 50 kt, a full barb 10, a half barb 5.
// Wind is rounded to the nearest 5 kt first, which is how the symbol is drawn.
// Below 3 kt there is no staff at all — that is the calm circle.
function windBarb(kt) {
  var k = Number(kt)
  if (!isFinite(k) || k < 3) return { calm: true, pennants: 0, barbs: 0, half: 0 }
  var units = Math.round(k / 5)
  var pennants = Math.floor(units / 10)
  units -= pennants * 10
  var barbs = Math.floor(units / 2)
  var half = units - barbs * 2
  return { calm: false, pennants: pennants, barbs: barbs, half: half }
}

var COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
               "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

function cardinal(deg) {
  var d = Number(deg)
  if (!isFinite(d)) return ""
  return COMPASS[Math.round(((d % 360) + 360) % 360 / 22.5) % 16]
}

// Variable-direction wind is reported as VRB, which arrives as a null heading
// with a speed. Say "variable" rather than drawing a barb pointing north.
function formatWind(dir, speedKt, gustKt) {
  var s = Number(speedKt)
  if (!isFinite(s) || s === 0) return "Calm"
  var d = Number(dir)
  var head = isFinite(d) && d > 0
    ? (cardinal(d) + " " + pad3(d) + "°")
    : "Variable"
  var out = head + " at " + Math.round(s) + " kt"
  var g = Number(gustKt)
  if (isFinite(g) && g > s) out += ", gusting " + Math.round(g)
  return out
}

function pad3(n) {
  var s = String(Math.round(Number(n)) % 360)
  while (s.length < 3) s = "0" + s
  return s
}

// A crosswind matters more than a headwind, so the panel shows the component
// across the nearest runway heading when the user names one.
function crosswindKt(windDir, speedKt, runwayHeading) {
  var w = Number(windDir), s = Number(speedKt), r = Number(runwayHeading)
  if (!isFinite(w) || !isFinite(s) || !isFinite(r)) return null
  return Math.abs(s * Math.sin((w - r) * Math.PI / 180))
}

// ---- Sky and weather -------------------------------------------------------

var COVERS = {
  SKC: "clear", CLR: "clear", CAVOK: "clear", NCD: "clear", NSC: "no significant cloud",
  FEW: "few", SCT: "scattered", BKN: "broken", OVC: "overcast",
  OVX: "obscured", VV: "vertical visibility"
}

function cloudLabel(cover) {
  return COVERS[String(cover || "").toUpperCase()] || String(cover || "").toLowerCase()
}

// Present weather is a compact code: an optional intensity or proximity, then
// an optional descriptor, then one or more phenomena. Decoding it as a whole
// token would need a table of every combination, so build it from the pieces.
var WX_INTENSITY = { "-": "light", "+": "heavy", "VC": "nearby" }
var WX_DESCRIPTOR = {
  MI: "shallow", PR: "partial", BC: "patches of", DR: "low drifting",
  BL: "blowing", SH: "showers of", TS: "thunderstorm", FZ: "freezing"
}
var WX_PHENOM = {
  DZ: "drizzle", RA: "rain", SN: "snow", SG: "snow grains", IC: "ice crystals",
  PL: "ice pellets", GR: "hail", GS: "small hail", UP: "unknown precipitation",
  BR: "mist", FG: "fog", FU: "smoke", VA: "volcanic ash", DU: "dust",
  SA: "sand", HZ: "haze", PY: "spray", PO: "dust whirls", SQ: "squalls",
  FC: "funnel cloud", SS: "sandstorm", DS: "duststorm"
}

function decodeWxToken(token) {
  var t = String(token || "").toUpperCase()
  if (t === "") return ""
  var words = []

  if (t.slice(0, 2) === "VC") { words.push(WX_INTENSITY.VC); t = t.slice(2) }
  else if (t.charAt(0) === "-" || t.charAt(0) === "+") {
    words.push(WX_INTENSITY[t.charAt(0)]); t = t.slice(1)
  }

  var descriptor = WX_DESCRIPTOR[t.slice(0, 2)]
  if (descriptor) { words.push(descriptor); t = t.slice(2) }

  var phenomena = []
  while (t.length >= 2) {
    var name = WX_PHENOM[t.slice(0, 2)]
    if (!name) break
    phenomena.push(name)
    t = t.slice(2)
  }
  // A bare TS with nothing after it is still a thunderstorm, and a leftover
  // fragment means we met something not in the table — keep it rather than
  // silently dropping half the report.
  if (!phenomena.length && !descriptor && t !== "") return String(token)
  // A descriptor with nothing to describe reads as a dangling preposition:
  // VCSH is "nearby showers", not "nearby showers of".
  if (!phenomena.length && descriptor) {
    words[words.length - 1] = descriptor.replace(/ of$/, "")
  }
  return words.concat(phenomena).join(" ").trim()
}

function decodeWx(wxString) {
  var s = String(wxString || "").trim()
  if (s === "") return ""
  var out = []
  var tokens = s.split(/\s+/)
  for (var i = 0; i < tokens.length; i++) {
    var decoded = decodeWxToken(tokens[i])
    if (decoded !== "") out.push(decoded)
  }
  return out.join(", ")
}

// ---- Temperature and pressure ----------------------------------------------

function cToF(c) { var v = Number(c); return isFinite(v) ? v * 9 / 5 + 32 : NaN }

// Magnus formula over water, the approximation the NWS itself uses. Good to
// well under a percent across the range a surface observation ever reports.
function relativeHumidity(tempC, dewpC) {
  var t = Number(tempC), d = Number(dewpC)
  if (!isFinite(t) || !isFinite(d)) return null
  var e = function (x) { return 6.112 * Math.exp(17.67 * x / (x + 243.5)) }
  return Math.max(0, Math.min(100, 100 * e(d) / e(t)))
}

// Altimeter comes back in hectopascals from this API even though the raw report
// carries inches of mercury, so both are derived from the one number.
function hPaToInHg(hpa) { var v = Number(hpa); return isFinite(v) ? v / 33.8639 : NaN }

// Pressure altitude, then density altitude by the dry-air approximation used on
// every E6B and in the AIM's own worked example. Good to a few tens of feet at
// airfield elevations, which is all a bar widget should claim.
function densityAltitudeFt(elevFt, altimeterHpa, tempC) {
  var elev = Number(elevFt), hpa = Number(altimeterHpa), t = Number(tempC)
  if (!isFinite(elev) || !isFinite(hpa) || !isFinite(t)) return null
  var pressureAlt = elev + 145366.45 * (1 - Math.pow(hpa / 1013.25, 0.190284))
  var isaTemp = 15 - 1.98 * (elev / 1000)
  return Math.round(pressureAlt + 118.8 * (t - isaTemp))
}

// ---- TAF -------------------------------------------------------------------

// The API hands back decoded forecast periods but does not categorise them, so
// the timeline strip has to do it. TEMPO and PROB groups describe a temporary
// deviation inside another period rather than a period of their own; they are
// carried alongside so the panel can mark them without letting a 30-minute
// TEMPO recolour a six-hour block.
function tafPeriods(fcsts) {
  var out = []
  var list = fcsts || []
  for (var i = 0; i < list.length; i++) {
    var f = list[i] || {}
    var change = String(f.fcstChange || "").toUpperCase()
    var vis = visibilitySM(f.visib)
    var ceil = ceilingFt(f.clouds, f.vertVis)
    out.push({
      from: Number(f.timeFrom) * 1000,
      to: Number(f.timeTo) * 1000,
      change: change,
      transient: change === "TEMPO" || (f.probability !== null && f.probability !== undefined),
      probability: f.probability === null || f.probability === undefined ? null : Number(f.probability),
      visSM: vis,
      visPlus: visibilityIsPlus(f.visib),
      ceilFt: ceil,
      category: flightCategory(vis, ceil),
      wdir: f.wdir === null || f.wdir === undefined ? null : Number(f.wdir),
      wspd: Number(f.wspd),
      wgst: f.wgst === null || f.wgst === undefined ? null : Number(f.wgst),
      wx: String(f.wxString || ""),
      clouds: f.clouds || []
    })
  }
  out.sort(function (a, b) { return a.from - b.from })
  return out
}

// The first period at or after now whose category is worse than the current
// one — the thing a pilot actually scans a TAF for.
function nextDeterioration(periods, fromMs, currentCategory) {
  var base = categoryRank(currentCategory)
  for (var i = 0; i < periods.length; i++) {
    var p = periods[i]
    if (p.transient || p.to <= fromMs || p.category === "") continue
    if (categoryRank(p.category) < base) return p
  }
  return null
}

// ---- Stations --------------------------------------------------------------

// Great-circle distance, for picking the closest reporting station to a
// location and for listing the neighbours in distance order.
function distanceNm(lat1, lon1, lat2, lon2) {
  var toRad = Math.PI / 180
  var dLat = (lat2 - lat1) * toRad
  var dLon = (lon2 - lon1) * toRad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
          Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) *
          Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 3440.065 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

function bearingDeg(lat1, lon1, lat2, lon2) {
  var toRad = Math.PI / 180
  var y = Math.sin((lon2 - lon1) * toRad) * Math.cos(lat2 * toRad)
  var x = Math.cos(lat1 * toRad) * Math.sin(lat2 * toRad) -
          Math.sin(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.cos((lon2 - lon1) * toRad)
  return (Math.atan2(y, x) / toRad + 360) % 360
}

// ---- Age -------------------------------------------------------------------

// A METAR is issued roughly hourly, so anything past about 75 minutes means the
// station has gone quiet and the panel should say so rather than present stale
// numbers as current.
function ageMinutes(observedMs, nowMs) {
  var o = Number(observedMs), n = Number(nowMs)
  if (!isFinite(o) || !isFinite(n)) return null
  return (n - o) / 60000
}

function isStale(observedMs, nowMs) {
  var age = ageMinutes(observedMs, nowMs)
  return age === null || age > 75
}

function formatAge(minutes) {
  var m = Number(minutes)
  if (!isFinite(m)) return ""
  if (m < 1) return "just now"
  if (m < 60) return Math.round(m) + " min ago"
  var h = Math.floor(m / 60)
  var rest = Math.round(m - h * 60)
  return rest ? h + "h " + rest + "m ago" : h + "h ago"
}
