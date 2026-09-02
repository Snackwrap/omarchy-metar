// Checks metar.js against the FAA's own category definitions and against real
// published observations. Run with:  node tools/test-metar.mjs
// The live check hits aviationweather.gov; pass --offline to skip it.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "..", "metar.js"), "utf8").replace(/^\.pragma library\s*/, "")
const names = [...src.matchAll(/^function ([a-zA-Z0-9_]+)/gm)].map(m => m[1])
const M = new Function(`${src}\nreturn {${names.join(",")}}`)()

let failures = 0
function check(name, ok, detail) {
  if (!ok) failures++
  console.log(`${ok ? "  ok  " : "FAIL  "}${name}${detail ? "   " + detail : ""}`)
}
function eq(name, got, want) {
  check(name, got === want, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
}
function near(name, got, want, tol) {
  check(name, Math.abs(got - want) <= tol, `got ${got}, want ${want}±${tol}`)
}

console.log("\n# flight category — the boundaries, from both sides")
// Ceiling alone. The bands are 500 / 1000 / 3000, inclusive at the top.
eq("ceiling 400 -> LIFR",   M.flightCategory(10, 400),  "LIFR")
eq("ceiling 499 -> LIFR",   M.flightCategory(10, 499),  "LIFR")
eq("ceiling 500 -> IFR",    M.flightCategory(10, 500),  "IFR")
eq("ceiling 999 -> IFR",    M.flightCategory(10, 999),  "IFR")
eq("ceiling 1000 -> MVFR",  M.flightCategory(10, 1000), "MVFR")
eq("ceiling 3000 -> MVFR",  M.flightCategory(10, 3000), "MVFR")
eq("ceiling 3001 -> VFR",   M.flightCategory(10, 3001), "VFR")

// Visibility alone. The bands are 1 / 3 / 5, and 5 itself is still marginal.
eq("vis 0.5 -> LIFR",  M.flightCategory(0.5, null), "LIFR")
eq("vis 0.99 -> LIFR", M.flightCategory(0.99, null), "LIFR")
eq("vis 1 -> IFR",     M.flightCategory(1, null),   "IFR")
eq("vis 2.9 -> IFR",   M.flightCategory(2.9, null), "IFR")
eq("vis 3 -> MVFR",    M.flightCategory(3, null),   "MVFR")
eq("vis 5 -> MVFR",    M.flightCategory(5, null),   "MVFR")
eq("vis 5.1 -> VFR",   M.flightCategory(5.1, null), "VFR")

// The worse of the two wins, whichever it is.
eq("good vis, bad ceiling", M.flightCategory(10, 300), "LIFR")
eq("bad vis, good ceiling", M.flightCategory(0.25, 12000), "LIFR")
eq("MVFR vis with IFR ceiling", M.flightCategory(4, 700), "IFR")
eq("no ceiling reported is unlimited", M.flightCategory(10, null), "VFR")
eq("nothing reported is unknown", M.flightCategory(null, null), "")

console.log("\n# ceiling — only broken and above, plus vertical visibility")
eq("few and scattered are not a ceiling",
   M.ceilingFt([{ cover: "FEW", base: 200 }, { cover: "SCT", base: 400 }]), null)
eq("lowest broken layer wins",
   M.ceilingFt([{ cover: "SCT", base: 900 }, { cover: "BKN", base: 1300 }, { cover: "OVC", base: 2500 }]), 1300)
eq("obscured sky uses vertical visibility",
   M.ceilingFt([{ cover: "OVX", base: null }], 200), 200)
eq("vertical visibility beats a higher layer",
   M.ceilingFt([{ cover: "BKN", base: 1500 }], 300), 300)
eq("clear sky has no ceiling", M.ceilingFt([]), null)
// The API sends vertVis as an explicit null whenever the sky is not obscured,
// and Number(null) is 0 — which would put the ceiling on the ground.
eq("explicit null vertical visibility is not a ceiling",
   M.ceilingFt([{ cover: "FEW", base: 2500 }, { cover: "SCT", base: 5000 }], null), null)
eq("null vertVis with a real broken layer",
   M.ceilingFt([{ cover: "BKN", base: 1800 }], null), 1800)
eq("a forecast period of few and scattered is VFR", M.flightCategory(
   M.visibilitySM("6+"), M.ceilingFt([{ cover: "FEW", base: 2500 }, { cover: "SCT", base: 5000 }], null)), "VFR")

console.log("\n# visibility parsing — every shape the API emits")
eq('"10+"', M.visibilitySM("10+"), 10)
eq('"6+"', M.visibilitySM("6+"), 6)
eq('"3"', M.visibilitySM("3"), 3)
eq('"1 1/2"', M.visibilitySM("1 1/2"), 1.5)
eq('"1/2"', M.visibilitySM("1/2"), 0.5)
eq('"3/4"', M.visibilitySM("3/4"), 0.75)
eq('"10SM"', M.visibilitySM("10SM"), 10)
eq("plain number", M.visibilitySM(2.5), 2.5)
eq("null", M.visibilitySM(null), null)
check('"M1/4" is below a quarter mile', M.visibilitySM("M1/4") < 0.25,
      `got ${M.visibilitySM("M1/4")}`)
eq('"M1/4" is still LIFR', M.flightCategory(M.visibilitySM("M1/4"), null), "LIFR")

console.log("\n# wind barbs — 50 kt pennant, 10 kt barb, 5 kt half")
eq("calm below 3 kt", JSON.stringify(M.windBarb(2)),
   JSON.stringify({ calm: true, pennants: 0, barbs: 0, half: 0 }))
eq("5 kt is one half barb", JSON.stringify(M.windBarb(5)),
   JSON.stringify({ calm: false, pennants: 0, barbs: 0, half: 1 }))
eq("10 kt is one full barb", JSON.stringify(M.windBarb(10)),
   JSON.stringify({ calm: false, pennants: 0, barbs: 1, half: 0 }))
eq("15 kt is a barb and a half", JSON.stringify(M.windBarb(15)),
   JSON.stringify({ calm: false, pennants: 0, barbs: 1, half: 1 }))
eq("50 kt is one pennant", JSON.stringify(M.windBarb(50)),
   JSON.stringify({ calm: false, pennants: 1, barbs: 0, half: 0 }))
eq("65 kt is a pennant, barb and half", JSON.stringify(M.windBarb(65)),
   JSON.stringify({ calm: false, pennants: 1, barbs: 1, half: 1 }))
eq("13 kt rounds to 15", JSON.stringify(M.windBarb(13)), JSON.stringify(M.windBarb(15)))

console.log("\n# compass")
eq("0 -> N", M.cardinal(0), "N")
eq("90 -> E", M.cardinal(90), "E")
eq("225 -> SW", M.cardinal(225), "SW")
eq("350 -> N", M.cardinal(350), "N")
eq("wraps past 360", M.cardinal(370), "N")      // 370 is 010, still within N
eq("wraps to NNE", M.cardinal(380), "NNE")     // 380 is 020

console.log("\n# wind wording")
eq("calm", M.formatWind(0, 0), "Calm")
eq("steady", M.formatWind(220, 13), "SW 220° at 13 kt")
eq("gusting", M.formatWind(310, 18, 27), "NW 310° at 18 kt, gusting 27")
eq("variable direction", M.formatWind(null, 4), "Variable at 4 kt")
near("crosswind at 90 degrees", M.crosswindKt(90, 20, 360), 20, 0.01)
near("crosswind straight down the runway", M.crosswindKt(360, 20, 360), 0, 0.01)
near("crosswind at 30 degrees off", M.crosswindKt(30, 20, 360), 10, 0.01)

console.log("\n# present weather")
eq("light rain", M.decodeWx("-RA"), "light rain")
eq("heavy thunderstorm rain", M.decodeWx("+TSRA"), "heavy thunderstorm rain")
eq("nearby thunderstorm", M.decodeWx("VCTS"), "nearby thunderstorm")
eq("freezing fog", M.decodeWx("FZFG"), "freezing fog")
eq("rain and mist", M.decodeWx("-RA BR"), "light rain, mist")
eq("showers of snow", M.decodeWx("SHSN"), "showers of snow")
eq("blowing snow", M.decodeWx("BLSN"), "blowing snow")
eq("patches of fog", M.decodeWx("BCFG"), "patches of fog")
eq("bare thunderstorm", M.decodeWx("TS"), "thunderstorm")
// A descriptor with nothing after it must not leave a dangling preposition.
eq("nearby showers", M.decodeWx("VCSH"), "nearby showers")
eq("bare patches", M.decodeWx("BC"), "patches")
eq("but keeps it when there is something to describe", M.decodeWx("SHRA"), "showers of rain")
eq("empty stays empty", M.decodeWx(""), "")
eq("unknown token is passed through", M.decodeWx("ZZ"), "ZZ")

console.log("\n# humidity and density altitude")
eq("saturated air is 100%", Math.round(M.relativeHumidity(15, 15)), 100)
near("21.7/11.1 at KSFO", M.relativeHumidity(21.7, 11.1), 51, 2)
// The AIM's worked example: 5883 ft field, 30.10 inHg (1019.3 hPa), 25 C.
// Published answer is about 8200 ft.
near("AIM worked example", M.densityAltitudeFt(5883, 1019.3, 25), 8200, 250)
check("density altitude is below field elevation on a cold day",
      M.densityAltitudeFt(5883, 1019.3, -20) < 5883,
      `got ${M.densityAltitudeFt(5883, 1019.3, -20)}`)
near("1013.25 hPa is 29.92 inHg", M.hPaToInHg(1013.25), 29.92, 0.01)

console.log("\n# staleness")
const now = Date.UTC(2026, 0, 1, 12, 0)
check("a 20-minute-old report is current", !M.isStale(now - 20 * 60000, now))
check("a 2-hour-old report is stale", M.isStale(now - 120 * 60000, now))
eq("age wording, minutes", M.formatAge(43), "43 min ago")
eq("age wording, hours", M.formatAge(150), "2h 30m ago")
eq("age wording, exact hours", M.formatAge(120), "2h ago")

console.log("\n# TAF periods")
const fcsts = [
  { timeFrom: 1000, timeTo: 2000, fcstChange: null, visib: "6+", vertVis: null, clouds: [{ cover: "SCT", base: 3500 }] },
  { timeFrom: 2000, timeTo: 3000, fcstChange: "FM", visib: "2", clouds: [{ cover: "OVC", base: 700 }] },
  { timeFrom: 2200, timeTo: 2400, fcstChange: "TEMPO", visib: "1/2", clouds: [{ cover: "OVC", base: 200 }] },
]
const periods = M.tafPeriods(fcsts)
eq("period count", periods.length, 3)
eq("first period is VFR", periods[0].category, "VFR")
eq("first period keeps the plus", periods[0].visPlus, true)
eq("second period is IFR", periods[1].category, "IFR")
eq("TEMPO is marked transient", periods[2].transient, true)
eq("FM is not transient", periods[1].transient, false)
eq("times are milliseconds", periods[0].from, 1000000)
const worse = M.nextDeterioration(periods, 0, "VFR")
eq("next deterioration skips the TEMPO and finds the FM", worse && worse.category, "IFR")
eq("nothing worse than LIFR", M.nextDeterioration(periods, 0, "LIFR"), null)

console.log("\n# distance and bearing")
// KSFO to KOAK is about 17 nm on a bearing of roughly 060.
near("KSFO -> KOAK distance", M.distanceNm(37.6196, -122.3656, 37.7213, -122.2207), 9.7, 1.5)
near("KSFO -> KOAK bearing", M.bearingDeg(37.6196, -122.3656, 37.7213, -122.2207), 44, 6)
near("a degree of latitude is 60 nm", M.distanceNm(0, 0, 1, 0), 60, 0.5)

console.log("\n# formatting")
eq("unlimited ceiling", M.formatCeiling(null), "unlimited")
eq("ten or more", M.formatVisibility(10), "10+ sm")
eq("P6SM keeps its plus", M.formatVisibility(6, true), "6+ sm")
eq("a hard six does not gain one", M.formatVisibility(6, false), "6 sm")
check("plus is detected in the raw value", M.visibilityIsPlus("6+") && !M.visibilityIsPlus("2"))
eq("a mile and a half", M.formatVisibility(1.5), "1.5 sm")
eq("half a mile", M.formatVisibility(0.5), "1/2 sm")
eq("a quarter", M.formatVisibility(0.25), "1/4 sm")
eq("category names", M.categoryName("MVFR"), "Marginal visual")

if (!process.argv.includes("--offline")) {
  console.log("\n# live observations — our category has to match the AWC's own")
  const ids = ["KSFO", "KJFK", "KORD", "KDEN", "KSEA", "KBOS", "KLAX", "KATL",
               "PANC", "KMIA", "KMSP", "KPDX"]
  try {
    const res = await fetch(
      `https://aviationweather.gov/api/data/metar?ids=${ids.join(",")}&format=json`,
      { signal: AbortSignal.timeout(15000) })
    const obs = await res.json()
    check("fetched observations", obs.length > 0, `${obs.length} stations`)
    for (const o of obs) {
      if (!o.fltCat) continue
      const vis = M.visibilitySM(o.visib)
      const ceil = M.ceilingFt(o.clouds, o.vertVis)
      const got = M.flightCategory(vis, ceil)
      check(`${o.icaoId} category`, got === o.fltCat,
            `got ${got}, AWC says ${o.fltCat}  [vis ${o.visib} ceil ${ceil}]`)
    }
  } catch (e) {
    console.log(`  skip  live check unavailable (${e.message})`)
  }
}

console.log(`\n${failures ? `${failures} FAILED` : "all checks passed"}\n`)
process.exit(failures ? 1 : 0)
