#!/bin/sh
# SBRadioEQ -- assert driving the UI did not mutate the user's saved settings.
#
#   sh tools/check-settings-unchanged.sh <before> <after>
#
# exit 0  identical
# exit 1  changed -- prints every key that moved
# exit 2  a file is missing or unreadable (NOT treated as "unchanged")
#
# WHY THIS EXISTS.
#
# tools/screenshot.sh drives the real UI by injecting input events. On its first
# real use a stray scroll reached an EQ cell that was in edit mode and moved the
# user's saved bassGain from 13.5 to 11.0 -- exactly five steps of the 0.5 dB
# gain increment (lua/uistate.lua: `v = v + delta * 0.5`). Nothing announced it.
#
# It was caught only because a screenshot happened to show a value that could be
# compared against a backup taken hours earlier for an unrelated reason. That is
# luck, not a process. Next time there may be no screenshot of the changed value,
# and the user's tuning is silently different.
#
# So the diff is not advisory and it is not a log line: a driving run that
# changed the settings FAILS.

set -e

BEFORE="${1:?usage: check-settings-unchanged.sh <before> <after>}"
AFTER="${2:?usage: check-settings-unchanged.sh <before> <after>}"

for f in "$BEFORE" "$AFTER"; do
	if [ ! -f "$f" ]; then
		echo "FAIL: $f is missing -- cannot prove the settings are unchanged"
		echo "      Absence is not evidence of no change. Treating as a failure."
		exit 2
	fi
	if [ ! -s "$f" ]; then
		echo "FAIL: $f is empty -- cannot prove the settings are unchanged"
		exit 2
	fi
done

if cmp -s "$BEFORE" "$AFTER"; then
	echo "  ok    settings unchanged by this run"
	exit 0
fi

echo "  FAIL  DRIVING THE UI CHANGED THE SAVED SETTINGS"
echo ""

# Report the keys that moved. The settings file is one line of key=value pairs
# inside braces, so split on commas rather than diffing lines -- a line diff on a
# single-line file just prints the whole file twice and names nothing.
keys() {
	tr ',{}' '\n\n\n' < "$1" | sed -n 's/^[[:space:]]*\([a-zA-Z_]*\)=\(.*\)$/\1 \2/p'
}

# `|| true` under set -e: join/grep returning no rows must not kill the report
# before it prints. The whole point of this branch is to explain the failure.
before_keys=$(keys "$BEFORE" || true)
after_keys=$(keys "$AFTER" || true)

echo "$before_keys" | while read -r k v; do
	[ -n "$k" ] || continue
	nv=$(echo "$after_keys" | sed -n "s/^$k //p")
	if [ "$nv" != "$v" ]; then
		printf '        %-14s %s  ->  %s\n' "$k" "$v" "${nv:-<removed>}"
	fi
done

echo "$after_keys" | while read -r k v; do
	[ -n "$k" ] || continue
	if ! echo "$before_keys" | grep -q "^$k "; then
		printf '        %-14s <absent>  ->  %s\n' "$k" "$v"
	fi
done

echo ""
echo "        Restore with:"
echo "          scp -O \"$BEFORE\" \$RADIO:/etc/squeezeplay/userpath/settings/SBRadioEQ.lua"
echo "        then REBOOT -- the running applet holds the changed values in"
echo "        memory and will write them back over the restored file."
exit 1
