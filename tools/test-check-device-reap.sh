#!/bin/sh
# SBRadioEQ -- prove check-device-reap.sh can actually fail.
#
#   sh tools/test-check-device-reap.sh
#
# A gate that has only ever been seen passing has not been tested. Each fixture
# is a REAL way the orphan bug comes back:
#
#   * the reap block deleted (the state the tree was in when three orphaned
#     sweeps drove the load average to 3.29);
#   * the before-set capture deleted, leaving a reap with nothing to subtract;
#   * reaping BY NAME, which is worse than not reaping -- it kills SqueezePlay;
#   * discovery silently matching nothing, so the gate scans zero files and
#     reports clean about it.
#
# The last one is the quiet one and the reason the vacuous-pass guard exists:
# a gate that checks nothing passes loudest.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
GATE=tools/check-device-reap.sh

pass=0
fail=0

# Run the gate in a throwaway copy of tools/, after applying a mutation.
#   $1 label   $2 expected exit   $3 shell snippet run inside the copy
fixture() {
	label=$1; want=$2; mutate=$3
	tmp=$(mktemp -d)
	mkdir -p "$tmp/tools"
	cp "$HERE"/tools/*.sh "$tmp/tools/" 2>/dev/null || true
	( cd "$tmp" && eval "$mutate" ) || true

	got=0
	( cd "$tmp" && sh "$GATE" >/dev/null 2>&1 ) || got=$?

	if [ "$got" -eq "$want" ]; then
		pass=$((pass + 1)); printf '  ok   %-52s exit=%s\n' "$label" "$got"
	else
		fail=$((fail + 1)); printf '  FAIL %-52s exit=%s want=%s\n' "$label" "$got" "$want"
	fi
	rm -rf "$tmp"
}

echo "=== check-device-reap fixtures ==="

# CONTROL. The real tree must pass, or every failure below is meaningless.
fixture "the untouched tree passes" 0 "true"

fixture "bench.sh with its reap deleted" 1 \
	"sed -i 's/kill -9/echo would-kill/g' tools/bench.sh"

fixture "run-suite.sh with its reap deleted" 1 \
	"sed -i 's/kill -9/echo would-kill/g' tools/run-suite.sh"

fixture "the before-set capture removed" 1 \
	"sed -i 's/pidof jive/true/g' tools/bench.sh"

fixture "reaping by name (pkill) instead of by set" 1 \
	"sed -i 's/kill -9\$STRAY/pkill jive/' tools/bench.sh"

fixture "reaping by name (killall) instead of by set" 1 \
	"sed -i 's/kill -9\$STRAY/killall jive/' tools/bench.sh"

fixture "reaping the whole pidof set" 1 \
	"sed -i 's/kill -9\$STRAY/kill -9 \$(pidof jive)/' tools/bench.sh"

#[[ THE EXEMPTION MUST ARGUE FOR ITSELF.
#
# deploy.sh kills every jive BY NAME deliberately -- stopping SqueezePlay is what
# deploying does. That is a genuine false positive for the kill-by-name rule, so
# an exemption exists. These two fixtures are what keep it from becoming a shrug:
# the marker must carry a real reason, and it must be the MARKER doing the work,
# not an accident of matching.
#]]
fixture "REAP-EXEMPT with too short a reason" 1 \
	"sed -i 's/^# REAP-EXEMPT:.*/# REAP-EXEMPT: because/' tools/deploy.sh"

fixture "deploy.sh fails once its exemption is removed" 1 \
	"sed -i '/REAP-EXEMPT/d' tools/deploy.sh"

# THE QUIET ONE. If discovery stops matching, the gate scans nothing. Without the
# vacuous-pass guard this fixture exits 0 and the suite reads green while the
# whole class is unguarded.
fixture "discovery matches nothing (gate must not pass vacuously)" 1 \
	"rm -f tools/run-suite.sh && sed -i 's/jive/JIVE_RENAMED/g' tools/bench.sh"

echo ""
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
