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
#      gone and up to ~34 dB of compensation is not. The unwind must be
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
# Match on the NAME, not the full parameter list: this aborted (correctly, but
# needlessly) the moment `allowShell` was added as a second parameter. A gate
# keyed to a signature reports "cannot find it" for every ordinary refactor,
# which is the kind of noise that gets a gate switched off.
body=$(awk '/^function _applyNow\(self/{f=1} f{print} f&&/^end$/{exit}' "$APPLET")
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

# --- D. Reset Tone must not announce a reset that did not happen -----------
#
# Reset Tone is the documented pre-uninstall action. It used to call _applyNow,
# discard the result, store the flat settings, and log SBEQ-RESET success
# unconditionally -- so the one action that makes the device safe to remove could
# fail silently and report itself done. The success log must be conditional.
reset=$(awk '/^function resetToDefaults\(self\)/{f=1} f{print} f&&/^end$/{exit}' "$APPLET")
[ -n "$reset" ] || {
	echo "FAIL(2): could not extract resetToDefaults -- gate cannot verify it"
	exit 2
}
if echo "$reset" | grep -q 'SBEQ-RESET to defaults'; then
	if echo "$reset" | grep -qE '^[[:space:]]*if .*\bok\b.*then'; then
		echo "  ok   Reset Tone announces success only on a checked result"
	else
		echo "FAIL: resetToDefaults logs SBEQ-RESET success unconditionally."
		echo "      The pre-uninstall action can then fail while telling the user"
		echo "      it succeeded, leaving make-up gain in the player volume."
		bad=$((bad + 1))
	fi
else
	echo "  ok   Reset Tone does not emit an unconditional success log"
fi

# --- E. ONE OWNER for player volume ----------------------------------------
#
# ⛔⛔ THE CLASS THIS EXISTS FOR. The ordering fix put the volume move inside the
# PCM mute -- and both Back-cancel handlers went on doing their OWN
# player:volume() rollback beforehand, outside the mute, which is the same defect
# in a place the fix never swept. It was invisible to test_ordering, which drives
# the low-level function and never runs a UI handler.
#
# So the rule is structural rather than careful: exactly one function may write
# player volume, and it is the transaction-aware one. Anything else is the defect
# reappearing somewhere new.
# ⛔ MATCH THE CALL, NOT THE VARIABLE NAME. The first version of this check
# grepped `player:volume(` and a fixture calling the same method through a
# variable named `p` walked straight past it -- the gate would have enforced a
# naming convention while believing it enforced an invariant. `:volume(` with at
# least one argument is the WRITE; the read is getVolume().
owners=$(awk '
	/^function [A-Za-z_]/ { fn = $2; sub(/\(.*/, "", fn) }
	/:volume\([^)]/       { print (fn == "" ? "<top-level>" : fn) }
' "$APPLET" "$HERE"/lua/*.lua | sort -u)

[ -n "$owners" ] || {
	echo "FAIL(2): no player:volume() call found at all -- the gate cannot be"
	echo "         checking what it thinks it is checking."
	exit 2
}

strays=$(echo "$owners" | grep -v '^_levelMatch$' || true)
if [ -z "$strays" ]; then
	echo "  ok   player volume is written only by _levelMatch"
else
	echo "FAIL: player:volume() is called outside _levelMatch, by:"
	echo "$strays" | sed 's/^/        /'
	echo "      Only the transaction-aware path may move the volume -- anywhere"
	echo "      else is outside the PCM mute, which is the ordering defect."
	bad=$((bad + 1))
fi

# --- F. ONE OWNER for the codec controls ------------------------------------
#
# ⛔⛔ THE RULE ABOVE IS PER-FUNCTION, AND THAT IS NOT ENOUGH ON ITS OWN.
#
# Checks A-E inspect _applyNow by name. The ordering they protect -- mute, write
# the filter, reconcile the player volume WHILE STILL MUTED, unmute last -- is a
# property of the SEQUENCE, not of that function's name, so any second piece of
# code that drives the mixer directly is invisible to them and free to get the
# order wrong. That is not hypothetical: a recovery action written outside
# _applyNow unmuted first and lowered the volume afterwards, which is precisely
# the state the ordering exists to prevent, and every check above stayed green.
#
# So the applet does not touch codec controls at all. It calls the apply
# transaction; eqapply owns setMixer, the mute control and the enable bit. A UI
# file reaching for a mixer is the defect class, whatever order it happens to use.
# A comment-stripped view: this file's own prose names setMixer and MUTE_CTL when
# explaining why they belong in eqapply, and a check that reads its own
# explanation reports a defect that is not there.
#
# ⛔ AND IT MUST NOT BE EMPTY. The first version of this check referenced a
# variable that was never assigned, so it grepped an empty string, found nothing
# and printed "ok" -- a gate that passes because it reads nothing is worse than
# no gate, because the green is believed.
codeNC=$(awk '/^[[:space:]]*--\[\[/{inc=1} !inc{print} /^[[:space:]]*\]\]/{inc=0}' "$APPLET" \
	| sed 's/--.*$//')
[ -n "$codeNC" ] || {
	echo "FAIL(2): the comment-stripped applet view is empty -- this check would"
	echo "         pass by reading nothing."
	exit 2
}

appletMixer=$(printf '%s\n' "$codeNC" \
	| grep -nE ':setMixer\(|MUTE_CTL|NAME\.enable' || true)

if [ -z "$appletMixer" ]; then
	echo "  ok   the applet drives no codec control directly"
else
	echo "FAIL: the applet writes codec controls itself:"
	printf '%s\n' "$appletMixer" | sed 's/^/        /'
	echo "      Mute, enable and coefficients belong to eqapply's transaction,"
	echo "      which is the only place their ORDER is guaranteed."
	bad=$((bad + 1))
fi

echo ""
if [ "$bad" -eq 0 ]; then
	echo "check-apply-checked: a failed apply is unwound and visible"
	exit 0
fi
echo "check-apply-checked: $bad property/properties not held"
exit 1
