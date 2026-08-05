#!/bin/sh
# SBRadioEQ -- on-screen text may not promise capabilities the code does not have.
#
#   sh tools/check-ui-claims.sh
#
# A comment that goes stale is read by maintainers. A STRING that goes stale is
# read by the person holding the Radio, and it tells them the device is doing
# something it is not. Both of the screens shown when baby_bsp is missing said
# "Any EQ already saved is still applied at startup" -- and one described a
# roughly one-second fallback. By then the shell writer had been deleted and the
# startup service went through the same BSP-only path, so on the one firmware
# where those screens can appear, neither sentence was true.
#
# This cannot check prose against behaviour in general. What it CAN do is forbid
# the specific claims this codebase has already outlived, so re-introducing one
# is caught rather than shipped. Each entry is a claim that was true once.
#
# Exit 0 clean, 1 a forbidden claim is on screen, 2 the gate could not run.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"
STRINGS="$HERE/applet/strings.txt"

[ -f "$APPLET" ]  || { echo "FAIL(2): $APPLET not found"; exit 2; }
[ -f "$STRINGS" ] || { echo "FAIL(2): $STRINGS not found"; exit 2; }

# ⛔ SCAN STRING LITERALS, NOT THE WHOLE FILE. This gate's own explanation above
# names every phrase it forbids; a whole-file scan reports itself. The applet's
# block comments go the same way -- they discuss the wording they replaced.
lits=$(awk '/^[[:space:]]*--\[\[/{inc=1} !inc{print} /^[[:space:]]*\]\]/{inc=0}' "$APPLET" \
	| sed 's/--.*$//' \
	| grep -o '"[^"]*"' || true)

# strings.txt is entirely user-facing; take the translation lines whole.
lits="$lits
$(grep -E "^	[A-Z][A-Z]	" "$STRINGS" || true)"

[ -n "$(printf '%s' "$lits" | tr -d '[:space:]')" ] || {
	echo "FAIL(2): no UI strings extracted -- this gate would pass by reading nothing."
	exit 2
}

bad=0
flag() {                                   # $1 = pattern, $2 = why
	hits=$(printf '%s\n' "$lits" | grep -iE "$1" || true)
	if [ -n "$hits" ]; then
		echo "FAIL: on-screen text claims: $2"
		printf '%s\n' "$hits" | sed 's/^/        /'
		bad=$((bad + 1))
	fi
}

# There is one codec writer. Nothing slower stands behind it.
flag 'fallback' \
     "a fallback writer exists. baby_bsp is the only one."

# Startup uses the same BSP-only apply. Without the module, nothing is applied --
# and these words only ever appear on the screens shown when it is missing.
flag 'applied at startup|applies at startup|still applied at boot' \
     "saved EQ is applied at startup regardless. It is not, without baby_bsp."

# The deleted shell path was the only thing that ever took ~1 s per write.
flag 'second per adjustment|a second per click' \
     "an adjustment takes about a second. That was the deleted shell writer."

# Compensation is best effort; it does not promise constant loudness.
flag 'without the music getting louder or quieter|volume stays the same' \
     "loudness never changes. When volume range runs out, the result is quieter."

echo ""
if [ "$bad" -eq 0 ]; then
	echo "check-ui-claims: on-screen text makes no superseded claim"
	exit 0
fi
echo "check-ui-claims: $bad superseded claim(s) on screen"
exit 1
