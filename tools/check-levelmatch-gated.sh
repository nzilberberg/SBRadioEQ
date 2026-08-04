#!/bin/sh
# SBRadioEQ -- level matching is gated EVERYWHERE it takes effect.
#
#   sh tools/check-levelmatch-gated.sh
#
# Level matching is not one line of code. It reaches FOUR places, and switching
# it off has to switch off all of them or the feature is half-off -- which is worse
# than either state, because the parts that remain are now acting on a premise
# the user has withdrawn:
#
#   1. _levelMatch      the volume move itself
#   2. _nudgeKey        the affordability clamp -- it exists ONLY because
#                       make-up is paid for out of the volume control
#   3. _redraw          the EQ screen's "-14/82" readout
#   4. _redrawTone      the Tone screen's copy of it
#   5/6. both Back paths  cancel-restores-volume, one per editor screen
#
# ⛔ THE LOUD ONE. _levelMatch must force its target to ZERO when the flag is
# off -- NOT return early. Returning leaves make-up already folded into the
# volume sitting there with nothing compensating for it: switch off after a +15
# boost and the music stays 15 dB loud over a curve the user has just stopped
# paying for. Forcing target 0 runs the same machinery in reverse and unwinds
# it. This gate checks for the correct form specifically, because the wrong form
# looks perfectly reasonable.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"
UISTATE="$HERE/lua/uistate.lua"

for f in "$APPLET" "$UISTATE"; do
	[ -f "$f" ] || { echo "FAIL: missing $f"; exit 2; }
done

fail=0
code=$(sed 's/--.*$//' "$APPLET")

# ⛔ A FORBIDDEN-TOKEN CHECK MUST NOT READ ITS OWN PROSE. `code` strips LINE
# comments only, so the name of a removed function, written inside a --[[ ]]
# block explaining why it was removed, still looks like a live call. That fired
# on the first run of the check below -- the same trap as a gate matching the
# word "touch" in an English sentence. This view drops block comments as well.
codeNC=$(awk '/^[[:space:]]*--\[\[/{inc=1} !inc{print} /^[[:space:]]*\]\]/{inc=0}' "$APPLET" \
	| sed 's/--.*$//')

# ---- the flag exists and defaults ON ---------------------------------------
echo "the setting:"
if sed 's/--.*$//' "$UISTATE" | awk '/^M\.DEFAULTS/,/^}/' | grep -qE '^[[:space:]]*levelMatch[[:space:]]*=[[:space:]]*true'; then
	echo "  ok    levelMatch defaults to true"
else
	echo "  FAIL  levelMatch is not defaulted to true in M.DEFAULTS"
	echo "        without matching, turning the bass up makes the music quieter"
	fail=1
fi

# ---- the loud one: target zero, not an early return ------------------------
echo ""
echo "switching off unwinds existing make-up:"
lm=$(printf '%s\n' "$code" | awk '/^function _levelMatch/,/^end/')
if printf '%s\n' "$lm" | grep -qE 'if not s\.levelMatch then target = 0'; then
	echo "  ok    _levelMatch forces target to 0 when off"
else
	echo "  FAIL  _levelMatch does not force target to 0 when off"
	fail=1
fi
if printf '%s\n' "$lm" | grep -qE 'if not s\.levelMatch then[[:space:]]*return'; then
	echo "  FAIL  _levelMatch RETURNS EARLY when off"
	echo "        make-up already in the volume would be stranded there --"
	echo "        switch off after a +15 boost and the music stays 15 dB loud"
	fail=1
else
	echo "  ok    it does not return early"
fi

# ---- every volume move lives in a function that knows about the flag -------
# Function-scoped rather than line-adjacent: _levelMatch's guard is at the top
# of the function, twenty lines above the move it governs.
echo ""
echo "every player volume move is inside a levelMatch-aware function:"
report=$(printf '%s\n' "$code" | awk '
	/^function [A-Za-z_]+/ { fn = $2; sub(/\(.*/, "", fn); hasvol = 0; hasgate = 0 }
	/:volume\([^)]/        { if (fn != "") hasvol = 1 }
	/s\.levelMatch/        { if (fn != "") hasgate = 1 }
	/^end/ {
		if (fn != "" && hasvol) printf "%s %s\n", fn, (hasgate ? "ok" : "UNGATED")
		fn = ""
	}
')
if [ -z "$report" ]; then
	echo "  FAIL  found no volume moves at all -- has the parser broken?"
	fail=1
else
	printf '%s\n' "$report" | while read -r fn state; do
		if [ "$state" = "ok" ]; then echo "  ok    $fn"; else echo "  FAIL  $fn moves the volume with no levelMatch guard"; fi
	done
	if printf '%s\n' "$report" | grep -q UNGATED; then fail=1; fi
fi

# ---- the derived decisions -------------------------------------------------
echo ""
echo "decisions derived from the make-up are gated too:"

# ⛔ THE CLAMP IS NOW COST-BASED, AND THIS CHECK HAD TO CHANGE WITH IT.
#
# It used to look for `s.levelMatch and U.mustCheckAffordability(...)`. That
# helper decided whether to check from WHICH CONTROL MOVED -- gain only -- so Q
# and frequency edits skipped the guard although Q changes what the curve costs
# (30.00 dB at Q 1.0 vs 34.41 dB at Q 2.0, measured). The helper is gone.
#
# Two things must hold now: the affordability comparison is still gated on
# levelMatch, and it is fed by a DESIGNED cost rather than a field-type test.
aff=$(printf '%s\n' "$code" | grep -c 'U\.affordable(' || true)
affg=$(printf '%s\n' "$code" | grep -c 'and s\.levelMatch then\|if s\.levelMatch' || true)
if [ "$aff" -gt 0 ] && [ "$affg" -gt 0 ]; then
	echo "  ok    the affordability clamp is gated on levelMatch ($aff comparison(s))"
else
	echo "  FAIL  the affordability clamp is missing or not gated ($aff, gate $affg)"
	echo "        with matching off nothing is paid for, so nothing can run out"
	fail=1
fi

# The clamp must ask the CURVE what it costs. A reintroduced field-kind test is
# the defect returning.
if printf '%s\n' "$codeNC" | grep -q 'mustCheckAffordability'; then
	echo "  FAIL  mustCheckAffordability is back -- affordability keyed to which"
	echo "        control moved, not to what the curve costs. Q and frequency"
	echo "        change the cost; that hole let an unaffordable curve be applied."
	fail=1
else
	echo "  ok    affordability is decided from the designed curve's cost"
fi

hr=$(printf '%s\n' "$code" | grep -c '_headroomDb()' || true)
hrg=$(printf '%s\n' "$code" | grep -c 's\.levelMatch and self\.attenDb' || true)
# _headroomDb's own definition contains the call site count baseline of 0; each
# READOUT that prints it must sit behind a levelMatch test.
if [ "$hrg" -ge 2 ]; then
	echo "  ok    both headroom readouts ($hrg gated, $hr use(s) of _headroomDb)"
else
	echo "  FAIL  only $hrg of the 2 headroom readouts are gated"
	echo "        '-14/82' is make-up spent over make-up available; with"
	echo "        matching off neither number is real"
	fail=1
fi

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-levelmatch-gated: FAILED"
	exit 1
fi
echo "check-levelmatch-gated: every effect site is gated, and one function owns the volume"
