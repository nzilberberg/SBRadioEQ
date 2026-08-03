#!/bin/sh
# SBRadioEQ -- the defaults exist ONCE, and Reset does not leave the volume up.
#
#   sh tools/check-defaults-single-source.sh
#
# TWO INVARIANTS, both silent when broken.
#
# 1. ONE TABLE. The values a fresh install starts with and the values "Reset
#    Tone" restores must be the same thing, because the user asked for that.
#    They are lua/uistate.lua's M.DEFAULTS. A second copy in the Meta would
#    agree on the day it was written and drift the day either was tuned -- and
#    nothing would fail: installs would simply start somewhere Reset never
#    returns to.
#
# 2. RESET MUST NOT COPY appliedAtten. This one is a LOUD AUDIO bug.
#
#    appliedAtten records how much make-up gain is folded into the PLAYER
#    VOLUME. When Reset runs, the volume is still carrying the old boost's
#    make-up -- up to 15 dB.
#
#    Copy appliedAtten = 0 in with everything else and _levelMatch computes
#    delta = target(0) - applied(0) = 0, concludes there is nothing to do, and
#    leaves the volume 15 dB up over a curve that is now flat. Same shape as the
#    bypass bug: the compensation outliving the thing it compensated for.
#
#    Excluding it makes the delta -15 and the volume comes DOWN. The direction
#    is always quieter, which is the safe way to be wrong.
#
# 3. Q CEILING. Shelf overshoot begins above shape 1.0 and is paid for in
#    make-up volume -- MEASURED on the device: a +10 dB request costs 10.00 dB
#    at 1.0, 10.18 at 1.2, 10.59 at 1.5. A default above 1.0 spends headroom on
#    a hump nobody asked for.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
UISTATE="$HERE/lua/uistate.lua"
META="$HERE/applet/SBRadioEQMeta.lua"
APPLET="$HERE/applet/SBRadioEQApplet.lua"

for f in "$UISTATE" "$META" "$APPLET"; do
	[ -f "$f" ] || { echo "FAIL: missing $f"; exit 2; }
done

fail=0

# ---- 1. one definition ----------------------------------------------------
echo "one definition of the defaults:"
if grep -qE '^M\.DEFAULTS[[:space:]]*=' "$UISTATE"; then
	echo "  ok    uistate.lua defines M.DEFAULTS"
else
	echo "  FAIL  uistate.lua has no M.DEFAULTS"
	fail=1
fi

# The Meta's defaultSettings body, comments stripped.
metabody=$(sed 's/--.*$//' "$META" | awk '/^function defaultSettings/,/^end/')
if printf '%s\n' "$metabody" | grep -q 'U\.defaults()'; then
	echo "  ok    the Meta returns U.defaults()"
else
	echo "  FAIL  the Meta does not return U.defaults()"
	fail=1
fi

restated=$(printf '%s\n' "$metabody" \
           | grep -oE '(bassGain|bassFreq|bassQ|trebGain|trebFreq|trebQ)[[:space:]]*=' || true)
if [ -n "$restated" ]; then
	echo "  FAIL  the Meta RESTATES default values instead of sharing them:"
	printf '%s\n' "$restated" | sed 's/^/          /'
	fail=1
else
	echo "  ok    the Meta restates no values of its own"
fi

if grep -qE 'U\.defaults\(\)' "$APPLET"; then
	echo "  ok    the applet's reset uses U.defaults()"
else
	echo "  FAIL  the applet's reset does not use U.defaults()"
	fail=1
fi

# ---- 2. reset must not copy appliedAtten ----------------------------------
echo ""
echo "reset leaves the volume bookkeeping alone:"
resetbody=$(sed 's/--.*$//' "$APPLET" | awk '/^function resetToDefaults/,/^end/')
if [ -z "$resetbody" ]; then
	echo "  FAIL  no resetToDefaults found"
	fail=1
elif printf '%s\n' "$resetbody" | grep -qE 'k[[:space:]]*~=[[:space:]]*"appliedAtten"'; then
	echo "  ok    appliedAtten is excluded from the copy"
else
	echo "  FAIL  appliedAtten is NOT excluded from the reset copy"
	echo "        the volume will be left up to 15 dB high over a flat curve"
	fail=1
fi

# It must also re-apply, or nothing moves the volume at all.
if printf '%s\n' "$resetbody" | grep -qE '_applyNow|_flushApply'; then
	echo "  ok    reset re-applies, so the volume is corrected"
else
	echo "  FAIL  reset never applies -- the curve changes but the volume does not"
	fail=1
fi

# ---- 3. the measured Q ceiling --------------------------------------------
echo ""
echo "shelf shape stays at or below the measured overshoot ceiling:"
for k in bassQ trebQ; do
	v=$(sed 's/--.*$//' "$UISTATE" | awk '/^M\.DEFAULTS/,/^}/' \
	    | grep -E "^[[:space:]]*$k[[:space:]]*=" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
	if [ -z "$v" ]; then
		echo "  FAIL  $k is not set in M.DEFAULTS"
		fail=1
	elif awk -v x="$v" 'BEGIN { exit !(x <= 1.0) }'; then
		echo "  ok    $k = $v"
	else
		echo "  FAIL  $k = $v exceeds 1.0 -- the shelf overshoots and the"
		echo "        overshoot is paid for in make-up volume"
		fail=1
	fi
done

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-defaults-single-source: FAILED"
	exit 1
fi
echo "check-defaults-single-source: one table, safe reset, shape within the ceiling"
