#!/bin/sh
# SBRadioEQ -- bypass has exactly ONE state, and every control reads it.
#
#   sh tools/check-bypass-single-source.sh [file]
#
# THE INVARIANT. Bypass is reachable from three places -- hold the knob on the
# Equalizer, hold it on Tone, or tick "Tone Control" in the menu -- and the user
# asked that editing one edit them all. That is satisfied not by syncing three
# values but by there being ONE: `settings.enabled`. _applyNow reads it directly.
#
# TWO WAYS THIS BREAKS, both silent:
#
#   1. A control DISPLAYS a literal instead of the live flag. The Tone Control
#      checkbox shipped exactly like this while it was a placeholder --
#      `Checkbox("checkbox", function() end, true)` -- hardcoded on. Wire the
#      callback but leave the literal, and the box reads "on" every time the
#      menu opens, including right after a hold-to-bypass turned it off. It
#      looks correct and lies.
#
#   2. Someone adds a SECOND flag. A `bypassed` or `toneEnabled` field alongside
#      `enabled` gives two sources of truth that agree until they don't, and the
#      symptom is a bypass that comes back by itself.
#
# Neither crashes, neither reddens a test, and both are invisible until someone
# toggles bypass in one place and checks another.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
TARGET="${1:-$HERE/applet/SBRadioEQApplet.lua}"

[ -f "$TARGET" ] || { echo "FAIL: no such file: $TARGET"; exit 2; }

fail=0

# ---- 1. no second bypass flag ---------------------------------------------
echo "one source of truth:"
# COMMENTS ARE STRIPPED FIRST, and a rival must be ASSIGNED, not merely named.
# The first version of this check scanned raw text for the word "bypassed" and
# fired on the real applet -- the prose "While bypassed the filter applies no
# cut" is not a second flag. A gate that fails the correct implementation gets
# switched off, so the pattern has to describe a variable, not a word.
code=$(sed 's/--.*$//' "$TARGET")
rivals=$(printf '%s\n' "$code" \
         | grep -oE '\b(bypassed|toneEnabled|bypassEnabled|isBypassed|bypassState|eqEnabled)[[:space:]]*=' \
         | sed 's/[[:space:]]*=//' | sort -u || true)
if [ -n "$rivals" ]; then
	echo "  FAIL  a second bypass flag exists alongside settings.enabled:"
	printf '%s\n' "$rivals" | sed 's/^/          /'
	echo "        two sources of truth agree until they do not"
	fail=1
else
	echo "  ok    settings.enabled is the only bypass field"
fi

writes=$(grep -cE '\bs\.enabled[[:space:]]*=' "$TARGET" || true)
if [ "$writes" -ge 1 ]; then
	echo "  ok    bypass is written through s.enabled ($writes site(s))"
else
	echo "  FAIL  nothing writes s.enabled -- bypass cannot be toggled"
	fail=1
fi

# ---- 2. the Tone Control checkbox must READ the live flag ------------------
# Extract the menu item whose text is SBRADIOEQ_TONE_CONTROL, up to its `})`.
echo ""
echo "the Tone Control checkbox:"
block=$(awk '
	/SBRADIOEQ_TONE_CONTROL/ { inblk = 1 }
	inblk                    { print }
	inblk && /^[[:space:]]*\}\)/ { exit }
' "$TARGET")

if [ -z "$block" ]; then
	echo "  FAIL  no SBRADIOEQ_TONE_CONTROL item found"
	exit 1
fi

# The Checkbox's THIRD argument is its initial state. It must be derived from
# the live setting, not typed in.
#
# Checked as its own thing, BEFORE the "does the block mention enabled" test.
# Those are different questions and conflating them hid a real fixture: with a
# wired callback the block always contains `s.enabled = ...`, so a grep for
# "enabled" passes happily while the initial state is still a hardcoded `true`.
# The literal is the defect; look for it directly.
init=$(printf '%s\n' "$block" \
       | grep -E '^[[:space:]]*(true|false)\)[[:space:]]*,?[[:space:]]*$|,[[:space:]]*(true|false)\)' || true)

if [ -n "$init" ]; then
	echo "  FAIL  its initial state is a LITERAL, not the live flag:"
	printf '%s\n' "$init" | sed 's/^/          /'
	echo "        it will show that value even when bypass says otherwise --"
	echo "        open the menu after a hold-to-bypass and it reads the opposite"
	fail=1
elif printf '%s\n' "$block" | grep -qE 'getSettings\(\)\.enabled|s\.enabled' ; then
	echo "  ok    initial state is read from settings.enabled"
else
	echo "  FAIL  its initial state does not reference settings.enabled"
	fail=1
fi

# And its callback must WRITE the flag, not just look like it does.
if echo "$block" | grep -qE 's\.enabled[[:space:]]*='; then
	echo "  ok    its callback writes settings.enabled"
else
	echo "  FAIL  its callback does not write settings.enabled"
	echo "        a checkbox that accepts the press and changes nothing is worse"
	echo "        than one that is plainly disconnected"
	fail=1
fi

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-bypass-single-source: FAILED"
	exit 1
fi
echo "check-bypass-single-source: one flag, and every control reads it"
