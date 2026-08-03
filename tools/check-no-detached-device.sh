#!/bin/sh
# SBRadioEQ -- no committed script may detach work that touches the device.
#
#   sh tools/check-no-detached-device.sh
#
# WHAT THIS COSTS WHEN IT HAPPENS. An agent backgrounded a bench sweep on the
# Radio at 01:57. Its output file was still ZERO BYTES seven hours later, and
# the run had sat blocked that whole time waiting for a completion notification
# that never arrived. Seven hours, for a search that runs in minutes.
#
# WHY IT HANGS. A detached ssh to this box does not reliably signal completion:
# the remote `jive` can exit, or the channel can drop, without the local side
# ever seeing an end-of-stream. Nothing then wakes the waiter. Worse, there is
# no `timeout` command ON the device, so the remote end cannot bound itself
# either -- a runaway loop there is unkillable except by hand.
#
# THE RULE. Device work runs in the FOREGROUND, bounded by the size of the loop
# you write. tools/bench.sh is that path and has no background option by design.
#
# This gate reads the SHIPPED and COMMITTED scripts. It cannot police what an
# agent types at a shell -- that is what the brief is for -- but it does stop
# the pattern being committed and copied.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
fail=0

# Everything committed that could talk to the device.
FILES=$(find "$HERE/tools" "$HERE/test" -type f \( -name '*.sh' -o -name '*.lua' \) 2>/dev/null \
        | grep -v 'check-no-detached-device.sh' || true)

[ -n "$FILES" ] || { echo "FAIL: found no scripts to scan"; exit 2; }

echo "scanning $(printf '%s\n' "$FILES" | grep -c .) committed script(s):"

for f in $FILES; do
	# Comments stripped: these files DISCUSS backgrounding at length, and a gate
	# that fires on its own explanation gets switched off.
	code=$(sed 's/#.*$//; s/--.*$//' "$f")

	# An ssh/scp line that also detaches, on the same line.
	hits=$(printf '%s\n' "$code" | grep -nE '(ssh|scp)[^|]*&[[:space:]]*$' || true)
	if [ -n "$hits" ]; then
		echo "  FAIL  $(basename "$f") detaches a device command:"
		printf '%s\n' "$hits" | sed 's/^/          /'
		fail=1
	fi

	# nohup / disown anywhere near device work in the same file.
	if printf '%s\n' "$code" | grep -qE 'nohup|disown'; then
		if printf '%s\n' "$code" | grep -qE 'ssh|scp|RADIO'; then
			echo "  FAIL  $(basename "$f") uses nohup/disown in a file that talks to the device"
			fail=1
		fi
	fi
done

[ "$fail" -eq 0 ] && echo "  ok    no committed script detaches device work"

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-no-detached-device: FAILED"
	exit 1
fi
echo "check-no-detached-device: device work is all foreground"
