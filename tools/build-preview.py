#!/usr/bin/env python3
"""Generate tools/promo.html — the marketplace card — with the tab captures inlined.

The screenshots are embedded as data URIs so the page renders identically from
any working directory and needs nothing fetched at build time.
"""
import base64
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABS = ROOT / "assets" / "tabs"

# Every capture is 788 wide but its height follows its content, so crop them all
# to a common band from the top. That keeps the mastheads and tab rows aligned
# across the grid instead of letting the tall tabs tower over the short ones.
BAND = 578

PANELS = [
    ("now.png",      "NOW",      "wind, sky and the numbers behind the category"),
    ("forecast.png", "FORECAST", "the TAF as a category timeline"),
    ("nearby.png",   "NEARBY",   "every field reporting within ~66 nm"),
    ("raw.png",      "RAW",      "the reports as issued, and where to go next"),
]


def uri(name):
    out = subprocess.run(
        ["magick", str(TABS / name), "-crop", f"788x{BAND}+0+0", "+repage", "png:-"],
        check=True, capture_output=True).stdout
    return "data:image/png;base64," + base64.b64encode(out).decode()


cards = "\n".join(
    f'''      <figure class="card">
        <div class="shot"><img src="{uri(f)}" alt="{label} tab"></div>
        <figcaption><b>{label}</b> {note}</figcaption>
      </figure>''' for f, label, note in PANELS)

HTML = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ width:1600px; height:1000px; background:#12151c; overflow:hidden;
         font-family:'JetBrainsMono Nerd Font','JetBrainsMono NF',monospace; position:relative; }}
  .wrap {{ position:relative; display:flex; height:100%; padding:66px 60px; gap:52px; align-items:center; }}
  .left {{ width:566px; flex:none; }}
  .brand {{ display:flex; align-items:center; gap:13px; margin-bottom:30px; }}
  .brand .mark {{ color:#3fb950; font-size:23px; }}
  .brand .word {{ color:#68718f; font-size:15px; font-weight:700; letter-spacing:6px; }}
  h1 {{ color:#dde3f4; font-size:46px; line-height:1.15; font-weight:800; letter-spacing:-0.5px; }}
  h1 .acc {{ color:#3fb950; }}
  .sub {{ color:#858ead; font-size:17px; line-height:1.55; margin-top:19px; }}

  /* The four categories, in the colours every aviation chart uses. */
  .cats {{ display:flex; gap:9px; margin-top:30px; }}
  .cat {{ flex:1; border-radius:7px; padding:9px 4px 8px; text-align:center;
          border:1px solid rgba(255,255,255,.07); background:rgba(255,255,255,.03); }}
  .cat b {{ display:block; font-size:15px; font-weight:800; letter-spacing:.5px; }}
  .cat span {{ display:block; color:#68718f; font-size:10.5px; margin-top:3px; letter-spacing:.4px; }}

  .feat {{ list-style:none; margin-top:28px; }}
  .feat li {{ color:#aab2cd; font-size:15.5px; line-height:1.5; margin-bottom:12px;
              padding-left:22px; position:relative; }}
  .feat li::before {{ content:"\\25B8"; color:#3fb950; font-weight:700; position:absolute; left:0; }}
  .feat b {{ color:#dde3f4; }}
  .install {{ margin-top:30px; display:inline-block; background:#181c26; border:1px solid #2b3140;
             border-radius:9px; padding:13px 19px; color:#aab2cd; font-size:14px; white-space:nowrap; }}
  .install .p {{ color:#68718f; }} .install .c {{ color:#3fb950; }}

  .grid {{ flex:1; display:grid; grid-template-columns:1fr 1fr; gap:26px 24px; }}
  /* The captures are cut to a common band, so fade the cut edge rather than
     letting each card end on a half-drawn row. */
  .card .shot {{ border-radius:9px; border:1px solid #2f3546; overflow:hidden;
                box-shadow:0 18px 44px rgba(0,0,0,.55);
                -webkit-mask-image:linear-gradient(to bottom,#000 82%,transparent 100%);
                mask-image:linear-gradient(to bottom,#000 82%,transparent 100%); }}
  .card .shot img {{ display:block; width:100%; }}
  .card figcaption {{ margin-top:11px; color:#68718f; font-size:13px; letter-spacing:.3px; }}
  .card figcaption b {{ color:#3fb950; letter-spacing:2.2px; margin-right:9px; }}
</style></head><body>
  <div class="wrap">
    <div class="left">
      <div class="brand"><span class="mark">&#xf072;</span><span class="word">AVIATION WEATHER</span></div>
      <h1>Is it flyable?<br><span class="acc">Ask the bar.</span></h1>
      <div class="sub">METAR and TAF for your nearest airfield, in the colours every aviation chart already uses.</div>

      <div class="cats">
        <div class="cat" style="border-color:rgba(63,185,80,.35)"><b style="color:#3fb950">VFR</b><span>&gt;3000 &amp; &gt;5</span></div>
        <div class="cat" style="border-color:rgba(77,159,255,.35)"><b style="color:#4d9fff">MVFR</b><span>1000&ndash;3000</span></div>
        <div class="cat" style="border-color:rgba(240,86,63,.35)"><b style="color:#f0563f">IFR</b><span>500&ndash;999</span></div>
        <div class="cat" style="border-color:rgba(217,114,232,.35)"><b style="color:#d972e8">LIFR</b><span>&lt;500</span></div>
      </div>

      <ul class="feat">
        <li><b>The wind as a station-model barb</b>, and the sky drawn to height</li>
        <li><b>The forecast as a timeline</b> &mdash; and when it deteriorates, to what</li>
        <li><b>Finds its own airfield.</b> No API key, no account, nothing to set up</li>
      </ul>
      <div class="install"><span class="p">$</span> omarchy plugin add <span class="c">github.com/Snackwrap/omarchy-metar</span></div>
    </div>
    <div class="grid">
{cards}
    </div>
  </div>
</body></html>"""

(ROOT / "tools" / "promo.html").write_text(HTML, encoding="utf-8")
print("tools/promo.html written")
