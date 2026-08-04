#!/bin/sh
# GATE: device work must use a directory of ours, never the shared /tmp.
#
#   sh tools/check-device-workspace.sh
#
# ⛔⛔ THE INCIDENT. /tmp on the Radio is shared and writeable, and more than one
# session uses that device as a bench. On 2026-08-04 a parallel session working
# on an OpenVPN applet copied its own test_nospawn.lua into /tmp eleven minutes
# after ours landed. Our suite executed THEIR file and reported
#
#     test_nospawn passed=1 failed=6
#
# against this project -- six failures naming a policy module this repo has never
# contained, while our own test_nospawn.lua sat untouched on disk.
#
# It fails in the worst direction: the suite is red, the names look like ours,
# and the obvious reading is that the last change broke something. The tell was
# device timestamps (ours 08:25, theirs 08:36) and /tmp/openvpn.log beside them --
# not anything in the test output.
#
# THE RULE: any committed script that stages files onto the device, or runs from
# a directory there, must use a path named for this project. Then two sessions
# can share one Radio and neither can see the other's files.
#
# Exit 0 clean, 1 a shared-path use, 2 the gate could not run.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=/tmp/sbradioeq

scripts=$(ls "$HERE"/tools/*.sh 2>/dev/null || true)
[ -n "$scripts" ] || { echo "FAIL(2): no scripts found to scan -- gate cannot run"; exit 2; }

bad=""
n=0

for f in $scripts; do
	base=$(basename "$f")

	#[[ ⛔ THIS GATE MUST NOT SCAN ITSELF -- and the first version did.
	#
	# Its own grep pattern contains the forbidden string, so it reported itself as
	# a violation. That is the FOURTH gate in this project to match its own text:
	# a forbidden-token check matching the word in its explanation, a level-match
	# gate naming the function it forbids, a dupe gate reading a comment that
	# quoted a UI string, and now this. Stripping comments is not enough when the
	# pattern itself is code.
	#]]
	[ "$base" = "check-device-workspace.sh" ] && continue
	n=$((n + 1))

	# Only the parts that actually touch the device.
	body=$(sed 's/#.*$//' "$f")

	# Anything already under our own prefix is the CORRECT form, so it is filtered
	# out of every pattern rather than being excluded inside each regex.
	scan() { printf '%s\n' "$body" | grep -nE "$1" | grep -v "/tmp/sbradioeq" || true; }

	# 1. scp to the device's bare /tmp
	hits=$(scan '\$RADIO:/tmp/')
	# 2. running out of the device's bare /tmp
	hits2=$(scan 'cd /tmp[[:space:]]*&&')
	# 3. writing a fixed filename into the device's bare /tmp -- but only on a line
	#    that is talking to the device. Without that qualifier this matched a
	#    FIXTURE STRING in test-check-footprint.sh ("amixer >> /tmp/eq.state"),
	#    which is local test data and touches no Radio.
	hits3=$(scan '(\$SSH|\$RADIO).*>[[:space:]]*/tmp/[A-Za-z_]')

	for h in "$hits" "$hits2" "$hits3"; do
		[ -n "$h" ] || continue
		bad="$bad
  $base: $(printf '%s' "$h" | head -2 | tr '\n' ' ')"
	done
done

if [ -n "$bad" ]; then
	echo "check-device-workspace: shared /tmp used for device work:"
	printf '%s\n' "$bad"
	echo ""
	echo "Use a path under $PREFIX-<purpose> instead. Another session writes to"
	echo "that device too, and a name collision there runs their file as ours."
	exit 1
fi

echo "check-device-workspace: $n script(s), all device work is under $PREFIX-*"
exit 0
