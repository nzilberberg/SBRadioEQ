#!/bin/sh
# SBRadioEQ -- every Canvas screen must honour the draw LAYER.
#
#   sh tools/check-canvas-layer.sh
#
# THE FAULT THIS PREVENTS.
#
# jive/ui/Canvas.lua is:
#
#     function draw(self, surface) self.render(surface) end
#
# It never looks at the layer the framework passes, so a Canvas paints in EVERY
# pass. A window transition draws each layer at its own offset -- the outgoing
# window at -x, the incoming one at screenWidth-x, then LAYER_FRAME back at 0,0
# -- so a Canvas that paints unconditionally covers the animation with an
# unoffset copy of itself. The screen CUTS instead of sliding.
#
# It cost a full debugging round on the EQ screen, and it was misdiagnosed once
# on the way (the wallpaper blit was blamed and removed; that was a real waste
# but not the cause). The fix is one line per Canvas:
#
#     self.canvas.draw = function(_, surface, layer)
#         if layer and (layer & LAYER_CONTENT) == 0 then return end
#         applet:_redrawX(surface)
#     end
#
# WHY A GATE. This is a property of the FRAMEWORK, not of any one screen, so
# every Canvas screen ever added has to repeat it -- and the failure is silent,
# cosmetic, and only visible mid-animation. Tone Controls already lists Loudness
# and a Reset confirm as screens that do not exist yet. Whoever builds those
# will not remember this. The gate is what remembers.
#
# The rule: constructing a Canvas obliges you to override its draw, and that
# override must test the layer. All three counts must agree.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
TARGET="${1:-$HERE/applet/SBRadioEQApplet.lua}"

[ -f "$TARGET" ] || { echo "FAIL: no such file: $TARGET"; exit 2; }

# `= Canvas(` and not `require(...Canvas)`: the import is not a construction.
constructions=$(grep -cE '=[[:space:]]*Canvas\(' "$TARGET" || true)
overrides=$(grep -cE '\.draw[[:space:]]*=[[:space:]]*function[[:space:]]*\([^)]*layer' "$TARGET" || true)
layerchecks=$(grep -cE 'layer[[:space:]]*&[[:space:]]*LAYER_CONTENT' "$TARGET" || true)

echo "  Canvas constructions        : $constructions"
echo "  draw overrides taking layer : $overrides"
echo "  overrides testing the layer : $layerchecks"

fail=0

if [ "$constructions" -eq 0 ]; then
	echo "  ok    no Canvas screens in this file"
	exit 0
fi

if [ "$overrides" -lt "$constructions" ]; then
	echo "  FAIL  $constructions Canvas(es) but only $overrides layer-aware draw override(s)"
	echo "        A Canvas without the override paints in every transition pass and"
	echo "        the screen will CUT instead of sliding."
	fail=1
fi

if [ "$layerchecks" -lt "$constructions" ]; then
	echo "  FAIL  $constructions Canvas(es) but only $layerchecks layer test(s)"
	echo "        An override that accepts 'layer' and ignores it is the same bug"
	echo "        wearing a fix."
	fail=1
fi

# LAYER_CONTENT must actually be captured -- module(...) replaces the global
# environment, so an uncaptured constant is nil and `layer & nil` throws at the
# first repaint rather than at load.
if ! grep -qE '^local LAYER_CONTENT' "$TARGET"; then
	echo "  FAIL  LAYER_CONTENT is used but never captured as a local"
	echo "        module(...) replaces the global environment; it would be nil."
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	echo "  ok    every Canvas honours the draw layer"
	exit 0
fi
echo ""
echo "check-canvas-layer: FAILED"
exit 1
