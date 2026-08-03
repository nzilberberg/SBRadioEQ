#!/bin/sh
# SBRadioEQ -- what is drawn ON the editing fader bar must stay readable.
#
#   sh tools/check-edit-contrast.sh [file]
#
# THE DESIGN. Editing a fader fills its BAR with the skin's teal (EDIT_TOP ->
# EDIT_BOT, the same constants the EQ screen's editing cell uses). The row keeps
# its dark selection gradient and its light text; only the bar lights up.
#
# THE FAILURE THIS CATCHES. Three marks live INSIDE that bar and are drawn in
# translucent white or teal when it is dark:
#
#   fillCol    the centre-out fill, teal at 38% -- on a teal bar, invisible
#   axisCol    the centre detent, white at 30%  -- on a teal bar, invisible
#   needleCol  the needle's core
#
# Miss one and nothing crashes, nothing warns, and no test reddens. The mark
# simply disappears in the one state an idle screenshot never shows. The centre
# detent vanishing is the worst of them: it is how "flat" is found without
# reading the number.
#
# WHY THESE THREE BY NAME, rather than "every literal in the branch". The first
# version of this gate did exactly that and was WRONG, in a way worth recording:
# it flagged the bar's own teal background and the needle's white halo, both of
# which are light ON PURPOSE. A gate that fires on the correct implementation
# gets switched off, and then it defends nothing. The rule is not "everything is
# dark" -- it is "the marks that sit on the light bar are dark", and those marks
# have names.
#
# The needle deliberately draws a LIGHT halo under its dark core, because it
# crosses the bar: dark panel above and below, teal between, so no single colour
# works for its whole length. The halo is not checked; the core is.
#
# Luminance is Rec. 601 on the RGB bytes. Alpha is ignored -- a mark of the
# wrong hue is wrong however transparent it is.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
TARGET="${1:-$HERE/applet/SBRadioEQApplet.lua}"
LUMA_MAX="${LUMA_MAX:-90}"     # 0..255; above this is "light"

[ -f "$TARGET" ] || { echo "FAIL: no such file: $TARGET"; exit 2; }

fail=0

# ---- 1. the shared constants, not a private re-invention -------------------
echo "the edit state uses the shared constants:"
for c in EDIT_TOP EDIT_BOT C_EDIT_INK; do
	n=$(grep -cE "\b$c\b" "$TARGET" || true)
	if [ "$n" -ge 2 ]; then
		echo "  ok    $c referenced ($n)"
	else
		echo "  FAIL  $c defined but not used by any screen's edit state"
		fail=1
	fi
done

# ---- 2. the marks drawn ON the bar must be dark ----------------------------
echo ""
echo "marks drawn on the light editing bar:"

# The editing branch only: between `if editing then` and its `else`.
branch=$(awk '
	/if editing then/            { inblk = 1; next }
	inblk && /^[[:space:]]*else/ { inblk = 0 }
	inblk                        { print }
' "$TARGET")

if [ -z "$branch" ]; then
	echo "  FAIL  no `if editing then` branch found -- has the edit state been removed?"
	exit 1
fi

# Named constants this gate can resolve, so a mark may be written either as a
# literal or as the shared constant.
resolve() {
	case "$1" in
		C_EDIT_INK) grep -oE '^local C_EDIT_INK[[:space:]]*=[[:space:]]*0x[0-9A-Fa-f]{8}' "$TARGET" \
		            | grep -oE '0x[0-9A-Fa-f]{8}' ;;
		C_HILITE)   grep -oE '^local C_HILITE[[:space:]]*=[[:space:]]*0x[0-9A-Fa-f]{8}' "$TARGET" \
		            | grep -oE '0x[0-9A-Fa-f]{8}' ;;
		C_AXIS)     grep -oE '^local C_AXIS[[:space:]]*=[[:space:]]*0x[0-9A-Fa-f]{8}' "$TARGET" \
		            | grep -oE '0x[0-9A-Fa-f]{8}' ;;
		C_GRID)     grep -oE '^local C_GRID[[:space:]]*=[[:space:]]*0x[0-9A-Fa-f]{8}' "$TARGET" \
		            | grep -oE '0x[0-9A-Fa-f]{8}' ;;
		0x*)        echo "$1" ;;
		*)          echo "" ;;
	esac
}

for mark in fillCol axisCol needleCol; do
	rhs=$(echo "$branch" | grep -E "^[[:space:]]*$mark[[:space:]]*=" \
	      | head -1 | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')

	if [ -z "$rhs" ]; then
		echo "  FAIL  $mark is not assigned in the editing branch"
		echo "        it would keep its dark-bar colour and vanish on the teal"
		fail=1
		continue
	fi

	val=$(resolve "$rhs")
	if [ -z "$val" ]; then
		echo "  FAIL  $mark = $rhs -- this gate cannot resolve that to a colour"
		echo "        use a literal or one of the constants it knows, so the"
		echo "        contrast stays checkable"
		fail=1
		continue
	fi

	luma=$(echo "$val" | awk '{
		h = substr($0, 3)
		printf "%d", 0.299*strtonum("0x" substr(h,1,2)) \
		           + 0.587*strtonum("0x" substr(h,3,2)) \
		           + 0.114*strtonum("0x" substr(h,5,2))
	}')

	if [ "$luma" -le "$LUMA_MAX" ]; then
		echo "  ok    $mark = $rhs  luma=$luma"
	else
		echo "  FAIL  $mark = $rhs  luma=$luma -- LIGHT, on a light bar"
		echo "        this mark will wash out while the fader is being edited"
		fail=1
	fi
done

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-edit-contrast: FAILED"
	exit 1
fi
echo "check-edit-contrast: the editing bar's marks are readable"
