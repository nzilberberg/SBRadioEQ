#!/bin/sh
# SBRadioEQ -- settings must not be persisted after an apply nobody checked.
#
#   sh tools/check-apply-checked.sh
#
# ⛔ KNOWN RED as of build 42. This gate currently FAILS on the real applet, by
# design: it is the acceptance test for the audio-transaction work, written
# before the fix rather than after it. A gate authored after its fix passes on
# the first run and has never been seen to bite, which is not evidence of
# anything. It turns green when the call sites below start consulting a result.
#
# THE DEFECT IT GUARDS
#
# _applyNow() returns nothing, in both its success and its failure branch. So
# every caller that follows it with storeSettings() persists the REQUESTED curve
# as though it were the APPLIED one, and no caller can tell the difference.
#
# That is not cosmetic. On failure _applyNow deliberately does not run level
# matching -- correct, because raising the volume over attenuation that was never
# applied is the loud-audio bug this project already shipped once. But the make-up
# ALREADY folded into the player volume stays there, and the hardware may by then
# have been forced to bypass. The worst instance is Reset Tone: it flattens the
# curve, stores flat settings, logs success, and can leave up to ~27 dB of make-up
# over a flat curve with nothing on screen to say so.
#
# THE RULE
#
# A call to self:_applyNow() / self:_flushApply() whose return value is DISCARDED
# may not be followed, within a few lines, by self:storeSettings() or a success
# log. Binding the result is not enough on its own -- the bound name must actually
# be read before the persist, or it is a variable, not a check.
#
# Exit 0 clean, 1 violations, 2 the gate could not run.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"
LOOKAHEAD=4

[ -f "$APPLET" ] || { echo "FAIL(2): $APPLET not found -- gate cannot run"; exit 2; }

# ⛔ REFUSE TO PASS VACUOUSLY. If the apply calls are renamed or restructured,
# this gate would scan for a pattern that no longer exists, find nothing, and
# report clean about a file it did not understand. An empty match set is a
# harness failure here, never a verdict. (Same trap as check-footprint.sh's
# unreadable-RUNTIME abort.)
calls=$(grep -cE 'self:(_applyNow|_flushApply)\(\)' "$APPLET" || true)
if [ "$calls" -eq 0 ]; then
	echo "FAIL(2): no self:_applyNow()/self:_flushApply() calls found in the applet."
	echo "         Either the file changed shape or the pattern is stale -- this gate"
	echo "         must not report clean about a file it cannot read."
	exit 2
fi

report=$(awk -v LOOK="$LOOKAHEAD" '
	{ line[NR] = $0 }
	END {
		bad = 0
		for (i = 1; i <= NR; i++) {
			if (line[i] !~ /self:(_applyNow|_flushApply)\(\)/) continue

			# Is the result bound to a name?  local x = self:_applyNow()
			bound = 0; var = ""
			if (match(line[i], /^[ \t]*(local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*self:(_applyNow|_flushApply)\(\)/)) {
				bound = 1
				t = line[i]
				sub(/^[ \t]*/, "", t)
				sub(/^local[ \t]+/, "", t)
				sub(/[ \t]*=.*$/, "", t)
				var = t
			}

			# Look ahead for a persist / success log, and for a read of var.
			read = 0
			for (j = i + 1; j <= NR && j <= i + LOOK; j++) {
				if (bound && var != "" && line[j] ~ ("[^A-Za-z0-9_]" var "[^A-Za-z0-9_]?")) read = 1

				if (line[j] ~ /self:storeSettings\(\)/ || line[j] ~ /log:info\(/) {
					if (!bound) {
						printf "  line %d: %s\n", i, trim(line[i])
						printf "          -> line %d persists/announces: %s\n", j, trim(line[j])
						printf "          result of the apply is DISCARDED\n"
						bad++
					} else if (!read) {
						printf "  line %d: %s\n", i, trim(line[i])
						printf "          -> line %d persists/announces: %s\n", j, trim(line[j])
						printf "          %s is assigned but never read before the persist\n", var
						bad++
					}
					break
				}
			}
		}
		printf "COUNT=%d\n", bad
	}
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
' "$APPLET")

count=$(echo "$report" | sed -n 's/^COUNT=//p')
body=$(echo "$report" | grep -v '^COUNT=' || true)

if [ "$count" -eq 0 ]; then
	echo "check-apply-checked: clean -- every persist follows a checked apply ($calls apply calls)"
	exit 0
fi

echo "check-apply-checked: $count site(s) persist settings after an unchecked apply"
echo ""
echo "$body"
echo "the requested curve is being saved as though the hardware had taken it."
exit 1
