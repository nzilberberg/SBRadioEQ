#!/bin/sh
# SBRadioEQ -- a failed hardware apply must be UNWOUND and VISIBLE.
#
#   sh tools/check-apply-checked.sh
#
# WHAT THIS GUARDS, AND WHY IT IS NOT WHAT THE FIRST VERSION GUARDED
#
# The first version of this gate required every call site to consult the result
# of _applyNow() before calling storeSettings(). That encoded a MECHANISM, and
# the wrong one: persisting the desired curve is legitimate, the defect is the
# failure going unhandled. Written that way the gate would have fired on the
# correct fix -- and a gate that fires on correct code gets switched off. The
# rule now names the two PROPERTIES that actually have to hold, wherever the
# code chooses to implement them.
#
#   A. A failure must be VISIBLE.   self.hwError was set and logged and read by
#      nothing, so a failed write showed the user a graph of the curve it had
#      just failed to apply. A written-but-never-read field is not reporting.
#
#   B. A failure must be UNWOUND.   Refusing to add NEW make-up is half the job.
#      The previous curve's make-up is already in the player volume, and the
#      failure path has very likely dropped the filter -- so the attenuation is
#      gone and up to ~27 dB of compensation is not. The unwind must be
#      conditional on the bypass being CONFIRMED, not merely attempted.
#
#   C. The result must be RETURNABLE.  _applyNow returned nothing in both
#      branches, so no caller could tell applied from failed even if it wanted to.
#
# Exit 0 clean, 1 violations, 2 the gate could not run.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"

[ -f "$APPLET" ] || { echo "FAIL(2): $APPLET not found -- gate cannot run"; exit 2; }

# ⛔ REFUSE TO PASS VACUOUSLY. If _applyNow is renamed or restructured, a
# scan-for-a-pattern gate finds nothing and reports clean about a file it did not
# understand. An empty extraction is a harness failure, never a verdict.
body=$(awk '/^function _applyNow\(self\)/{f=1} f{print} f&&/^end$/{exit}' "$APPLET")
[ -n "$body" ] || {
	echo "FAIL(2): could not extract _applyNow from the applet."
	echo "         The function was renamed or reshaped -- this gate must not"
	echo "         report clean about code it cannot find."
	exit 2
}

bad=0

# --- A. the failure state is BRANCHED ON, not merely mentioned -------------
#
# ⛔ "NOT AN ASSIGNMENT" IS TOO WEAK A DEFINITION OF A READ, and this gate was
# written that way first. On the DEFECTIVE code it counted the `log:warn(...,
# self.hwError, ...)` line as a consumer and passed -- a false negative on the
# exact defect it exists to catch, found by asking what it would have said
# before the fix rather than by trusting the green.
#
# Logging is not reporting: syslog on a headless device is not a user-visible
# channel, and a comment mentioning the field counts for even less. What makes a
# failure visible is code that BRANCHES on it and draws something.
reads=$(grep -cE '(if|elseif)[[:space:]]+(not[[:space:]]+)?self\.hwError|self\.hwError[[:space:]]+and' "$APPLET" || true)
if [ "$reads" -eq 0 ]; then
	echo "FAIL: self.hwError is never branched on -- only assigned, logged, or"
	echo "      mentioned. A failed apply would be invisible: the screen keeps"
	echo "      showing the curve that was requested, not what the chip is running."
	bad=$((bad + 1))
else
	echo "  ok   the failure state is branched on in $reads place(s) -- it is shown"
fi

# --- B. the unwind, and its condition -------------------------------------
#
# ⛔ GREPPING THE WHOLE BODY FOR "safeBypassed" IS NOT A CHECK OF THE CONDITION.
# Written that way, this passed a fixture whose guard had been replaced by
# `if true then`, because the word still appeared in the log line below it. The
# guard has to be checked WHERE IT GUARDS -- immediately above the unwind.
unwind=$(echo "$body" | awk '
	/_levelMatch\(0\)/ { hit = NR
		for (j = NR - 3; j < NR; j++)
			if (j > 0 && prev[j] ~ /safeBypassed/) { print "guarded"; exit }
		print "unguarded"; exit
	}
	{ prev[NR] = $0 }
	END { if (!hit) print "absent" }
')
case "$unwind" in
	guarded)
		echo "  ok   make-up is unwound on failure, guarded by a CONFIRMED bypass" ;;
	unguarded)
		echo "FAIL: the unwind is not guarded by safeBypassed."
		echo "      Lowering the volume when the filter may still be applying its cut"
		echo "      is a guess. The confirmation is what makes the unwind safe."
		bad=$((bad + 1)) ;;
	*)
		echo "FAIL: _applyNow never unwinds the existing make-up on failure."
		echo "      Declining to ADD compensation is not enough -- the previous curve's"
		echo "      make-up stays in the player volume over a filter that has just been"
		echo "      bypassed. That is the loud-audio failure, reached from the other side."
		bad=$((bad + 1)) ;;
esac

# --- C. callers can tell applied from failed -------------------------------
#
# ⛔ CHECK THAT THE FUNCTION CANNOT FALL OFF ITS END -- not that a return exists
# somewhere. Two weaker versions of this check each passed a mutant:
#
#   grep 'return res'          the SUCCESS branch says that too.
#   last line matching return  once the failure return is gone, the last match
#                              is the success branch's, so removing the failure
#                              path's return reads as still present.
#
# The property is that the LAST STATEMENT of the body is a return carrying a
# value: a failure path that falls off the end returns nil, and nil is what every
# caller then has to interpret.
laststmt=$(echo "$body" | sed '$d' | grep -vE '^[[:space:]]*(--.*)?$' | grep -vE '^[[:space:]]*(\]\]|--\[\[)' | tail -1)
#
# ⛔ AND ANCHOR IT. `case "$laststmt" in *return\ *)` matches "return" ANYWHERE in
# the line, so `if false then return {...}` -- a statement that returns only on a
# condition that is never true -- read as a return. The third wrong version of
# this one check. Anchor at the start of the statement.
if echo "$laststmt" | grep -qE '^[[:space:]]*return[[:space:]]'; then
	echo "  ok   the failure path returns a result, so a caller can branch on it"
else
	echo "FAIL: _applyNow can fall off its end, returning nil to the caller."
	echo "      Its last statement is:$laststmt"
	echo "      A caller cannot distinguish that from a successful apply."
	bad=$((bad + 1))
fi

echo ""
if [ "$bad" -eq 0 ]; then
	echo "check-apply-checked: a failed apply is unwound and visible"
	exit 0
fi
echo "check-apply-checked: $bad property/properties not held"
exit 1
