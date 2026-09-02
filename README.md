# Aviation Weather — Omarchy bar plugin

The flight category at your nearest airfield, as a colored pill in the
[Omarchy](https://omarchy.org) (Quattro) bar. Green through magenta is the same
scale every aviation chart uses, so it reads without being read.

Click it for the observation decoded into plain English, the terminal forecast
as a category timeline, the neighbouring fields, and the raw reports.

No API key, no account. It finds its own airfield from the location your Omarchy
weather widget already knows.

## The four tabs

- **Now** — the current observation: wind drawn as a proper station-model barb
  beside the wind in words, visibility, ceiling, the sky layers, temperature and
  dewpoint with relative humidity, altimeter in both inches and hectopascals,
  and the density altitude.
- **Forecast** — the TAF as one strip, time running left to right, each block
  coloured by the category it forecasts, with a marker for now. Below it, the
  line a pilot actually scans a TAF for: when it deteriorates, and to what.
- **Nearby** — every field reporting within about 66 nm, nearest first, each
  with its own category. Useful when your home field is IFR and you want to know
  how far the murk extends.
- **Raw** — the METAR and TAF exactly as issued, for when you would rather read
  them yourself.

## Flight categories

The pill and every coloured block use the FAA's definitions, where the worse of
ceiling and visibility decides:

| | Ceiling | | Visibility |
|---|---|---|---|
| **VFR** | above 3000 ft | and | above 5 sm |
| **MVFR** | 1000–3000 ft | or | 3–5 sm |
| **IFR** | 500–999 ft | or | 1 to under 3 sm |
| **LIFR** | below 500 ft | or | below 1 sm |

A ceiling is the lowest broken or overcast layer, or the vertical visibility
into an obscured sky. Few and scattered are not ceilings, however low they sit.

These rules live in `metar.js` with no Qt types in them, so
`tools/test-metar.mjs` runs the same code under node and checks it against the
boundaries from both sides — and then against a dozen live stations, where our
computed category has to match the Aviation Weather Center's own.

```bash
node tools/test-metar.mjs            # includes the live check
node tools/test-metar.mjs --offline  # rules only
```

## Requirements

- Omarchy **Quattro (v4)** with `omarchy-shell` (Quickshell-based bar)
- `curl` on `PATH`
- A Nerd Font in the bar (Omarchy ships one) for the aircraft glyph

## Install

```bash
omarchy plugin add https://github.com/Snackwrap/omarchy-metar.git --enable
omarchy bar move com.leafbox.metar right
```

## Uninstall

```bash
omarchy plugin disable com.leafbox.metar
omarchy plugin remove com.leafbox.metar
omarchy restart shell
```

## Settings

Omarchy has no settings UI for bar widgets yet — the manifest declares a schema
for the one that is coming. Until then, set any key from the table below with:

```bash
omarchy bar set com.leafbox.metar station KSFO
omarchy restart shell
```

An empty value falls back to the default, so `omarchy bar set com.leafbox.metar
station ""` goes back to picking the nearest field automatically.

| Setting | Key | Does |
|---|---|---|
| Station | `station` | ICAO code, e.g. `KSFO`. Blank picks the nearest reporting field |
| Latitude / longitude | `latitude`, `longitude` | Override the location. Blank inherits your Omarchy weather location |
| Bar pill shows | `pillContent` | `category`, `station`, `both` or `wind` |
| Times | `timeFormat` | `local` or `zulu` |
| Temperature | `temperature` | `C` or `F` |
| Default tab | `defaultTab` | `now`, `forecast`, `nearby` or `raw` |
| Runway heading | `runwayHeading` | e.g. `280`, to show the crosswind component. Blank hides it |
| Notify when it drops to | `alertCategory` | `off`, `MVFR`, `IFR` or `LIFR` |
| Popup position | `popupPosition` | `icon` (under the bar icon) or `center` |

Naming a station explicitly turns off the Nearby tab, since neighbours are found
by searching around your location rather than around the station.

## Interaction

| Action | Result |
|---|---|
| Left click | Toggle the popup |
| Middle click | Force a refresh |
| Hover | The station, category, visibility, ceiling and wind |

## How it works

- `BarWidget.qml` — the bar-slot button and popout-identity shim.
- `Panel.qml` — fetches and renders. One `bbox` query to the METAR endpoint
  returns the nearest reporting field *and* its neighbours, so resolving the
  station costs nothing over filling the Nearby tab; a second call fetches the
  TAF for whichever station won.
- `metar.js` — every rule: categories, ceilings, the shapes visibility arrives
  in, wind barbs, weather codes, density altitude, TAF periods. Deliberately
  free of Qt types so it can be tested under node.
- `WindBarb.qml` — the station-model barb on a `Canvas`. A pennant is 50 kt, a
  full barb 10, a half barb 5, and under 3 kt it is the open calm circle.
- `TafTimeline.qml` — the forecast strip. TEMPO and PROB groups describe a
  temporary deviation inside another period rather than a period of their own,
  so they are drawn as a thin band underneath; letting a thirty-minute TEMPO
  recolour a six-hour block would make the forecast look far worse than it is.

Observations are refetched every ten minutes, and whenever the popup is opened.
Reports are issued about hourly, with unscheduled specials in between, so that
keeps the pill honest without hammering a public service. Anything older than 75
minutes is called out as stale rather than presented as current.

## Data and disclaimer

Observations and forecasts come from the **NOAA / NWS Aviation Weather Center**
(`aviationweather.gov`), which requires no key. Location names, when your weather
widget stores only a name, are resolved through Open-Meteo's geocoding API — the
same service the built-in weather panel uses.

**This is not a flight-planning tool.** It is a status pill for a desktop bar.
It has no currency guarantee, no NOTAMs, no AIRMETs or SIGMETs, and no
redundancy. Get your weather from an official briefing source before you fly.

## License

MIT.

Data © NOAA / National Weather Service, public domain. This project is not
affiliated with or endorsed by NOAA, the NWS, or the FAA.
