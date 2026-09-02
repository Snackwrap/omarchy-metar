#!/usr/bin/env bash
# Capture the popup, one PNG per tab, for the marketplace listing assets.
#
# Two things make this awkward to do by hand, and this script works around both:
#
#   * Clicking a terminal closes the popup, so it has to be driven over IPC
#     (`omarchy-shell shell summon`) rather than opened with the mouse.
#   * The popup is drawn inside a fullscreen layer surface, so the compositor
#     cannot tell us its rectangle. We shoot the screen with the popup open and
#     twice with it closed. The region that changed between open and closed is
#     the popup; whatever changed between the two *closed* shots is something
#     animating on its own, and gets masked out first.
#
# Every tab here is unconditional, so `defaultTab` alone picks which one opens.
#
# Usage:  tools/capture-preview.sh [tab ...]      (default: all of them)
set -euo pipefail

ID="com.leafbox.metar"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="$ROOT/assets/tabs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TABS=("$@")
[ ${#TABS[@]} -eq 0 ] && TABS=(now forecast nearby raw)

mkdir -p "$OUTDIR"

# Park the pointer in a corner once, up front. Whichever row it rests on picks
# up its hover fill and reads like a selection in the screenshot. It has to be
# done once rather than per tab: moving it switches focus under
# focus-follows-mouse, and that window's redraw is exactly the kind of change
# the diff below would mistake for the popup.
hyprctl dispatch 'hl.dsp.cursor.move({x=4,y=796})' >/dev/null 2>&1 \
  || hyprctl dispatch movecursor 4 796 >/dev/null 2>&1 || true

# Shoot against an empty workspace. Anything still animating behind the popup —
# a video, a page mid-transition, a blinking cursor — lands in the diff and the
# crop stretches to cover it, so the reliable fix is to have nothing there.
# The original workspace is restored on the way out, including on Ctrl-C.
HOME_WS=$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || echo "")
SCRATCH_WS=$(hyprctl workspaces -j | python3 -c '
import json, sys
used = {w["id"] for w in json.load(sys.stdin)}
print(next(i for i in range(1, 100) if i not in used))
' 2>/dev/null || echo "")

restore_workspace() {
  [ -n "$HOME_WS" ] && hyprctl dispatch "hl.dsp.focus({workspace = \"$HOME_WS\"})" >/dev/null 2>&1 || true
}
if [ -n "$SCRATCH_WS" ]; then
  trap 'restore_workspace; rm -rf "$TMP"' EXIT
  hyprctl dispatch "hl.dsp.focus({workspace = \"$SCRATCH_WS\"})" >/dev/null 2>&1 || true
  echo "   (capturing on empty workspace $SCRATCH_WS, back to $HOME_WS afterwards)"
fi
sleep 1.5

# There is no `omarchy bar get`, so read the current values straight out of the
# merged shell config in order to hand them back at the end.
read_setting() {
  python3 - "$1" <<'PYEOF'
import json, os, sys
try:
    cfg = json.load(open(os.path.expanduser("~/.config/omarchy/shell.json")))
except Exception:
    sys.exit()
for slot in cfg.get("bar", {}).get("layout", {}).values():
    for w in slot:
        if w.get("id") == "com.leafbox.metar" and sys.argv[1] in w:
            print(w[sys.argv[1]])
PYEOF
}

restore_tab=$(read_setting defaultTab)


for tab in "${TABS[@]}"; do
  omarchy bar set "$ID" defaultTab "$tab"
  sleep 0.6                      # let the settings write land before the reread
  omarchy restart shell
  sleep 4.5                      # the shell needs a beat to come back up

  # Closed and open shots go back to back with nothing printed between them, so
  # the popup is the only thing that differs and the diff crops it exactly. If
  # something else on screen redraws anyway the box comes back implausibly wide,
  # so take the shot again rather than shipping a screenshot of the desktop.
  box=""
  for attempt in 1 2 3 4 5 6; do
    omarchy-shell shell hide "$ID" 2>/dev/null || true
    sleep 0.7
    grim "$TMP/closed.png"
    sleep 0.8
    grim "$TMP/closed2.png"      # a second reference: whatever moved between
                                 # these two is animating on its own
    omarchy-shell shell summon "$ID"
    sleep 4.0                    # let the fetch land and the panel settle
    grim "$TMP/open.png"
    omarchy-shell shell hide "$ID" 2>/dev/null || true

    box=$(python3 "$ROOT/tools/diff-box.py" "$TMP/open.png" "$TMP/closed2.png" "$TMP/closed.png") || box=""
    [ -n "$box" ] && break
    echo "   $tab: attempt $attempt caught the desktop, retrying" >&2
  done
  if [ -z "$box" ]; then
    echo "!! $tab: could not isolate the popup, skipping" >&2
    continue
  fi
  magick "$TMP/open.png" -crop "$box" +repage "$OUTDIR/$tab.png"
  echo "   $tab -> assets/tabs/$tab.png ($box)"
done

# Put the user's own settings back.
omarchy bar set "$ID" defaultTab "${restore_tab:-now}"
omarchy restart shell
echo "Done. Now run tools/build-preview.sh to compose preview.png."
